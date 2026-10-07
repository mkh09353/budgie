import AVFoundation

/// Streams captured audio of any format into a 16 kHz mono 16-bit WAV, the
/// format parakeet.cpp transcribes. One converter is kept for the whole file so
/// the resampler's state carries across buffers. Not thread-safe: call every
/// method from one queue.
final class PCMFileWriter {
    let url: URL
    private(set) var framesWritten: AVAudioFramePosition = 0
    /// Sees every 16 kHz mono Float32 buffer as it is written, silence included.
    var onWrite: ((AVAudioPCMBuffer) -> Void)?

    private var file: AVAudioFile?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(url: URL) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
    }

    var secondsWritten: Double { Double(framesWritten) / outputFormat.sampleRate }

    /// Pads the file with silence, used to line a stream up with the meeting's
    /// start when its first buffer arrives late.
    func appendSilence(seconds: Double) throws {
        var remaining = AVAudioFrameCount(max(0, seconds) * outputFormat.sampleRate)
        while remaining > 0 {
            let count = min(remaining, 16_000)
            guard let silence = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: count) else { return }
            silence.frameLength = count  // AVAudioPCMBuffer memory starts zeroed
            try write(silence)
            remaining -= count
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        if buffer.format == outputFormat {
            try write(buffer)
            return
        }
        let converter = try converter(for: buffer.format)
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // Supply the buffer once, then report "no data now" rather than end of
        // stream, so the converter keeps its resampler state for the next call.
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw error ?? NSError(domain: "Budgie.PCMFileWriter", code: 1)
        }
        try write(output)
    }

    /// Closes the file; AVAudioFile finalizes the WAV header when released.
    func finish() {
        file = nil
        converter = nil
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file, buffer.frameLength > 0 else { return }
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        onWrite?(buffer)
    }

    private func converter(for format: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, let converterInputFormat, converterInputFormat == format {
            return converter
        }
        guard let created = AVAudioConverter(from: format, to: outputFormat) else {
            throw NSError(domain: "Budgie.PCMFileWriter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Cannot convert \(format) to 16 kHz mono"
            ])
        }
        created.downmix = true
        converter = created
        converterInputFormat = format
        return created
    }
}

/// Perceptual input level for meters.
enum AudioLevel {
    /// RMS of a float buffer mapped to 0...1 over roughly -50 dB ... 0 dB.
    /// Reads every channel, interleaved or not.
    static func normalized(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        var count = 0
        if buffer.format.isInterleaved {
            let samples = frames * channelCount
            for i in 0..<samples { sum += channels[0][i] * channels[0][i] }
            count = samples
        } else {
            for ch in 0..<channelCount {
                for i in 0..<frames { sum += channels[ch][i] * channels[ch][i] }
            }
            count = frames * channelCount
        }
        let rms = (sum / Float(max(count, 1))).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}

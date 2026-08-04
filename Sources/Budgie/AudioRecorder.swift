import AVFoundation

/// Captures microphone audio while the key is held, then writes it out as a
/// 16 kHz mono 16-bit WAV for the Punctuated engine to transcribe.
final class AudioRecorder {
    /// Called on the main thread with a live input level (0...1) while recording.
    var onLevel: ((Float) -> Void)?
    /// Called from the audio tap with each captured buffer.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSCondition()
    private var buffers: [AVAudioPCMBuffer] = []
    private var inputFormat: AVAudioFormat?
    private var recording = false
    private var activeCallbacks = 0

    func start() {
        lock.lock()
        guard !recording else {
            lock.unlock()
            return
        }
        buffers.removeAll()
        recording = true
        lock.unlock()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            NSLog("Budgie: no input format — is microphone access granted?")
            lock.lock(); recording = false; lock.unlock()
            return
        }
        inputFormat = format

        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(StreamingRuntimePolicy.audioTapBufferFrames),
            format: format
        ) { [weak self] buffer, _ in
            guard let self, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            self.lock.lock()
            guard self.recording else {
                self.lock.unlock()
                return
            }
            self.activeCallbacks += 1
            let onBuffer = self.onBuffer
            if onBuffer == nil {
                self.buffers.append(copy)
            }
            self.lock.unlock()

            if let onBuffer {
                // Live mode owns the copied buffer and processes it immediately;
                // keeping a second copy for a WAV that will never be written
                // makes memory grow for the full duration of the dictation.
                onBuffer(copy)
            }
            self.reportLevel(of: buffer)

            self.lock.lock()
            self.activeCallbacks -= 1
            if self.activeCallbacks == 0 {
                self.lock.broadcast()
            }
            self.lock.unlock()
        }

        do {
            try engine.start()
        } catch {
            NSLog("Budgie: audio engine failed to start: \(error)")
            lock.lock(); recording = false; lock.unlock()
            input.removeTap(onBus: 0)
            waitForActiveCallbacks()
        }
    }

    /// Stops capture and returns the WAV file URL, or nil if nothing usable.
    func stop(shouldWriteWav: Bool = true) -> URL? {
        lock.lock()
        guard recording else {
            lock.unlock()
            return nil
        }
        recording = false
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        while activeCallbacks > 0 {
            lock.wait()
        }
        let captured = buffers
        buffers.removeAll()
        lock.unlock()
        DispatchQueue.main.async { self.onLevel?(0) }
        guard shouldWriteWav else { return nil }
        return writeWav(from: captured)
    }

    private func waitForActiveCallbacks() {
        lock.lock()
        while activeCallbacks > 0 {
            lock.wait()
        }
        lock.unlock()
    }

    /// Computes an RMS level from a buffer and maps it to a perceptual 0...1
    /// scale (roughly -50 dB ... 0 dB), then reports it on the main thread.
    private func reportLevel(of buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        DispatchQueue.main.async { self.onLevel?(level) }
    }

    private func writeWav(from chunks: [AVAudioPCMBuffer]) -> URL? {
        guard let inFmt = inputFormat, !chunks.isEmpty else { return nil }

        let totalFrames = chunks.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard Double(totalFrames) >= inFmt.sampleRate * Config.minRecordingSeconds else { return nil }

        // Concatenate every captured chunk into one contiguous buffer.
        guard let combined = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: totalFrames) else { return nil }
        var offset = 0
        let channels = Int(inFmt.channelCount)
        for chunk in chunks {
            guard let src = chunk.floatChannelData, let dst = combined.floatChannelData else { continue }
            let frames = Int(chunk.frameLength)
            for ch in 0..<channels {
                memcpy(dst[ch] + offset, src[ch], frames * MemoryLayout<Float>.size)
            }
            offset += frames
        }
        combined.frameLength = totalFrames

        // Resample to 16 kHz mono.
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFmt, to: outFmt) else { return nil }

        let outCapacity = AVAudioFrameCount(Double(totalFrames) * 16_000.0 / inFmt.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity) else { return nil }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return combined
        }
        if status == .error {
            NSLog("Budgie: resample failed: \(String(describing: convError))")
            return nil
        }

        // Write a 16-bit PCM WAV; AVAudioFile converts the float buffer on write.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("budgie-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: outBuf)
            return url
        } catch {
            NSLog("Budgie: failed to write WAV: \(error)")
            return nil
        }
    }
}

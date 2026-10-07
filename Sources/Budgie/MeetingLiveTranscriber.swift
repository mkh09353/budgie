import AVFoundation

/// A slice of one meeting stream: 16 kHz mono samples starting `offset`
/// seconds into the meeting.
struct AudioChunk {
    let speaker: Speaker
    let offset: TimeInterval
    let samples: [Float]

    static let sampleRate: Double = 16_000

    var duration: TimeInterval { Double(samples.count) / Self.sampleRate }

    /// True when no 100 ms window rises above about -60 dBFS. Core Audio
    /// delivers digital silence for a quiet call, so most of "Them" while you
    /// talk is skipped without running the model. Set low on purpose: a quiet
    /// voice must never be mistaken for silence, while noise only costs time.
    var isSilent: Bool {
        let window = Int(Self.sampleRate / 10)
        var index = 0
        while index < samples.count {
            let end = min(index + window, samples.count)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            if (sum / Float(end - index)).squareRoot() > 0.001 { return false }
            index = end
        }
        return true
    }
}

/// Cuts one stream into chunks of about `target` seconds, each ending at the
/// quietest moment of its last stretch so words are not split between chunks.
/// Not thread-safe: feed it from the stream's queue.
final class AudioChunker {
    let speaker: Speaker
    private let target: TimeInterval
    private let onChunk: (AudioChunk) -> Void
    private var pending: [Float] = []
    private var pendingOffset: TimeInterval = 0

    init(speaker: Speaker, target: TimeInterval = 60, onChunk: @escaping (AudioChunk) -> Void) {
        self.speaker = speaker
        self.target = target
        self.onChunk = onChunk
    }

    /// Takes 16 kHz mono Float32 buffers, as `PCMFileWriter` writes them.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        let targetCount = Int(target * AudioChunk.sampleRate)
        while pending.count >= targetCount {
            emit(count: cutPoint(before: targetCount))
        }
    }

    /// Emits whatever is left; call once the stream has stopped.
    func finish() {
        if !pending.isEmpty { emit(count: pending.count) }
    }

    private func emit(count: Int) {
        let chunk = AudioChunk(speaker: speaker, offset: pendingOffset, samples: Array(pending[..<count]))
        pending.removeFirst(count)
        pendingOffset += chunk.duration
        onChunk(chunk)
    }

    /// The middle of the quietest 300 ms in the last quarter of the chunk.
    private func cutPoint(before end: Int) -> Int {
        let hop = Int(AudioChunk.sampleRate / 10)
        let searchStart = end - end / 4
        var energies: [Float] = []
        var index = searchStart
        while index + hop <= end {
            var sum: Float = 0
            for i in index..<(index + hop) { sum += pending[i] * pending[i] }
            energies.append(sum)
            index += hop
        }
        guard energies.count >= 3 else { return end }
        var best = 0
        var bestEnergy = Float.greatestFiniteMagnitude
        for i in 0...(energies.count - 3) {
            let energy = energies[i] + energies[i + 1] + energies[i + 2]
            if energy < bestEnergy {
                bestEnergy = energy
                best = i
            }
        }
        return searchStart + (best + 1) * hop + hop / 2
    }
}

/// How far live transcription has got, for the popover while recording.
struct MeetingLiveProgress: Equatable {
    /// Everything before this point in the meeting has been transcribed.
    var through: TimeInterval
    /// The latest line said, echo removed.
    var lastLine: TranscriptLine?
}

/// Transcribes a meeting while it records, a chunk at a time, so stopping only
/// waits for the last chunk of each stream. Chunks run one at a time on a
/// background queue in the order they were cut.
final class MeetingLiveTranscriber {
    private let engine: StandardTranscriber
    private let queue = DispatchQueue(label: "com.maxheadley.budgie.meeting-chunks", qos: .utility)
    private var words: [Speaker: [TranscriptWord]] = [.me: [], .them: []]
    /// Where each stream's chunks have been transcribed up to.
    private var done: [Speaker: TimeInterval] = [.me: 0, .them: 0]
    private var failure: Error?
    private let temporaryDirectory: URL

    /// Called on the transcription queue as each chunk starts.
    var onChunkStart: ((Speaker) -> Void)?
    /// Called on the transcription queue after each chunk.
    var onProgress: ((MeetingLiveProgress) -> Void)?

    init(engine: StandardTranscriber) {
        self.engine = engine
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("budgie-meeting-\(UUID().uuidString)", isDirectory: true)
    }

    /// Thread-safe; chunks may arrive from either stream's queue.
    func submit(_ chunk: AudioChunk) {
        queue.async { self.transcribe(chunk) }
    }

    /// Calls `completion` on the main queue once every submitted chunk is done,
    /// with each stream's words in meeting time, or the first error.
    func finish(completion: @escaping (Result<(me: [TranscriptWord], them: [TranscriptWord]), Error>) -> Void) {
        queue.async {
            try? FileManager.default.removeItem(at: self.temporaryDirectory)
            let result: Result<(me: [TranscriptWord], them: [TranscriptWord]), Error>
            if let failure = self.failure {
                result = .failure(failure)
            } else {
                result = .success((me: self.words[.me] ?? [], them: self.words[.them] ?? []))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func transcribe(_ chunk: AudioChunk) {
        // After one failure the meeting is re-transcribed from its files.
        guard failure == nil else { return }
        defer {
            done[chunk.speaker] = chunk.offset + chunk.duration
            reportProgress()
        }
        guard chunk.duration >= 0.3, !chunk.isSilent else { return }
        onChunkStart?(chunk.speaker)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let wav = temporaryDirectory.appendingPathComponent("chunk.wav")
            try write(chunk, to: wav)
            let json = try engine.transcribeJSONWithVAD(wav)
            let document = try JSONDecoder().decode(ParakeetJSONDocument.self, from: Data(json.utf8))
            words[chunk.speaker, default: []] += document.words.map {
                TranscriptWord(w: $0.w, start: $0.start + chunk.offset, end: $0.end + chunk.offset)
            }
        } catch {
            NSLog("Budgie: meeting chunk at \(chunk.offset)s failed: \(error)")
            failure = error
        }
    }

    private func reportProgress() {
        guard let onProgress, failure == nil else { return }
        let through = min(done[.me] ?? 0, done[.them] ?? 0)
        let lines = MeetingTranscript.merge(
            me: words[.me] ?? [], them: words[.them] ?? [],
            started: Date(), duration: through, heardSystemAudio: true
        ).lines
        // Prefer a line both streams have caught up with, so "Them" can't
        // appear to answer something "Me" hasn't been transcribed saying yet.
        let lastLine = lines.last { $0.start < through } ?? lines.last
        onProgress(MeetingLiveProgress(through: through, lastLine: lastLine))
    }

    private func write(_ chunk: AudioChunk, to url: URL) throws {
        let writer = try PCMFileWriter(url: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate, channels: 1, interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else {
            return
        }
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
        }
        try writer.append(buffer)
        writer.finish()
    }
}

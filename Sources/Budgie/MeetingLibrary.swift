import AVFoundation

/// Written when a meeting starts and completed when it stops, so a recording
/// can be transcribed again later from its folder alone.
struct MeetingInfo: Codable {
    var started: Date
    var duration: TimeInterval?
    var heardSystemAudio: Bool?
    var heardMicAudio: Bool?
    /// The first transcript line, saved at transcription so listing meetings
    /// never has to parse a transcript.
    var preview: String?
}

/// One meeting folder, as the popover lists it.
struct MeetingSummary: Identifiable, Equatable {
    let folder: URL
    let started: Date
    let duration: TimeInterval?
    /// The first transcript line, or nil before transcription.
    let preview: String?
    let hasTranscript: Bool

    var id: URL { folder }
    var transcriptURL: URL { folder.appendingPathComponent(MeetingLibrary.transcriptFileName) }
}

enum MeetingStage: Equatable {
    case downloadingModel
    case transcribingMe
    case transcribingThem
    case saving

    var label: String {
        switch self {
        case .downloadingModel: return "Downloading the speech model…"
        case .transcribingMe:   return "Transcribing your mic…"
        case .transcribingThem: return "Transcribing the call…"
        case .saving:           return "Saving the transcript…"
        }
    }
}

/// Meeting folders on disk: `<root>/2026-10-07-1430/` holding `me.wav`,
/// `them.wav`, `meeting.json` and, once transcribed, `transcript.md` and
/// `transcript.json`. Plain files, so Claude, Codex or anything else can read
/// a meeting straight from the folder.
enum MeetingLibrary {
    static let infoFileName = "meeting.json"
    static let transcriptFileName = "transcript.md"
    static let transcriptJSONFileName = "transcript.json"

    static func createFolder(in root: URL, started: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let base = formatter.string(from: started)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        try writeInfo(MeetingInfo(started: started), to: folder)
        return folder
    }

    static func writeInfo(_ info: MeetingInfo, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: folder.appendingPathComponent(infoFileName), options: .atomic)
    }

    static func readInfo(from folder: URL) throws -> MeetingInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: folder.appendingPathComponent(infoFileName))
        return try decoder.decode(MeetingInfo.self, from: data)
    }

    /// Meetings in `root`, newest first.
    static func list(in root: URL, limit: Int = 30) -> [MeetingSummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        // Only the small meeting.json files are read; this runs each time the
        // popover opens.
        let summaries: [MeetingSummary] = folders.compactMap { folder in
            guard let info = try? readInfo(from: folder) else { return nil }
            let hasTranscript = FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(transcriptFileName).path
            )
            return MeetingSummary(
                folder: folder,
                started: info.started,
                duration: info.duration,
                preview: hasTranscript ? (info.preview ?? "") : nil,
                hasTranscript: hasTranscript
            )
        }
        return Array(summaries.sorted { $0.started > $1.started }.prefix(limit))
    }

    /// Transcribes both channels of a recorded meeting from its files and
    /// saves the transcript. Used to retry a meeting, and when live
    /// transcription failed. Blocks; call it off the main thread. `progress`
    /// is called on the calling queue.
    static func transcribe(
        folder: URL, engine: StandardTranscriber,
        progress: (MeetingStage) -> Void
    ) throws -> MeetingTranscript {
        if !StandardTranscriber.standardModelAvailable { progress(.downloadingModel) }
        progress(.transcribingMe)
        let me = try words(in: folder.appendingPathComponent(MeetingRecorder.meFileName), engine: engine)
        progress(.transcribingThem)
        let them = try words(in: folder.appendingPathComponent(MeetingRecorder.themFileName), engine: engine)
        progress(.saving)
        return try save(folder: folder, me: me, them: them)
    }

    /// Merges each channel's words and writes `transcript.md`,
    /// `transcript.json` and the preview.
    static func save(folder: URL, me: [TranscriptWord], them: [TranscriptWord]) throws -> MeetingTranscript {
        let info = try readInfo(from: folder)
        let duration = info.duration ?? audioDuration(of: folder.appendingPathComponent(MeetingRecorder.meFileName))
        let transcript = MeetingTranscript.merge(
            me: me, them: them, started: info.started, duration: duration,
            heardSystemAudio: info.heardSystemAudio ?? true,
            heardMicAudio: info.heardMicAudio ?? true
        )
        try transcript.json().write(to: folder.appendingPathComponent(transcriptJSONFileName), options: .atomic)
        try Data(transcript.markdown().utf8)
            .write(to: folder.appendingPathComponent(transcriptFileName), options: .atomic)
        var updated = info
        updated.preview = transcript.lines.first?.text ?? "No speech detected"
        try writeInfo(updated, to: folder)
        return transcript
    }

    private static func words(in wav: URL, engine: StandardTranscriber) throws -> [TranscriptWord] {
        // parakeet.cpp rejects an empty file; a channel that never got audio
        // simply has no words.
        guard audioDuration(of: wav) >= 0.3 else { return [] }
        let json = try engine.transcribeJSONWithVAD(wav)
        return try JSONDecoder().decode(ParakeetJSONDocument.self, from: Data(json.utf8)).words
    }

    private static func audioDuration(of wav: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: wav) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

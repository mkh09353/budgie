import Foundation

/// Who said a line. There is no diarization: the microphone is "Me" and
/// everything the Mac played is "Them".
enum Speaker: String, Codable {
    case me = "Me"
    case them = "Them"
}

struct TranscriptLine: Codable, Equatable {
    let speaker: Speaker
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// A word with timestamps, as parakeet.cpp's JSON documents give them.
struct TranscriptWord: Decodable, Equatable {
    let w: String
    let start: TimeInterval
    let end: TimeInterval
}

/// A finished meeting transcript: both channels merged into one timeline.
struct MeetingTranscript: Codable, Equatable {
    var started: Date
    var duration: TimeInterval
    var heardSystemAudio: Bool
    var heardMicAudio: Bool
    var lines: [TranscriptLine]

    /// A pause longer than this starts a new line.
    static let lineBreakGap: TimeInterval = 1.2
    /// A line this long breaks at the next sentence end.
    static let longLineWords = 60
    /// A "Me" word is echo when "Them" said the same word this close in time.
    static let echoWindow: TimeInterval = 0.6
    /// Echo is removed only in runs at least this long, so a lone "yeah" said
    /// over someone else's "yeah" survives.
    static let minimumEchoRun = 2

    /// Builds the merged timeline from each channel's words.
    static func merge(
        me: [TranscriptWord], them: [TranscriptWord],
        started: Date, duration: TimeInterval,
        heardSystemAudio: Bool, heardMicAudio: Bool = true
    ) -> MeetingTranscript {
        let theirLines = lines(from: them, speaker: .them)
        let myLines = lines(from: removingEcho(from: me, heardIn: them), speaker: .me)
        let merged = (myLines + theirLines).sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.speaker == .them
        }
        return MeetingTranscript(
            started: started, duration: duration,
            heardSystemAudio: heardSystemAudio, heardMicAudio: heardMicAudio, lines: merged
        )
    }

    /// Groups one channel's words into lines at pauses and long sentences.
    static func lines(from words: [TranscriptWord], speaker: Speaker) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var current: [TranscriptWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.w).joined(separator: " ")
            lines.append(TranscriptLine(speaker: speaker, start: first.start, end: last.end, text: text))
            current.removeAll()
        }

        for word in words where !word.w.trimmingCharacters(in: .whitespaces).isEmpty {
            if let previous = current.last {
                let pause = word.start - previous.end
                let endsSentence = previous.w.last.map { ".?!".contains($0) } ?? false
                if pause > lineBreakGap || (current.count >= longLineWords && endsSentence) {
                    flush()
                }
            }
            current.append(word)
        }
        flush()
        return lines
    }

    /// Without headphones the microphone also hears the call, so "Me" repeats
    /// what "Them" said a moment earlier. Drops "Me" words that match a "Them"
    /// word within `echoWindow`, in runs of at least `minimumEchoRun`. Works
    /// per word, before lines are formed, so a real reply right after an
    /// echoed sentence is kept.
    static func removingEcho(from mine: [TranscriptWord], heardIn theirs: [TranscriptWord]) -> [TranscriptWord] {
        let theirWords = theirs.map { (start: $0.start, word: normalized($0.w)) }
        var lower = 0
        let isEcho: [Bool] = mine.map { word in
            let key = normalized(word.w)
            guard !key.isEmpty else { return false }
            // Both channels are in time order, so the window only moves forward.
            while lower < theirWords.count, theirWords[lower].start < word.start - echoWindow {
                lower += 1
            }
            var index = lower
            while index < theirWords.count, theirWords[index].start <= word.start + echoWindow {
                if theirWords[index].word == key { return true }
                index += 1
            }
            return false
        }

        var kept: [TranscriptWord] = []
        var index = 0
        while index < mine.count {
            guard isEcho[index] else {
                kept.append(mine[index])
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < mine.count, isEcho[runEnd] { runEnd += 1 }
            if runEnd - index < minimumEchoRun {
                kept.append(contentsOf: mine[index..<runEnd])
            }
            index = runEnd
        }
        return kept
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    // MARK: - Rendering

    /// Plain Markdown meant to be pasted into an LLM as-is.
    func markdown() -> String {
        var out = "# Meeting · \(Self.titleFormatter.string(from: started))\n\n"
        out += "Duration \(Self.timestamp(duration)). "
        out += "\"Me\" is this Mac's microphone; \"Them\" is the audio this Mac played "
        out += "(the other people on the call). Transcribed on-device by Budgie.\n"
        if !heardSystemAudio {
            out += "\n> No system audio was captured. If the call was audible, allow Budgie under "
            out += "System Settings › Privacy & Security › Screen & System Audio Recording.\n"
        }
        if !heardMicAudio {
            out += "\n> No microphone audio was captured. Check the input device and that Budgie is "
            out += "allowed under System Settings › Privacy & Security › Microphone.\n"
        }
        if lines.isEmpty {
            out += "\n_No speech was detected._\n"
        }
        for line in lines {
            out += "\n**[\(Self.timestamp(line.start))] \(line.speaker.rawValue):** \(line.text)\n"
        }
        return out
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> MeetingTranscript {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingTranscript.self, from: data)
    }

    /// "4:05" under an hour, "1:02:09" from an hour on.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
}

/// The `words` array of a parakeet.cpp JSON transcription document.
struct ParakeetJSONDocument: Decodable {
    let words: [TranscriptWord]
}

import Foundation

/// Runs the CrispASR binary once over a finished recording and returns the text.
enum Transcriber {
    static func transcribe(_ wavURL: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Config.binaryPath)
        process.arguments = [
            "--backend", Config.backend,
            "-m", Config.modelPath,
            "-f", wavURL.path,
            "-np",  // print nothing but the result
            "-nt"   // no timestamps
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("Budgie: transcription failed: \(error)")
            return ""
        }
    }
}

import Foundation

/// Paths to the local speech engines and models.
///
/// `build.sh` bundles the `crispasr` binary, its dylibs, the standard GGUF
/// model and the streaming Core ML model inside `Budgie.app`, then rewrites the
/// engine's rpaths to `@executable_path`, so the app is self-contained. These
/// properties resolve to the bundled copies at runtime; when the bundled files
/// are absent (e.g. running via `swift run` during development) they fall back
/// to the original build-tree locations.
enum Config {
    /// Repo root, derived from this source file's compile-time location, used
    /// only for the `swift run` dev fallback below. `CrispASR/` and `models/`
    /// live inside the repo (see the README), so this resolves them wherever
    /// the repo is checked out — no hard-coded path to go stale.
    private static let devRoot: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/Budgie/
        .deletingLastPathComponent()   // Sources/
        .deletingLastPathComponent()   // repo root
        .path

    static let binaryPath: String = {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/crispasr").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return "\(devRoot)/CrispASR/build/bin/crispasr"
    }()

    static let modelPath: String = {
        if let bundled = Bundle.main.url(
            forResource: "parakeet-tdt-0.6b-v3-q4_k", withExtension: "gguf"
        ) {
            return bundled.path
        }
        return "\(devRoot)/models/parakeet-tdt-0.6b-v3-q4_k.gguf"
    }()

    static let streamingModelDirectoryName = "nemotron_coreml_560ms"

    static let streamingModelDirectoryPath: String = {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent(streamingModelDirectoryName, isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        return "\(devRoot)/models/\(streamingModelDirectoryName)"
    }()

    static let backend = "parakeet"

    /// Ignore key taps shorter than this — avoids firing on an accidental brush.
    static let minRecordingSeconds = 0.3

    /// Local port for the warm crispasr HTTP server.
    static let serverPort = 8377

    /// Shut the warm server down (freeing ~700 MB) after this long with no use.
    static let serverIdleSeconds: TimeInterval = 300
}

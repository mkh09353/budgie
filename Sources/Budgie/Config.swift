import Foundation

/// Paths to the CrispASR engine and model.
///
/// `build.sh` bundles the `crispasr` binary, its dylibs and the model inside
/// `Budgie.app` and rewrites the engine's rpaths to `@executable_path`, so the
/// app is self-contained and runs on any Apple-silicon Mac. These properties
/// resolve to the bundled copies at runtime; when the bundled files are absent
/// (e.g. running via `swift run` during development) they fall back to the
/// original build-tree locations.
enum Config {
    /// Build-tree locations, used only when running outside the app bundle.
    private static let devRoot = "/Users/maxheadley/Documents/stt"

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

    static let backend = "parakeet"

    /// Ignore key taps shorter than this — avoids firing on an accidental brush.
    static let minRecordingSeconds = 0.3

    /// Local port for the warm crispasr HTTP server.
    static let serverPort = 8377

    /// Shut the warm server down (freeing ~700 MB) after this long with no use.
    static let serverIdleSeconds: TimeInterval = 300
}

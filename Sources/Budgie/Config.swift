import Foundation

/// Paths to the local speech models and the parakeet.cpp C library.
///
/// `build.sh` bundles the parakeet.cpp C library and the streaming GGUF model
/// inside `Budgie.app`, rewriting the library rpaths to `@rpath`, so Live mode
/// is self-contained. Punctuated mode resolves to a cached model in
/// Application Support, downloading it on first use.
enum Config {
    /// Repo root, derived from this source file's compile-time location, used
    /// only for the `swift run` dev fallback below. `ParakeetCpp/` and `models/`
    /// live inside the repo (see the README), so this resolves them wherever the
    /// repo is checked out — no hard-coded path to go stale.
    private static let devRoot: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/Budgie/
        .deletingLastPathComponent()   // Sources/
        .deletingLastPathComponent()   // repo root
        .path

    private static let runningFromAppBundle = Bundle.main.bundleURL.pathExtension == "app"

    /// The Punctuated-mode NVIDIA Parakeet TDT 0.6b v3 model, run through
    /// parakeet.cpp's C library. It is not bundled; Punctuated mode
    /// downloads it into Application Support on first use.
    static let standardModelFileName = "tdt-0.6b-v3-q4_k.gguf"

    static let standardModelDownloadURL = URL(
        string: "https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/tdt-0.6b-v3-q4_k.gguf"
    )!

    static let applicationSupportDirectoryURL: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Budgie", isDirectory: true)
    }()

    static let modelCacheDirectoryURL: URL = {
        applicationSupportDirectoryURL.appendingPathComponent("Models", isDirectory: true)
    }()

    static let standardModelCacheURL: URL = {
        modelCacheDirectoryURL.appendingPathComponent(standardModelFileName)
    }()

    static let standardModelPath: String = {
        if let bundled = Bundle.main.url(
            forResource: "tdt-0.6b-v3-q4_k",
            withExtension: "gguf"
        ) {
            return bundled.path
        }
        if FileManager.default.fileExists(atPath: standardModelCacheURL.path) {
            return standardModelCacheURL.path
        }

        if !runningFromAppBundle {
            let developmentModelPath = "\(devRoot)/models/\(standardModelFileName)"
            if FileManager.default.fileExists(atPath: developmentModelPath) {
                return developmentModelPath
            }
        }

        return standardModelCacheURL.path
    }()

    static let streamingModelFileName = "realtime_eou_120m-v1-q8_0.gguf"

    static let streamingModelPath: String = {
        if let bundled = Bundle.main.url(
            forResource: "realtime_eou_120m-v1-q8_0",
            withExtension: "gguf"
        ) {
            return bundled.path
        }
        return "\(devRoot)/models/\(streamingModelFileName)"
    }()

    static let parakeetLibraryPath: String = {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/Parakeet/libparakeet.dylib")
            .path
        if FileManager.default.fileExists(atPath: bundled) { return bundled }

        let primary = "\(devRoot)/ParakeetCpp/build-shared/libparakeet.dylib"
        if FileManager.default.fileExists(atPath: primary) { return primary }

        return "\(devRoot)/parakeet.cpp/build-shared/libparakeet.dylib"
    }()

    /// Ignore key taps shorter than this — avoids firing on an accidental brush.
    static let minRecordingSeconds = 0.3

    /// Unload a warm model after this long with no use, reclaiming its memory.
    /// Re-warming `mmap`s the GGUF, so it costs only a fraction of a second.
    static let idleTeardownSeconds: TimeInterval = 300
}

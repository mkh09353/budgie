import Foundation

/// Runs the standard (non-streaming) TDT model through parakeet.cpp's C library
/// over a finished recording.
///
/// The model is loaded once and kept warm so each dictation is just a transcribe
/// call; the context is torn down after `Config.idleTeardownSeconds` idle to
/// reclaim its ~600 MB. Re-warming `mmap`s the GGUF, so it costs only a fraction
/// of a second.
final class StandardTranscriber: @unchecked Sendable {
    /// Called on the main thread when the warm/cold state changes.
    var onWarmChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.maxheadley.budgie.standard")
    private var library: ParakeetLibrary?
    private var context: ParakeetContext?
    private var loaded = false
    private var idleTimer: Timer?

    /// Proactively load the model so the first dictation finds it warm.
    func warmUp() {
        queue.async {
            do {
                try self.ensureLoaded()
            } catch {
                self.setWarm(false)
                NSLog("Budgie: standard warm-up failed: \(error)")
            }
            self.scheduleIdleShutdown()
        }
    }

    /// Transcribe a finished WAV. Blocks the calling (background) queue until the
    /// result is ready. Returns "" on failure.
    func transcribe(_ wavURL: URL) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = ""

        queue.async {
            defer { semaphore.signal() }
            do {
                try self.ensureLoaded()
                guard let context = self.context else {
                    throw StreamingTranscriberError.notLoaded
                }
                result = try context.transcribe(wavPath: wavURL.path)
            } catch {
                NSLog("Budgie: standard transcription failed: \(error)")
                result = ""
            }
        }

        semaphore.wait()
        scheduleIdleShutdown()
        return result
    }

    /// Tear the model down now (called on idle timeout, engine switch and quit).
    func shutdown(wait: Bool = false) {
        if wait {
            let semaphore = DispatchSemaphore(value: 0)
            queue.async {
                self.shutdownOnQueue()
                semaphore.signal()
            }
            semaphore.wait()
        } else {
            queue.async { self.shutdownOnQueue() }
        }
    }

    private func ensureLoaded() throws {
        if loaded, context != nil {
            setWarm(true)
            return
        }

        let libraryPath = Config.parakeetLibraryPath
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw StreamingTranscriberError.libraryMissing(libraryPath)
        }

        let modelPath = Config.standardModelPath
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw StreamingTranscriberError.modelFileMissing(modelPath)
        }

        let library = try ParakeetLibrary(path: libraryPath)
        let context = try ParakeetContext(library: library, modelPath: modelPath)
        self.library = library
        self.context = context
        loaded = true
        setWarm(true)
    }

    private func shutdownOnQueue() {
        context = nil
        library = nil
        loaded = false
        setWarm(false)
        DispatchQueue.main.async {
            self.idleTimer?.invalidate()
            self.idleTimer = nil
        }
    }

    private func scheduleIdleShutdown() {
        DispatchQueue.main.async {
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(
                withTimeInterval: Config.idleTeardownSeconds, repeats: false
            ) { [weak self] _ in
                self?.shutdown()
            }
        }
    }

    private func setWarm(_ warm: Bool) {
        DispatchQueue.main.async { self.onWarmChange?(warm) }
    }
}

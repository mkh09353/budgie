import Foundation

/// Runs the standard (non-streaming) TDT model through parakeet.cpp's C library
/// over a finished recording.
///
/// The large model is downloaded into Application Support on first use, then
/// loaded once and kept warm so each dictation is just a transcribe call. The
/// context is torn down after `Config.idleTeardownSeconds` idle to reclaim its
/// memory; the downloaded model remains cached.
final class StandardTranscriber: @unchecked Sendable {
    /// Called on the main thread when the warm/cold state changes.
    var onWarmChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.maxheadley.budgie.standard")
    private var library: ParakeetLibrary?
    private var context: ParakeetContext?
    private var loaded = false
    private var idleTimer: Timer?

    static var standardModelAvailable: Bool {
        FileManager.default.fileExists(atPath: Config.standardModelPath)
    }

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

    func prepareForActivation(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                try self.ensureLoaded()
                self.scheduleIdleShutdown()
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                self.setWarm(false)
                NSLog("Budgie: punctuated model preparation failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Transcribe a finished WAV. Blocks the calling (background) queue until
    /// the result is ready.
    func transcribe(_ wavURL: URL) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .success("")

        queue.async {
            defer { semaphore.signal() }
            do {
                try self.ensureLoaded()
                guard let context = self.context else {
                    throw StreamingTranscriberError.notLoaded
                }
                result = .success(try context.transcribe(wavPath: wavURL.path))
            } catch {
                NSLog("Budgie: standard transcription failed: \(error)")
                result = .failure(error)
            }
        }

        semaphore.wait()
        scheduleIdleShutdown()
        return try result.get()
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

        let modelPath = try ensureModelAvailable()

        let library = try ParakeetLibrary(path: libraryPath)
        let context = try ParakeetContext(library: library, modelPath: modelPath)
        self.library = library
        self.context = context
        loaded = true
        setWarm(true)
    }

    private func ensureModelAvailable() throws -> String {
        let modelPath = Config.standardModelPath
        if FileManager.default.fileExists(atPath: modelPath) {
            return modelPath
        }

        return try downloadStandardModel()
    }

    private func downloadStandardModel() throws -> String {
        let destination = Config.standardModelCacheURL
        let directory = Config.modelCacheDirectoryURL
        let temporary = directory.appendingPathComponent(".\(Config.standardModelFileName).download")
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        if fileManager.fileExists(atPath: destination.path) {
            return destination.path
        }

        try? fileManager.removeItem(at: temporary)
        NSLog("Budgie: downloading standard model to \(destination.path)")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error>?
        let task = URLSession.shared.downloadTask(with: Config.standardModelDownloadURL) {
            url, response, error in
            defer { semaphore.signal() }

            if let error {
                result = .failure(StreamingTranscriberError.modelDownloadFailed(
                    error.localizedDescription
                ))
                return
            }

            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                result = .failure(StreamingTranscriberError.modelDownloadFailed(
                    "HTTP \(http.statusCode)"
                ))
                return
            }

            guard let url else {
                result = .failure(StreamingTranscriberError.modelDownloadFailed(
                    "download produced no file"
                ))
                return
            }

            do {
                try? fileManager.removeItem(at: temporary)
                try fileManager.moveItem(at: url, to: temporary)
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: temporary, to: destination)
                result = .success(destination.path)
            } catch {
                result = .failure(StreamingTranscriberError.modelDownloadFailed(
                    error.localizedDescription
                ))
            }
        }

        task.resume()
        semaphore.wait()

        guard let result else {
            throw StreamingTranscriberError.modelDownloadFailed("unknown error")
        }

        let path = try result.get()
        NSLog("Budgie: standard model ready at \(path)")
        return path
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

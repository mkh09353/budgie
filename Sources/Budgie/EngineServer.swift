import Foundation

/// Manages a warm `crispasr --server` process: the model is loaded once and
/// stays resident (~700 MB), so each dictation is a quick HTTP round-trip
/// instead of spawning the engine afresh.
///
/// The server starts at launch (and lazily on the first dictation if needed)
/// and is torn down after `Config.serverIdleSeconds` with no use, reclaiming
/// the memory. Re-warming is cheap — the engine `mmap`s the model, so a cold
/// start measures ~0.3 s (see the timing log in `ensureRunning()`).
final class EngineServer {
    /// Called on the main thread when the warm/cold state changes.
    var onWarmChange: ((Bool) -> Void)?

    /// Serializes the whole of `ensureRunning()` — see that method for why.
    private let lock = NSLock()
    private var process: Process?
    /// True only once the server's model has finished loading and answered
    /// `/health`. A running-but-not-`ready` process is still cold.
    private var ready = false
    private var idleTimer: Timer?

    private var baseURL: String { "http://127.0.0.1:\(Config.serverPort)" }

    /// Transcribe a WAV via the warm server. Starts it if needed. Falls back to
    /// a one-shot binary invocation if the server can't be brought up.
    func transcribe(_ wavURL: URL) -> String {
        guard ensureRunning() else {
            NSLog("Budgie: warm server unavailable, using one-shot")
            return Transcriber.transcribe(wavURL)
        }
        let text = postInference(wavURL)
        scheduleIdleShutdown()
        return text
    }

    /// Proactively start the server in the background so the *first* dictation
    /// finds it already warm. The cold start itself is only ~0.3 s; doing it at
    /// launch also gets it out of the way before the user holds the key.
    /// Called once at launch.
    func warmUp() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, self.ensureRunning() else { return }
            DispatchQueue.main.async { self.onWarmChange?(true) }
            // Don't sit at ~700 MB forever if the user never dictates.
            self.scheduleIdleShutdown()
        }
    }

    /// Terminate the server now (called on idle timeout and app quit).
    func shutdown() {
        lock.lock()
        process?.terminate()
        process = nil
        ready = false
        lock.unlock()
        DispatchQueue.main.async {
            self.idleTimer?.invalidate()
            self.idleTimer = nil
            self.onWarmChange?(false)
        }
    }

    // MARK: - Server lifecycle

    /// Ensure exactly one healthy server is up.
    ///
    /// The whole body runs under `lock`, so the two callers — `warmUp()` at
    /// launch and `transcribe()` on a dictation — can't race. A dictation that
    /// arrives mid-warm-up blocks here until the single in-flight launch
    /// finishes, then sees the `ready` server and returns. Previously each
    /// caller ran its own launch, and the second one's `killStaleServers()`
    /// would shoot down the server the first was still loading.
    private func ensureRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // A previous launch already finished and the process is still alive.
        if ready, process?.isRunning == true { return true }

        // Nothing usable — drop any half-dead state and start from scratch.
        ready = false
        process = nil
        killStaleServers()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Config.binaryPath)
        proc.arguments = [
            "--server",
            "--backend", Config.backend,
            "-m", Config.modelPath,
            "--host", "127.0.0.1",
            "--port", String(Config.serverPort)
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let launchedAt = Date()
        do {
            try proc.run()
        } catch {
            NSLog("Budgie: failed to launch server: \(error)")
            return false
        }
        process = proc

        // Block until the model has loaded and answered /health, so callers
        // never POST to a server that's running but not yet ready.
        guard waitForHealth(timeout: 20) else {
            NSLog("Budgie: server did not become healthy")
            proc.terminate()
            process = nil
            return false
        }
        let coldStart = Date().timeIntervalSince(launchedAt)
        NSLog(String(format: "Budgie: engine cold start — model ready in %.1f s", coldStart))
        ready = true
        DispatchQueue.main.async { self.onWarmChange?(true) }
        return true
    }

    private func killStaleServers() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "crispasr --server"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func waitForHealth(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if httpGetOK("\(baseURL)/health") { return true }
            usleep(200_000)
        }
        return false
    }

    private func scheduleIdleShutdown() {
        DispatchQueue.main.async {
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(
                withTimeInterval: Config.serverIdleSeconds, repeats: false
            ) { [weak self] _ in
                self?.shutdown()
            }
        }
    }

    // MARK: - HTTP

    private func httpGetOK(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        return syncRequest(request) != nil
    }

    private func postInference(_ wavURL: URL) -> String {
        guard let audio = try? Data(contentsOf: wavURL),
              let url = URL(string: "\(baseURL)/inference") else { return "" }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        body.appendString("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)",
                          forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        guard let data = syncRequest(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a request synchronously (safe — always called from a background queue).
    private func syncRequest(_ request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                result = data
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return result
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

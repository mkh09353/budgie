import AVFoundation
import CoreML
import FluidAudio
import Foundation

enum StreamingTranscriberError: LocalizedError {
    case modelDirectoryMissing(String)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .modelDirectoryMissing(let path):
            return "Streaming model missing at \(path)"
        case .notLoaded:
            return "Streaming engine is not loaded"
        }
    }
}

/// Keeps FluidAudio's Nemotron streaming model loaded and feeds it buffers in
/// the same order the microphone tap produced them.
final class StreamingTranscriber: @unchecked Sendable {
    var onWarmChange: ((Bool) -> Void)?
    var onPartial: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.maxheadley.budgie.streaming")
    private var manager: StreamingNemotronAsrManager?
    private var loaded = false
    private var pendingError: Error?

    func warmUp() {
        queue.async {
            do {
                try self.ensureLoaded()
            } catch {
                self.pendingError = error
                self.setWarm(false)
                NSLog("Budgie: streaming warm-up failed: \(error)")
            }
        }
    }

    func beginSession() {
        queue.async {
            self.pendingError = nil
            do {
                try self.ensureLoaded()
                guard let manager = self.manager else { throw StreamingTranscriberError.notLoaded }
                try self.waitForAsync {
                    await manager.reset()
                    await manager.setPartialCallback { [weak self] partial in
                        self?.emitPartial(partial)
                    }
                }
            } catch {
                self.pendingError = error
                self.setWarm(false)
                NSLog("Budgie: streaming session failed to start: \(error)")
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        queue.async {
            guard self.pendingError == nil else { return }
            do {
                try self.ensureLoaded()
                guard let manager = self.manager else { throw StreamingTranscriberError.notLoaded }
                _ = try self.waitForAsync { try await manager.process(audioBuffer: copy) }
            } catch {
                self.pendingError = error
                NSLog("Budgie: streaming chunk failed: \(error)")
            }
        }
    }

    func finish() throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .success("")

        queue.async {
            defer { semaphore.signal() }
            do {
                if let pendingError = self.pendingError { throw pendingError }
                try self.ensureLoaded()
                guard let manager = self.manager else { throw StreamingTranscriberError.notLoaded }
                let transcript = try self.waitForAsync { try await manager.finish() }
                try? self.waitForAsync { await manager.reset() }
                result = .success(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                result = .failure(error)
            }
        }

        semaphore.wait()
        return try result.get()
    }

    func cancelSession() {
        queue.async {
            self.pendingError = nil
            guard let manager = self.manager else { return }
            try? self.waitForAsync { await manager.reset() }
        }
    }

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
        if loaded {
            setWarm(true)
            return
        }

        let modelDir = URL(fileURLWithPath: Config.streamingModelDirectoryPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw StreamingTranscriberError.modelDirectoryMissing(modelDir.path)
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let manager = StreamingNemotronAsrManager(
            configuration: configuration,
            requestedChunkSize: .ms560
        )
        try waitForAsync { try await manager.loadModels(from: modelDir) }
        self.manager = manager
        loaded = true
        setWarm(true)
    }

    private func shutdownOnQueue() {
        if let manager {
            try? waitForAsync { await manager.cleanup() }
        }
        manager = nil
        loaded = false
        pendingError = nil
        setWarm(false)
    }

    private func setWarm(_ warm: Bool) {
        DispatchQueue.main.async { self.onWarmChange?(warm) }
    }

    private func emitPartial(_ partial: String) {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { self.onPartial?(text) }
    }

    private func waitForAsync<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?

        Task {
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        guard let result else { throw StreamingTranscriberError.notLoaded }
        return try result.get()
    }
}

import AVFoundation
import Darwin
import Foundation

enum StreamingTranscriberError: LocalizedError {
    case libraryMissing(String)
    case libraryLoadFailed(String, String)
    case symbolMissing(String)
    case modelFileMissing(String)
    case contextLoadFailed(String)
    case streamStartFailed(String)
    case streamFeedFailed(String)
    case streamFinalizeFailed(String)
    case transcribeFailed(String)
    case resampleFailed(String)
    case invalidPCMBuffer
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .libraryMissing(let path):
            return "parakeet.cpp library missing at \(path)"
        case .libraryLoadFailed(let path, let message):
            return "Could not load parakeet.cpp library at \(path): \(message)"
        case .symbolMissing(let name):
            return "parakeet.cpp library is missing \(name)"
        case .modelFileMissing(let path):
            return "Streaming model missing at \(path)"
        case .contextLoadFailed(let message):
            return "Could not load streaming model: \(message)"
        case .streamStartFailed(let message):
            return "Could not start streaming session: \(message)"
        case .streamFeedFailed(let message):
            return "Streaming feed failed: \(message)"
        case .streamFinalizeFailed(let message):
            return "Streaming finalize failed: \(message)"
        case .transcribeFailed(let message):
            return "Transcription failed: \(message)"
        case .resampleFailed(let message):
            return "Audio resample failed: \(message)"
        case .invalidPCMBuffer:
            return "Audio buffer did not contain float PCM"
        case .notLoaded:
            return "Streaming engine is not loaded"
        }
    }
}

/// Keeps parakeet.cpp's C library loaded and feeds cache-aware streaming
/// sessions with 16 kHz mono float PCM.
final class StreamingTranscriber: @unchecked Sendable {
    var onWarmChange: ((Bool) -> Void)?
    var onPartial: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.maxheadley.budgie.streaming")
    private let streamFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var library: ParakeetLibrary?
    private var context: ParakeetContext?
    private var stream: ParakeetStreamSession?
    private var loaded = false
    private var pendingError: Error?
    private var runningTranscript = ""

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
            self.runningTranscript = ""
            do {
                try self.ensureLoaded()
                guard let context = self.context else { throw StreamingTranscriberError.notLoaded }
                self.stream?.free()
                self.stream = try ParakeetStreamSession(context: context)
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
                guard let stream = self.stream else { throw StreamingTranscriberError.notLoaded }
                let samples = try self.pcm16kMono(from: copy)
                guard !samples.isEmpty else { return }
                let delta = try stream.feed(samples)
                self.appendTranscriptDelta(delta)
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
                guard let stream = self.stream else { throw StreamingTranscriberError.notLoaded }
                let tail = try stream.finalize()
                self.appendTranscriptDelta(tail)
                stream.free()
                self.stream = nil
                result = .success(
                    self.runningTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                )
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
            self.runningTranscript = ""
            self.stream?.free()
            self.stream = nil
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
        if loaded, context != nil {
            setWarm(true)
            return
        }

        let libraryPath = Config.parakeetLibraryPath
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw StreamingTranscriberError.libraryMissing(libraryPath)
        }

        let modelPath = Config.streamingModelPath
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
        stream?.free()
        stream = nil
        context = nil
        library = nil
        loaded = false
        pendingError = nil
        runningTranscript = ""
        setWarm(false)
    }

    private func pcm16kMono(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        if isStreamFormat(buffer.format) {
            return try floatSamples(from: buffer)
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: streamFormat) else {
            throw StreamingTranscriberError.resampleFailed("could not create converter")
        }

        let ratio = streamFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: streamFormat,
            frameCapacity: capacity
        ) else {
            throw StreamingTranscriberError.resampleFailed("could not allocate output buffer")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw StreamingTranscriberError.resampleFailed(
                conversionError?.localizedDescription ?? "unknown converter error"
            )
        }

        return try floatSamples(from: converted)
    }

    private func isStreamFormat(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32 &&
            format.channelCount == 1 &&
            abs(format.sampleRate - streamFormat.sampleRate) < 0.5
    }

    private func floatSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return [] }
        guard let channel = buffer.floatChannelData?[0] else {
            throw StreamingTranscriberError.invalidPCMBuffer
        }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    private func appendTranscriptDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        runningTranscript += delta
        emitPartial(runningTranscript)
    }

    private func setWarm(_ warm: Bool) {
        DispatchQueue.main.async { self.onWarmChange?(warm) }
    }

    private func emitPartial(_ partial: String) {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { self.onPartial?(text) }
    }
}

/// dlopen wrapper around parakeet.cpp's flat C API. Shared by the streaming
/// engine (`StreamingTranscriber`) and the one-shot engine
/// (`StandardTranscriber`); both load the same `libparakeet.dylib` and reuse
/// these typed symbols.
final class ParakeetLibrary {
    typealias AbiVersion = @convention(c) () -> CInt
    typealias Load = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias TranscribePath = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?,
        CInt
    ) -> UnsafeMutablePointer<CChar>?
    typealias StreamBegin = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias StreamFeed = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<Float>?,
        CInt,
        UnsafeMutablePointer<CInt>?
    ) -> UnsafeMutablePointer<CChar>?
    typealias StreamFinalize = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    typealias StreamFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    typealias LastError = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?

    let handle: UnsafeMutableRawPointer
    let load: Load
    let free: Free
    let transcribePath: TranscribePath
    let streamBegin: StreamBegin
    let streamFeed: StreamFeed
    let streamFinalize: StreamFinalize
    let streamFree: StreamFree
    let freeString: FreeString
    let lastError: LastError

    init(path: String) throws {
        guard let opened = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw StreamingTranscriberError.libraryLoadFailed(path, Self.dlerrorMessage())
        }

        do {
            let abiVersion: AbiVersion = try Self.symbol(
                "parakeet_capi_abi_version",
                from: opened
            )
            let abi = abiVersion()
            guard abi >= 1 else {
                throw StreamingTranscriberError.libraryLoadFailed(
                    path,
                    "unsupported C API ABI \(abi)"
                )
            }

            self.handle = opened
            self.load = try Self.symbol("parakeet_capi_load", from: opened)
            self.free = try Self.symbol("parakeet_capi_free", from: opened)
            self.transcribePath = try Self.symbol("parakeet_capi_transcribe_path", from: opened)
            self.streamBegin = try Self.symbol("parakeet_capi_stream_begin", from: opened)
            self.streamFeed = try Self.symbol("parakeet_capi_stream_feed", from: opened)
            self.streamFinalize = try Self.symbol("parakeet_capi_stream_finalize", from: opened)
            self.streamFree = try Self.symbol("parakeet_capi_stream_free", from: opened)
            self.freeString = try Self.symbol("parakeet_capi_free_string", from: opened)
            self.lastError = try Self.symbol("parakeet_capi_last_error", from: opened)
        } catch {
            dlclose(opened)
            throw error
        }
    }

    deinit {
        dlclose(handle)
    }

    private static func symbol<T>(_ name: String, from handle: UnsafeMutableRawPointer) throws -> T {
        guard let raw = dlsym(handle, name) else {
            throw StreamingTranscriberError.symbolMissing(name)
        }
        return unsafeBitCast(raw, to: T.self)
    }

    private static func dlerrorMessage() -> String {
        guard let message = dlerror() else { return "unknown dlopen error" }
        return String(cString: message)
    }
}

final class ParakeetContext {
    let library: ParakeetLibrary
    let pointer: UnsafeMutableRawPointer

    init(library: ParakeetLibrary, modelPath: String) throws {
        self.library = library
        guard let loaded = modelPath.withCString({ library.load($0) }) else {
            throw StreamingTranscriberError.contextLoadFailed(modelPath)
        }
        self.pointer = loaded
    }

    deinit {
        library.free(pointer)
    }

    var lastErrorMessage: String {
        guard let message = library.lastError(pointer) else { return "unknown error" }
        let text = String(cString: message)
        return text.isEmpty ? "unknown error" : text
    }

    /// One-shot transcription of a WAV file. `decoder` 0 lets parakeet.cpp pick
    /// the head by architecture (the transducer for the TDT model).
    func transcribe(wavPath: String, decoder: CInt = 0) throws -> String {
        guard let result = wavPath.withCString({
            library.transcribePath(pointer, $0, decoder)
        }) else {
            throw StreamingTranscriberError.transcribeFailed(lastErrorMessage)
        }
        defer { library.freeString(result) }
        return String(cString: result)
    }
}

private final class ParakeetStreamSession {
    private let context: ParakeetContext
    private let pointer: UnsafeMutableRawPointer
    private var isFreed = false

    init(context: ParakeetContext) throws {
        self.context = context
        guard let stream = context.library.streamBegin(context.pointer) else {
            throw StreamingTranscriberError.streamStartFailed(context.lastErrorMessage)
        }
        self.pointer = stream
    }

    deinit {
        free()
    }

    func feed(_ samples: [Float]) throws -> String {
        guard samples.count <= Int(CInt.max) else {
            throw StreamingTranscriberError.streamFeedFailed("too many samples")
        }
        guard !samples.isEmpty else { return "" }

        return try samples.withUnsafeBufferPointer { buffer in
            var eou: CInt = 0
            let text = context.library.streamFeed(
                pointer,
                buffer.baseAddress,
                CInt(buffer.count),
                &eou
            )
            return try takeString(text, failure: .streamFeedFailed(context.lastErrorMessage))
        }
    }

    func finalize() throws -> String {
        let text = context.library.streamFinalize(pointer)
        return try takeString(text, failure: .streamFinalizeFailed(context.lastErrorMessage))
    }

    func free() {
        guard !isFreed else { return }
        context.library.streamFree(pointer)
        isFreed = true
    }

    private func takeString(
        _ pointer: UnsafeMutablePointer<CChar>?,
        failure: StreamingTranscriberError
    ) throws -> String {
        guard let pointer else { throw failure }
        defer { context.library.freeString(pointer) }
        return String(cString: pointer)
    }
}

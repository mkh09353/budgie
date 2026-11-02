import Foundation
import os

/// Budgie's log. Every line goes to the unified log (Console.app, or
/// `log stream --level debug --predicate 'subsystem == "com.maxheadley.budgie"'`)
/// and to `~/Library/Logs/Budgie/budgie.log`, so a slow start or a failure can
/// be read back after the fact.
///
/// `debug` lines (per-step timings, gesture decisions) are only kept with
/// diagnostic logging on: Settings → About, `BUDGIE_DEBUG_LOG=1` in the
/// environment, or `defaults write com.maxheadley.budgie diagnosticLogging -bool true`.
///
/// Never log what the user said, typed or saved.
enum Log {
    enum Category: String {
        case app, dictation, audio, engine, meeting, saves, update
    }

    enum Level: String {
        case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR"
    }

    static let subsystem = "com.maxheadley.budgie"
    static var directoryURL: URL { fileQueue.sync { directory } }
    static var fileURL: URL { directoryURL.appendingPathComponent("budgie.log") }
    /// The file is rolled over to `budgie.old.log` past this size.
    static let maximumFileBytes: UInt64 = 2_000_000

    /// Diagnostic logging forced on from the environment, whatever the setting.
    static let forcedByEnvironment = ProcessInfo.processInfo.environment["BUDGIE_DEBUG_LOG"] == "1"

    /// Whether `debug` lines are kept. Set from `UserPrefs.diagnosticLogging`.
    static var verbose: Bool {
        get { verboseLock.withLock { $0 } }
        set { verboseLock.withLock { $0 = newValue || forcedByEnvironment } }
    }

    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        guard verbose else { return }
        write(.debug, category, message())
    }

    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        write(.info, category, message())
    }

    static func warning(_ category: Category, _ message: @autoclosure () -> String) {
        write(.warning, category, message())
    }

    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        write(.error, category, message())
    }

    /// A duration as whole milliseconds, e.g. "1840 ms".
    static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.0f ms", seconds * 1_000)
    }

    /// Seconds since boot, the clock key events are stamped with.
    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Writing

    private static let verboseLock = OSAllocatedUnfairLock(initialState: forcedByEnvironment)
    private static let fileQueue = DispatchQueue(label: "com.maxheadley.budgie.log", qos: .utility)
    private static var loggers: [Category: Logger] = [:]
    private static let loggersLock = NSLock()
    /// Only touched on `fileQueue`.
    private static var handle: FileHandle?
    private static var directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Budgie", isDirectory: true)

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func write(_ level: Level, _ category: Category, _ message: String) {
        let logger = loggersLock.withLock {
            if let logger = loggers[category] { return logger }
            let logger = Logger(subsystem: subsystem, category: category.rawValue)
            loggers[category] = logger
            return logger
        }
        switch level {
        case .debug:   logger.debug("\(message, privacy: .public)")
        case .info:    logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error:   logger.error("\(message, privacy: .public)")
        }

        let date = Date()
        let thread = currentThreadLabel()
        fileQueue.async {
            let line = "\(timestampFormatter.string(from: date)) \(level.rawValue) [\(thread)] "
                + "\(category.rawValue): \(message)\n"
            append(line)
        }
    }

    /// "main", or the label of the dispatch queue doing the work, so a line
    /// shows whether a step ran where it was meant to. A queue's work run
    /// synchronously from the main thread reads "main/<queue>": it blocks it.
    private static func currentThreadLabel() -> String {
        var label = String(cString: __dispatch_queue_get_label(nil))
        let prefix = "com.maxheadley.budgie."
        if label.hasPrefix(prefix) { label = String(label.dropFirst(prefix.count)) }
        if label.isEmpty { label = "thread" }
        guard Thread.isMainThread else { return label }
        return label == "com.apple.main-thread" ? "main" : "main/\(label)"
    }

    private static func append(_ line: String) {
        if handle == nil { openFile() }
        guard let handle else { return }
        handle.write(Data(line.utf8))
        if handle.offsetInFile > maximumFileBytes {
            try? handle.close()
            self.handle = nil
            let file = directory.appendingPathComponent("budgie.log")
            let old = directory.appendingPathComponent("budgie.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: file, to: old)
        }
    }

    private static func openFile() {
        let fileManager = FileManager.default
        let file = directory.appendingPathComponent("budgie.log")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: file.path) {
            fileManager.createFile(atPath: file.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
    }

    /// Waits for queued lines to reach the file. For tests and quitting.
    static func flush() {
        fileQueue.sync {}
    }

    /// Sends later lines to `directory` instead. For tests.
    static func redirect(to newDirectory: URL) {
        fileQueue.sync {
            try? handle?.close()
            handle = nil
            directory = newDirectory
        }
    }
}

/// Times one dictation's start, from the key press to the first live text, so
/// a slow start says which step was slow. Times are seconds since boot.
struct DictationStartTrace {
    /// The key event's own timestamp.
    let pressed: TimeInterval
    /// When the main thread got round to handling the press.
    let handled: TimeInterval
    var micReady: TimeInterval?
    var firstAudio: TimeInterval?
    var firstText: TimeInterval?
    var mic: MicStartTiming?
    var engineWarm: Bool

    /// Longer than this from press to hearing audio feels like a missed press.
    static let slowThreshold: TimeInterval = 0.5

    var isSlow: Bool {
        guard let heard = firstAudio ?? micReady else { return true }
        return heard - pressed > Self.slowThreshold
    }

    var summary: String {
        func since(_ time: TimeInterval?) -> String {
            time.map { Log.ms($0 - pressed) } ?? "never"
        }
        var parts = [
            "press handled after \(Log.ms(handled - pressed))",
            "mic ready \(since(micReady))",
            "first audio \(since(firstAudio))",
            "first text \(since(firstText))",
            engineWarm ? "engine warm" : "engine COLD"
        ]
        if let mic { parts.append(mic.summary) }
        return parts.joined(separator: ", ")
    }
}

/// How long each step of opening the microphone took.
struct MicStartTiming {
    var inputNode: TimeInterval = 0
    var installTap: TimeInterval = 0
    var engineStart: TimeInterval = 0
    var device = "unknown input"
    var sampleRate: Double = 0

    var total: TimeInterval { inputNode + installTap + engineStart }

    var summary: String {
        "mic \(device) @ \(Int(sampleRate)) Hz "
            + "(inputNode \(Log.ms(inputNode)), installTap \(Log.ms(installTap)), "
            + "engine.start \(Log.ms(engineStart)))"
    }
}

/// While diagnostic logging is on, pings the main thread ten times a second
/// and logs any stretch where it couldn't answer: key presses, the panel and
/// starting the microphone all wait on it.
final class MainThreadWatchdog {
    static let stallThreshold: TimeInterval = 0.25

    private let queue = DispatchQueue(label: "com.maxheadley.budgie.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// When the unanswered ping was sent. Only touched on `queue`.
    private var pingSent: TimeInterval?

    func setRunning(_ running: Bool) {
        queue.async {
            if running { self.startOnQueue() } else { self.stopOnQueue() }
        }
    }

    private func startOnQueue() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.resume()
        self.timer = timer
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        pingSent = nil
    }

    private func ping() {
        guard pingSent == nil else { return }
        let sent = Log.uptime
        pingSent = sent
        DispatchQueue.main.async { [weak self] in
            let answered = Log.uptime
            self?.queue.async {
                guard let self else { return }
                self.pingSent = nil
                let stall = answered - sent
                if stall > Self.stallThreshold {
                    Log.warning(.app, "main thread was blocked for \(Log.ms(stall))")
                }
            }
        }
    }
}

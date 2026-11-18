import Foundation
#if canImport(os)
import os
#endif

/// Protokollstufe.
public enum LogLevel: String, Codable, Sendable, Comparable {
    case debug, info, notice, warning, error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .warning: return 3
        case .error: return 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// Ein Protokolleintrag für die Diagnoseansicht.
public struct LogEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var date: Date
    public var level: LogLevel
    public var category: String
    public var message: String

    public init(id: String = UUID().uuidString, date: Date = Date(), level: LogLevel, category: String, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Zentrales Protokoll mit Ringpuffer, optionaler Dateiausgabe und Weiterleitung an das
/// Unified Logging System auf Apple-Plattformen. Zugangsdaten werden vor der
/// Ausgabe entfernt.
public final class SyncLogger: @unchecked Sendable {
    public static let shared = SyncLogger()

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let capacity = 2000
    private var fileHandle: FileHandle?
    private var secrets: [String] = []
    private var configuredMinimumLevel: LogLevel = .debug
    private var observers: [UUID: @Sendable (LogEntry) -> Void] = [:]

    public var minimumLevel: LogLevel {
        get {
            lock.lock(); defer { lock.unlock() }
            return configuredMinimumLevel
        }
        set {
            lock.lock(); configuredMinimumLevel = newValue; lock.unlock()
        }
    }

    #if canImport(os)
    private let osLogger = Logger(subsystem: "de.reichi.sync", category: "sync")
    #endif

    public init() {}

    /// Registriert einen geheimen Wert (z. B. Passwort), der aus allen Meldungen entfernt wird.
    public func registerSecret(_ value: String) {
        guard !value.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if !secrets.contains(value) { secrets.append(value) }
    }

    /// Aktiviert zusätzlich eine Protokolldatei.
    public func enableFileLogging(at url: URL) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil) }
        if let attrs = try? fm.attributesOfItem(atPath: url.path), let size = attrs[.size] as? NSNumber, size.int64Value > 5_000_000 {
            try? fm.removeItem(at: url)
            _ = fm.createFile(atPath: url.path, contents: nil)
        }
        try? fileHandle?.close()
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

    public func addObserver(_ observer: @escaping @Sendable (LogEntry) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = observer; lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock(); observers[id] = nil; lock.unlock()
    }

    public func log(_ level: LogLevel, _ category: String, _ message: @autoclosure () -> String) {
        lock.lock()
        let shouldLog = level >= configuredMinimumLevel
        lock.unlock()
        guard shouldLog else { return }
        let entry = LogEntry(level: level, category: category, message: redact(message()))
        let line = "\(ISO8601DateFormatter().string(from: entry.date)) [\(level.rawValue.uppercased())] \(category): \(entry.message)\n"
        let data = line.data(using: .utf8)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        if let fileHandle, let data { try? fileHandle.write(contentsOf: data) }
        let obs = Array(observers.values)
        lock.unlock()
        #if canImport(os)
        switch level {
        case .debug: osLogger.debug("\(category, privacy: .public): \(entry.message, privacy: .public)")
        case .info: osLogger.info("\(category, privacy: .public): \(entry.message, privacy: .public)")
        case .notice: osLogger.notice("\(category, privacy: .public): \(entry.message, privacy: .public)")
        case .warning: osLogger.warning("\(category, privacy: .public): \(entry.message, privacy: .public)")
        case .error: osLogger.error("\(category, privacy: .public): \(entry.message, privacy: .public)")
        }
        #else
        if level >= .info { FileHandle.standardError.write(Data("[\(level.rawValue)] \(category): \(entry.message)\n".utf8)) }
        #endif
        for o in obs { o(entry) }
    }

    public func debug(_ category: String, _ message: @autoclosure () -> String) { log(.debug, category, message()) }
    public func info(_ category: String, _ message: @autoclosure () -> String) { log(.info, category, message()) }
    public func notice(_ category: String, _ message: @autoclosure () -> String) { log(.notice, category, message()) }
    public func warning(_ category: String, _ message: @autoclosure () -> String) { log(.warning, category, message()) }
    public func error(_ category: String, _ message: @autoclosure () -> String) { log(.error, category, message()) }

    public func recentEntries(limit: Int = 500) -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.suffix(limit))
    }

    /// Entfernt registrierte Geheimnisse, Authorization-Header und URL-Userinfo.
    public func redact(_ message: String) -> String {
        var result = message
        lock.lock()
        let secrets = self.secrets
        lock.unlock()
        for s in secrets { result = result.replacingOccurrences(of: s, with: "•••") }
        if let regex = try? NSRegularExpression(pattern: "(?i)(authorization:\\s*)(basic|bearer|digest)\\s+\\S+", options: []) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1$2 •••")
        }
        if let regex = try? NSRegularExpression(pattern: "(?i)(https?://)([^/\\s@]+)@", options: []) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1•••@")
        }
        return result
    }
}

import Foundation

/// Fehler bei lokalen Dateioperationen.
public enum LocalFileError: Error, Sendable, Equatable {
    case rootMissing
    case diskFull
    case notFound(String)
    case changedSinceScan(String)
    case nameCollision(String)
    case io(String)

    public var userDescription: String {
        switch self {
        case .rootMissing: return "Der lokale Ordner ist nicht verfügbar."
        case .diskFull: return "Auf dem Mac ist nicht genügend Speicherplatz frei. Betroffene Downloads wurden pausiert."
        case .notFound(let p): return "Die lokale Datei „\(p)“ wurde nicht gefunden."
        case .changedSinceScan(let p): return "„\(p)“ wurde zwischenzeitlich lokal geändert und wird beim nächsten Abgleich erneut geprüft."
        case .nameCollision(let p): return "„\(p)“ kollidiert mit einem gleichnamigen Eintrag (Groß-/Kleinschreibung)."
        case .io(let s): return "Dateifehler: \(s)"
        }
    }
}

/// Zugriff auf den lokalen Synchronisierungsordner.
///
/// Alle Pfade sind relative Schlüsselpfade; der Zugriff bleibt stets innerhalb
/// des Stammordners (`RelativePath.localURL`).
public struct LocalFileSystem: Sendable {
    public let root: URL
    private var fm: FileManager { .default }

    /// Verzeichnis für temporäre Downloads innerhalb des Stammordners (gleiches Volume → atomare Ersetzung).
    public var temporaryDirectory: URL { root.appendingPathComponent(ExclusionRules.internalPrefix + "-tmp", isDirectory: true) }

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func rootExists() -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func url(_ relativePath: String) throws -> URL {
        try RelativePath.localURL(root: root, relativePath: relativePath)
    }

    public struct Attributes: Sendable, Equatable {
        public var kind: ItemKind
        public var size: Int64
        public var modified: Double
        public var isSymlink: Bool
    }

    public func attributes(_ relativePath: String) throws -> Attributes? {
        let target = try url(relativePath)
        return try attributes(at: target)
    }

    public func attributes(at target: URL) throws -> Attributes? {
        guard let attrs = try? fm.attributesOfItem(atPath: target.path) else { return nil }
        let type = attrs[.type] as? FileAttributeType
        let isSymlink = type == .typeSymbolicLink
        let kind: ItemKind = type == .typeDirectory ? .directory : .file
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Attributes(kind: kind, size: size, modified: modified, isSymlink: isSymlink)
    }

    public func hash(_ relativePath: String) throws -> String {
        try SHA256Hasher.hashFile(at: url(relativePath))
    }

    public func ensureTemporaryDirectory() throws {
        if !fm.fileExists(atPath: temporaryDirectory.path) {
            try fm.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isHidden = true
            var dir = temporaryDirectory
            try? dir.setResourceValues(values)
        }
    }

    public func makeTemporaryFileURL() throws -> URL {
        try ensureTemporaryDirectory()
        return temporaryDirectory.appendingPathComponent(ExclusionRules.internalPrefix + "-" + UUID().uuidString + ".part")
    }

    public func cleanupTemporaryFiles(olderThan age: TimeInterval = 60 * 60 * 24) {
        guard let items = try? fm.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            if let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, Date().timeIntervalSince(date) > age {
                try? fm.removeItem(at: item)
            }
        }
    }

    public func createDirectory(_ relativePath: String) throws {
        let target = try url(relativePath)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw LocalFileError.io("An der Stelle des Ordners „\(relativePath)“ liegt eine Datei")
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
    }

    /// Verschiebt eine heruntergeladene temporäre Datei an ihren Zielort.
    ///
    /// - Wenn `expectedHash` gesetzt ist, muss die vorhandene Datei noch genau diesen
    ///   Inhalt haben (Prüfung zunächst über Größe/Änderungszeit, bei Abweichung über Hash),
    ///   sonst wird abgebrochen und die temporäre Datei entfernt.
    /// - Wenn `expectedHash` `nil` ist, darf am Ziel noch keine Datei liegen.
    public func installDownloadedFile(from temp: URL, to relativePath: String, expectedHash: String?, expectedSize: Int64?, expectedModified: Double?, modifiedDate: Date?) throws {
        let target = try url(relativePath)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let modifiedDate {
            try? fm.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: temp.path)
        }
        let existing = try attributes(at: target)
        if let existing {
            guard existing.kind == .file else {
                try? fm.removeItem(at: temp)
                throw LocalFileError.io("Am Zielort „\(relativePath)“ liegt ein Ordner")
            }
            guard let expectedHash else {
                try? fm.removeItem(at: temp)
                throw LocalFileError.changedSinceScan(relativePath)
            }
            let unchangedByStat = expectedSize == existing.size && expectedModified.map { abs($0 - existing.modified) < 0.001 } == true
            if !unchangedByStat {
                let currentHash = try SHA256Hasher.hashFile(at: target)
                if currentHash != expectedHash {
                    try? fm.removeItem(at: temp)
                    throw LocalFileError.changedSinceScan(relativePath)
                }
            }
            _ = try fm.replaceItemAt(target, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            do {
                try fm.moveItem(at: temp, to: target)
            } catch {
                try? fm.removeItem(at: temp)
                throw Self.mapError(error)
            }
        }
    }

    /// Verschiebt eine Datei oder einen Ordner in den Papierkorb; falls das nicht
    /// möglich ist, in den Wiederherstellungsbereich.
    @discardableResult
    public func trash(_ relativePath: String, recoveryDirectory: URL?) throws -> URL? {
        let target = try url(relativePath)
        guard fm.fileExists(atPath: target.path) else { return nil }
        #if os(macOS)
        var resulting: NSURL?
        do {
            try fm.trashItem(at: target, resultingItemURL: &resulting)
            return resulting as URL?
        } catch {
            SyncLogger.shared.warning("local", "Papierkorb nicht verfügbar für \(relativePath): \(error.localizedDescription)")
        }
        #endif
        guard let recoveryDirectory else {
            throw LocalFileError.io("Weder Papierkorb noch Wiederherstellungsbereich verfügbar")
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = recoveryDirectory.appendingPathComponent(stamp, isDirectory: true).appendingPathComponent(relativePath)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: target, to: dest)
        return dest
    }

    public func move(_ from: String, to: String) throws {
        let source = try url(from)
        let dest = try url(to)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { throw LocalFileError.io("Zielpfad „\(to)“ existiert bereits") }
        try fm.moveItem(at: source, to: dest)
    }

    public func copy(_ from: String, to: String) throws {
        let source = try url(from)
        let dest = try url(to)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { throw LocalFileError.io("Zielpfad „\(to)“ existiert bereits") }
        try fm.copyItem(at: source, to: dest)
    }

    /// Entfernt einen leeren Ordner (keine Dateien, nur ausgeschlossene Einträge erlaubt).
    public func removeDirectoryIfEmpty(_ relativePath: String, rules: ExclusionRules) throws -> Bool {
        let target = try url(relativePath)
        guard let children = try? fm.contentsOfDirectory(atPath: target.path) else { return false }
        for child in children {
            let childPath = RelativePath.join(relativePath, child.precomposedStringWithCanonicalMapping)
            if !rules.isExcluded(relativePath: childPath) { return false }
        }
        try fm.removeItem(at: target)
        return true
    }

    /// Freier Speicherplatz auf dem Volume des Stammordners.
    public func availableCapacity() -> Int64? {
        #if os(macOS)
        if let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let cap = values.volumeAvailableCapacityForImportantUsage {
            return cap
        }
        #endif
        if let attrs = try? fm.attributesOfFileSystem(forPath: root.path), let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    public static func mapError(_ error: Error) -> Error {
        if let local = error as? LocalFileError { return local }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteOutOfSpaceError || ns.code == NSFileWriteVolumeReadOnlyError) {
            return LocalFileError.diskFull
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) {
            return LocalFileError.diskFull
        }
        return LocalFileError.io(ns.localizedDescription)
    }
}

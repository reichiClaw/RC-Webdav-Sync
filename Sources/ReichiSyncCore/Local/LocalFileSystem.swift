import Foundation

/// Fehler bei lokalen Dateioperationen.
public enum LocalFileError: Error, Sendable, Equatable {
    case rootMissing
    case diskFull
    case notFound(String)
    case changedSinceScan(String)
    case nameCollision(String)
    case symbolicLink(String)
    case io(String)

    public var userDescription: String {
        switch self {
        case .rootMissing: return "Der lokale Ordner ist nicht verfügbar."
        case .diskFull: return "Auf dem Mac ist nicht genügend Speicherplatz frei. Betroffene Downloads wurden pausiert."
        case .notFound(let p): return "Die lokale Datei „\(p)“ wurde nicht gefunden."
        case .changedSinceScan(let p): return "„\(p)“ wurde zwischenzeitlich lokal geändert und wird beim nächsten Abgleich erneut geprüft."
        case .nameCollision(let p): return "„\(p)“ kollidiert mit einem gleichnamigen Eintrag (Groß-/Kleinschreibung)."
        case .symbolicLink(let p): return "„\(p)“ enthält einen symbolischen Link. Der Zugriff wurde aus Sicherheitsgründen abgebrochen."
        case .io(let s): return "Dateifehler: \(s)"
        }
    }
}

/// Teilt die einmal gebundene Wurzelidentität zwischen Kopien des
/// `LocalFileSystem`-Werts. Falls die Metadaten beim Erzeugen vorübergehend
/// nicht lesbar sind, wird die erste später erfolgreich gelesene Identität
/// atomar gebunden.
private final class RootIdentityState: @unchecked Sendable {
    private let lock = NSLock()
    private var expected: String?

    init(expected: String?) {
        self.expected = expected
    }

    func accepts(_ current: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let expected { return expected == current }
        expected = current
        return true
    }
}

/// Zugriff auf den lokalen Synchronisierungsordner.
///
/// Alle Pfade sind relative Schlüsselpfade; der Zugriff bleibt stets innerhalb
/// des Stammordners (`RelativePath.localURL`).
public struct LocalFileSystem: Sendable {
    public let root: URL
    /// Gerät+Inode des beim Erzeugen ausgewählten Stammordners. Ein später unter
    /// demselben Pfad eingehängter Link oder anderer Ordner ist nicht dieselbe
    /// Sync-Wurzel und darf niemals automatisch verwendet werden.
    private let rootIdentity: RootIdentityState
    private let prefersTrash: Bool
    private var fm: FileManager { .default }

    /// Verzeichnis für temporäre Downloads innerhalb des Stammordners (gleiches Volume → atomare Ersetzung).
    public var temporaryDirectory: URL { root.appendingPathComponent(ExclusionRules.internalPrefix + "-tmp", isDirectory: true) }

    public init(root: URL, expectedRootFileID: String? = nil, prefersTrash: Bool = true) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        let observed = (try? POSIXFileMetadata.read(atPath: self.root.path))?.fileID
        self.rootIdentity = RootIdentityState(expected: expectedRootFileID ?? observed)
        self.prefersTrash = prefersTrash
    }

    public func rootExists() -> Bool {
        guard (try? validateRootIdentity()) != nil else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func url(_ relativePath: String) throws -> URL {
        try validateRootIdentity()
        let target = try RelativePath.localURL(root: root, relativePath: relativePath)
        try rejectSymbolicLinkComponents(relativePath)
        try validateRootIdentity()
        return target
    }

    public func validateRootIdentity() throws {
        let current: POSIXFileMetadata.Values
        do {
            guard let value = try POSIXFileMetadata.read(atPath: root.path) else {
                throw LocalFileError.rootMissing
            }
            current = value
        } catch {
            throw LocalFileError.rootMissing
        }
        guard !current.isSymbolicLink,
              rootIdentity.accepts(current.fileID) else {
            throw LocalFileError.rootMissing
        }
    }

    /// Prüft jede bereits vorhandene Pfadkomponente mit `lstat`, also ohne
    /// Links zu folgen. Nicht vorhandene Restkomponenten sind für neue Dateien
    /// und Ordner zulässig.
    private func rejectSymbolicLinkComponents(_ relativePath: String) throws {
        let normalized = try RelativePath.normalize(relativePath)
        var current = root
        for segment in normalized.split(separator: "/") {
            current.appendPathComponent(String(segment))
            guard let metadata = try POSIXFileMetadata.read(atPath: current.path) else { break }
            if metadata.isSymbolicLink {
                throw LocalFileError.symbolicLink(normalized)
            }
        }
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
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: target.path)
        } catch {
            let ns = error as NSError
            if (ns.domain == NSCocoaErrorDomain
                && (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError))
                || (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOENT) || ns.code == Int(ENOTDIR))) {
                return nil
            }
            throw Self.mapError(error)
        }
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
        let directory = try url(ExclusionRules.internalPrefix + "-tmp")
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isHidden = true
            var dir = directory
            try? dir.setResourceValues(values)
        }
    }

    public func makeTemporaryFileURL() throws -> URL {
        try ensureTemporaryDirectory()
        return try url(
            ExclusionRules.internalPrefix + "-tmp/"
                + ExclusionRules.internalPrefix + "-" + UUID().uuidString + ".part"
        )
    }

    public func cleanupTemporaryFiles(olderThan age: TimeInterval = 60 * 60 * 24) {
        guard let directory = try? url(ExclusionRules.internalPrefix + "-tmp"),
              let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
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
    ///   Inhalt haben. Größe und Zeitstempel allein reichen dafür nicht aus.
    /// - Wenn `expectedHash` `nil` ist, darf am Ziel noch keine Datei liegen.
    public func installDownloadedFile(from temp: URL, to relativePath: String, expectedHash: String?,
                                      expectedSize _: Int64?, expectedModified _: Double?, modifiedDate: Date?) throws {
        let target = try url(relativePath)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try url(relativePath)
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
            guard let before = try POSIXFileMetadata.read(atPath: target.path),
                  !before.isSymbolicLink else {
                try? fm.removeItem(at: temp)
                throw LocalFileError.changedSinceScan(relativePath)
            }
            let currentHash = try SHA256Hasher.hashFile(at: target)
            guard let afterHash = try POSIXFileMetadata.read(atPath: target.path),
                  afterHash.cacheToken == before.cacheToken,
                  !afterHash.isSymbolicLink,
                  currentHash == expectedHash else {
                try? fm.removeItem(at: temp)
                throw LocalFileError.changedSinceScan(relativePath)
            }
            _ = try url(relativePath)
            guard let immediatelyBeforeReplace = try POSIXFileMetadata.read(atPath: target.path),
                  immediatelyBeforeReplace.cacheToken == before.cacheToken,
                  !immediatelyBeforeReplace.isSymbolicLink else {
                try? fm.removeItem(at: temp)
                throw LocalFileError.changedSinceScan(relativePath)
            }
            try atomicReplace(
                target: target,
                with: temp,
                expectedMetadata: before,
                expectedHash: expectedHash,
                relativePath: relativePath
            )
        } else {
            guard expectedHash == nil else {
                try? fm.removeItem(at: temp)
                throw LocalFileError.changedSinceScan(relativePath)
            }
            do {
                _ = try url(relativePath)
                try fm.moveItem(at: temp, to: target)
            } catch {
                try? fm.removeItem(at: temp)
                throw Self.mapError(error)
            }
        }
    }

    /// Ersetzt `target` atomar durch `temp` (gleiches Volume).
    private func atomicReplace(target: URL, with temp: URL, expectedMetadata: POSIXFileMetadata.Values,
                               expectedHash: String, relativePath: String) throws {
        #if os(macOS)
        let exchange = temp.withUnsafeFileSystemRepresentation { tempPath in
            target.withUnsafeFileSystemRepresentation { targetPath in
                renamex_np(tempPath!, targetPath!, UInt32(RENAME_SWAP))
            }
        }
        if exchange == 0 {
            let displacedMetadata = try POSIXFileMetadata.read(atPath: temp.path)
            let displacedHash = try? SHA256Hasher.hashFile(at: temp)
            if displacedMetadata?.cacheToken == expectedMetadata.cacheToken,
               displacedMetadata?.isSymbolicLink == false,
               displacedHash == expectedHash {
                try fm.removeItem(at: temp)
                return
            }

            // Die atomar verdrängte Datei war nicht mehr die geprüfte Version.
            // Zuerst den Tausch rückgängig machen. Schlägt selbst das fehl,
            // wird die unbekannte lokale Version unter einem sichtbaren Namen
            // gerettet und niemals vom Aufrufer als Temp-Datei entfernt.
            let rollback = temp.withUnsafeFileSystemRepresentation { tempPath in
                target.withUnsafeFileSystemRepresentation { targetPath in
                    renamex_np(tempPath!, targetPath!, UInt32(RENAME_SWAP))
                }
            }
            if rollback != 0 {
                let rescue = uniqueDestination(
                    for: root.appendingPathComponent("Lokale Sicherheitskopie \(UUID().uuidString)")
                )
                do {
                    try fm.moveItem(at: temp, to: rescue)
                } catch {
                    throw LocalFileError.io(
                        "„\(relativePath)“ änderte sich während der atomaren Ersetzung; die lokale Version liegt noch unter \(temp.path)"
                    )
                }
            }
            throw LocalFileError.changedSinceScan(relativePath)
        }
        let exchangeError = errno
        if exchangeError == ENOTSUP || exchangeError == EINVAL {
            throw LocalFileError.io(
                "Das Dateisystem unterstützt keine atomar abgesicherte Ersetzung von „\(relativePath)“"
            )
        }
        throw Self.mapError(NSError(domain: NSPOSIXErrorDomain, code: Int(exchangeError)))
        #else
        let result = temp.withUnsafeFileSystemRepresentation { tempPath in
            target.withUnsafeFileSystemRepresentation { targetPath in
                rename(tempPath!, targetPath!)
            }
        }
        if result != 0 {
            let err = NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
            try? fm.removeItem(at: temp)
            throw Self.mapError(err)
        }
        #endif
    }

    /// Verschiebt eine Datei oder einen Ordner in den Papierkorb; falls das nicht
    /// möglich ist, in den Wiederherstellungsbereich.
    @discardableResult
    public func trash(_ relativePath: String, recoveryDirectory: URL?) throws -> URL? {
        let target = try url(relativePath)
        guard fm.fileExists(atPath: target.path) else { return nil }
        #if os(macOS)
        if prefersTrash {
            var resulting: NSURL?
            do {
                try fm.trashItem(at: target, resultingItemURL: &resulting)
                return resulting as URL?
            } catch {
                SyncLogger.shared.warning("local", "Papierkorb nicht verfügbar für \(relativePath): \(error.localizedDescription)")
            }
        }
        #endif
        guard let recoveryDirectory else {
            throw LocalFileError.io("Weder Papierkorb noch Wiederherstellungsbereich verfügbar")
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let desired = recoveryDirectory.appendingPathComponent(stamp, isDirectory: true).appendingPathComponent(relativePath)
        let dest = uniqueDestination(for: desired)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try url(relativePath)
        try fm.moveItem(at: target, to: dest)
        return dest
    }

    /// Nimmt genau den am Pfad vorhandenen Datei-Inode atomar aus dem
    /// Sync-Ordner, prüft erst danach dessen Inhalt und entfernt ausschließlich
    /// diese verifizierte Version. Eine zwischen Scan und Löschung atomar
    /// ersetzte Datei wird wiederhergestellt oder als sichtbare
    /// Sicherheitskopie bewahrt.
    @discardableResult
    public func trashVerifiedFile(_ relativePath: String, expectedHash: String,
                                  recoveryDirectory: URL?) throws -> URL? {
        let target = try url(relativePath)
        let quarantine = try makeTemporaryFileURL()
        do {
            try fm.moveItem(at: target, to: quarantine)
        } catch {
            try? fm.removeItem(at: quarantine)
            throw Self.mapError(error)
        }

        func restoreUnexpectedVersion() {
            if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: quarantine, to: target)
            }
            if fm.fileExists(atPath: quarantine.path) {
                let rescue = uniqueDestination(
                    for: root.appendingPathComponent("Lokale Sicherheitskopie \(UUID().uuidString)")
                )
                try? fm.moveItem(at: quarantine, to: rescue)
            }
        }

        do {
            guard let before = try POSIXFileMetadata.read(atPath: quarantine.path),
                  !before.isSymbolicLink else {
                restoreUnexpectedVersion()
                throw LocalFileError.changedSinceScan(relativePath)
            }
            let actualHash = try SHA256Hasher.hashFile(at: quarantine)
            guard let after = try POSIXFileMetadata.read(atPath: quarantine.path),
                  after.cacheToken == before.cacheToken,
                  !after.isSymbolicLink,
                  actualHash == expectedHash else {
                restoreUnexpectedVersion()
                throw LocalFileError.changedSinceScan(relativePath)
            }

            #if os(macOS)
            if prefersTrash {
                var resulting: NSURL?
                do {
                    try fm.trashItem(at: quarantine, resultingItemURL: &resulting)
                    return resulting as URL?
                } catch {
                    SyncLogger.shared.warning(
                        "local",
                        "Papierkorb nicht verfügbar für \(relativePath): \(error.localizedDescription)"
                    )
                }
            }
            #endif
            guard let recoveryDirectory else {
                restoreUnexpectedVersion()
                throw LocalFileError.io("Weder Papierkorb noch Wiederherstellungsbereich verfügbar")
            }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let desired = recoveryDirectory.appendingPathComponent(stamp, isDirectory: true)
                .appendingPathComponent(relativePath)
            let destination = uniqueDestination(for: desired)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: quarantine, to: destination)
            return destination
        } catch {
            if fm.fileExists(atPath: quarantine.path) { restoreUnexpectedVersion() }
            throw error
        }
    }

    public func move(_ from: String, to: String) throws {
        let source = try url(from)
        let dest = try url(to)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try url(to)
        if fm.fileExists(atPath: dest.path) { throw LocalFileError.io("Zielpfad „\(to)“ existiert bereits") }
        try fm.moveItem(at: source, to: dest)
    }

    public func copy(_ from: String, to: String) throws {
        let source = try url(from)
        let dest = try url(to)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try url(to)
        if fm.fileExists(atPath: dest.path) { throw LocalFileError.io("Zielpfad „\(to)“ existiert bereits") }
        try fm.copyItem(at: source, to: dest)
    }

    /// Liefert einen freien relativen Pfad, ohne vorhandene Dateien zu
    /// überschreiben. Der Suffix bleibt vor der Dateiendung.
    public func uniqueRelativePath(_ desiredPath: String) throws -> String {
        let normalized = try RelativePath.normalize(desiredPath)
        if !fm.fileExists(atPath: try url(normalized).path) { return normalized }
        let parent = RelativePath.parent(of: normalized) ?? ""
        let name = RelativePath.name(of: normalized)
        let nameURL = URL(fileURLWithPath: name)
        let ext = nameURL.pathExtension
        let base = nameURL.deletingPathExtension().lastPathComponent
        for number in 2...10_000 {
            let candidateName = disambiguatedFileName(base: base, extension: ext, suffix: " \(number)")
            let candidate = RelativePath.join(parent, candidateName)
            if !fm.fileExists(atPath: try url(candidate).path) { return candidate }
        }
        return RelativePath.join(
            parent,
            disambiguatedFileName(base: base, extension: ext, suffix: " \(UUID().uuidString)")
        )
    }

    private func disambiguatedFileName(base: String, extension ext: String, suffix: String) -> String {
        let safeExtension = RelativePath.truncateUTF8(ext, maxBytes: 32)
        let extensionPart = safeExtension.isEmpty ? "" : "." + safeExtension
        let baseBudget = max(1, 255 - suffix.utf8.count - extensionPart.utf8.count)
        var safeBase = RelativePath.truncateUTF8(base, maxBytes: baseBudget)
        if safeBase.isEmpty { safeBase = RelativePath.truncateUTF8("Datei", maxBytes: baseBudget) }
        return safeBase + suffix + extensionPart
    }

    /// Entfernt ausschließlich einen tatsächlich leeren Ordner. Ausgeschlossene
    /// Inhalte gehören weiterhin dem Benutzer und dürfen nie nebenbei verschwinden.
    public func removeDirectoryIfEmpty(_ relativePath: String, rules _: ExclusionRules) throws -> Bool {
        let target = try url(relativePath)
        _ = try url(relativePath)
        let result = target.withUnsafeFileSystemRepresentation { path in
            rmdir(path!)
        }
        if result == 0 { return true }
        let code = errno
        if code == ENOTEMPTY || code == EEXIST { return false }
        if code == ENOENT { return true }
        throw Self.mapError(NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
    }

    private func uniqueDestination(for desired: URL) -> URL {
        guard fm.fileExists(atPath: desired.path) else { return desired }
        let directory = desired.deletingLastPathComponent()
        let ext = desired.pathExtension
        let base = desired.deletingPathExtension().lastPathComponent
        for number in 2...10_000 {
            var name = "\(base) \(number)"
            if !ext.isEmpty { name += ".\(ext)" }
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let fallback = directory.appendingPathComponent("\(base) \(UUID().uuidString)")
        return ext.isEmpty ? fallback : fallback.appendingPathExtension(ext)
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

import Foundation

/// Erstellt eine Bestandsaufnahme des lokalen Ordners.
///
/// - Hashes werden nur wiederverwendet, wenn Größe, Änderungszeit,
///   Dateisystem-Identität und POSIX-Änderungszeit übereinstimmen.
/// - Symbolische Links werden nicht gefolgt und als übersprungen gemeldet.
/// - Dateien, die gerade geschrieben werden (Änderung jünger als `settleTime`),
///   werden als „beschäftigt“ gemeldet und im aktuellen Lauf nicht übertragen.
/// - macOS-Dateipakete (z. B. `.rtfd`, `.key`) werden als normale Ordner behandelt
///   und ihre Inhalte als einzelne Dateien synchronisiert.
public struct LocalScanner: Sendable {
    public let fileSystem: LocalFileSystem
    public let rules: ExclusionRules
    public let settleTime: TimeInterval

    public init(fileSystem: LocalFileSystem, rules: ExclusionRules, settleTime: TimeInterval = 2.0) {
        self.fileSystem = fileSystem
        self.rules = rules
        self.settleTime = settleTime
    }

    public struct Result: Sendable {
        public var snapshot: LocalSnapshot
        public var hashIndex: [String: SyncStore.LocalIndexEntry]
        /// Pfade, die wegen Groß-/Kleinschreibungs- oder Normalisierungskollision übersprungen wurden.
        public var collisions: [String]
    }

    /// Führt den Scan aus. Diese Funktion ist blockierend und sollte außerhalb des
    /// Main-Actors laufen (z. B. innerhalb eines Actors oder `Task.detached`).
    public func scan(previousIndex: [String: SyncStore.LocalIndexEntry], now: Date = Date(), isCancelled: @Sendable () -> Bool = { false }) throws -> Result {
        guard fileSystem.rootExists() else { throw LocalFileError.rootMissing }
        var items: [String: LocalItem] = [:]
        var index: [String: SyncStore.LocalIndexEntry] = [:]
        var busy: Set<String> = []
        var skipped: [String: String] = [:]
        var collisions: [String] = []
        var seenKeys: [String: String] = [:]   // caseInsensitiveKey → path
        var rawPathsByNormalizedPath: [String: String] = [:]
        var collisionPrefixes: Set<String> = []
        var complete = true

        var stack: [(rel: String, rawRel: String)] = [("", "")]
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .nameKey, .isRegularFileKey]

        while let (rel, rawRel) = stack.popLast() {
            if isCancelled() { throw CancellationError() }
            let dirURL = try fileSystem.url(rawRel)
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: Array(keys), options: [])
            } catch {
                SyncLogger.shared.warning("scan", "Ordner nicht lesbar: \(rel) — \(error.localizedDescription)")
                complete = false
                continue
            }
            for child in children {
                let rawName = child.lastPathComponent
                let name = rawName.precomposedStringWithCanonicalMapping
                let childRel = RelativePath.join(rel, name)
                let childRaw = RelativePath.join(rawRel, rawName)
                if rules.isExcluded(relativePath: childRel) { continue }
                guard let values = try? child.resourceValues(forKeys: keys) else {
                    complete = false
                    continue
                }
                if values.isSymbolicLink == true {
                    skipped[childRel] = "Symbolischer Link wird aus Sicherheitsgründen nicht synchronisiert; der Pfad bleibt unverändert"
                    continue
                }
                guard let childPOSIX = try? POSIXFileMetadata.read(atPath: child.path),
                      !childPOSIX.isSymbolicLink else {
                    skipped[childRel] = "Eintrag ist während der Bestandsaufnahme verschwunden oder wurde durch einen Link ersetzt"
                    complete = false
                    continue
                }
                if let existingRawPath = rawPathsByNormalizedPath[childRel],
                   !existingRawPath.utf8.elementsEqual(childRaw.utf8) {
                    collisionPrefixes.insert(childRel)
                    collisions.append(childRel)
                    skipped[childRel] = "Mehrere lokale Einträge ergeben denselben Unicode-normalisierten Namen"
                    continue
                }
                rawPathsByNormalizedPath[childRel] = childRaw
                let ciKey = RelativePath.caseInsensitiveKey(childRel)
                if let other = seenKeys[ciKey], other != childRel {
                    collisionPrefixes.insert(other)
                    collisionPrefixes.insert(childRel)
                    collisions.append(contentsOf: [other, childRel])
                    skipped[other] = "Kollidiert mit „\(childRel)“"
                    skipped[childRel] = "Kollidiert mit „\(other)“"
                    continue
                }
                seenKeys[ciKey] = childRel
                if values.isDirectory == true {
                    items[childRel] = LocalItem(path: childRel, rawPath: childRaw, kind: .directory)
                    stack.append((childRel, childRaw))
                    continue
                }
                guard values.isRegularFile == true else {
                    skipped[childRel] = "Kein regulärer Dateityp"
                    continue
                }
                let size = Int64(values.fileSize ?? 0)
                let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let posix = childPOSIX
                let age = now.timeIntervalSince1970 - modified
                if age >= 0 && age < settleTime {
                    busy.insert(childRel)
                    continue
                }
                let hash: String
                if let cached = previousIndex[childRel],
                   cached.size == size,
                   cached.mtime == modified,
                   cached.fileID == posix.cacheToken,
                   cached.changeTime == posix.changeTime {
                    hash = cached.hash
                } else {
                    do {
                        hash = try SHA256Hasher.hashFile(at: child, isCancelled: isCancelled)
                    } catch {
                        skipped[childRel] = "Nicht lesbar: \(error.localizedDescription)"
                        complete = false
                        continue
                    }
                    // Erneut prüfen, ob die Datei während des Hashens verändert wurde.
                    if let after = try? child.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                       let afterPOSIX = try? POSIXFileMetadata.read(atPath: child.path),
                       Int64(after.fileSize ?? 0) != size
                        || (after.contentModificationDate?.timeIntervalSince1970 ?? 0) != modified
                        || afterPOSIX.cacheToken != posix.cacheToken {
                        busy.insert(childRel)
                        continue
                    }
                }
                items[childRel] = LocalItem(path: childRel, rawPath: childRaw, kind: .file, size: size, modified: modified, hash: hash)
                index[childRel] = SyncStore.LocalIndexEntry(
                    size: size,
                    mtime: modified,
                    hash: hash,
                    fileID: posix.cacheToken,
                    changeTime: posix.changeTime
                )
            }
        }
        try fileSystem.validateRootIdentity()
        if !collisionPrefixes.isEmpty {
            for prefix in collisionPrefixes {
                for path in items.keys where path == prefix || RelativePath.isDescendant(path, of: prefix) {
                    items[path] = nil
                    index[path] = nil
                }
            }
        }
        collisions = Array(Set(collisions)).sorted()
        let snapshot = LocalSnapshot(items: items, isComplete: complete, busyPaths: busy, skippedPaths: skipped)
        return Result(snapshot: snapshot, hashIndex: index, collisions: collisions)
    }
}

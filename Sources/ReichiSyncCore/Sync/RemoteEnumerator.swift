import Foundation

/// Erstellt die Server-Bestandsaufnahme – entweder über `sync-collection`
/// (RFC 6578) mit zwischengespeichertem Bestand oder über eine rekursive
/// `PROPFIND Depth: 1`-Traversierung.
public struct RemoteEnumerator: Sendable {
    public let client: WebDAVClientProtocol
    public let rules: ExclusionRules
    public let concurrency: Int

    public init(client: WebDAVClientProtocol, rules: ExclusionRules, concurrency: Int = 4) {
        self.client = client
        self.rules = rules
        self.concurrency = max(1, concurrency)
    }

    /// Rekursive Traversierung. Verbindungsfehler brechen den Vorgang ab (→ offline);
    /// andere Fehler in Unterordnern werden als unvollständige Bereiche vermerkt.
    public func fullWalk(isCancelled: @Sendable () -> Bool = { false }) async throws -> RemoteSnapshot {
        var items: [String: RemoteItem] = [:]
        var failed: Set<String> = []
        var complete = true
        var pending: [String] = [""]
        var scheduledDirectories: Set<String> = [""]
        var rawPathsByNormalizedPath: [String: String] = [:]
        var collisions: Set<String> = []

        while !pending.isEmpty {
            if isCancelled() { throw CancellationError() }
            let batch = Array(pending.prefix(concurrency))
            pending.removeFirst(batch.count)
            let client = self.client
            let results: [(String, Result<[RemoteItem], Error>)] = await withTaskGroup(of: (String, Result<[RemoteItem], Error>).self) { group in
                for dir in batch {
                    group.addTask {
                        do {
                            return (dir, .success(try await client.list(directory: dir)))
                        } catch {
                            return (dir, .failure(error))
                        }
                    }
                }
                var collected: [(String, Result<[RemoteItem], Error>)] = []
                for await r in group { collected.append(r) }
                return collected
            }
            for (rawDirectory, result) in results {
                let directory = (try? RelativePath.normalize(rawDirectory)) ?? rawDirectory
                switch result {
                case .success(let children):
                    for var child in children {
                        guard let normalized = try? RelativePath.normalize(child.path),
                              RelativePath.parent(of: normalized) == directory else {
                            // Eine unerwartete oder ungültige Serverantwort macht
                            // die Aufnahme unvollständig. So kann daraus niemals
                            // eine Löschung abgeleitet werden.
                            complete = false
                            failed.insert(directory)
                            continue
                        }
                        if rules.isExcluded(relativePath: normalized) { continue }
                        if let existingRawPath = rawPathsByNormalizedPath[normalized],
                           !existingRawPath.utf8.elementsEqual(child.rawPath.utf8) {
                            // NFC/NFD-Varianten können auf dem Server getrennte
                            // Ressourcen sein, auf dem Mac aber denselben Namen
                            // bezeichnen. Keine davon darf die andere ersetzen.
                            items[normalized] = nil
                            collisions.insert(normalized)
                            complete = false
                            failed.insert(directory)
                            continue
                        }
                        rawPathsByNormalizedPath[normalized] = child.rawPath
                        if collisions.contains(normalized) { continue }
                        child.path = normalized
                        items[normalized] = child
                        if child.kind == .directory, scheduledDirectories.insert(normalized).inserted {
                            pending.append(child.rawPath)
                        }
                    }
                case .failure(let error):
                    if let dav = error as? WebDAVError {
                        if directory.isEmpty { throw dav }
                        if dav.isConnectivityProblem { throw dav }
                        if case .authenticationRequired = dav { throw dav }
                        if case .cancelled = dav { throw dav }
                    } else if error is CancellationError {
                        throw error
                    } else if directory.isEmpty {
                        throw error
                    }
                    SyncLogger.shared.warning("remote", "Auflistung fehlgeschlagen für „\(directory)“: \(error)")
                    failed.insert(directory)
                    complete = false
                }
            }
        }
        return RemoteSnapshot(
            items: items,
            isComplete: complete,
            failedPrefixes: failed,
            collisions: collisions.sorted(),
            syncToken: nil
        )
    }

    /// Aktualisiert einen zwischengespeicherten Bestand über `sync-collection`.
    /// Wirft `WebDAVError.invalidSyncToken`, wenn eine vollständige Traversierung nötig ist.
    public func incremental(cached: [String: RemoteItem], token: String) async throws -> RemoteSnapshot {
        let result = try await client.syncCollection(token: token)
        // Regeln können sich zwischen Läufen geändert haben. Ausgeschlossene
        // Einträge dürfen nicht aus dem persistenten Cache wieder auftauchen.
        var items = cached.filter { !rules.isExcluded(relativePath: $0.key) }
        for change in result.changes {
            let path = try RelativePath.normalize(change.path)
            if rules.isExcluded(relativePath: path) { continue }
            if change.deleted {
                items[path] = nil
                for key in items.keys where RelativePath.isDescendant(key, of: path) { items[key] = nil }
            } else if var item = change.item {
                if let existing = items[path],
                   !existing.rawPath.utf8.elementsEqual(item.rawPath.utf8) {
                    // Der persistierte Index kann zwei kanonisch äquivalente
                    // Servernamen nicht darstellen. Vollständige Traversierung
                    // erzwingen, die den Konflikt explizit einfriert.
                    throw WebDAVError.invalidResponse("Mehrdeutiger Unicode-Pfad „\(path)“")
                }
                item.path = path
                items[path] = item
            }
        }
        return RemoteSnapshot(items: items, isComplete: true, failedPrefixes: [], syncToken: result.newToken)
    }
}

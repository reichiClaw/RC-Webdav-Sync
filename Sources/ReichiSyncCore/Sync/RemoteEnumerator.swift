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
            for (dir, result) in results {
                switch result {
                case .success(let children):
                    for child in children {
                        if rules.isExcluded(relativePath: child.path) { continue }
                        // Sicherstellen, dass das Kind tatsächlich unterhalb des angefragten Ordners liegt.
                        guard dir.isEmpty || RelativePath.isDescendant(child.path, of: dir) else { continue }
                        items[child.path] = child
                        if child.kind == .directory { pending.append(child.rawPath) }
                    }
                case .failure(let error):
                    if let dav = error as? WebDAVError {
                        if dir.isEmpty { throw dav }
                        if dav.isConnectivityProblem { throw dav }
                        if case .authenticationRequired = dav { throw dav }
                        if case .cancelled = dav { throw dav }
                    } else if error is CancellationError {
                        throw error
                    } else if dir.isEmpty {
                        throw error
                    }
                    SyncLogger.shared.warning("remote", "Auflistung fehlgeschlagen für „\(dir)“: \(error)")
                    let key = (try? RelativePath.normalize(dir)) ?? dir
                    failed.insert(key)
                    complete = false
                }
            }
        }
        return RemoteSnapshot(items: items, isComplete: complete, failedPrefixes: failed, syncToken: nil)
    }

    /// Aktualisiert einen zwischengespeicherten Bestand über `sync-collection`.
    /// Wirft `WebDAVError.invalidSyncToken`, wenn eine vollständige Traversierung nötig ist.
    public func incremental(cached: [String: RemoteItem], token: String) async throws -> RemoteSnapshot {
        let result = try await client.syncCollection(token: token)
        var items = cached
        for change in result.changes {
            if rules.isExcluded(relativePath: change.path) { continue }
            if change.deleted {
                items[change.path] = nil
                for key in items.keys where RelativePath.isDescendant(key, of: change.path) { items[key] = nil }
            } else if let item = change.item {
                items[change.path] = item
            }
        }
        return RemoteSnapshot(items: items, isComplete: true, failedPrefixes: [], syncToken: result.newToken)
    }
}

import Foundation

/// Persistente Ablage für Synchronisierungsstände, Hash-Cache, Warteschlange,
/// Konflikte, Aktivitätsprotokoll und ausstehende Löschbestätigungen.
///
/// Die Datenbank liegt außerhalb des synchronisierten Ordners
/// (z. B. `~/Library/Application Support/reichi Sync/sync.sqlite`).
public actor SyncStore {
    private let db: SQLiteDatabase
    private static let schemaVersion = 1

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try Self.migrate(db)
    }

    /// Erzeugt eine temporäre In-Memory-Datenbank (für Tests).
    public static func inMemory() throws -> SyncStore {
        try SyncStore(path: ":memory:")
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        if db.userVersion >= Self.schemaVersion { return }
        try db.transaction {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """)
            try db.execute("""
            CREATE TABLE IF NOT EXISTS accounts (
                id TEXT PRIMARY KEY,
                json TEXT NOT NULL
            )
            """)
            try db.execute("""
            CREATE TABLE IF NOT EXISTS mappings (
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                mapping_key TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_successful_sync REAL,
                sync_token TEXT,
                remote_index_complete INTEGER NOT NULL DEFAULT 0
            )
            """)
            try db.execute("CREATE INDEX IF NOT EXISTS idx_mappings_key ON mappings(account_id, mapping_key)")
            try db.execute("""
            CREATE TABLE IF NOT EXISTS entries (
                mapping_id TEXT NOT NULL,
                path TEXT NOT NULL,
                kind TEXT NOT NULL,
                local_hash TEXT,
                local_size INTEGER NOT NULL DEFAULT 0,
                local_mtime REAL NOT NULL DEFAULT 0,
                remote_validator TEXT,
                remote_validator_strong INTEGER NOT NULL DEFAULT 0,
                remote_size INTEGER NOT NULL DEFAULT 0,
                remote_mtime REAL,
                synced_at REAL NOT NULL,
                PRIMARY KEY (mapping_id, path)
            )
            """)
            try db.execute("""
            CREATE TABLE IF NOT EXISTS local_index (
                mapping_id TEXT NOT NULL,
                path TEXT NOT NULL,
                size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                hash TEXT NOT NULL,
                PRIMARY KEY (mapping_id, path)
            )
            """)
            try db.execute("""
            CREATE TABLE IF NOT EXISTS remote_index (
                mapping_id TEXT NOT NULL,
                path TEXT NOT NULL,
                raw_path TEXT NOT NULL,
                kind TEXT NOT NULL,
                size INTEGER NOT NULL DEFAULT 0,
                mtime REAL,
                validator TEXT,
                validator_strong INTEGER NOT NULL DEFAULT 0,
                content_type TEXT,
                PRIMARY KEY (mapping_id, path)
            )
            """)
            try db.execute("""
            CREATE TABLE IF NOT EXISTS conflicts (
                id TEXT PRIMARY KEY,
                mapping_id TEXT NOT NULL,
                path TEXT NOT NULL,
                json TEXT NOT NULL,
                status TEXT NOT NULL,
                detected_at REAL NOT NULL
            )
            """)
            try db.execute("CREATE INDEX IF NOT EXISTS idx_conflicts_mapping ON conflicts(mapping_id, status)")
            try db.execute("""
            CREATE TABLE IF NOT EXISTS transfers (
                id TEXT PRIMARY KEY,
                mapping_id TEXT NOT NULL,
                started_at REAL NOT NULL,
                json TEXT NOT NULL
            )
            """)
            try db.execute("CREATE INDEX IF NOT EXISTS idx_transfers_mapping ON transfers(mapping_id, started_at)")
            try db.execute("""
            CREATE TABLE IF NOT EXISTS queue (
                mapping_id TEXT NOT NULL,
                path TEXT NOT NULL,
                direction TEXT NOT NULL,
                size INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                PRIMARY KEY (mapping_id, path, direction)
            )
            """)
            try db.execute("""
            CREATE TABLE IF NOT EXISTS pending_deletions (
                mapping_id TEXT NOT NULL,
                path TEXT NOT NULL,
                side TEXT NOT NULL,
                kind TEXT NOT NULL,
                planned_at REAL NOT NULL,
                PRIMARY KEY (mapping_id, path, side)
            )
            """)
            db.userVersion = Self.schemaVersion
        }
    }

    // MARK: - Meta

    public func meta(_ key: String) -> String? {
        try? db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.string("value")
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.execute("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
        } else {
            try db.execute("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    // MARK: - Accounts

    public func saveAccount(_ account: AccountConfiguration) throws {
        let json = try String(decoding: JSONEncoder().encode(account), as: UTF8.self)
        try db.execute("INSERT INTO accounts(id, json) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json", [.text(account.id), .text(json)])
    }

    public func accounts() throws -> [AccountConfiguration] {
        try db.query("SELECT json FROM accounts").compactMap { row in
            guard let json = row.string("json") else { return nil }
            return try? JSONDecoder().decode(AccountConfiguration.self, from: Data(json.utf8))
        }
    }

    public func deleteAccount(id: String) throws {
        try db.transaction {
            let mappings = try db.query("SELECT id FROM mappings WHERE account_id = ?", [.text(id)]).compactMap { $0.string("id") }
            for m in mappings { try deleteMappingData(m) }
            try db.execute("DELETE FROM mappings WHERE account_id = ?", [.text(id)])
            try db.execute("DELETE FROM accounts WHERE id = ?", [.text(id)])
        }
    }

    // MARK: - Mappings

    /// Liefert die Zuordnung für den aktuellen Schlüssel oder legt eine neue an.
    /// Eine Änderung des Server- oder lokalen Pfades führt damit zu einem leeren
    /// Synchronisierungsstand — alte Baselines können keine falschen Löschungen auslösen.
    public func mapping(for account: AccountConfiguration) throws -> SyncMapping {
        if let row = try db.query("SELECT * FROM mappings WHERE account_id = ? AND mapping_key = ?", [.text(account.id), .text(account.mappingKey)]).first {
            return Self.mapping(from: row)
        }
        let mapping = SyncMapping(accountID: account.id, mappingKey: account.mappingKey)
        try db.execute("""
        INSERT INTO mappings(id, account_id, mapping_key, created_at, last_successful_sync, sync_token, remote_index_complete)
        VALUES(?, ?, ?, ?, NULL, NULL, 0)
        """, [.text(mapping.id), .text(mapping.accountID), .text(mapping.mappingKey), .real(mapping.createdAt.timeIntervalSince1970)])
        return mapping
    }

    public func mapping(id: String) throws -> SyncMapping? {
        try db.query("SELECT * FROM mappings WHERE id = ?", [.text(id)]).first.map(Self.mapping(from:))
    }

    private static func mapping(from row: SQLRow) -> SyncMapping {
        SyncMapping(
            id: row.string("id") ?? "",
            accountID: row.string("account_id") ?? "",
            mappingKey: row.string("mapping_key") ?? "",
            createdAt: row.date("created_at") ?? Date(),
            lastSuccessfulSync: row.date("last_successful_sync"),
            syncToken: row.string("sync_token"),
            remoteIndexIsComplete: row.bool("remote_index_complete")
        )
    }

    public func updateMapping(_ mapping: SyncMapping) throws {
        try db.execute("""
        UPDATE mappings SET last_successful_sync = ?, sync_token = ?, remote_index_complete = ? WHERE id = ?
        """, [SQLValue(mapping.lastSuccessfulSync), SQLValue(mapping.syncToken), SQLValue(mapping.remoteIndexIsComplete), .text(mapping.id)])
    }

    public func setLastSuccessfulSync(_ date: Date, mappingID: String) throws {
        try db.execute("UPDATE mappings SET last_successful_sync = ? WHERE id = ?", [SQLValue(date), .text(mappingID)])
    }

    public func setSyncToken(_ token: String?, remoteIndexComplete: Bool, mappingID: String) throws {
        try db.execute("UPDATE mappings SET sync_token = ?, remote_index_complete = ? WHERE id = ?", [SQLValue(token), SQLValue(remoteIndexComplete), .text(mappingID)])
    }

    private func deleteMappingData(_ mappingID: String) throws {
        for table in ["entries", "local_index", "remote_index", "conflicts", "transfers", "queue", "pending_deletions"] {
            try db.execute("DELETE FROM \(table) WHERE mapping_id = ?", [.text(mappingID)])
        }
    }

    // MARK: - Baseline

    public func baseline(mappingID: String) throws -> [String: BaselineEntry] {
        var result: [String: BaselineEntry] = [:]
        for row in try db.query("SELECT * FROM entries WHERE mapping_id = ?", [.text(mappingID)]) {
            guard let path = row.string("path"), let kindRaw = row.string("kind"), let kind = ItemKind(rawValue: kindRaw) else { continue }
            result[path] = BaselineEntry(
                path: path, kind: kind,
                localHash: row.string("local_hash"),
                localSize: row.int64("local_size") ?? 0,
                localModified: row.double("local_mtime") ?? 0,
                remoteValidator: row.string("remote_validator"),
                remoteValidatorIsStrong: row.bool("remote_validator_strong"),
                remoteSize: row.int64("remote_size") ?? 0,
                remoteModified: row.double("remote_mtime"),
                syncedAt: row.date("synced_at") ?? Date()
            )
        }
        return result
    }

    public func baselineCount(mappingID: String) throws -> Int {
        try db.query("SELECT COUNT(*) AS c FROM entries WHERE mapping_id = ?", [.text(mappingID)]).first?.int("c") ?? 0
    }

    public func upsertBaseline(_ entry: BaselineEntry, mappingID: String) throws {
        try db.execute("""
        INSERT INTO entries(mapping_id, path, kind, local_hash, local_size, local_mtime, remote_validator, remote_validator_strong, remote_size, remote_mtime, synced_at)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(mapping_id, path) DO UPDATE SET
            kind = excluded.kind, local_hash = excluded.local_hash, local_size = excluded.local_size, local_mtime = excluded.local_mtime,
            remote_validator = excluded.remote_validator, remote_validator_strong = excluded.remote_validator_strong,
            remote_size = excluded.remote_size, remote_mtime = excluded.remote_mtime, synced_at = excluded.synced_at
        """, [
            .text(mappingID), .text(entry.path), .text(entry.kind.rawValue), SQLValue(entry.localHash), .integer(entry.localSize),
            .real(entry.localModified), SQLValue(entry.remoteValidator), SQLValue(entry.remoteValidatorIsStrong), .integer(entry.remoteSize),
            SQLValue(entry.remoteModified), .real(entry.syncedAt.timeIntervalSince1970),
        ])
    }

    public func removeBaseline(path: String, mappingID: String) throws {
        try db.execute("DELETE FROM entries WHERE mapping_id = ? AND path = ?", [.text(mappingID), .text(path)])
    }

    /// Entfernt einen Eintrag und alle Nachkommen.
    public func removeBaselineSubtree(path: String, mappingID: String) throws {
        try db.execute("DELETE FROM entries WHERE mapping_id = ? AND (path = ? OR path LIKE ? ESCAPE '\\')", [.text(mappingID), .text(path), .text(Self.likePrefix(path))])
    }

    /// Benennt einen Baseline-Eintrag samt Nachkommen um (nach erfolgreichem MOVE).
    public func renameBaseline(from: String, to: String, mappingID: String) throws {
        let all = try baseline(mappingID: mappingID)
        try db.transaction {
            for (path, entry) in all where path == from || RelativePath.isDescendant(path, of: from) {
                let newPath = to + path.dropFirst(from.count)
                try db.execute("DELETE FROM entries WHERE mapping_id = ? AND path = ?", [.text(mappingID), .text(path)])
                var moved = entry
                moved.path = String(newPath)
                try upsertBaseline(moved, mappingID: mappingID)
            }
        }
    }

    private static func likePrefix(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return escaped + "/%"
    }

    // MARK: - Local hash cache

    public struct LocalIndexEntry: Sendable, Hashable {
        public var size: Int64
        public var mtime: Double
        public var hash: String
        public init(size: Int64, mtime: Double, hash: String) {
            self.size = size
            self.mtime = mtime
            self.hash = hash
        }
    }

    public func localIndex(mappingID: String) throws -> [String: LocalIndexEntry] {
        var result: [String: LocalIndexEntry] = [:]
        for row in try db.query("SELECT path, size, mtime, hash FROM local_index WHERE mapping_id = ?", [.text(mappingID)]) {
            guard let path = row.string("path"), let hash = row.string("hash") else { continue }
            result[path] = LocalIndexEntry(size: row.int64("size") ?? 0, mtime: row.double("mtime") ?? 0, hash: hash)
        }
        return result
    }

    public func replaceLocalIndex(_ index: [String: LocalIndexEntry], mappingID: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM local_index WHERE mapping_id = ?", [.text(mappingID)])
            for (path, e) in index {
                try db.execute("INSERT INTO local_index(mapping_id, path, size, mtime, hash) VALUES(?, ?, ?, ?, ?)",
                               [.text(mappingID), .text(path), .integer(e.size), .real(e.mtime), .text(e.hash)])
            }
        }
    }

    // MARK: - Remote index (Cache für Sync-Collection)

    public func remoteIndex(mappingID: String) throws -> [String: RemoteItem] {
        var result: [String: RemoteItem] = [:]
        for row in try db.query("SELECT * FROM remote_index WHERE mapping_id = ?", [.text(mappingID)]) {
            guard let path = row.string("path"), let kindRaw = row.string("kind"), let kind = ItemKind(rawValue: kindRaw) else { continue }
            result[path] = RemoteItem(path: path, rawPath: row.string("raw_path") ?? path, kind: kind, size: row.int64("size") ?? 0,
                                      modified: row.double("mtime"), validator: row.string("validator"),
                                      validatorIsStrong: row.bool("validator_strong"), contentType: row.string("content_type"))
        }
        return result
    }

    public func replaceRemoteIndex(_ items: [String: RemoteItem], mappingID: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM remote_index WHERE mapping_id = ?", [.text(mappingID)])
            for (_, item) in items { try insertRemoteIndexItem(item, mappingID: mappingID) }
        }
    }

    private func insertRemoteIndexItem(_ item: RemoteItem, mappingID: String) throws {
        try db.execute("""
        INSERT INTO remote_index(mapping_id, path, raw_path, kind, size, mtime, validator, validator_strong, content_type)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(mapping_id, path) DO UPDATE SET raw_path = excluded.raw_path, kind = excluded.kind, size = excluded.size,
            mtime = excluded.mtime, validator = excluded.validator, validator_strong = excluded.validator_strong, content_type = excluded.content_type
        """, [.text(mappingID), .text(item.path), .text(item.rawPath), .text(item.kind.rawValue), .integer(item.size), SQLValue(item.modified),
              SQLValue(item.validator), SQLValue(item.validatorIsStrong), SQLValue(item.contentType)])
    }

    // MARK: - Conflicts

    public func conflicts(mappingID: String, includeResolved: Bool = false) throws -> [ConflictRecord] {
        let sql = includeResolved
            ? "SELECT json FROM conflicts WHERE mapping_id = ? ORDER BY detected_at DESC"
            : "SELECT json FROM conflicts WHERE mapping_id = ? AND status = 'open' ORDER BY detected_at DESC"
        return try db.query(sql, [.text(mappingID)]).compactMap { row in
            guard let json = row.string("json") else { return nil }
            return try? JSONDecoder().decode(ConflictRecord.self, from: Data(json.utf8))
        }
    }

    public func openConflict(path: String, mappingID: String) throws -> ConflictRecord? {
        try db.query("SELECT json FROM conflicts WHERE mapping_id = ? AND path = ? AND status = 'open'", [.text(mappingID), .text(path)]).first.flatMap { row in
            row.string("json").flatMap { try? JSONDecoder().decode(ConflictRecord.self, from: Data($0.utf8)) }
        }
    }

    public func saveConflict(_ conflict: ConflictRecord, mappingID: String) throws {
        let json = try String(decoding: JSONEncoder().encode(conflict), as: UTF8.self)
        try db.execute("""
        INSERT INTO conflicts(id, mapping_id, path, json, status, detected_at) VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET json = excluded.json, status = excluded.status, path = excluded.path
        """, [.text(conflict.id), .text(mappingID), .text(conflict.path), .text(json), .text(conflict.status.rawValue), .real(conflict.detectedAt.timeIntervalSince1970)])
    }

    public func deleteConflict(id: String) throws {
        try db.execute("DELETE FROM conflicts WHERE id = ?", [.text(id)])
    }

    public func openConflictCount(mappingID: String) throws -> Int {
        try db.query("SELECT COUNT(*) AS c FROM conflicts WHERE mapping_id = ? AND status = 'open'", [.text(mappingID)]).first?.int("c") ?? 0
    }

    // MARK: - Transfers (Aktivität)

    public func saveTransfer(_ record: TransferRecord, mappingID: String) throws {
        let json = try String(decoding: JSONEncoder().encode(record), as: UTF8.self)
        try db.execute("""
        INSERT INTO transfers(id, mapping_id, started_at, json) VALUES(?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET json = excluded.json
        """, [.text(record.id), .text(mappingID), .real(record.startedAt.timeIntervalSince1970), .text(json)])
    }

    public func transfers(mappingID: String, limit: Int = 300) throws -> [TransferRecord] {
        try db.query("SELECT json FROM transfers WHERE mapping_id = ? ORDER BY started_at DESC LIMIT ?", [.text(mappingID), .integer(Int64(limit))]).compactMap { row in
            guard let json = row.string("json") else { return nil }
            return try? JSONDecoder().decode(TransferRecord.self, from: Data(json.utf8))
        }
    }

    /// Markiert Übertragungen, die beim letzten Lauf noch liefen, als abgebrochen
    /// (z. B. nach Absturz). Die eigentliche Arbeit wird durch den nächsten Abgleich wiederholt.
    public func markRunningTransfersInterrupted(mappingID: String) throws {
        for var t in try transfers(mappingID: mappingID, limit: 10_000) where t.state == .running || t.state == .queued {
            t.state = .cancelled
            t.finishedAt = Date()
            t.errorMessage = "Unterbrochen (App wurde beendet). Wird beim nächsten Abgleich erneut geprüft."
            try saveTransfer(t, mappingID: mappingID)
        }
    }

    public func pruneTransfers(mappingID: String, keep: Int = 1000) throws {
        try db.execute("""
        DELETE FROM transfers WHERE mapping_id = ? AND id NOT IN (
            SELECT id FROM transfers WHERE mapping_id = ? ORDER BY started_at DESC LIMIT ?
        )
        """, [.text(mappingID), .text(mappingID), .integer(Int64(keep))])
    }

    // MARK: - Queue

    public func replaceQueue(_ items: [QueuedItem], mappingID: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM queue WHERE mapping_id = ?", [.text(mappingID)])
            for item in items {
                try db.execute("INSERT OR REPLACE INTO queue(mapping_id, path, direction, size, created_at) VALUES(?, ?, ?, ?, ?)",
                               [.text(mappingID), .text(item.path), .text(item.direction.rawValue), .integer(item.size), .real(item.createdAt.timeIntervalSince1970)])
            }
        }
    }

    public func removeQueued(path: String, direction: TransferDirection, mappingID: String) throws {
        try db.execute("DELETE FROM queue WHERE mapping_id = ? AND path = ? AND direction = ?", [.text(mappingID), .text(path), .text(direction.rawValue)])
    }

    public func queue(mappingID: String) throws -> [QueuedItem] {
        try db.query("SELECT * FROM queue WHERE mapping_id = ? ORDER BY created_at", [.text(mappingID)]).compactMap { row in
            guard let path = row.string("path"), let dirRaw = row.string("direction"), let dir = TransferDirection(rawValue: dirRaw) else { return nil }
            return QueuedItem(path: path, direction: dir, size: row.int64("size") ?? 0, createdAt: row.date("created_at") ?? Date())
        }
    }

    // MARK: - Pending deletions (Löschschutz)

    public func replacePendingDeletions(_ items: [PendingDeletion], mappingID: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM pending_deletions WHERE mapping_id = ?", [.text(mappingID)])
            for item in items {
                try db.execute("INSERT OR REPLACE INTO pending_deletions(mapping_id, path, side, kind, planned_at) VALUES(?, ?, ?, ?, ?)",
                               [.text(mappingID), .text(item.path), .text(item.side.rawValue), .text(item.kind.rawValue), .real(item.plannedAt.timeIntervalSince1970)])
            }
        }
    }

    public func pendingDeletions(mappingID: String) throws -> [PendingDeletion] {
        try db.query("SELECT * FROM pending_deletions WHERE mapping_id = ? ORDER BY path", [.text(mappingID)]).compactMap { row in
            guard let path = row.string("path"), let side = row.string("side").flatMap(PendingDeletion.Side.init(rawValue:)),
                  let kind = row.string("kind").flatMap(ItemKind.init(rawValue:)) else { return nil }
            return PendingDeletion(path: path, kind: kind, side: side, plannedAt: row.date("planned_at") ?? Date())
        }
    }

    public func clearPendingDeletions(mappingID: String) throws {
        try db.execute("DELETE FROM pending_deletions WHERE mapping_id = ?", [.text(mappingID)])
    }

    /// Setzt den Synchronisierungsstand einer Zuordnung vollständig zurück.
    public func resetMapping(id: String) throws {
        try db.transaction {
            try deleteMappingData(id)
            try db.execute("UPDATE mappings SET last_successful_sync = NULL, sync_token = NULL, remote_index_complete = 0 WHERE id = ?", [.text(id)])
        }
    }
}

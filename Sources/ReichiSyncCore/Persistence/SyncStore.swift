import Foundation

public enum SyncStoreError: LocalizedError, Sendable {
    case unsupportedSchema(existing: Int, supported: Int)
    case corruptRecord(table: String, identifier: String, details: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let existing, let supported):
            return "Die Synchronisierungsdatenbank hat Schema-Version \(existing), diese App unterstützt höchstens Version \(supported)."
        case .corruptRecord(let table, let identifier, let details):
            return "Beschädigter Datensatz in „\(table)“ (\(identifier)): \(details)"
        }
    }
}

/// Persistente Ablage für Synchronisierungsstände, Hash-Cache, Warteschlange,
/// Konflikte, Aktivitätsprotokoll und ausstehende Löschbestätigungen.
///
/// Die Datenbank liegt außerhalb des synchronisierten Ordners
/// (z. B. `~/Library/Application Support/reichi Sync/sync.sqlite`).
public actor SyncStore {
    private let db: SQLiteDatabase
    private static let schemaVersion = 5

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try Self.migrate(db)
    }

    /// Erzeugt eine temporäre In-Memory-Datenbank (für Tests).
    public static func inMemory() throws -> SyncStore {
        try SyncStore(path: ":memory:")
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        let existingVersion = try db.userVersion()
        guard existingVersion <= Self.schemaVersion else {
            throw SyncStoreError.unsupportedSchema(existing: existingVersion, supported: Self.schemaVersion)
        }
        if existingVersion == Self.schemaVersion { return }
        let needsSecretScrub = existingVersion > 0 && existingVersion < 4
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
                file_id TEXT,
                change_time REAL,
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
                confirmed INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (mapping_id, path, side)
            )
            """)
            try db.execute("""
            CREATE TABLE IF NOT EXISTS upload_sessions (
                mapping_id TEXT NOT NULL,
                path TEXT NOT NULL,
                json TEXT NOT NULL,
                PRIMARY KEY (mapping_id, path)
            )
            """)
            try db.execute("""
            CREATE TABLE IF NOT EXISTS shares (
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                json TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """)
            let localIndexColumns = Set(try db.query("PRAGMA table_info(local_index)").compactMap { $0.string("name") })
            if !localIndexColumns.contains("file_id") {
                try db.execute("ALTER TABLE local_index ADD COLUMN file_id TEXT")
            }
            if !localIndexColumns.contains("change_time") {
                try db.execute("ALTER TABLE local_index ADD COLUMN change_time REAL")
            }
            let pendingDeletionColumns = Set(try db.query("PRAGMA table_info(pending_deletions)").compactMap { $0.string("name") })
            if !pendingDeletionColumns.contains("confirmed") {
                try db.execute("ALTER TABLE pending_deletions ADD COLUMN confirmed INTEGER NOT NULL DEFAULT 0")
            }
            if existingVersion < 5 {
                // Schema 4 markierte den gesamten Löschplan über einen
                // Meta-Eintrag als bestätigt. In Schema 5 trägt jede Zeile
                // ihren Zustand selbst, damit neue Bestätigungen neben einer
                // bereits freigegebenen, aber blockierten Löschung bestehen.
                try db.execute("""
                UPDATE pending_deletions
                SET confirmed = 1
                WHERE EXISTS (
                    SELECT 1 FROM meta
                    WHERE meta.key = 'confirmed-deletions.' || pending_deletions.mapping_id
                      AND meta.value = '1'
                )
                """)
                try db.execute("DELETE FROM meta WHERE key LIKE 'confirmed-deletions.%'")
            }

            if existingVersion < 4 {
                // Ältere Versionen speicherten bei Cloudreve kurzlebige
                // Upload-Zugangsdaten und Freigabe-Passwörter in SQLite.
                // Diese Daten werden beim Upgrade vollständig entfernt.
                try db.execute("DELETE FROM upload_sessions")
                try db.execute("DELETE FROM shares")
            }

            // Schema 1/2 band den gemeinsamen Stand weder an den Benutzernamen
            // noch an die Cloudreve-Kontoidentität oder Ausschlussregeln.
            // Eine automatische Übernahme könnte deshalb den Stand eines
            // anderen Kontos als Baseline verwenden und dessen Dateien lokal
            // überschreiben. Alte Zuordnungen bleiben zur Diagnose erhalten;
            // `mapping(for:)` legt für den identitätsgebundenen Schlüssel einen
            // leeren Stand an, sodass der nächste Lauf sicher zusammenführt.

            // Der Constraint ist Teil der Korrektheit: Zwei Store-Instanzen
            // dürfen nie getrennte Baselines für dieselbe Zuordnung anlegen.
            try deduplicateMappings(db)
            try db.execute("DROP INDEX IF EXISTS idx_mappings_key")
            try db.execute("CREATE UNIQUE INDEX idx_mappings_key ON mappings(account_id, mapping_key)")
            try db.setUserVersion(Self.schemaVersion)
        }
        if needsSecretScrub {
            // `secure_delete` überschreibt die gelöschten Zellen. Checkpoint
            // und VACUUM entfernen zusätzlich frühere Kopien aus WAL und
            // unbenutzten Seiten der Hauptdatei.
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute("VACUUM")
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Konsolidiert Zuordnungen, die ältere Schemas bei zwei gleichzeitig
    /// startenden App-Instanzen anlegen konnten. Baseline-Zeilen werden pro Pfad
    /// nach dem neuesten `synced_at` übernommen; abgeleitete Caches und alte
    /// Löschfreigaben werden verworfen und beim nächsten Lauf sicher neu gebaut.
    private static func deduplicateMappings(_ db: SQLiteDatabase) throws {
        let groups = try db.query("""
        SELECT account_id, mapping_key
        FROM mappings
        GROUP BY account_id, mapping_key
        HAVING COUNT(*) > 1
        """)
        for group in groups {
            guard let accountID = group.string("account_id"),
                  let mappingKey = group.string("mapping_key") else { continue }
            let mappings = try db.query(
                """
                SELECT id, created_at, last_successful_sync
                FROM mappings
                WHERE account_id = ? AND mapping_key = ?
                ORDER BY created_at, id
                """,
                [.text(accountID), .text(mappingKey)]
            )
            guard let survivor = mappings.first?.string("id"), mappings.count > 1 else { continue }
            let ids = mappings.compactMap { $0.string("id") }
            let latestSuccessfulSync = mappings.compactMap { $0.double("last_successful_sync") }.max()
            let wasUserPaused = try ids.contains { id in
                try db.query("SELECT value FROM meta WHERE key = ?", [.text("user-pause.\(id)")])
                    .first?.string("value") == "1"
            }

            for duplicate in ids.dropFirst() {
                for row in try db.query(
                    "SELECT path, synced_at FROM entries WHERE mapping_id = ?",
                    [.text(duplicate)]
                ) {
                    guard let path = row.string("path"), let duplicateDate = row.double("synced_at") else { continue }
                    let survivorDate = try db.query(
                        "SELECT synced_at FROM entries WHERE mapping_id = ? AND path = ?",
                        [.text(survivor), .text(path)]
                    ).first?.double("synced_at")
                    if survivorDate.map({ duplicateDate > $0 }) ?? true {
                        try db.execute(
                            "DELETE FROM entries WHERE mapping_id = ? AND path = ?",
                            [.text(survivor), .text(path)]
                        )
                        try db.execute(
                            "UPDATE entries SET mapping_id = ? WHERE mapping_id = ? AND path = ?",
                            [.text(survivor), .text(duplicate), .text(path)]
                        )
                    } else {
                        try db.execute(
                            "DELETE FROM entries WHERE mapping_id = ? AND path = ?",
                            [.text(duplicate), .text(path)]
                        )
                    }
                }
                try db.execute("UPDATE conflicts SET mapping_id = ? WHERE mapping_id = ?", [.text(survivor), .text(duplicate)])
                try db.execute("UPDATE transfers SET mapping_id = ? WHERE mapping_id = ?", [.text(survivor), .text(duplicate)])
            }

            for table in ["local_index", "remote_index", "queue", "pending_deletions", "upload_sessions"] {
                for id in ids {
                    try db.execute("DELETE FROM \(table) WHERE mapping_id = ?", [.text(id)])
                }
            }
            for id in ids {
                try db.execute("DELETE FROM meta WHERE key = ?", [.text("user-pause.\(id)")])
            }
            if wasUserPaused {
                try db.execute(
                    "INSERT INTO meta(key, value) VALUES(?, '1') ON CONFLICT(key) DO UPDATE SET value = '1'",
                    [.text("user-pause.\(survivor)")]
                )
            }
            for duplicate in ids.dropFirst() {
                try db.execute("DELETE FROM mappings WHERE id = ?", [.text(duplicate)])
            }
            try db.execute(
                """
                UPDATE mappings
                SET last_successful_sync = ?, sync_token = NULL, remote_index_complete = 0
                WHERE id = ?
                """,
                [SQLValue(latestSuccessfulSync), .text(survivor)]
            )
        }
    }

    // MARK: - Meta

    private static func deletionConfirmationKey(_ mappingID: String) -> String {
        "confirmed-deletions.\(mappingID)"
    }

    public func meta(_ key: String) throws -> String? {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.string("value")
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.execute("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
        } else {
            try db.execute("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    // MARK: - Accounts

    private static func decodeRecord<T: Decodable>(_ type: T.Type, json: String?, table: String,
                                                    identifier: String) throws -> T {
        guard let json else {
            throw SyncStoreError.corruptRecord(table: table, identifier: identifier, details: "JSON fehlt")
        }
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw SyncStoreError.corruptRecord(table: table, identifier: identifier, details: "\(error)")
        }
    }

    public func saveAccount(_ account: AccountConfiguration) throws {
        let json = try String(decoding: JSONEncoder().encode(account), as: UTF8.self)
        try db.execute("INSERT INTO accounts(id, json) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json", [.text(account.id), .text(json)])
    }

    public func accounts() throws -> [AccountConfiguration] {
        try db.query("SELECT id, json FROM accounts").map { row in
            let id = row.string("id") ?? "<ohne ID>"
            return try Self.decodeRecord(AccountConfiguration.self, json: row.string("json"), table: "accounts", identifier: id)
        }
    }

    public func deleteAccount(id: String) throws {
        try db.transaction {
            let mappings = try db.query("SELECT id FROM mappings WHERE account_id = ?", [.text(id)]).compactMap { $0.string("id") }
            for m in mappings { try deleteMappingData(m) }
            try db.execute("DELETE FROM mappings WHERE account_id = ?", [.text(id)])
            try db.execute("DELETE FROM shares WHERE account_id = ?", [.text(id)])
            try db.execute("DELETE FROM accounts WHERE id = ?", [.text(id)])
        }
    }

    // MARK: - Mappings

    /// Liefert die Zuordnung für den aktuellen Schlüssel oder legt eine neue an.
    /// Eine Änderung des Server- oder lokalen Pfades führt damit zu einem leeren
    /// Synchronisierungsstand — alte Baselines können keine falschen Löschungen auslösen.
    public func mapping(for account: AccountConfiguration) throws -> SyncMapping {
        if let row = try db.query("SELECT * FROM mappings WHERE account_id = ? AND mapping_key = ?", [.text(account.id), .text(account.mappingKey)]).first {
            return try Self.mapping(from: row)
        }
        let mapping = SyncMapping(accountID: account.id, mappingKey: account.mappingKey)
        try db.execute("""
        INSERT INTO mappings(id, account_id, mapping_key, created_at, last_successful_sync, sync_token, remote_index_complete)
        VALUES(?, ?, ?, ?, NULL, NULL, 0)
        ON CONFLICT(account_id, mapping_key) DO NOTHING
        """, [.text(mapping.id), .text(mapping.accountID), .text(mapping.mappingKey), .real(mapping.createdAt.timeIntervalSince1970)])
        guard let row = try db.query(
            "SELECT * FROM mappings WHERE account_id = ? AND mapping_key = ?",
            [.text(account.id), .text(account.mappingKey)]
        ).first else {
            throw SyncStoreError.corruptRecord(
                table: "mappings",
                identifier: account.id,
                details: "Zuordnung konnte nicht atomar angelegt werden"
            )
        }
        return try Self.mapping(from: row)
    }

    public func mapping(id: String) throws -> SyncMapping? {
        guard let row = try db.query("SELECT * FROM mappings WHERE id = ?", [.text(id)]).first else { return nil }
        return try Self.mapping(from: row)
    }

    private static func mapping(from row: SQLRow) throws -> SyncMapping {
        guard let id = row.string("id"),
              let accountID = row.string("account_id"),
              let mappingKey = row.string("mapping_key"),
              let createdAt = row.date("created_at") else {
            throw SyncStoreError.corruptRecord(
                table: "mappings",
                identifier: row.string("id") ?? "<ohne ID>",
                details: "Pflichtfeld fehlt"
            )
        }
        return SyncMapping(
            id: id,
            accountID: accountID,
            mappingKey: mappingKey,
            createdAt: createdAt,
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
        for table in ["entries", "local_index", "remote_index", "conflicts", "transfers", "queue", "pending_deletions", "upload_sessions"] {
            try db.execute("DELETE FROM \(table) WHERE mapping_id = ?", [.text(mappingID)])
        }
        try db.execute(
            "DELETE FROM meta WHERE key IN (?, ?)",
            [.text("user-pause.\(mappingID)"), .text(Self.deletionConfirmationKey(mappingID))]
        )
    }

    // MARK: - Baseline

    public func baseline(mappingID: String) throws -> [String: BaselineEntry] {
        var result: [String: BaselineEntry] = [:]
        for row in try db.query("SELECT * FROM entries WHERE mapping_id = ?", [.text(mappingID)]) {
            guard let path = row.string("path"),
                  let kindRaw = row.string("kind"),
                  let kind = ItemKind(rawValue: kindRaw),
                  let localSize = row.int64("local_size"),
                  let localModified = row.double("local_mtime"),
                  let remoteSize = row.int64("remote_size"),
                  let syncedAt = row.date("synced_at") else {
                throw SyncStoreError.corruptRecord(
                    table: "entries",
                    identifier: row.string("path") ?? "<ohne Pfad>",
                    details: "Pflichtfeld fehlt oder ist ungültig"
                )
            }
            result[path] = BaselineEntry(
                path: path, kind: kind,
                localHash: row.string("local_hash"),
                localSize: localSize,
                localModified: localModified,
                remoteValidator: row.string("remote_validator"),
                remoteValidatorIsStrong: row.bool("remote_validator_strong"),
                remoteSize: remoteSize,
                remoteModified: row.double("remote_mtime"),
                syncedAt: syncedAt
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
        public var fileID: String?
        public var changeTime: Double?

        public init(size: Int64, mtime: Double, hash: String, fileID: String? = nil, changeTime: Double? = nil) {
            self.size = size
            self.mtime = mtime
            self.hash = hash
            self.fileID = fileID
            self.changeTime = changeTime
        }
    }

    public func localIndex(mappingID: String) throws -> [String: LocalIndexEntry] {
        var result: [String: LocalIndexEntry] = [:]
        for row in try db.query("SELECT path, size, mtime, hash, file_id, change_time FROM local_index WHERE mapping_id = ?", [.text(mappingID)]) {
            guard let path = row.string("path"),
                  let size = row.int64("size"),
                  let mtime = row.double("mtime"),
                  let hash = row.string("hash") else {
                throw SyncStoreError.corruptRecord(
                    table: "local_index",
                    identifier: row.string("path") ?? "<ohne Pfad>",
                    details: "Pflichtfeld fehlt"
                )
            }
            result[path] = LocalIndexEntry(
                size: size,
                mtime: mtime,
                hash: hash,
                fileID: row.string("file_id"),
                changeTime: row.double("change_time")
            )
        }
        return result
    }

    public func replaceLocalIndex(_ index: [String: LocalIndexEntry], mappingID: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM local_index WHERE mapping_id = ?", [.text(mappingID)])
            for (path, e) in index {
                try db.execute("""
                INSERT INTO local_index(mapping_id, path, size, mtime, hash, file_id, change_time)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                """, [
                    .text(mappingID), .text(path), .integer(e.size), .real(e.mtime), .text(e.hash),
                    SQLValue(e.fileID), SQLValue(e.changeTime),
                ])
            }
        }
    }

    public func removeLocalIndex(path: String, mappingID: String) throws {
        try db.execute(
            "DELETE FROM local_index WHERE mapping_id = ? AND path = ?",
            [.text(mappingID), .text(path)]
        )
    }

    // MARK: - Remote index (Cache für Sync-Collection)

    public func remoteIndex(mappingID: String) throws -> [String: RemoteItem] {
        var result: [String: RemoteItem] = [:]
        for row in try db.query("SELECT * FROM remote_index WHERE mapping_id = ?", [.text(mappingID)]) {
            guard let path = row.string("path"),
                  let rawPath = row.string("raw_path"),
                  let kindRaw = row.string("kind"),
                  let kind = ItemKind(rawValue: kindRaw),
                  let size = row.int64("size") else {
                throw SyncStoreError.corruptRecord(
                    table: "remote_index",
                    identifier: row.string("path") ?? "<ohne Pfad>",
                    details: "Pflichtfeld fehlt oder ist ungültig"
                )
            }
            result[path] = RemoteItem(path: path, rawPath: rawPath, kind: kind, size: size,
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

    /// Ersetzt Cache und zugehörigen Sync-Token in derselben Transaktion. Ein
    /// Token darf niemals fortgeschrieben werden, wenn der Bestand nicht
    /// vollständig persistiert werden konnte.
    public func replaceRemoteIndex(
        _ items: [String: RemoteItem],
        syncToken: String,
        mappingID: String
    ) throws {
        try db.transaction {
            try db.execute("DELETE FROM remote_index WHERE mapping_id = ?", [.text(mappingID)])
            for (_, item) in items { try insertRemoteIndexItem(item, mappingID: mappingID) }
            try db.execute(
                "UPDATE mappings SET sync_token = ?, remote_index_complete = 1 WHERE id = ?",
                [.text(syncToken), .text(mappingID)]
            )
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
            ? "SELECT id, json FROM conflicts WHERE mapping_id = ? ORDER BY detected_at DESC"
            : "SELECT id, json FROM conflicts WHERE mapping_id = ? AND status = 'open' ORDER BY detected_at DESC"
        return try db.query(sql, [.text(mappingID)]).map { row in
            try Self.decodeRecord(
                ConflictRecord.self,
                json: row.string("json"),
                table: "conflicts",
                identifier: row.string("id") ?? "<ohne ID>"
            )
        }
    }

    public func openConflict(path: String, mappingID: String) throws -> ConflictRecord? {
        guard let row = try db.query(
            "SELECT id, json FROM conflicts WHERE mapping_id = ? AND path = ? AND status = 'open'",
            [.text(mappingID), .text(path)]
        ).first else { return nil }
        return try Self.decodeRecord(
            ConflictRecord.self,
            json: row.string("json"),
            table: "conflicts",
            identifier: row.string("id") ?? path
        )
    }

    public func saveConflict(_ conflict: ConflictRecord, mappingID: String) throws {
        let json = try String(decoding: JSONEncoder().encode(conflict), as: UTF8.self)
        try db.execute("""
        INSERT INTO conflicts(id, mapping_id, path, json, status, detected_at) VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET json = excluded.json, status = excluded.status, path = excluded.path
        """, [.text(conflict.id), .text(mappingID), .text(conflict.path), .text(json), .text(conflict.status.rawValue), .real(conflict.detectedAt.timeIntervalSince1970)])
    }

    /// Persistiert den neuen gemeinsamen Stand und den dazugehörigen Konflikt
    /// atomar. Ohne diese Kopplung könnte die Konfliktkopie nach einem
    /// SQLite-Fehler existieren, ohne in der Oberfläche auffindbar zu sein.
    public func saveConflict(
        _ conflict: ConflictRecord,
        baseline: BaselineEntry,
        replacingBaselineSubtree: Bool = false,
        mappingID: String
    ) throws {
        try db.transaction {
            if replacingBaselineSubtree {
                try removeBaselineSubtree(path: baseline.path, mappingID: mappingID)
            }
            try upsertBaseline(baseline, mappingID: mappingID)
            try saveConflict(conflict, mappingID: mappingID)
        }
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
        try db.query("SELECT id, json FROM transfers WHERE mapping_id = ? ORDER BY started_at DESC LIMIT ?", [.text(mappingID), .integer(Int64(limit))]).map { row in
            try Self.decodeRecord(
                TransferRecord.self,
                json: row.string("json"),
                table: "transfers",
                identifier: row.string("id") ?? "<ohne ID>"
            )
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
        try db.query("SELECT * FROM queue WHERE mapping_id = ? ORDER BY created_at", [.text(mappingID)]).map { row in
            guard let path = row.string("path"),
                  let dirRaw = row.string("direction"),
                  let dir = TransferDirection(rawValue: dirRaw),
                  let size = row.int64("size"),
                  let createdAt = row.date("created_at") else {
                throw SyncStoreError.corruptRecord(
                    table: "queue",
                    identifier: row.string("path") ?? "<ohne Pfad>",
                    details: "Pflichtfeld fehlt oder ist ungültig"
                )
            }
            return QueuedItem(path: path, direction: dir, size: size, createdAt: createdAt)
        }
    }

    // MARK: - Pending deletions (Löschschutz)

    public func replacePendingDeletions(_ items: [PendingDeletion], mappingID: String) throws {
        try db.transaction {
            // Bereits freigegebene Einträge gehören zu einem älteren Plan und
            // bleiben bestehen. Nur der noch unbestätigte Vorschlag wird durch
            // die aktuelle Bestandsaufnahme ersetzt.
            try db.execute(
                "DELETE FROM pending_deletions WHERE mapping_id = ? AND confirmed = 0",
                [.text(mappingID)]
            )
            for item in items {
                try db.execute(
                    """
                    INSERT OR IGNORE INTO pending_deletions(
                        mapping_id, path, side, kind, planned_at, confirmed
                    ) VALUES(?, ?, ?, ?, ?, 0)
                    """,
                    [.text(mappingID), .text(item.path), .text(item.side.rawValue),
                     .text(item.kind.rawValue), .real(item.plannedAt.timeIntervalSince1970)]
                )
            }
        }
    }

    public func pendingDeletions(mappingID: String) throws -> [PendingDeletion] {
        try pendingDeletions(mappingID: mappingID, confirmed: nil)
    }

    private func pendingDeletions(mappingID: String, confirmed: Bool?) throws -> [PendingDeletion] {
        var sql = "SELECT * FROM pending_deletions WHERE mapping_id = ?"
        var arguments: [SQLValue] = [.text(mappingID)]
        if let confirmed {
            sql += " AND confirmed = ?"
            arguments.append(.integer(confirmed ? 1 : 0))
        }
        sql += " ORDER BY path"
        return try db.query(sql, arguments).map { row in
            guard let path = row.string("path"), let side = row.string("side").flatMap(PendingDeletion.Side.init(rawValue:)),
                  let kind = row.string("kind").flatMap(ItemKind.init(rawValue:)),
                  let plannedAt = row.date("planned_at") else {
                throw SyncStoreError.corruptRecord(
                    table: "pending_deletions",
                    identifier: row.string("path") ?? "<ohne Pfad>",
                    details: "Pflichtfeld fehlt oder ist ungültig"
                )
            }
            return PendingDeletion(path: path, kind: kind, side: side, plannedAt: plannedAt)
        }
    }

    /// Liefert nur Pläne, die noch eine Benutzerentscheidung benötigen.
    public func pendingDeletionsAwaitingConfirmation(mappingID: String) throws -> [PendingDeletion] {
        try pendingDeletions(mappingID: mappingID, confirmed: false)
    }

    /// Liefert die persistent freigegebenen Löschungen. Jede Freigabe bleibt
    /// bestehen, bis genau diese Aktion erfolgreich abgeschlossen wurde oder
    /// nach einer vollständigen Bestandsaufnahme nicht mehr anwendbar ist.
    public func confirmedPendingDeletions(mappingID: String) throws -> [PendingDeletion] {
        try pendingDeletions(mappingID: mappingID, confirmed: true)
    }

    @discardableResult
    public func confirmPendingDeletions(mappingID: String) throws -> [PendingDeletion] {
        try db.transaction {
            try db.execute(
                "UPDATE pending_deletions SET confirmed = 1 WHERE mapping_id = ? AND confirmed = 0",
                [.text(mappingID)]
            )
            return try pendingDeletions(mappingID: mappingID, confirmed: true)
        }
    }

    /// Entfernt ausschließlich erledigte oder gegenstandslos gewordene
    /// Freigaben und liefert den danach verbleibenden bestätigten Satz.
    @discardableResult
    public func consumeConfirmedPendingDeletions(
        _ authorizations: Set<DeletionAuthorization>,
        mappingID: String
    ) throws -> [PendingDeletion] {
        try db.transaction {
            for authorization in authorizations {
                try db.execute(
                    """
                    DELETE FROM pending_deletions
                    WHERE mapping_id = ? AND path = ? AND side = ? AND kind = ? AND confirmed = 1
                    """,
                    [.text(mappingID), .text(authorization.path), .text(authorization.side.rawValue),
                     .text(authorization.kind.rawValue)]
                )
            }
            return try pendingDeletions(mappingID: mappingID, confirmed: true)
        }
    }

    public func clearPendingDeletionsAwaitingConfirmation(mappingID: String) throws {
        try db.execute(
            "DELETE FROM pending_deletions WHERE mapping_id = ? AND confirmed = 0",
            [.text(mappingID)]
        )
    }

    public func clearPendingDeletions(mappingID: String) throws {
        try db.execute("DELETE FROM pending_deletions WHERE mapping_id = ?", [.text(mappingID)])
    }

    /// Verwirft einen bestätigungsbedürftigen Löschplan atomar: Entweder werden
    /// alle zugehörigen Baseline-Teilbäume und der Plan entfernt oder gar nichts.
    public func discardPendingDeletions(mappingID: String) throws {
        let pending = try pendingDeletions(mappingID: mappingID, confirmed: false)
        try db.transaction {
            for item in pending {
                try removeBaselineSubtree(path: item.path, mappingID: mappingID)
            }
            try db.execute(
                "DELETE FROM pending_deletions WHERE mapping_id = ? AND confirmed = 0",
                [.text(mappingID)]
            )
        }
    }

    // MARK: - Unterbrochene Uploads

    public func uploadState(path: String, mappingID: String) throws -> ResumableUploadState? {
        guard let row = try db.query(
            "SELECT path, json FROM upload_sessions WHERE mapping_id = ? AND path = ?",
            [.text(mappingID), .text(path)]
        ).first else { return nil }
        return try Self.decodeRecord(
            ResumableUploadState.self,
            json: row.string("json"),
            table: "upload_sessions",
            identifier: row.string("path") ?? path
        )
    }

    public func uploadStates(mappingID: String) throws -> [ResumableUploadState] {
        try db.query("SELECT path, json FROM upload_sessions WHERE mapping_id = ?", [.text(mappingID)]).map { row in
            try Self.decodeRecord(
                ResumableUploadState.self,
                json: row.string("json"),
                table: "upload_sessions",
                identifier: row.string("path") ?? "<ohne Pfad>"
            )
        }
    }

    public func saveUploadState(_ state: ResumableUploadState, mappingID: String) throws {
        var persisted = state
        // Verteidigung in der Persistenzgrenze: Auch manuell konstruierte oder
        // künftig erweiterte Zustände dürfen keine signierten URLs oder
        // kurzlebigen Upload-Credentials in SQLite/WAL schreiben.
        persisted.uploadURLs = []
        persisted.credential = nil
        let json = try String(decoding: JSONEncoder().encode(persisted), as: UTF8.self)
        try db.execute("INSERT INTO upload_sessions(mapping_id, path, json) VALUES(?, ?, ?) ON CONFLICT(mapping_id, path) DO UPDATE SET json = excluded.json",
                       [.text(mappingID), .text(state.path), .text(json)])
    }

    public func removeUploadState(path: String, mappingID: String) throws {
        try db.execute("DELETE FROM upload_sessions WHERE mapping_id = ? AND path = ?", [.text(mappingID), .text(path)])
    }

    // MARK: - Freigaben (lokaler Cache)

    public func saveShare(_ share: CloudreveShare, accountID: String) throws {
        let json = try String(decoding: JSONEncoder().encode(ShareCacheEntry(share: share)), as: UTF8.self)
        try db.execute("INSERT INTO shares(id, account_id, json, created_at) VALUES(?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                       [.text(share.id), .text(accountID), .text(json), .real((share.createdAt ?? Date()).timeIntervalSince1970)])
    }

    public func replaceShares(_ shares: [CloudreveShare], accountID: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM shares WHERE account_id = ?", [.text(accountID)])
            for share in shares { try saveShare(share, accountID: accountID) }
        }
    }

    public func shares(accountID: String) throws -> [CloudreveShare] {
        try db.query("SELECT id, json FROM shares WHERE account_id = ? ORDER BY created_at DESC", [.text(accountID)]).map { row in
            try Self.decodeRecord(
                ShareCacheEntry.self,
                json: row.string("json"),
                table: "shares",
                identifier: row.string("id") ?? "<ohne ID>"
            ).share
        }
    }

    public func deleteShare(id: String) throws {
        try db.execute("DELETE FROM shares WHERE id = ?", [.text(id)])
    }

    /// Setzt den Synchronisierungsstand einer Zuordnung vollständig zurück.
    public func resetMapping(id: String) throws {
        try db.transaction {
            try deleteMappingData(id)
            try db.execute("UPDATE mappings SET last_successful_sync = NULL, sync_token = NULL, remote_index_complete = 0 WHERE id = ?", [.text(id)])
        }
    }
}

/// Codable-Hülle für den lokalen Freigabe-Cache.
struct ShareCacheEntry: Codable {
    var id: String
    var name: String
    var url: URL
    var sourceURI: String?
    var isPrivate: Bool
    var expires: Date?
    var expired: Bool
    var visited: Int
    var downloaded: Int
    var remainDownloads: Int?
    var isFolder: Bool
    var createdAt: Date?

    init(share: CloudreveShare) {
        id = share.id; name = share.name; url = Self.sanitizedURL(for: share); sourceURI = share.sourceURI; isPrivate = share.isPrivate
        expires = share.expires; expired = share.expired; visited = share.visited; downloaded = share.downloaded; remainDownloads = share.remainDownloads
        isFolder = share.isFolder; createdAt = share.createdAt
    }

    /// Private Cloudreve-Links können das Passwort als Pfadsegment hinter der
    /// Share-ID enthalten. Der Offline-Cache speichert nur den Link bis zur ID;
    /// nach der nächsten Anmeldung wird der vollständige Link erneut geladen.
    private static func sanitizedURL(for share: CloudreveShare) -> URL {
        guard share.isPrivate else { return share.url }
        var components = URLComponents(url: share.url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        components?.user = nil
        components?.password = nil
        if var components {
            var segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if let idIndex = segments.lastIndex(of: share.id), idIndex + 1 < segments.count {
                segments.removeSubrange((idIndex + 1)...)
                components.path = "/" + segments.joined(separator: "/")
            } else if let password = share.password,
                      !password.isEmpty,
                      let passwordIndex = segments.firstIndex(of: password) {
                segments.removeSubrange(passwordIndex...)
                components.path = segments.isEmpty ? "/" : "/" + segments.joined(separator: "/")
            } else {
                // Unbekanntes privates URL-Schema: Nur die Origin ist garantiert
                // frei von einem Passwortsegment.
                components.path = "/"
            }
            if let url = components.url { return url }
        }
        var origin = URLComponents()
        origin.scheme = share.url.scheme
        origin.host = share.url.host
        origin.port = share.url.port
        origin.path = "/"
        return origin.url ?? URL(string: "about:blank")!
    }

    var share: CloudreveShare {
        CloudreveShare(id: id, name: name, url: url, sourceURI: sourceURI, isPrivate: isPrivate, password: nil, expires: expires, expired: expired,
                       visited: visited, downloaded: downloaded, remainDownloads: remainDownloads, isFolder: isFolder, createdAt: createdAt)
    }
}

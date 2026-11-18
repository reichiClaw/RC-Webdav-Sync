import XCTest
@testable import ReichiSyncCore

final class SyncStoreTests: XCTestCase {
    private func account(local: String = "/tmp/a", server: String = "https://example.org/dav/") -> AccountConfiguration {
        AccountConfiguration(id: "acc", name: "Test", serverURL: URL(string: server)!, username: "u", localRootPath: local)
    }

    func testMappingChangesWhenPathsChange() async throws {
        let store = try SyncStore.inMemory()
        let m1 = try await store.mapping(for: account())
        let m1b = try await store.mapping(for: account())
        XCTAssertEqual(m1.id, m1b.id)
        let m2 = try await store.mapping(for: account(local: "/tmp/b"))
        XCTAssertNotEqual(m1.id, m2.id)
        let m3 = try await store.mapping(for: account(server: "https://example.org/dav/anders/"))
        XCTAssertNotEqual(m1.id, m3.id)
        var differentUser = account()
        differentUser.username = "anderes-konto"
        let m4 = try await store.mapping(for: differentUser)
        XCTAssertNotEqual(m1.id, m4.id)
        var differentRules = account()
        differentRules.exclusionPatterns = ["*.tmp"]
        let m5 = try await store.mapping(for: differentRules)
        XCTAssertNotEqual(m1.id, m5.id)
        // Ein alter Synchronisierungsstand darf für die neue Zuordnung nicht sichtbar sein.
        try await store.upsertBaseline(BaselineEntry(path: "x", kind: .file, localHash: "h", localSize: 1, localModified: 1, remoteValidator: "e",
                                                     remoteValidatorIsStrong: true, remoteSize: 1, remoteModified: nil), mappingID: m1.id)
        let b2 = try await store.baseline(mappingID: m2.id)
        XCTAssertTrue(b2.isEmpty)
    }

    func testMappingKeyDoesNotChangeWhenPreviouslyMissingRootAppears() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Sync")
        let account = AccountConfiguration(
            id: "stable",
            name: "Stable",
            serverURL: URL(string: "https://example.org/dav/")!,
            username: "u",
            localRootPath: root.path
        )
        XCTAssertNil(account.localRootIdentity)
        let keyWhileMissing = account.mappingKey

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertEqual(account.mappingKey, keyWhileMissing)
        var rebound = account
        rebound.setLocalRootPath(root.path)
        XCTAssertNotEqual(rebound.mappingKey, keyWhileMissing)
    }

    func testBaselineRoundTripAndSubtreeRemoval() async throws {
        let store = try SyncStore.inMemory()
        let m = try await store.mapping(for: account())
        for p in ["d", "d/a.txt", "d/sub/b.txt", "d2/x.txt", "other.txt"] {
            try await store.upsertBaseline(BaselineEntry(path: p, kind: p.hasSuffix(".txt") ? .file : .directory, localHash: "h", localSize: 3, localModified: 2,
                                                         remoteValidator: "\"e\"", remoteValidatorIsStrong: true, remoteSize: 3, remoteModified: 4), mappingID: m.id)
        }
        var baseline = try await store.baseline(mappingID: m.id)
        XCTAssertEqual(baseline.count, 5)
        XCTAssertEqual(baseline["d/a.txt"]?.remoteValidator, "\"e\"")
        try await store.removeBaselineSubtree(path: "d", mappingID: m.id)
        baseline = try await store.baseline(mappingID: m.id)
        XCTAssertEqual(Set(baseline.keys), ["d2/x.txt", "other.txt"])

        try await store.renameBaseline(from: "d2", to: "d3", mappingID: m.id)
        baseline = try await store.baseline(mappingID: m.id)
        XCTAssertEqual(Set(baseline.keys), ["d3/x.txt", "other.txt"])
    }

    func testConflictsQueueTransfersPersist() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("sync.sqlite").path

        var mappingID = ""
        do {
            let store = try SyncStore(path: path)
            let m = try await store.mapping(for: account())
            mappingID = m.id
            try await store.saveConflict(ConflictRecord(path: "k.txt", kind: .file, reason: .bothModified, conflictCopyPath: "k (Konfliktkopie).txt"), mappingID: m.id)
            try await store.replaceQueue([QueuedItem(path: "q.txt", direction: .upload, size: 5)], mappingID: m.id)
            try await store.saveTransfer(TransferRecord(path: "t.txt", direction: .download, state: .running, bytesTotal: 10), mappingID: m.id)
            try await store.replacePendingDeletions([PendingDeletion(path: "del.txt", kind: .file, side: .local)], mappingID: m.id)
            let confirmed = try await store.confirmPendingDeletions(mappingID: m.id)
            XCTAssertEqual(confirmed.map(\.path), ["del.txt"])
            try await store.setSyncToken("tok", remoteIndexComplete: true, mappingID: m.id)
        }
        // „Neustart“
        let store = try SyncStore(path: path)
        let m = try await store.mapping(for: account())
        XCTAssertEqual(m.id, mappingID)
        XCTAssertEqual(m.syncToken, "tok")
        XCTAssertTrue(m.remoteIndexIsComplete)
        let conflicts = try await store.conflicts(mappingID: m.id)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.conflictCopyPath, "k (Konfliktkopie).txt")
        let queue = try await store.queue(mappingID: m.id)
        XCTAssertEqual(queue.map(\.path), ["q.txt"])
        let pending = try await store.pendingDeletions(mappingID: m.id)
        XCTAssertEqual(pending.map(\.path), ["del.txt"])
        let awaitingConfirmation = try await store.pendingDeletionsAwaitingConfirmation(mappingID: m.id)
        let confirmedAfterRestart = try await store.confirmedPendingDeletions(mappingID: m.id)
        XCTAssertTrue(awaitingConfirmation.isEmpty)
        XCTAssertEqual(confirmedAfterRestart.map(\.path), ["del.txt"])
        try await store.markRunningTransfersInterrupted(mappingID: m.id)
        let transfers = try await store.transfers(mappingID: m.id)
        XCTAssertEqual(transfers.first?.state, .cancelled)
    }

    func testConflictAndBaselinePersistAtomically() async throws {
        let store = try SyncStore.inMemory()
        let mapping = try await store.mapping(for: account())
        let baseline = BaselineEntry(
            path: "k.txt",
            kind: .file,
            localHash: "remote-hash",
            localSize: 6,
            localModified: 1,
            remoteValidator: "\"etag\"",
            remoteValidatorIsStrong: true,
            remoteSize: 6,
            remoteModified: 2
        )
        let conflict = ConflictRecord(
            path: "k.txt",
            kind: .file,
            reason: .bothModified,
            localHash: "local-hash",
            conflictCopyPath: "k (Konfliktkopie).txt"
        )
        try await store.upsertBaseline(
            BaselineEntry(
                path: "k.txt/alt",
                kind: .file,
                localHash: "alt",
                localSize: 3,
                localModified: 0,
                remoteValidator: "\"alt\"",
                remoteValidatorIsStrong: true,
                remoteSize: 3,
                remoteModified: nil
            ),
            mappingID: mapping.id
        )

        try await store.saveConflict(
            conflict,
            baseline: baseline,
            replacingBaselineSubtree: true,
            mappingID: mapping.id
        )

        let savedBaseline = try await store.baseline(mappingID: mapping.id)
        let savedConflicts = try await store.conflicts(mappingID: mapping.id)
        XCTAssertEqual(savedBaseline["k.txt"]?.localHash, "remote-hash")
        XCTAssertNil(savedBaseline["k.txt/alt"])
        XCTAssertEqual(savedConflicts.first?.id, conflict.id)
    }

    func testAccountPersistence() async throws {
        let store = try SyncStore.inMemory()
        var acc = account()
        acc.exclusionPatterns = ["*.tmp"]
        acc.pollInterval = 120
        try await store.saveAccount(acc)
        let loaded = try await store.accounts()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.pollInterval, 120)
        XCTAssertEqual(loaded.first?.exclusionPatterns, ["*.tmp"])
        try await store.deleteAccount(id: acc.id)
        let remaining = try await store.accounts()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMigrationScrubsPreviouslyPersistedSecrets() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("legacy.sqlite").path
        let legacy = try SQLiteDatabase(path: path)
        try legacy.execute("""
        CREATE TABLE local_index (
            mapping_id TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL,
            mtime REAL NOT NULL, hash TEXT NOT NULL, PRIMARY KEY (mapping_id, path)
        )
        """)
        try legacy.execute("CREATE TABLE upload_sessions (mapping_id TEXT NOT NULL, path TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY (mapping_id, path))")
        try legacy.execute("CREATE TABLE shares (id TEXT PRIMARY KEY, account_id TEXT NOT NULL, json TEXT NOT NULL, created_at REAL NOT NULL)")
        try legacy.execute("INSERT INTO upload_sessions VALUES('m', 'x', '{\"credential\":\"secret-upload-token\"}')")
        try legacy.execute("INSERT INTO shares VALUES('s', 'a', '{\"password\":\"secret-share-password\"}', 0)")
        try legacy.setUserVersion(2)

        _ = try SyncStore(path: path)

        let verify = try SQLiteDatabase(path: path)
        XCTAssertEqual(try verify.userVersion(), 4)
        XCTAssertEqual(try verify.query("SELECT COUNT(*) AS c FROM upload_sessions").first?.int("c"), 0)
        XCTAssertEqual(try verify.query("SELECT COUNT(*) AS c FROM shares").first?.int("c"), 0)
        let columns = Set(try verify.query("PRAGMA table_info(local_index)").compactMap { $0.string("name") })
        XCTAssertTrue(columns.isSuperset(of: ["file_id", "change_time"]))
    }

    func testSchemaTwoMappingStartsSafeInitialMergeAfterKeyUpgrade() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("mapping-upgrade.sqlite").path
        let acc = account()
        let accountJSON = String(decoding: try JSONEncoder().encode(acc), as: UTF8.self)
        let raw = try SQLiteDatabase(path: path)
        try raw.execute("CREATE TABLE accounts (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
        try raw.execute("""
        CREATE TABLE mappings (
            id TEXT PRIMARY KEY, account_id TEXT NOT NULL, mapping_key TEXT NOT NULL,
            created_at REAL NOT NULL, last_successful_sync REAL, sync_token TEXT,
            remote_index_complete INTEGER NOT NULL DEFAULT 0
        )
        """)
        try raw.execute("""
        CREATE TABLE entries (
            mapping_id TEXT NOT NULL, path TEXT NOT NULL, kind TEXT NOT NULL, local_hash TEXT,
            local_size INTEGER NOT NULL DEFAULT 0, local_mtime REAL NOT NULL DEFAULT 0,
            remote_validator TEXT, remote_validator_strong INTEGER NOT NULL DEFAULT 0,
            remote_size INTEGER NOT NULL DEFAULT 0, remote_mtime REAL, synced_at REAL NOT NULL,
            PRIMARY KEY (mapping_id, path)
        )
        """)
        try raw.execute("INSERT INTO accounts(id, json) VALUES(?, ?)", [.text(acc.id), .text(accountJSON)])
        try raw.execute(
            "INSERT INTO mappings VALUES('legacy-map', ?, ?, 1, 2, 'legacy-token', 1)",
            [.text(acc.id), .text(acc.legacyMappingKey)]
        )
        try raw.execute("""
        INSERT INTO entries VALUES(
            'legacy-map', 'wichtig.txt', 'file', 'hash', 4, 1,
            '"etag"', 1, 4, 1, 1
        )
        """)
        try raw.setUserVersion(2)

        let store = try SyncStore(path: path)
        let migrated = try await store.mapping(for: acc)
        XCTAssertNotEqual(migrated.id, "legacy-map")
        XCTAssertNil(migrated.syncToken)
        let migratedBaseline = try await store.baseline(mappingID: migrated.id)
        let legacyBaseline = try await store.baseline(mappingID: "legacy-map")
        XCTAssertTrue(migratedBaseline.isEmpty)
        XCTAssertEqual(
            legacyBaseline["wichtig.txt"]?.localHash,
            "hash",
            "Der alte Stand bleibt ausschließlich zur Diagnose erhalten"
        )
    }

    func testConcurrentStoresCreateOnlyOneMapping() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("concurrent.sqlite").path
        let first = try SyncStore(path: path)
        let second = try SyncStore(path: path)
        let acc = account()

        async let firstMapping = first.mapping(for: acc)
        async let secondMapping = second.mapping(for: acc)
        let mappings = try await [firstMapping, secondMapping]
        XCTAssertEqual(mappings[0].id, mappings[1].id)

        let verify = try SQLiteDatabase(path: path)
        XCTAssertEqual(try verify.query("SELECT COUNT(*) AS c FROM mappings").first?.int("c"), 1)
    }

    func testSchemaThreeDuplicateMappingsAreSafelyConsolidated() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("duplicate-mappings.sqlite").path
        let acc = account()
        var survivorID = ""
        do {
            let store = try SyncStore(path: path)
            try await store.saveAccount(acc)
            let mapping = try await store.mapping(for: acc)
            survivorID = mapping.id
            try await store.upsertBaseline(
                BaselineEntry(
                    path: "gleich.txt",
                    kind: .file,
                    localHash: "alt",
                    localSize: 3,
                    localModified: 1,
                    remoteValidator: "\"alt\"",
                    remoteValidatorIsStrong: true,
                    remoteSize: 3,
                    remoteModified: 1,
                    syncedAt: Date(timeIntervalSince1970: 10)
                ),
                mappingID: mapping.id
            )
        }

        let raw = try SQLiteDatabase(path: path)
        try raw.execute("DROP INDEX idx_mappings_key")
        try raw.execute(
            "INSERT INTO mappings VALUES('duplicate-map', ?, ?, 9999999999, 20, 'stale-token', 1)",
            [.text(acc.id), .text(acc.mappingKey)]
        )
        try raw.execute("""
        INSERT INTO entries VALUES(
            'duplicate-map', 'gleich.txt', 'file', 'neu', 3, 2,
            '"neu"', 1, 3, 2, 20
        )
        """)
        try raw.execute("""
        INSERT INTO entries VALUES(
            'duplicate-map', 'nur-dort.txt', 'file', 'erhalten', 8, 2,
            '"extra"', 1, 8, 2, 20
        )
        """)
        try raw.execute(
            "INSERT INTO queue VALUES('duplicate-map', 'stale.txt', 'upload', 1, 1)"
        )
        try raw.execute(
            "INSERT INTO meta(key, value) VALUES('user-pause.duplicate-map', '1')"
        )
        try raw.setUserVersion(3)

        let migrated = try SyncStore(path: path)
        let mapping = try await migrated.mapping(for: acc)
        XCTAssertEqual(mapping.id, survivorID)
        XCTAssertNil(mapping.syncToken)
        XCTAssertFalse(mapping.remoteIndexIsComplete)
        let baseline = try await migrated.baseline(mappingID: mapping.id)
        XCTAssertEqual(baseline["gleich.txt"]?.localHash, "neu")
        XCTAssertEqual(baseline["nur-dort.txt"]?.localHash, "erhalten")
        let queue = try await migrated.queue(mappingID: mapping.id)
        let pause = try await migrated.meta("user-pause.\(mapping.id)")
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(pause, "1")

        let verify = try SQLiteDatabase(path: path)
        XCTAssertEqual(try verify.query("SELECT COUNT(*) AS c FROM mappings").first?.int("c"), 1)
    }

    func testCorruptAccountIsReportedInsteadOfSilentlyDropped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("corrupt.sqlite").path
        let store = try SyncStore(path: path)
        try await store.saveAccount(account())
        let raw = try SQLiteDatabase(path: path)
        try raw.execute("UPDATE accounts SET json = 'kein-json' WHERE id = 'acc'")

        do {
            _ = try await store.accounts()
            XCTFail("Beschädigte Kontodaten dürfen nicht als leere Konfiguration erscheinen")
        } catch is SyncStoreError {
            // Erwartet.
        }
    }

    func testNewerDatabaseSchemaIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("future.sqlite").path
        let raw = try SQLiteDatabase(path: path)
        try raw.setUserVersion(999)
        XCTAssertThrowsError(try SyncStore(path: path)) { error in
            guard case SyncStoreError.unsupportedSchema = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }
    }
}

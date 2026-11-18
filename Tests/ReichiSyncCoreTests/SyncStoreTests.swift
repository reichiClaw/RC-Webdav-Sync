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
        // Ein alter Synchronisierungsstand darf für die neue Zuordnung nicht sichtbar sein.
        try await store.upsertBaseline(BaselineEntry(path: "x", kind: .file, localHash: "h", localSize: 1, localModified: 1, remoteValidator: "e",
                                                     remoteValidatorIsStrong: true, remoteSize: 1, remoteModified: nil), mappingID: m1.id)
        let b2 = try await store.baseline(mappingID: m2.id)
        XCTAssertTrue(b2.isEmpty)
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
        try await store.markRunningTransfersInterrupted(mappingID: m.id)
        let transfers = try await store.transfers(mappingID: m.id)
        XCTAssertEqual(transfers.first?.state, .cancelled)
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
}

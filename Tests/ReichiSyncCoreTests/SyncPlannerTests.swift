import XCTest
@testable import ReichiSyncCore

final class SyncPlannerTests: XCTestCase {
    // MARK: Hilfen

    private func base(_ path: String, hash: String = "h1", etag: String = "\"e1\"", kind: ItemKind = .file) -> BaselineEntry {
        BaselineEntry(path: path, kind: kind, localHash: kind == .file ? hash : nil, localSize: 10, localModified: 1000,
                      remoteValidator: etag, remoteValidatorIsStrong: true, remoteSize: 10, remoteModified: 1000)
    }

    private func local(_ path: String, hash: String = "h1", kind: ItemKind = .file) -> LocalItem {
        LocalItem(path: path, kind: kind, size: 10, modified: 1000, hash: kind == .file ? hash : nil)
    }

    private func remote(_ path: String, etag: String = "\"e1\"", kind: ItemKind = .file) -> RemoteItem {
        RemoteItem(path: path, kind: kind, size: 10, modified: 1000, validator: etag, validatorIsStrong: true)
    }

    private func plan(baseline: [BaselineEntry] = [], local: [LocalItem] = [], remote: [RemoteItem] = [],
                      localComplete: Bool = true, remoteComplete: Bool = true, failedPrefixes: Set<String> = [],
                      remoteCollisions: [String] = [], busy: Set<String> = [], openConflicts: Set<String> = []) -> SyncPlan {
        let localItems = Dictionary(uniqueKeysWithValues: local.map { ($0.path, $0) })
        let remoteItems = Dictionary(uniqueKeysWithValues: remote.map { ($0.path, $0) })
        let input = PlannerInput(
            baseline: Dictionary(uniqueKeysWithValues: baseline.map { ($0.path, $0) }),
            local: LocalSnapshot(items: localItems, isComplete: localComplete, busyPaths: busy),
            remote: RemoteSnapshot(
                items: remoteItems,
                isComplete: remoteComplete,
                failedPrefixes: failedPrefixes,
                collisions: remoteCollisions
            ),
            openConflictPaths: openConflicts
        )
        return SyncPlanner.plan(input)
    }

    private func only(_ plan: SyncPlan) -> SyncAction? {
        let actions = plan.allActions
        XCTAssertEqual(actions.count, 1, "Erwartet genau eine Aktion, erhalten: \(actions)")
        return actions.first
    }

    // MARK: Entscheidungstabelle

    func testUnchangedUnchanged() {
        let p = plan(baseline: [base("a.txt")], local: [local("a.txt")], remote: [remote("a.txt")])
        XCTAssertTrue(p.isEmpty)
    }

    func testChangedLocalUploads() {
        let p = plan(baseline: [base("a.txt")], local: [local("a.txt", hash: "h2")], remote: [remote("a.txt")])
        guard case .uploadChanged(let path, let l, let r)? = only(p) else { return XCTFail("\(p.allActions)") }
        XCTAssertEqual(path, "a.txt")
        XCTAssertEqual(l.hash, "h2")
        XCTAssertEqual(r.validator, "\"e1\"")
    }

    func testChangedRemoteDownloads() {
        let p = plan(baseline: [base("a.txt")], local: [local("a.txt")], remote: [remote("a.txt", etag: "\"e2\"")])
        guard case .download(_, let r, let replacing)? = only(p) else { return XCTFail("\(p.allActions)") }
        XCTAssertEqual(r.validator, "\"e2\"")
        XCTAssertEqual(replacing?.hash, "h1")
    }

    func testBothChangedVerifiesConflict() {
        let p = plan(baseline: [base("a.txt")], local: [local("a.txt", hash: "h2")], remote: [remote("a.txt", etag: "\"e2\"")])
        guard case .verifyConflict(_, _, _, let reason)? = only(p) else { return XCTFail("\(p.allActions)") }
        XCTAssertEqual(reason, .bothModified)
    }

    func testDeletedLocalUnchangedRemoteDeletesRemote() {
        let p = plan(baseline: [base("a.txt")], local: [], remote: [remote("a.txt")])
        guard case .deleteRemote(let path, _)? = only(p) else { return XCTFail("\(p.allActions)") }
        XCTAssertEqual(path, "a.txt")
    }

    func testUnchangedLocalDeletedRemoteDeletesLocal() {
        let p = plan(baseline: [base("a.txt")], local: [local("a.txt")], remote: [])
        guard case .deleteLocal(let path, _)? = only(p) else { return XCTFail("\(p.allActions)") }
        XCTAssertEqual(path, "a.txt")
    }

    func testDeletedLocalChangedRemoteKeepsRemote() {
        let p = plan(baseline: [base("a.txt")], local: [], remote: [remote("a.txt", etag: "\"e2\"")])
        guard case .keepRemoteAfterLocalDelete? = only(p) else { return XCTFail("\(p.allActions)") }
    }

    func testChangedLocalDeletedRemoteKeepsLocal() {
        let p = plan(baseline: [base("a.txt")], local: [local("a.txt", hash: "h2")], remote: [])
        guard case .keepLocalAfterRemoteDelete? = only(p) else { return XCTFail("\(p.allActions)") }
    }

    func testBothDeletedRemovesBaseline() {
        let p = plan(baseline: [base("a.txt")], local: [], remote: [])
        guard case .removeBaseline? = only(p) else { return XCTFail("\(p.allActions)") }
        XCTAssertTrue(p.deletions.isEmpty)
    }

    func testNewLocalUploadsNewRemoteDownloads() {
        let p = plan(local: [local("neu.txt")], remote: [remote("server.txt")])
        XCTAssertEqual(p.transfers.count, 2)
        XCTAssertTrue(p.transfers.contains { if case .uploadNew(let path, _) = $0 { return path == "neu.txt" }; return false })
        XCTAssertTrue(p.transfers.contains { if case .download(let path, _, let replacing) = $0 { return path == "server.txt" && replacing == nil }; return false })
    }

    func testInitialMergeSameNameVerifiesContent() {
        let p = plan(local: [local("a.txt", hash: "lokal")], remote: [remote("a.txt")])
        guard case .verifyConflict(_, _, _, let reason)? = only(p) else { return XCTFail("\(p.allActions)") }
        XCTAssertEqual(reason, .initialMergeDiffers)
    }

    func testKindMismatch() {
        let p = plan(local: [local("x", kind: .directory)], remote: [remote("x")])
        guard case .kindMismatch? = only(p) else { return XCTFail("\(p.allActions)") }
    }

    func testDirectoriesBothNewOnlyUpdateBaseline() {
        let p = plan(local: [local("d", kind: .directory)], remote: [remote("d", kind: .directory)])
        guard case .updateBaseline? = only(p) else { return XCTFail("\(p.allActions)") }
    }

    // MARK: Sicherheitsregeln

    func testIncompleteRemoteListingSuppressesDeletions() {
        let p = plan(baseline: [base("a.txt"), base("sub/b.txt"), base("sub", kind: .directory)],
                     local: [local("a.txt"), local("sub/b.txt"), local("sub", kind: .directory)],
                     remote: [remote("a.txt"), remote("sub", kind: .directory)],
                     remoteComplete: false, failedPrefixes: ["sub"])
        XCTAssertTrue(p.deletions.isEmpty, "\(p.deletions)")
        XCTAssertTrue(p.deletionsSuppressed)
    }

    func testIncompleteLocalScanSuppressesRemoteDeletions() {
        let p = plan(baseline: [base("a.txt")], local: [], remote: [remote("a.txt")], localComplete: false)
        XCTAssertTrue(p.deletions.isEmpty)
    }

    func testEmptyBaselineNeverDeletes() {
        // Datenbank verloren: beide Seiten haben Dateien, nichts darf gelöscht werden.
        let p = plan(local: [local("nur-lokal.txt")], remote: [remote("nur-server.txt")])
        XCTAssertTrue(p.deletions.isEmpty)
        XCTAssertEqual(p.transfers.count, 2)
    }

    func testBusyFilesAreFrozen() {
        let p = plan(baseline: [base("a.txt")], local: [], remote: [remote("a.txt")], busy: ["a.txt"])
        XCTAssertTrue(p.allActions.isEmpty)
        XCTAssertEqual(p.skipped.count, 1)
    }

    func testOpenConflictPathsAreFrozen() {
        let p = plan(baseline: [base("a.txt")], local: [local("a.txt", hash: "h2")], remote: [remote("a.txt")], openConflicts: ["a.txt"])
        XCTAssertTrue(p.allActions.isEmpty)
    }

    func testCaseCollisionOnServerIsSkipped() {
        let p = plan(remote: [remote("Bericht.txt"), remote("bericht.txt")])
        XCTAssertTrue(p.allActions.isEmpty)
        XCTAssertEqual(p.skipped.count, 2)
    }

    func testUnicodeNormalizationCollisionFreezesServerPathAndDescendants() {
        let p = plan(
            baseline: [base("über", kind: .directory), base("über/a.txt")],
            local: [local("über", kind: .directory), local("über/a.txt")],
            remote: [remote("über/a.txt", etag: "\"e2\"")],
            remoteComplete: false,
            failedPrefixes: [""],
            remoteCollisions: ["über"]
        )
        XCTAssertTrue(p.allActions.isEmpty)
        XCTAssertEqual(p.collisions, ["über"])
        XCTAssertTrue(p.skipped.contains { $0.path == "über" })
    }

    func testDeletionActionsExposeScopedAuthorizations() {
        let p = plan(
            baseline: [base("a.txt"), base("b.txt")],
            local: [],
            remote: [remote("a.txt"), remote("b.txt")]
        )
        XCTAssertEqual(
            Set(p.deletions.compactMap(\.deletionAuthorization)),
            [
                DeletionAuthorization(path: "a.txt", kind: .file, side: .remote),
                DeletionAuthorization(path: "b.txt", kind: .file, side: .remote)
            ]
        )
    }

    func testDeletionApprovalCannotFlipFromLocalToRemoteSide() {
        let p = plan(baseline: [base("a.txt")], local: [], remote: [remote("a.txt")])
        XCTAssertEqual(
            p.deletions.first?.deletionAuthorization,
            DeletionAuthorization(path: "a.txt", kind: .file, side: .remote)
        )
        XCTAssertNotEqual(
            p.deletions.first?.deletionAuthorization,
            DeletionAuthorization(path: "a.txt", kind: .file, side: .local)
        )
    }

    // MARK: Ordner

    func testLocallyDeletedDirectoryDeletesKnownRemoteFilesIndividually() {
        let p = plan(baseline: [base("d", kind: .directory), base("d/a.txt"), base("d/b.txt")],
                     local: [],
                     remote: [remote("d", kind: .directory), remote("d/a.txt"), remote("d/b.txt")])
        XCTAssertEqual(Set(p.deletions.map(\.path)), ["d/a.txt", "d/b.txt"])
        XCTAssertEqual(p.deletions.first?.path.split(separator: "/").count, 2)
    }

    func testLocallyDeletedDirectoryWithNewRemoteFileIsKept() {
        let p = plan(baseline: [base("d", kind: .directory), base("d/a.txt")],
                     local: [],
                     remote: [remote("d", kind: .directory), remote("d/a.txt"), remote("d/neu.txt")])
        // a.txt darf gelöscht werden, der Ordner bleibt, neu.txt wird heruntergeladen.
        XCTAssertEqual(p.deletions.map(\.path), ["d/a.txt"])
        XCTAssertTrue(p.transfers.contains { if case .download(let path, _, _) = $0 { return path == "d/neu.txt" }; return false })
        XCTAssertTrue(p.directoryCreations.contains { if case .createLocalDirectory(let path, _) = $0 { return path == "d" }; return false })
    }

    func testRemotelyDeletedDirectoryWithChangedLocalFileIsKept() {
        let p = plan(baseline: [base("d", kind: .directory), base("d/a.txt"), base("d/b.txt")],
                     local: [local("d", kind: .directory), local("d/a.txt"), local("d/b.txt", hash: "neu")],
                     remote: [])
        XCTAssertEqual(p.deletions.map(\.path), ["d/a.txt"])
        XCTAssertTrue(p.transfers.contains { if case .keepLocalAfterRemoteDelete(let path, _) = $0 { return path == "d/b.txt" }; return false })
        XCTAssertTrue(p.directoryCreations.contains { if case .createRemoteDirectory(let path) = $0 { return path == "d" }; return false })
    }

    func testRemotelyDeletedDirectoryDeletesFilesThenEmptyDirectory() {
        let p = plan(baseline: [base("d", kind: .directory), base("d/a.txt")],
                     local: [local("d", kind: .directory), local("d/a.txt")],
                     remote: [])
        XCTAssertEqual(p.deletions.map(\.path), ["d/a.txt", "d"])
    }

    func testUploadIntoMissingRemoteDirectoryCreatesParents() {
        let p = plan(local: [local("a", kind: .directory), local("a/b", kind: .directory), local("a/b/c.txt")])
        XCTAssertEqual(p.directoryCreations.map(\.path), ["a", "a/b"])
        XCTAssertEqual(p.transfers.map(\.path), ["a/b/c.txt"])
    }

    func testDeletionsAreOrderedDeepestFirst() {
        let p = plan(baseline: [base("d", kind: .directory), base("d/a.txt"), base("e.txt")],
                     local: [], remote: [remote("d", kind: .directory), remote("d/a.txt"), remote("e.txt")])
        // Bekannte Kinder werden einzeln konditional gelöscht. Der Ordner selbst
        // bleibt als Baseline-Tombstone bestehen, weil DELETE rekursiv wäre.
        XCTAssertEqual(Set(p.deletions.map(\.path)), ["d/a.txt", "e.txt"])
        XCTAssertEqual(p.deletions.first?.path, "d/a.txt")
    }

    // MARK: Umbenennungen

    func testLocalRenameBecomesRemoteMove() {
        let p = plan(baseline: [base("alt.txt", hash: "same")], local: [local("neu.txt", hash: "same")], remote: [remote("alt.txt")])
        XCTAssertEqual(p.moves.count, 1)
        guard case .moveRemote(let from, let to, _, _)? = p.moves.first else { return XCTFail() }
        XCTAssertEqual(from, "alt.txt")
        XCTAssertEqual(to, "neu.txt")
        XCTAssertTrue(p.deletions.isEmpty)
        XCTAssertTrue(p.transfers.isEmpty)
    }

    func testRenameNotDetectedWhenRemoteChanged() {
        let p = plan(baseline: [base("alt.txt", hash: "same")], local: [local("neu.txt", hash: "same")], remote: [remote("alt.txt", etag: "\"e2\"")])
        XCTAssertTrue(p.moves.isEmpty)
    }

    func testMissingValidatorIsReverifiedEvenWhenSizeMatches() {
        var r = remote("a.txt", etag: "")
        r.validator = nil
        let p = plan(baseline: [base("a.txt")], local: [local("a.txt")], remote: [r])
        guard case .download? = p.transfers.first else {
            return XCTFail("Ohne Validator ist gleiche Größe kein Beweis für unveränderten Inhalt")
        }
    }

    func testValidatorFallbackDetectsChangedModificationDate() {
        var b = base("a.txt")
        b.remoteValidator = nil
        b.remoteModified = 1_000
        var r = remote("a.txt", etag: "")
        r.validator = nil
        r.modified = 2_000
        let p = plan(baseline: [b], local: [local("a.txt")], remote: [r])
        guard case .download(_, _, _)? = only(p) else { return XCTFail("\(p.allActions)") }
    }
}

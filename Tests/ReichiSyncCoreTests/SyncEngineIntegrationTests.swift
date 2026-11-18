import XCTest
@testable import ReichiSyncCore

private actor InvocationCounter {
    private var counts: [String: Int] = [:]

    func next(_ key: String) -> Int {
        counts[key, default: 0] += 1
        return counts[key]!
    }
}

/// Testumgebung: temporärer lokaler Ordner, SQLite-Datei und In-Memory-WebDAV-Server.
final class EngineHarness {
    let root: URL
    let baseDirectory: URL
    let dbPath: String
    let server: FakeWebDAVServer
    let store: SyncStore
    let account: AccountConfiguration
    let mapping: SyncMapping
    let engine: SyncEngine
    let recovery: URL

    /// Neues Setup oder „Neustart“ eines vorhandenen (gleicher Ordner, gleiche Datenbank, gleicher Server).
    init(restarting previous: EngineHarness? = nil, server: FakeWebDAVServer? = nil, deletionGuard: DeletionGuard = DeletionGuard(threshold: 1000, fraction: 1.0)) async throws {
        if let previous {
            baseDirectory = previous.baseDirectory
            self.server = previous.server
        } else {
            baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("reichi-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            self.server = server ?? FakeWebDAVServer()
        }
        root = baseDirectory.appendingPathComponent("Sync")
        recovery = baseDirectory.appendingPathComponent("Recovery")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dbPath = baseDirectory.appendingPathComponent("sync.sqlite").path
        store = try SyncStore(path: dbPath)
        account = AccountConfiguration(id: "acc", name: "Test", serverURL: URL(string: "https://fake.example.org/dav/")!, username: "u", localRootPath: root.path)
        try await store.saveAccount(account)
        mapping = try await store.mapping(for: account)
        let fs = LocalFileSystem(root: root)
        let config = SyncEngineConfiguration(deviceName: "TestMac", recoveryDirectory: recovery, maxConcurrentTransfers: 2,
                                             deletionGuard: deletionGuard, caseInsensitiveLocalFileSystem: true, settleTime: 0, minimumFreeSpace: 0)
        engine = SyncEngine(account: account, mapping: mapping, client: self.server, store: store, fileSystem: fs, rules: ExclusionRules(), configuration: config)
        await engine.start()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    @discardableResult
    func write(_ path: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        // Unterschiedliche Änderungszeit erzwingen, damit Änderungen erkannt werden.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double.random(in: 5...50))], ofItemAtPath: url.path)
        return url
    }

    func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func localFiles() throws -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: root.path)!
        var result: [String] = []
        while let p = enumerator.nextObject() as? String {
            if p.hasPrefix(".reichi-sync") { continue }
            result.append(p)
        }
        return result.sorted()
    }

    @discardableResult
    func sync() async -> SyncStatus {
        await engine.syncAndWait(trigger: .manual)
        return await engine.currentStatus
    }

    func assertServerContent(_ path: String, _ expected: String?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await server.content(path)
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    func assertServerExists(_ path: String, _ expected: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await server.exists(path)
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    func assertConflictCount(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let count = await engine.conflicts().count
        XCTAssertEqual(count, expected, file: file, line: line)
    }

    func recoveredFiles() -> [String] {
        guard let e = FileManager.default.enumerator(atPath: recovery.path) else { return [] }
        var result: [String] = []
        while let p = e.nextObject() as? String { result.append(p) }
        return result
    }
}

final class SyncEngineIntegrationTests: XCTestCase {
    var harness: EngineHarness!

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
    }

    // 1. Lokale Datei anlegen und hochladen.
    func testLocalFileIsUploaded() async throws {
        harness = try await EngineHarness()
        try harness.write("Notiz.txt", "Hallo Server")
        let status = await harness.sync()
        await harness.assertServerContent("Notiz.txt", "Hallo Server")
        XCTAssertEqual(status.health, .synced, status.headline)
        XCTAssertNotNil(status.lastSuccessfulSync)
        let baseline = try await harness.store.baseline(mappingID: harness.mapping.id)
        XCTAssertEqual(baseline["Notiz.txt"]?.localHash, SHA256Hasher.hash(Data("Hallo Server".utf8)))
        XCTAssertNotNil(baseline["Notiz.txt"]?.remoteValidator)
        let log = await harness.server.log()
        XCTAssertTrue(log.contains { $0.hasPrefix("PUT Notiz.txt") && $0.contains("ifNoneMatch=true") }, "Neue Dateien müssen mit If-None-Match: * angelegt werden: \(log)")
    }

    // 2. Serverseitige Datei anlegen und herunterladen.
    func testRemoteFileIsDownloaded() async throws {
        harness = try await EngineHarness()
        await harness.server.mkdir("Ordner")
        await harness.server.putFile("Ordner/Server.txt", "Vom Server")
        let status = await harness.sync()
        XCTAssertEqual(harness.read("Ordner/Server.txt"), "Vom Server")
        XCTAssertEqual(status.health, .synced, status.headline)
        XCTAssertEqual(status.pendingCount, 0)
    }

    // 3. Offline ändern, neu starten, später synchronisieren.
    func testOfflineChangeSurvivesRestart() async throws {
        harness = try await EngineHarness()
        try harness.write("Doc.txt", "v1")
        await harness.sync()
        await harness.assertServerContent("Doc.txt", "v1")

        await harness.server.setOffline(true)
        try harness.write("Doc.txt", "v2 offline")
        try harness.write("Neu offline.txt", "neu")
        let offlineStatus = await harness.sync()
        XCTAssertEqual(offlineStatus.health, .offline)
        XCTAssertNotNil(offlineStatus.nextRetry)
        XCTAssertEqual(harness.read("Doc.txt"), "v2 offline", "Lokale Dateien bleiben offline unverändert nutzbar")
        await harness.assertServerContent("Doc.txt", "v1")

        // Neustart
        await harness.engine.shutdown()
        let restarted = try await EngineHarness(restarting: harness)
        harness = restarted
        await harness.server.setOffline(false)
        let status = await harness.sync()
        XCTAssertEqual(status.health, .synced, status.headline)
        await harness.assertServerContent("Doc.txt", "v2 offline")
        await harness.assertServerContent("Neu offline.txt", "neu")
    }

    // 4. Dieselbe Datei beidseitig ändern: beide Versionen bleiben erhalten.
    func testBothSidesModifiedKeepsBothVersions() async throws {
        harness = try await EngineHarness()
        try harness.write("Plan.txt", "gemeinsam")
        await harness.sync()
        try harness.write("Plan.txt", "lokal geändert")
        await harness.server.putFile("Plan.txt", "server geändert")
        let status = await harness.sync()

        XCTAssertEqual(harness.read("Plan.txt"), "server geändert", "Der Pfad trägt die Serverversion")
        let files = try harness.localFiles()
        let copy = try XCTUnwrap(files.first { $0.contains("Konfliktkopie von TestMac") }, "\(files)")
        XCTAssertEqual(harness.read(copy), "lokal geändert")
        await harness.assertServerContent(copy, "lokal geändert", "Konfliktkopie wird im Folgedurchgang hochgeladen")
        await harness.assertServerContent("Plan.txt", "server geändert")
        XCTAssertEqual(status.health, .conflicts, status.headline)
        let conflicts = await harness.engine.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.reason, .bothModified)
        XCTAssertEqual(conflicts.first?.conflictCopyPath, copy)

        // Entscheidung: lokale Version verwenden.
        try await harness.engine.resolveConflict(id: conflicts[0].id, resolution: .useLocal)
        await harness.sync()
        XCTAssertEqual(harness.read("Plan.txt"), "lokal geändert")
        await harness.assertServerContent("Plan.txt", "lokal geändert")
        XCTAssertFalse(harness.exists(copy))
        await harness.assertServerExists(copy, false)
        let after = await harness.engine.currentStatus
        XCTAssertEqual(after.health, .synced, after.headline)
        XCTAssertFalse(harness.recoveredFiles().isEmpty, "Verworfene Kopie liegt im Wiederherstellungsbereich")
    }

    func testBothSidesModifiedWithIdenticalContentMerges() async throws {
        harness = try await EngineHarness()
        try harness.write("Gleich.txt", "a")
        await harness.sync()
        try harness.write("Gleich.txt", "b")
        await harness.server.putFile("Gleich.txt", "b")
        let status = await harness.sync()
        XCTAssertEqual(status.health, .synced, status.headline)
        XCTAssertEqual(try harness.localFiles(), ["Gleich.txt"])
        await harness.assertConflictCount(0)
    }

    // 5. Löschen auf einer Seite, Ändern auf der anderen: Konflikt statt Datenverlust.
    func testDeleteVersusModifyPreservesData() async throws {
        harness = try await EngineHarness()
        try harness.write("A.txt", "a1")
        try harness.write("B.txt", "b1")
        await harness.sync()

        // A: lokal gelöscht, Server geändert
        try harness.remove("A.txt")
        await harness.server.putFile("A.txt", "a2 server")
        // B: lokal geändert, Server gelöscht
        try harness.write("B.txt", "b2 lokal")
        await harness.server.remove("B.txt")

        let status = await harness.sync()
        XCTAssertEqual(harness.read("A.txt"), "a2 server")
        await harness.assertServerContent("A.txt", "a2 server")
        XCTAssertEqual(harness.read("B.txt"), "b2 lokal")
        await harness.assertServerContent("B.txt", "b2 lokal")
        let conflicts = await harness.engine.conflicts()
        XCTAssertEqual(Set(conflicts.map(\.reason)), [.deletedLocallyModifiedRemotely, .modifiedLocallyDeletedRemotely])
        XCTAssertEqual(status.health, .conflicts)

        // Löschung für A doch übernehmen.
        let a = try XCTUnwrap(conflicts.first { $0.path == "A.txt" })
        try await harness.engine.resolveConflict(id: a.id, resolution: .applyDeletion)
        await harness.sync()
        XCTAssertFalse(harness.exists("A.txt"))
        await harness.assertServerExists("A.txt", false)
        let b = try XCTUnwrap(conflicts.first { $0.path == "B.txt" })
        try await harness.engine.resolveConflict(id: b.id, resolution: .keepBoth)
        await harness.sync()
        let final = await harness.engine.currentStatus
        XCTAssertEqual(final.health, .synced, final.headline)
    }

    // 6. Verbindung während Upload/Download unterbrechen.
    func testInterruptedUploadIsRecoveredWithoutConflict() async throws {
        harness = try await EngineHarness()
        try harness.write("Groß.bin", String(repeating: "x", count: 5000))
        await harness.server.setDropConnectionOnUploadButStore(true)
        let first = await harness.sync()
        XCTAssertNotEqual(first.health, .synced)
        XCTAssertEqual(first.health, .offline)
        XCTAssertNotNil(first.nextRetry, "Ein Verbindungsabbruch während des Transfers muss automatisch erneut versucht werden")
        let baseline = try await harness.store.baseline(mappingID: harness.mapping.id)
        XCTAssertNil(baseline["Groß.bin"], "Gemeinsamer Stand darf erst nach bestätigtem Erfolg aktualisiert werden")
        let transfers = await harness.engine.transfers()
        XCTAssertTrue(transfers.contains { $0.state == .failed && $0.path == "Groß.bin" })

        let second = await harness.sync()
        XCTAssertEqual(second.health, .synced, second.headline)
        XCTAssertEqual(try harness.localFiles(), ["Groß.bin"], "Kein Konflikt, keine Kopie – Inhalt war identisch")
        await harness.assertConflictCount(0)
    }

    func testInterruptedDownloadLeavesNoPartialFile() async throws {
        harness = try await EngineHarness()
        await harness.server.putFile("Bild.jpg", "binärdaten")
        await harness.server.setDropConnectionOnDownload(true)
        let first = await harness.sync()
        XCTAssertFalse(harness.exists("Bild.jpg"))
        XCTAssertNotEqual(first.health, .synced)
        let temp = harness.root.appendingPathComponent(".reichi-sync-tmp")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Temporäre Dateien müssen aufgeräumt werden: \(leftovers)")
        await harness.server.setDropConnectionOnDownload(false)
        let second = await harness.sync()
        XCTAssertEqual(harness.read("Bild.jpg"), "binärdaten")
        XCTAssertEqual(second.health, .synced, second.headline)
    }

    // 7. Datei während ihres Uploads erneut bearbeiten.
    func testFileModifiedDuringUploadStaysPending() async throws {
        harness = try await EngineHarness()
        let url = try harness.write("Live.txt", "erste Fassung")
        await harness.server.setBeforeUpload { path in
            guard path == "Live.txt" else { return }
            try? Data("zweite Fassung".utf8).write(to: url)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        }
        await harness.sync()
        await harness.server.setBeforeUpload(nil)
        await harness.assertServerContent("Live.txt", "zweite Fassung", "Die zweite Fassung muss im Folgedurchgang hochgeladen werden")
        let status = await harness.engine.currentStatus
        XCTAssertEqual(status.health, .synced, status.headline)
    }

    func testSameSizeAndMtimeModificationDuringUploadIsRetried() async throws {
        harness = try await EngineHarness()
        let url = try harness.write("Metadaten.txt", "AAAA")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        let counter = InvocationCounter()
        await harness.server.setBeforeUpload { path in
            guard path == "Metadaten.txt", await counter.next(path) == 1 else { return }
            try? Data("BBBB".utf8).write(to: url)
            try? FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        }

        let status = await harness.sync()
        await harness.server.setBeforeUpload(nil)

        await harness.assertServerContent("Metadaten.txt", "BBBB")
        XCTAssertEqual(status.health, .synced, status.headline)
        let baseline = try await harness.store.baseline(mappingID: harness.mapping.id)
        XCTAssertEqual(baseline["Metadaten.txt"]?.localHash, SHA256Hasher.hash(Data("BBBB".utf8)))
    }

    // 8. Server liefert Fehler oder unvollständige Auflistung: keine Löschungen.
    func testIncompleteRemoteListingNeverDeletesLocally() async throws {
        harness = try await EngineHarness()
        try harness.write("Wichtig/Vertrag.pdf", "pdf")
        try harness.write("Sonst.txt", "s")
        await harness.sync()
        await harness.assertServerContent("Wichtig/Vertrag.pdf", "pdf")

        await harness.server.setFailListing(["Wichtig"])
        await harness.sync()
        XCTAssertEqual(harness.read("Wichtig/Vertrag.pdf"), "pdf", "Datei darf trotz fehlender Auflistung nicht gelöscht werden")
        let status = await harness.engine.currentStatus
        XCTAssertNotEqual(status.health, .synced, "Unvollständige Bestandsaufnahme darf nicht als synchronisiert gelten")

        await harness.server.setFailListing([])
        await harness.server.setAuthFails(true)
        let authStatus = await harness.sync()
        XCTAssertEqual(authStatus.pauseReason, .authenticationRequired)
        XCTAssertEqual(harness.read("Wichtig/Vertrag.pdf"), "pdf")
        await harness.server.setAuthFails(false)
    }

    func testInvalidServerResponseIsAttentionNotOffline() async throws {
        harness = try await EngineHarness()
        await harness.server.setFailListing([""])

        let status = await harness.sync()

        XCTAssertEqual(status.health, .attention)
        XCTAssertNotNil(status.nextRetry)
        XCTAssertNotNil(status.lastIssue)
    }

    // 9. Lokaler Stammordner fehlt: Synchronisierung pausiert.
    func testMissingLocalRootPausesAndDeletesNothing() async throws {
        harness = try await EngineHarness()
        try harness.write("Daten.txt", "d")
        await harness.sync()
        try FileManager.default.removeItem(at: harness.root)
        let status = await harness.sync()
        XCTAssertEqual(status.health, .paused)
        XCTAssertEqual(status.pauseReason, .localRootMissing)
        await harness.assertServerContent("Daten.txt", "d", "Ein fehlender Stammordner darf keine Löschungen auf dem Server auslösen")
        let log = await harness.server.log()
        XCTAssertFalse(log.contains { $0.hasPrefix("DELETE") })
    }

    // 10. Gleichnamige, unterschiedliche Dateien beim ersten Abgleich: beide bleiben erhalten.
    func testInitialMergeKeepsBothDifferentFiles() async throws {
        harness = try await EngineHarness()
        try harness.write("Readme.md", "lokale Fassung")
        try harness.write("Gleich.txt", "identisch")
        await harness.server.putFile("Readme.md", "Server-Fassung")
        await harness.server.putFile("Gleich.txt", "identisch")
        await harness.server.putFile("NurServer.txt", "s")
        await harness.sync()
        let files = try harness.localFiles()
        XCTAssertTrue(files.contains("NurServer.txt"))
        XCTAssertEqual(harness.read("Readme.md"), "Server-Fassung")
        let copy = try XCTUnwrap(files.first { $0.hasPrefix("Readme (Konfliktkopie von TestMac") })
        XCTAssertEqual(harness.read(copy), "lokale Fassung")
        await harness.assertServerContent(copy, "lokale Fassung")
        XCTAssertEqual(files.filter { $0.hasPrefix("Gleich") }, ["Gleich.txt"], "Identische Inhalte erzeugen keine Kopie")
        let firstConflict = await harness.engine.conflicts().first
        XCTAssertEqual(firstConflict?.reason, .initialMergeDiffers)
    }

    // 11. Sonderzeichen und kollidierende Dateinamen.
    func testSpecialCharactersAndCollisions() async throws {
        harness = try await EngineHarness()
        let nfdName = "U\u{0308}bersicht \u{1F4C1} Q4.txt" // NFD-„Ü“ + Emoji
        try harness.write(nfdName, "umlaut")
        try harness.write("Ordner mit Leerzeichen/Datei & Zeichen #1.txt", "x")
        await harness.server.putFile("Bericht.txt", "groß")
        await harness.server.putFile("bericht.txt", "klein")
        await harness.server.putFile("Emoji 🚀.txt", "rakete")
        let status = await harness.sync()

        await harness.assertServerContent("Übersicht 📁 Q4.txt", "umlaut", "Server erhält den NFC-normalisierten Namen")
        await harness.assertServerContent("Ordner mit Leerzeichen/Datei & Zeichen #1.txt", "x")
        XCTAssertEqual(harness.read("Emoji 🚀.txt"), "rakete")
        XCTAssertFalse(harness.exists("Bericht.txt"))
        XCTAssertFalse(harness.exists("bericht.txt"))
        XCTAssertEqual(status.skippedCount, 2, "Kollidierende Namen werden übersprungen und gemeldet")
        XCTAssertNotEqual(status.health, .synced)
    }

    func testNFDDirectoryRawPathIsWalkedCompletely() async throws {
        let server = FakeWebDAVServer()
        let rawDirectory = "U\u{0308}bersicht"
        await server.mkdirWithRawPath(rawDirectory)
        await server.putFileWithRawPath("\(rawDirectory)/Datei.txt", "unicode")
        harness = try await EngineHarness(server: server)

        let status = await harness.sync()

        XCTAssertEqual(harness.read("Übersicht/Datei.txt"), "unicode")
        XCTAssertEqual(status.health, .synced, status.headline)
        let log = await server.log()
        XCTAssertTrue(log.contains("LIST \(rawDirectory)"), "\(log)")
    }

    // 12. Geänderte Serverversion zwischen Bestandsaufnahme und Upload wird erkannt.
    func testRemoteChangedBetweenListingAndUploadIsDetected() async throws {
        harness = try await EngineHarness()
        try harness.write("Race.txt", "v1")
        await harness.sync()
        try harness.write("Race.txt", "v2 lokal")
        let server = harness.server
        await harness.server.setBeforeUpload { path in
            guard path == "Race.txt" else { return }
            await server.putFile("Race.txt", "v2 server")
        }
        await harness.sync()
        await harness.server.setBeforeUpload(nil)
        await harness.assertServerContent("Race.txt", "v2 server", "Die Serverversion darf nicht überschrieben werden")
        let log = await harness.server.log()
        XCTAssertTrue(log.contains { $0.hasPrefix("PUT Race.txt ifMatch=\"") }, "Upload muss If-Match verwenden: \(log)")
        let files = try harness.localFiles()
        XCTAssertTrue(files.contains { $0.contains("Konfliktkopie") }, "Nach 412 wird neu abgeglichen und ein Konflikt erzeugt: \(files)")
        let copy = files.first { $0.contains("Konfliktkopie") }!
        XCTAssertEqual(harness.read(copy), "v2 lokal")
        XCTAssertEqual(harness.read("Race.txt"), "v2 server")
    }

    // 13. Nach Neustart bleiben Warteschlange und Konflikte erhalten.
    func testQueueAndConflictsSurviveRestart() async throws {
        harness = try await EngineHarness()
        try harness.write("K.txt", "a")
        await harness.sync()
        try harness.write("K.txt", "b")
        await harness.server.putFile("K.txt", "c")
        await harness.sync()
        await harness.assertConflictCount(1)

        await harness.server.setOffline(true)
        try harness.write("Offen.txt", "pending")
        await harness.sync()
        await harness.engine.shutdown()

        harness = try await EngineHarness(restarting: harness)
        await harness.assertConflictCount(1)
        let startStatus = await harness.engine.currentStatus
        XCTAssertGreaterThanOrEqual(startStatus.openConflicts, 1)
        await harness.server.setOffline(false)
        await harness.sync()
        await harness.assertServerContent("Offen.txt", "pending")
    }

    // Löschungen: Papierkorb/Wiederherstellungsbereich und Löschschutz.
    func testRemoteDeletionMovesLocalFileToRecovery() async throws {
        harness = try await EngineHarness()
        try harness.write("Weg.txt", "bye")
        await harness.sync()
        await harness.server.remove("Weg.txt")
        let status = await harness.sync()
        XCTAssertFalse(harness.exists("Weg.txt"))
        XCTAssertTrue(harness.recoveredFiles().contains { $0.hasSuffix("Weg.txt") })
        XCTAssertEqual(status.health, .synced, status.headline)
    }

    func testLocalDirectoryDeletionRemovesKnownFilesButKeepsRemoteDirectory() async throws {
        harness = try await EngineHarness(deletionGuard: DeletionGuard(threshold: 1000, fraction: 0.1))
        try harness.write("Alt/x.txt", "x")
        try harness.write("Alt/y.txt", "y")
        try harness.write("Bleibt.txt", "b")
        await harness.sync()
        try harness.remove("Alt")
        await harness.server.clearLog()
        await harness.sync()
        let heldStatus = await harness.engine.currentStatus
        XCTAssertEqual(heldStatus.pendingDeletions, 2)
        await harness.engine.confirmPendingDeletions()
        await harness.engine.syncAndWait()
        await harness.assertServerExists("Alt", true, "WebDAV kann ein rekursives Ordner-DELETE nicht atomar gegen neue Kinder schützen")
        await harness.assertServerExists("Alt/x.txt", false)
        await harness.assertServerExists("Alt/y.txt", false)
        await harness.assertServerContent("Bleibt.txt", "b")
        let baseline = try await harness.store.baseline(mappingID: harness.mapping.id)
        XCTAssertEqual(Set(baseline.keys), ["Alt", "Bleibt.txt"])
        let status = await harness.engine.currentStatus
        XCTAssertEqual(status.pendingDeletions, 0, "Ein absichtlich blockierter Serverordner darf nicht wiederholt eine Bestätigung verlangen")
        XCTAssertEqual(status.health, .synced, status.headline)
        let log = await harness.server.log()
        let deletes = log.filter { $0.hasPrefix("DELETE") }
        XCTAssertEqual(deletes.count, 2, "Bekannte Dateien werden einzeln gelöscht; der Ordner selbst bleibt: \(log)")
        XCTAssertTrue(deletes.allSatisfy { $0.contains("ifMatch=\"") })
    }

    func testRetainedRemoteDirectoryRestoresNewDeepDescendant() async throws {
        harness = try await EngineHarness()
        try harness.write("d/sub/bestand.txt", "alt")
        try harness.write("bleibt.txt", "bleibt")
        await harness.sync()
        try harness.remove("d")
        let server = harness.server
        await harness.sync()
        await server.putFile("d/sub/neu.txt", "server-neu")
        let status = await harness.sync()

        await harness.assertServerContent("d/sub/neu.txt", "server-neu", "Ein nach der Bestandsaufnahme angelegter tiefer Nachkomme darf nicht rekursiv gelöscht werden")
        XCTAssertEqual(harness.read("d/sub/neu.txt"), "server-neu")
        XCTAssertNotEqual(status.health, .paused)
    }

    func testExcludedLocalContentBlocksParentDeletion() async throws {
        harness = try await EngineHarness()
        try harness.write("d/a.txt", "a")
        await harness.sync()
        await harness.server.remove("d")
        try harness.write("d/.DS_Store", "Finder-Metadaten")

        let status = await harness.sync()

        XCTAssertTrue(harness.exists("d/.DS_Store"), "Ausgeschlossene Benutzerdateien dürfen nicht mit dem Elternordner entfernt werden")
        XCTAssertFalse(harness.exists("d/a.txt"), "Die bekannte Datei darf separat und wiederherstellbar entfernt werden")
        XCTAssertTrue(harness.recoveredFiles().contains { $0.hasSuffix("d/a.txt") })
        XCTAssertNotEqual(status.health, .synced)
    }

    func testSymlinkReplacementNeverDeletesRemoteFile() async throws {
        harness = try await EngineHarness()
        try harness.write("sicher.txt", "serverinhalt")
        await harness.sync()
        let outside = harness.baseDirectory.appendingPathComponent("outside.txt")
        try Data("außen".utf8).write(to: outside)
        try harness.remove("sicher.txt")
        try FileManager.default.createSymbolicLink(
            at: harness.root.appendingPathComponent("sicher.txt"),
            withDestinationURL: outside
        )

        let status = await harness.sync()

        await harness.assertServerContent("sicher.txt", "serverinhalt")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "außen")
        XCTAssertNotEqual(status.health, .synced)
    }

    func testDeleteIsDeferredWhenServerIgnoresIfMatch() async throws {
        let server = FakeWebDAVServer()
        harness = try await EngineHarness(server: server)
        try harness.write("race.txt", "v1")
        try harness.write("bleibt.txt", "bleibt")
        await harness.sync()
        await harness.engine.shutdown()
        await server.setHonorsIfMatch(false)
        harness = try await EngineHarness(restarting: harness)
        try harness.remove("race.txt")
        await harness.sync()

        await harness.assertServerContent("race.txt", "v1", "Ohne atomare If-Match-Auswertung darf keine entfernte Version gelöscht werden")
        XCTAssertNil(harness.read("race.txt"))
        let log = await server.log()
        XCTAssertFalse(log.contains { $0.hasPrefix("DELETE race.txt") })
        let queue = await harness.engine.queue()
        XCTAssertTrue(queue.contains { $0.path == "race.txt" })
    }

    func testAuthenticationFailureDuringTransferPausesEngine() async throws {
        harness = try await EngineHarness()
        try harness.write("auth.txt", "inhalt")
        await harness.server.setAuthFailOnUpload(true)

        let failed = await harness.sync()

        XCTAssertEqual(failed.pauseReason, .authenticationRequired)
        XCTAssertEqual(failed.health, .paused)
        let queue = await harness.engine.queue()
        XCTAssertTrue(queue.contains { $0.path == "auth.txt" })

        await harness.server.setAuthFailOnUpload(false)
        await harness.engine.resume()
        await harness.engine.syncAndWait()
        await harness.assertServerContent("auth.txt", "inhalt")
    }

    func testEmptiedLocalFolderRequiresConfirmation() async throws {
        harness = try await EngineHarness()
        try harness.write("Einzig.txt", "x")
        await harness.sync()
        try harness.remove("Einzig.txt")
        let status = await harness.sync()
        XCTAssertEqual(status.pendingDeletions, 1, "Ein plötzlich leerer Ordner darf nie automatisch Löschungen auslösen")
        await harness.assertServerContent("Einzig.txt", "x")
    }

    func testDeletionGuardHoldsLargeDeletionsUntilConfirmed() async throws {
        harness = try await EngineHarness(deletionGuard: DeletionGuard(threshold: 3, fraction: 0.5))
        for i in 0..<5 { try harness.write("f\(i).txt", "\(i)") }
        await harness.sync()
        for i in 0..<4 { try harness.remove("f\(i).txt") }
        let status = await harness.sync()
        XCTAssertEqual(status.health, .attention)
        XCTAssertEqual(status.pendingDeletions, 4)
        for i in 0..<4 { await harness.assertServerExists("f\(i).txt", true, "Zurückgehaltene Löschung darf nicht ausgeführt werden") }
        let pending = await harness.engine.pendingDeletions()
        XCTAssertEqual(pending.count, 4)
        XCTAssertTrue(pending.allSatisfy { $0.side == .remote })

        await harness.engine.confirmPendingDeletions()
        await harness.engine.syncAndWait()
        for i in 0..<4 { await harness.assertServerExists("f\(i).txt", false) }
        let after = await harness.engine.currentStatus
        XCTAssertEqual(after.health, .synced, after.headline)
    }

    func testDiscardingHeldDeletionsRestoresFiles() async throws {
        harness = try await EngineHarness(deletionGuard: DeletionGuard(threshold: 2, fraction: 0.5))
        for i in 0..<4 { try harness.write("g\(i).txt", "\(i)") }
        await harness.sync()
        for i in 0..<4 { await harness.server.remove("g\(i).txt") }
        let status = await harness.sync()
        XCTAssertEqual(status.pendingDeletions, 4)
        for i in 0..<4 { XCTAssertTrue(harness.exists("g\(i).txt")) }
        await harness.engine.discardPendingDeletions()
        await harness.engine.syncAndWait()
        for i in 0..<4 { await harness.assertServerContent("g\(i).txt", "\(i)", "Verworfene Löschung → Dateien werden wieder hochgeladen") }
    }

    func testLocalRenameUsesMove() async throws {
        harness = try await EngineHarness()
        try harness.write("Alt.txt", "inhalt")
        await harness.sync()
        try FileManager.default.moveItem(at: harness.root.appendingPathComponent("Alt.txt"), to: harness.root.appendingPathComponent("Neu.txt"))
        await harness.server.clearLog()
        let status = await harness.sync()
        let log = await harness.server.log()
        XCTAssertTrue(log.contains("MOVE Alt.txt -> Neu.txt"), "\(log)")
        await harness.assertServerContent("Neu.txt", "inhalt")
        await harness.assertServerExists("Alt.txt", false)
        XCTAssertEqual(status.health, .synced)
    }

    func testUnsupportedMoveFallbackCompletesUploadDeleteAndQueue() async throws {
        let server = FakeWebDAVServer()
        harness = try await EngineHarness(server: server)
        try harness.write("Alt.txt", "inhalt")
        await harness.sync()
        try FileManager.default.moveItem(
            at: harness.root.appendingPathComponent("Alt.txt"),
            to: harness.root.appendingPathComponent("Neu.txt")
        )
        await server.setMoveUnsupported(true)

        let status = await harness.sync()

        await harness.assertServerContent("Neu.txt", "inhalt")
        await harness.assertServerExists("Alt.txt", false)
        let queue = await harness.engine.queue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(status.health, .synced, status.headline)
    }

    func testEmptyDirectoriesAndEmptyFiles() async throws {
        harness = try await EngineHarness()
        try harness.mkdir("Leer/Tiefer")
        try harness.write("leer.txt", "")
        await harness.server.mkdir("ServerLeer")
        let status = await harness.sync()
        await harness.assertServerExists("Leer/Tiefer", true)
        await harness.assertServerContent("leer.txt", "")
        XCTAssertTrue(harness.exists("ServerLeer"))
        XCTAssertEqual(status.health, .synced, status.headline)
    }

    func testSyncCollectionIncrementalUpdates() async throws {
        let server = FakeWebDAVServer()
        await server.setSupportsSync(true)
        harness = try await EngineHarness(server: server)
        await server.putFile("a.txt", "a")
        await harness.sync()
        XCTAssertEqual(harness.read("a.txt"), "a")
        let mapping = try await harness.store.mapping(id: harness.mapping.id)
        XCTAssertNotNil(mapping?.syncToken)

        await server.clearLog()
        await server.putFile("b.txt", "b")
        await server.remove("a.txt")
        let status = await harness.sync()
        let log = await server.log()
        XCTAssertTrue(log.contains { $0.hasPrefix("SYNC fake-sync-") }, "Zweiter Durchgang nutzt sync-collection: \(log)")
        XCTAssertFalse(log.contains("LIST "), "Keine vollständige Traversierung nötig: \(log)")
        XCTAssertEqual(harness.read("b.txt"), "b")
        XCTAssertFalse(harness.exists("a.txt"))
        XCTAssertEqual(status.health, .synced, status.headline)
    }

    func testExcludedFilesAreNotUploaded() async throws {
        harness = try await EngineHarness()
        try harness.write(".DS_Store", "meta")
        try harness.write("Ordner/._Resource", "rf")
        try harness.write("~$Word.docx", "lock")
        try harness.write("Echt.txt", "echt")
        await harness.sync()
        await harness.assertServerExists(".DS_Store", false)
        await harness.assertServerExists("Ordner/._Resource", false)
        await harness.assertServerExists("~$Word.docx", false)
        await harness.assertServerContent("Echt.txt", "echt")
    }

    func testWeakETagsDoNotPermitUnprotectedOverwrite() async throws {
        let server = FakeWebDAVServer()
        await server.setWeakETags(true)
        harness = try await EngineHarness(server: server)
        try harness.write("W.txt", "1")
        await harness.sync()
        try harness.write("W.txt", "2")
        await server.clearLog()
        await harness.sync()
        let log = await server.log()
        XCTAssertFalse(log.contains { $0.hasPrefix("PUT W.txt") }, "Eine Vorprüfung ohne atomare Bedingung schließt das TOCTOU-Fenster nicht: \(log)")
        await harness.assertServerContent("W.txt", "1")
        XCTAssertEqual(harness.read("W.txt"), "2")
        let queue = await harness.engine.queue()
        XCTAssertTrue(queue.contains { $0.path == "W.txt" })
    }

    func testPauseAndResume() async throws {
        harness = try await EngineHarness()
        await harness.engine.pause()
        try harness.write("P.txt", "p")
        await harness.engine.requestSync(trigger: .interval)
        await harness.engine.syncAndWait(trigger: .interval)
        var status = await harness.engine.currentStatus
        XCTAssertEqual(status.health, .paused)
        await harness.assertServerExists("P.txt", false)
        await harness.engine.resume()
        await harness.engine.syncAndWait()
        status = await harness.engine.currentStatus
        XCTAssertEqual(status.health, .synced, status.headline)
        await harness.assertServerContent("P.txt", "p")
    }

    func testUserPauseSurvivesRestart() async throws {
        harness = try await EngineHarness()
        await harness.engine.pause()
        await harness.engine.shutdown()

        harness = try await EngineHarness(restarting: harness)
        var status = await harness.engine.currentStatus
        XCTAssertTrue(status.isPaused)
        XCTAssertEqual(status.pauseReason, .user)
        try harness.write("NachNeustart.txt", "bleibt lokal")
        await harness.engine.syncAndWait(trigger: .manual)
        await harness.assertServerExists("NachNeustart.txt", false)

        await harness.engine.resume()
        await harness.engine.syncAndWait()
        status = await harness.engine.currentStatus
        XCTAssertFalse(status.isPaused)
        await harness.assertServerContent("NachNeustart.txt", "bleibt lokal")
    }
}

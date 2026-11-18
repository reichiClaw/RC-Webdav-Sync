import XCTest
@testable import ReichiSyncCore

/// Startet den Python-Testserver (`Scripts/dev-webdav-server.py`) und prüft den
/// echten HTTP-WebDAV-Client inklusive bedingter Schreibzugriffe – sowie einen
/// vollständigen Engine-Durchlauf über HTTP.
final class WebDAVClientHTTPTests: XCTestCase {
    private var server: DevServerLauncher!
    private var serverRoot: URL { server.serverRoot }
    private var baseURL: URL { server.davURL }

    override func setUpWithError() throws {
        server = try DevServerLauncher()
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    private func makeClient(password: String = "geheim") throws -> WebDAVClient {
        try WebDAVClient(baseURL: baseURL, credentials: WebDAVCredentials(username: "anna", password: password))
    }

    func testCapabilitiesAndProbe() async throws {
        let client = try makeClient()
        let caps = try await client.detectCapabilities()
        XCTAssertTrue(caps.davClasses.contains("1"))
        XCTAssertFalse(caps.supportsSyncCollection)
        let root = try await client.probe()
        XCTAssertEqual(root.kind, .directory)
    }

    func testWrongPasswordIsAuthenticationError() async throws {
        let client = try makeClient(password: "falsch")
        do {
            _ = try await client.probe()
            XCTFail("Erwartet 401")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .authenticationRequired(status: 401))
        }
    }

    func testFullCycleWithConditionalRequests() async throws {
        let client = try makeClient()
        try await client.makeDirectory("Ordner ä 📁")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Inhalt 1".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let created = try await client.upload(file: temp, to: "Ordner ä 📁/Datei mit Leerzeichen.txt", ifMatch: nil, ifNoneMatchAll: true, progress: nil)
        XCTAssertEqual(created.status, 201)
        let etag1 = try XCTUnwrap(created.etag)
        XCTAssertFalse(etag1.hasPrefix("W/"))

        // Erneutes Anlegen mit If-None-Match: * muss scheitern.
        do {
            _ = try await client.upload(file: temp, to: "Ordner ä 📁/Datei mit Leerzeichen.txt", ifMatch: nil, ifNoneMatchAll: true, progress: nil)
            XCTFail("Erwartet 412")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .preconditionFailed)
        }

        // Auflisten
        let items = try await client.list(directory: "Ordner ä 📁")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.path, "Ordner ä 📁/Datei mit Leerzeichen.txt")
        XCTAssertEqual(items.first?.size, 8)
        XCTAssertEqual(items.first?.validator, etag1)
        XCTAssertTrue(items.first?.validatorIsStrong ?? false)

        // Überschreiben mit korrektem If-Match
        try Data("Inhalt 2".utf8).write(to: temp)
        let updated = try await client.upload(file: temp, to: "Ordner ä 📁/Datei mit Leerzeichen.txt", ifMatch: etag1, ifNoneMatchAll: false, progress: nil)
        XCTAssertEqual(updated.status, 204)
        let etag2 = try XCTUnwrap(updated.etag)
        XCTAssertNotEqual(etag1, etag2)

        // Überschreiben mit veraltetem If-Match → 412
        do {
            _ = try await client.upload(file: temp, to: "Ordner ä 📁/Datei mit Leerzeichen.txt", ifMatch: etag1, ifNoneMatchAll: false, progress: nil)
            XCTFail("Erwartet 412")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .preconditionFailed)
        }

        // Download
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) }
        let download = try await client.download("Ordner ä 📁/Datei mit Leerzeichen.txt", to: dest, progress: nil)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "Inhalt 2")
        XCTAssertEqual(download.etag, etag2)
        XCTAssertEqual(download.contentLength, 8)

        // stat / MOVE / DELETE
        let stat = try await client.stat("Ordner ä 📁/Datei mit Leerzeichen.txt")
        XCTAssertEqual(stat?.validator, etag2)
        try await client.move(from: "Ordner ä 📁/Datei mit Leerzeichen.txt", to: "Ordner ä 📁/Neu.txt", overwrite: false, ifMatch: etag2)
        let afterMove = try await client.stat("Ordner ä 📁/Datei mit Leerzeichen.txt")
        XCTAssertNil(afterMove)
        let moved = try await client.stat("Ordner ä 📁/Neu.txt")
        XCTAssertNotNil(moved)
        try await client.delete("Ordner ä 📁/Neu.txt", ifMatch: moved?.validator)
        let afterDelete = try await client.stat("Ordner ä 📁/Neu.txt")
        XCTAssertNil(afterDelete)
        try await client.delete("Ordner ä 📁", ifMatch: nil)
        let rootItems = try await client.list(directory: "")
        XCTAssertTrue(rootItems.isEmpty)

        // Nicht vorhandene Ressource
        do {
            _ = try await client.download("fehlt.txt", to: dest, progress: nil)
            XCTFail("Erwartet 404")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testEngineEndToEndOverHTTP() async throws {
        let client = try makeClient()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reichi-http-\(UUID().uuidString)")
        let selectedRoot = base.appendingPathComponent("Sync")
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        let fileSystem = LocalFileSystem(root: selectedRoot, prefersTrash: false)
        let root = fileSystem.root
        defer { try? FileManager.default.removeItem(at: base) }

        // Server-Vorbestand
        try FileManager.default.createDirectory(at: serverRoot.appendingPathComponent("Vom Server"), withIntermediateDirectories: true)
        try Data("remote".utf8).write(to: serverRoot.appendingPathComponent("Vom Server/remote.txt"))
        // Lokaler Vorbestand
        try Data("lokal".utf8).write(to: root.appendingPathComponent("lokal.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: root.appendingPathComponent("lokal.txt").path)

        let store = try SyncStore(path: base.appendingPathComponent("db.sqlite").path)
        let account = AccountConfiguration(name: "HTTP", serverURL: baseURL, username: "anna", localRootPath: root.path, allowInsecureHTTP: true)
        let mapping = try await store.mapping(for: account)
        let config = SyncEngineConfiguration(
            deviceName: "HTTPMac",
            recoveryDirectory: base.appendingPathComponent("Recovery"),
            deletionGuard: DeletionGuard(threshold: 1000, fraction: 1),
            settleTime: 0,
            minimumFreeSpace: 0
        )
        let engine = SyncEngine(account: account, mapping: mapping, client: client, store: store, fileSystem: fileSystem, rules: ExclusionRules(), configuration: config)
        await engine.start()
        await engine.syncAndWait()
        var status = await engine.currentStatus
        XCTAssertEqual(status.health, .synced, status.headline)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Vom Server/remote.txt"), encoding: .utf8), "remote")
        XCTAssertEqual(try String(contentsOf: serverRoot.appendingPathComponent("lokal.txt"), encoding: .utf8), "lokal")

        // Serveränderung + lokale Löschung
        let remoteUpdate = base.appendingPathComponent("remote-v2.txt")
        try Data("remote v2".utf8).write(to: remoteUpdate)
        let currentRemote = try await client.stat("Vom Server/remote.txt")
        let previousRemote = try XCTUnwrap(currentRemote)
        let updatedRemote = try await client.upload(
            file: remoteUpdate,
            to: "Vom Server/remote.txt",
            ifMatch: previousRemote.validator,
            ifNoneMatchAll: false,
            progress: nil
        )
        XCTAssertNotEqual(updatedRemote.etag, previousRemote.validator)
        try FileManager.default.removeItem(at: root.appendingPathComponent("lokal.txt"))
        try Data("neu".utf8).write(to: root.appendingPathComponent("neu.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: root.appendingPathComponent("neu.txt").path)
        await engine.syncAndWait()
        status = await engine.currentStatus
        let transfers = await engine.transfers()
        let queue = await engine.queue()
        let pendingDeletions = await engine.pendingDeletions()
        let diagnostics = [
            "issue=\(status.lastIssue?.message ?? "keine") [\(status.lastIssue?.detail ?? "keine Details")]",
            "pending=\(status.pendingCount), deletions=\(status.pendingDeletions)",
            "queue=\(queue.map(\.path))",
            "held=\(pendingDeletions.map(\.path))",
            "transfers=\(transfers.map { "\($0.path):\($0.state.rawValue):\($0.errorMessage ?? "-"):\($0.errorDetail ?? "-")" })",
        ].joined(separator: "; ")
        XCTAssertEqual(status.health, .synced, "\(status.headline): \(diagnostics)")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Vom Server/remote.txt"), encoding: .utf8), "remote v2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: serverRoot.appendingPathComponent("lokal.txt").path))
        XCTAssertEqual(try String(contentsOf: serverRoot.appendingPathComponent("neu.txt"), encoding: .utf8), "neu")
        await engine.shutdown()
    }
}

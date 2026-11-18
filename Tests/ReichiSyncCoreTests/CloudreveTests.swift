import XCTest
@testable import ReichiSyncCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Prüft den Cloudreve-API-Client, den Chunk-/Resume-Upload und die Engine-Integration
/// gegen die Cloudreve-Emulation des Python-Testservers (`--cloudreve`).
final class CloudreveTests: XCTestCase {
    private var server: DevServerLauncher!
    private var base: URL!
    private let chunkSize: Int64 = 64 * 1024

    override func setUpWithError() throws {
        server = try DevServerLauncher()
        try server.start(user: "anna@example.org", password: "dav-geheim", extraArguments: ["--cloudreve", "--chunk-size", String(chunkSize)])
        base = FileManager.default.temporaryDirectory.appendingPathComponent("reichi-cr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: - Hilfen

    private func signedInAPI() async throws -> CloudreveAPIClient {
        // Kurzer Timeout: Foundation unter Linux bemerkt serverseitig zurückgesetzte Verbindungen
        // bei Upload-Tasks erst über den Timeout; so bleiben die Abbruch-Tests schnell.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let api = try CloudreveAPIClient(siteURL: server.siteURL, allowInsecureHTTP: true, sessionConfiguration: configuration)
        let result = try await api.login(email: "anna@example.org", password: "dav-geheim")
        guard case .signedIn = result else { XCTFail("Anmeldung erwartet"); throw CloudreveError.authenticationRequired("Test") }
        return api
    }

    private func davClient() throws -> WebDAVClient {
        try WebDAVClient(baseURL: server.davURL, credentials: WebDAVCredentials(username: "anna@example.org", password: "dav-geheim"),
                         allowInsecureHTTP: true, serverKindHint: .cloudreve)
    }

    private func makeStore() throws -> SyncStore {
        try SyncStore(path: base.appendingPathComponent("db-\(UUID().uuidString).sqlite").path)
    }

    private func randomFile(name: String, size: Int) throws -> URL {
        let url = base.appendingPathComponent(name)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { buffer in
            for i in 0..<buffer.count { buffer[i] = UInt8((i * 31 + size) & 0xFF) }
        }
        try data.write(to: url)
        return url
    }

    private func requestInfo(for url: URL, path: String, replacing: String? = nil) throws -> UploadRequestInfo {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)!.int64Value
        let modified = (attrs[.modificationDate] as? Date)!.timeIntervalSince1970
        let hash = try SHA256Hasher.hashFile(at: url)
        return UploadRequestInfo(path: path, rawPath: path, fileURL: url, size: size, modified: modified, hash: hash, replacingValidator: replacing)
    }

    private func transport(api: CloudreveAPIClient, store: SyncStore, mappingID: String) throws -> CloudreveUploadTransport {
        CloudreveUploadTransport(api: api, dav: try davClient(), store: store, mappingID: mappingID, rootURI: "cloudreve://my/")
    }

    // MARK: - Erkennung & Anmeldung

    func testCapabilityDetectionRecognisesCloudreve() async throws {
        let caps = try await davClient().detectCapabilities()
        XCTAssertEqual(caps.serverKind, .cloudreve)
        XCTAssertEqual(caps.serverVersion, "4.1.0-dev")
        XCTAssertFalse(caps.honorsIfMatch)
        XCTAssertFalse(caps.supportsConditionalWrites, "Cloudreve wertet If-Match nicht aus → Engine muss PROPFIND-Vorprüfung nutzen")
    }

    func testGenericHintStillRecognisesCloudreveSafely() async throws {
        let client = try WebDAVClient(baseURL: server.davURL, credentials: WebDAVCredentials(username: "anna@example.org", password: "dav-geheim"),
                                      allowInsecureHTTP: true, serverKindHint: .generic)
        let caps = try await client.detectCapabilities()
        XCTAssertEqual(caps.serverKind, .cloudreve)
        XCTAssertFalse(caps.honorsIfMatch)
    }

    func testLoginRefreshAndDavAccounts() async throws {
        let changes = Recorder<CloudreveTokens?>()
        let api = try CloudreveAPIClient(siteURL: server.siteURL, allowInsecureHTTP: true, onTokensChanged: { tokens in
            changes.append(tokens)
        })
        let version = try await api.ping()
        XCTAssertEqual(version, "4.1.0-dev")
        XCTAssertFalse(api.isSignedIn)

        do {
            _ = try await api.login(email: "anna@example.org", password: "falsch")
            XCTFail("Falsches Passwort muss scheitern")
        } catch let error as CloudreveError {
            guard case .authenticationRequired = error else { return XCTFail("Unerwarteter Fehler \(error)") }
        }

        let result = try await api.login(email: "anna@example.org", password: "dav-geheim")
        guard case .signedIn(let tokens) = result else { return XCTFail("Anmeldung erwartet") }
        XCTAssertTrue(api.isSignedIn)
        XCTAssertTrue(tokens.accessToken.hasPrefix("acc-"))
        XCTAssertFalse(tokens.accessTokenNeedsRefresh)

        let accounts = try await api.listDavAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.uri, "cloudreve://my/")
        XCTAssertEqual(accounts.first?.password, "dav-geheim")
        XCTAssertFalse(accounts.first?.readonly ?? true)

        try await api.createFolder(uri: "cloudreve://my/Sync%20Ordner")
        try await api.createFolder(uri: "cloudreve://my/Sync%20Ordner") // bereits vorhanden → toleriert
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.serverRoot.appendingPathComponent("Sync Ordner").path))
        let created = try await api.createDavAccount(name: "reichi Sync", uri: "cloudreve://my/Sync%20Ordner")
        XCTAssertEqual(created.uri, "cloudreve://my/Sync%20Ordner")
        let allAccounts = try await api.listDavAccounts()
        XCTAssertEqual(allAccounts.count, 2)

        // Server verwirft Access-Token → Client erneuert per Refresh-Token und wiederholt.
        try await server.hook("expire-tokens", json: [:])
        let afterExpiry = try await api.listDavAccounts()
        XCTAssertEqual(afterExpiry.count, 2)
        let refreshed = try XCTUnwrap(api.currentTokens)
        XCTAssertNotEqual(refreshed.accessToken, tokens.accessToken)
        XCTAssertNotEqual(refreshed.refreshToken, tokens.refreshToken)
        XCTAssertEqual(changes.values.count, 2, "Login + Refresh müssen gemeldet werden")

        // Mehrere gleichzeitige 401-Antworten dürfen einen rotierenden
        // Refresh-Token nur genau einmal verwenden.
        try await server.hook("reset-log", json: [:])
        try await server.hook("expire-tokens", json: [:])
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { try await api.listDavAccounts().count }
            }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(counts, Array(repeating: 2, count: 8))
        let refreshRequests = (try await server.requestLog()).filter { $0 == "POST /api/v4/session/token/refresh" }
        XCTAssertEqual(refreshRequests.count, 1)

        try await api.deleteDavAccount(id: created.id)
        let remainingAccounts = try await api.listDavAccounts()
        XCTAssertEqual(remainingAccounts.map(\.id), [accounts[0].id])

        api.signOut()
        XCTAssertFalse(api.isSignedIn)
        do {
            _ = try await api.listDavAccounts()
            XCTFail("Ohne Anmeldung muss ein Fehler kommen")
        } catch let error as CloudreveError {
            guard case .authenticationRequired = error else { return XCTFail("Unerwarteter Fehler \(error)") }
        }
    }

    func testTransientRefreshFailureKeepsTokensForRetry() async throws {
        let loginAPI = try await signedInAPI()
        var tokens = try XCTUnwrap(loginAPI.currentTokens)
        tokens.accessExpires = Date().addingTimeInterval(-1)
        let changes = Recorder<CloudreveTokens?>()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        let api = try CloudreveAPIClient(
            siteURL: server.siteURL,
            tokens: tokens,
            allowInsecureHTTP: true,
            sessionConfiguration: configuration,
            onTokensChanged: { changes.append($0) }
        )

        server.stop()
        do {
            _ = try await api.listDavAccounts()
            XCTFail("Ohne Server muss die Token-Erneuerung scheitern")
        } catch let error as CloudreveError {
            guard case .network = error else { return XCTFail("Netzwerkfehler erwartet, nicht \(error)") }
        }

        XCTAssertEqual(api.currentTokens, tokens, "Ein vorübergehender Netzfehler darf die erneuerbare Sitzung nicht löschen")
        XCTAssertTrue(api.isSignedIn)
        XCTAssertTrue(changes.values.isEmpty)
    }

    func testSignOutDuringRefreshCannotRestoreTokens() async throws {
        let loginAPI = try await signedInAPI()
        var tokens = try XCTUnwrap(loginAPI.currentTokens)
        tokens.accessExpires = Date().addingTimeInterval(-1)
        let changes = Recorder<CloudreveTokens?>()
        let api = try CloudreveAPIClient(
            siteURL: server.siteURL,
            tokens: tokens,
            allowInsecureHTTP: true,
            onTokensChanged: { changes.append($0) }
        )
        try await server.hook("delay-refresh", json: ["seconds": 1.0])

        let request = Task { try await api.listDavAccounts() }
        var refreshStarted = false
        for _ in 0..<100 {
            if try await server.requestLog().contains("POST /api/v4/session/token/refresh") {
                refreshStarted = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(refreshStarted, "Der Test muss während eines laufenden Refreshs abmelden")

        api.signOut()
        do {
            _ = try await request.value
            XCTFail("Die Anfrage darf nach der Abmeldung nicht erfolgreich werden")
        } catch {
            // Abmeldung bricht die laufende Anfrage ab.
        }
        XCTAssertNil(api.currentTokens)
        XCTAssertFalse(api.isSignedIn)
        XCTAssertEqual(changes.values, [nil])
    }

    func testTwoFactorFlow() async throws {
        server.stop()
        server = try DevServerLauncher()
        try server.start(user: "anna@example.org", password: "dav-geheim", extraArguments: ["--cloudreve", "--twofa", "123456"])
        let api = try CloudreveAPIClient(siteURL: server.siteURL, allowInsecureHTTP: true)
        let result = try await api.login(email: "anna@example.org", password: "dav-geheim")
        guard case .twoFactorRequired(let sessionID) = result else { return XCTFail("2FA erwartet") }
        do {
            _ = try await api.verifyTwoFactor(sessionID: sessionID, otp: "000000")
            XCTFail("Falscher Code muss scheitern")
        } catch let error as CloudreveError {
            guard case .api(let code, _) = error, code == CloudreveError.Code.twoFactorCodeError else { return XCTFail("Unerwarteter Fehler \(error)") }
        }
        // Falscher Code hat die Sitzung in der Emulation nicht verbraucht.
        let second = try await api.login(email: "anna@example.org", password: "dav-geheim")
        guard case .twoFactorRequired(let sid) = second else { return XCTFail("2FA erwartet") }
        let tokens = try await api.verifyTwoFactor(sessionID: sid, otp: "123456")
        XCTAssertTrue(tokens.accessToken.hasPrefix("acc-"))
        XCTAssertTrue(api.isSignedIn)
    }

    // MARK: - Chunked Upload

    func testChunkedUploadEndToEnd() async throws {
        let api = try await signedInAPI()
        let store = try makeStore()
        let size = Int(chunkSize) * 2 + 1234 // 3 Chunks, letzter kürzer
        let file = try randomFile(name: "gross.bin", size: size)
        let info = try requestInfo(for: file, path: "Ordner/gross ä.bin")
        try await davClient().makeDirectory("Ordner")
        let transport = try transport(api: api, store: store, mappingID: "m1")

        let progress = Recorder<Int64>()
        let result = try await transport.upload(info) { done, _ in progress.append(done) }
        XCTAssertEqual(result.status, 201)
        XCTAssertNil(result.etag, "Ein nachträgliches PROPFIND darf nicht als kausaler Upload-Validator gelten")

        let remote = server.serverRoot.appendingPathComponent("Ordner/gross ä.bin")
        XCTAssertEqual(try Data(contentsOf: remote), try Data(contentsOf: file))
        let stat = try await davClient().stat("Ordner/gross ä.bin")
        XCTAssertEqual(stat?.size, Int64(size))
        let etag = try XCTUnwrap(stat?.validator)
        XCTAssertEqual(progress.values.last, Int64(size))
        let remaining = try await store.uploadState(path: "Ordner/gross ä.bin", mappingID: "m1")
        XCTAssertNil(remaining, "Status muss nach Abschluss entfernt sein")

        let log = try await server.requestLog()
        XCTAssertEqual(log.filter { $0.hasPrefix("POST /api/v4/file/upload/") }.count, 3)

        // Überschreiben: previous = Entity-ID (ETag ohne Anführungszeichen) → neue Version.
        let file2 = try randomFile(name: "gross2.bin", size: size + 7)
        let info2 = try requestInfo(for: file2, path: "Ordner/gross ä.bin", replacing: etag)
        let result2 = try await transport.upload(info2, progress: nil)
        XCTAssertNil(result2.etag)
        let secondStat = try await davClient().stat("Ordner/gross ä.bin")
        let secondETag = try XCTUnwrap(secondStat?.validator)
        XCTAssertNotEqual(secondETag, etag)
        XCTAssertEqual(try Data(contentsOf: remote), try Data(contentsOf: file2))

        // Veralteter Validator → Versionskonflikt (wie 412 beim WebDAV-PUT).
        do {
            _ = try await transport.upload(info2, progress: nil)
            XCTFail("Veraltete Version muss abgewiesen werden")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .preconditionFailed)
        }
    }

    func testUnchunkedCloudreveSessionStreamsWholeFile() async throws {
        server.stop()
        server = try DevServerLauncher()
        try server.start(
            user: "anna@example.org",
            password: "dav-geheim",
            extraArguments: ["--cloudreve", "--chunk-size", "0"]
        )
        let api = try await signedInAPI()
        let store = try makeStore()
        let file = try randomFile(name: "ungeteilt.bin", size: 200_123)
        let info = try requestInfo(for: file, path: "ungeteilt.bin")
        let transport = try transport(api: api, store: store, mappingID: "m1")

        _ = try await transport.upload(info, progress: nil)

        XCTAssertEqual(
            try Data(contentsOf: server.serverRoot.appendingPathComponent("ungeteilt.bin")),
            try Data(contentsOf: file)
        )
        let log = try await server.requestLog()
        XCTAssertEqual(log.filter { $0.hasPrefix("POST /api/v4/file/upload/") }.count, 1)
    }

    func testOverwriteRequiresCloudreveEntityIDInsteadOfSyntheticValidator() async throws {
        let api = try await signedInAPI()
        let store = try makeStore()
        let file = try randomFile(name: "synthetic.bin", size: 1024)
        let info = try requestInfo(
            for: file,
            path: "synthetic.bin",
            replacing: "mtime:1700000000;size:1024"
        )
        let transport = try transport(api: api, store: store, mappingID: "m1")
        try await server.hook("reset-log", json: [:])

        do {
            _ = try await transport.upload(info, progress: nil)
            XCTFail("Ein Ersatzvalidator darf nicht als Cloudreve-Entity-ID verwendet werden")
        } catch let error as CloudreveError {
            guard case .unsupportedStoragePolicy = error else { return XCTFail("Unerwarteter Fehler: \(error)") }
        }
        let log = try await server.requestLog()
        XCTAssertFalse(log.contains("PUT /api/v4/file/upload"))
    }

    func testInterruptedUploadResumesWithoutResendingChunks() async throws {
        let api = try await signedInAPI()
        let store = try makeStore()
        let size = Int(chunkSize) * 4
        let file = try randomFile(name: "resume.bin", size: size)
        let info = try requestInfo(for: file, path: "resume.bin")
        let transport = try transport(api: api, store: store, mappingID: "m1")

        try await server.hook("fail-chunks", json: ["indexes": [2]])
        do {
            _ = try await transport.upload(info, progress: nil)
            XCTFail("Abbruch erwartet")
        } catch let error as WebDAVError {
            guard case .network = error else { return XCTFail("Netzwerkfehler erwartet, nicht \(error)") }
        }
        let savedState = try await store.uploadState(path: "resume.bin", mappingID: "m1")
        let saved = try XCTUnwrap(savedState)
        XCTAssertEqual(saved.uploadedChunks, 2)
        XCTAssertEqual(saved.totalChunks, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.serverRoot.appendingPathComponent("resume.bin").path))

        try await server.hook("reset-log", json: [:])
        let result = try await transport.upload(info, progress: nil)
        XCTAssertEqual(result.status, 201)
        let log = try await server.requestLog()
        let chunkPosts = log.filter { $0.hasPrefix("POST /api/v4/file/upload/") }
        XCTAssertEqual(chunkPosts.count, 2, "Nur Chunks 2 und 3 dürfen erneut gesendet werden: \(chunkPosts)")
        XCTAssertTrue(chunkPosts.allSatisfy { $0.hasSuffix("/2") || $0.hasSuffix("/3") })
        XCTAssertFalse(log.contains("PUT /api/v4/file/upload"), "Keine neue Sitzung")
        XCTAssertEqual(try Data(contentsOf: server.serverRoot.appendingPathComponent("resume.bin")), try Data(contentsOf: file))
        let afterResume = try await store.uploadState(path: "resume.bin", mappingID: "m1")
        XCTAssertNil(afterResume)
    }

    func testLostFinalChunkResponseIsRecognisedWithoutRestartingSession() async throws {
        let api = try await signedInAPI()
        let store = try makeStore()
        let size = Int(chunkSize) * 3
        let file = try randomFile(name: "committed.bin", size: size)
        let info = try requestInfo(for: file, path: "committed.bin")
        let transport = try transport(api: api, store: store, mappingID: "m1")

        try await server.hook("drop-after-commit", json: ["indexes": [2]])
        do {
            _ = try await transport.upload(info, progress: nil)
            XCTFail("Verlorene Abschlussantwort muss zunächst als Netzwerkfehler erscheinen")
        } catch let error as WebDAVError {
            guard case .network = error else { return XCTFail("Netzwerkfehler erwartet, nicht \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: server.serverRoot.appendingPathComponent("committed.bin")), try Data(contentsOf: file))
        let pending = try await store.uploadState(path: "committed.bin", mappingID: "m1")
        XCTAssertEqual(pending?.uploadedChunks, 2)

        try await server.hook("reset-log", json: [:])
        let result = try await transport.upload(info, progress: nil)
        XCTAssertEqual(result.status, 201)
        let log = try await server.requestLog()
        XCTAssertFalse(log.contains("PUT /api/v4/file/upload"), "Eine bereits vollständig gespeicherte Datei darf keine neue Sitzung erzeugen")
        XCTAssertFalse(log.contains { $0.hasPrefix("POST /api/v4/file/upload/") })
        let remaining = try await store.uploadState(path: "committed.bin", mappingID: "m1")
        XCTAssertNil(remaining)
    }

    func testExpiredSessionRestartsUpload() async throws {
        let api = try await signedInAPI()
        let store = try makeStore()
        let size = Int(chunkSize) * 3
        let file = try randomFile(name: "expired.bin", size: size)
        let info = try requestInfo(for: file, path: "expired.bin")
        let transport = try transport(api: api, store: store, mappingID: "m1")

        try await server.hook("fail-chunks", json: ["indexes": [1]])
        _ = try? await transport.upload(info, progress: nil)
        let partial = try await store.uploadState(path: "expired.bin", mappingID: "m1")
        XCTAssertEqual(partial?.uploadedChunks, 1)

        // Server kennt die Sitzung nicht mehr → 40011 → Neustart mit frischer Sitzung.
        try await server.hook("expire-sessions", json: [:])
        try await server.hook("reset-log", json: [:])
        let result = try await transport.upload(info, progress: nil)
        XCTAssertEqual(result.status, 201)
        let log = try await server.requestLog()
        XCTAssertEqual(log.filter { $0 == "PUT /api/v4/file/upload" }.count, 1)
        XCTAssertEqual(log.filter { $0.hasPrefix("POST /api/v4/file/upload/") }.count, 4, "1 abgelehnter + 3 neue Chunks")
        XCTAssertEqual(try Data(contentsOf: server.serverRoot.appendingPathComponent("expired.bin")), try Data(contentsOf: file))
    }

    func testLocalChangeDuringUploadAbortsSession() async throws {
        let api = try await signedInAPI()
        let store = try makeStore()
        let size = Int(chunkSize) * 3
        let file = try randomFile(name: "changing.bin", size: size)
        let info = try requestInfo(for: file, path: "changing.bin")
        let transport = try transport(api: api, store: store, mappingID: "m1")

        try await server.hook("fail-chunks", json: ["indexes": [1]])
        _ = try? await transport.upload(info, progress: nil)
        let pending = try await store.uploadState(path: "changing.bin", mappingID: "m1")
        XCTAssertNotNil(pending)

        // Datei lokal verändern (gleiche Größe, andere mtime).
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        do {
            _ = try await transport.upload(info, progress: nil)
            XCTFail("Änderung muss erkannt werden")
        } catch LocalFileError.changedSinceScan {
            // erwartet
        }
        let afterChange = try await store.uploadState(path: "changing.bin", mappingID: "m1")
        XCTAssertNil(afterChange)
        let sessions = try await server.hook("sessions")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: sessions) as? [Any])?.count, 0, "Sitzung muss serverseitig gelöscht sein")
    }

    // MARK: - Engine-Integration

    func testEngineUsesChunkTransportAboveThreshold() async throws {
        let api = try await signedInAPI()
        let root = base.appendingPathComponent("Sync")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bigSize = Int(chunkSize) * 2 + 10
        _ = try randomFile(name: "Sync/gross.bin", size: bigSize)
        try Data("klein".utf8).write(to: root.appendingPathComponent("klein.txt"))
        for name in ["gross.bin", "klein.txt"] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: root.appendingPathComponent(name).path)
        }

        let store = try makeStore()
        let account = AccountConfiguration(name: "Cloudreve", serverURL: server.davURL, username: "anna@example.org", localRootPath: root.path,
                                           allowInsecureHTTP: true, serverKind: .cloudreve, cloudreveSiteURL: server.siteURL,
                                           cloudreveEmail: "anna@example.org", davAccountURI: "cloudreve://my/", chunkedUploadThreshold: chunkSize)
        let mapping = try await store.mapping(for: account)
        let client = try davClient()
        let transport = CloudreveUploadTransport(api: api, dav: client, store: store, mappingID: mapping.id, rootURI: account.davAccountURI ?? "cloudreve://my/")
        let config = SyncEngineConfiguration(deviceName: "Mac", recoveryDirectory: base.appendingPathComponent("Recovery"), settleTime: 0,
                                             minimumFreeSpace: 0, chunkedUploadThreshold: account.chunkedUploadThreshold)
        let engine = SyncEngine(account: account, mapping: mapping, client: client, store: store, fileSystem: LocalFileSystem(root: root),
                                rules: ExclusionRules(), configuration: config, uploadTransport: transport)
        await engine.start()
        await engine.syncAndWait()
        let status = await engine.currentStatus
        XCTAssertEqual(status.health, .synced, status.headline)
        XCTAssertEqual(try Data(contentsOf: server.serverRoot.appendingPathComponent("gross.bin")), try Data(contentsOf: root.appendingPathComponent("gross.bin")))
        XCTAssertEqual(try String(contentsOf: server.serverRoot.appendingPathComponent("klein.txt"), encoding: .utf8), "klein")

        let log = try await server.requestLog()
        XCTAssertEqual(log.filter { $0 == "PUT /api/v4/file/upload" }.count, 2,
                       "Cloudreve-Uploads nutzen den versionierten API-Pfad, da WebDAV If-Match ignoriert")
        XCTAssertEqual(log.filter { $0.hasPrefix("POST /api/v4/file/upload/") }.count, 4)

        // Baseline muss den Server-ETag der großen Datei kennen (sonst würde sie erneut übertragen).
        let remoteStat = try await client.stat("gross.bin")
        let baseline = try await store.baseline(mappingID: mapping.id)
        XCTAssertEqual(baseline["gross.bin"]?.remoteValidator, remoteStat?.validator)

        // Zweiter Durchlauf: nichts zu tun.
        try await server.hook("reset-log", json: [:])
        await engine.syncAndWait()
        let secondLog = try await server.requestLog()
        XCTAssertTrue(secondLog.filter { $0.contains("/file/upload") }.isEmpty)
        await engine.shutdown()
    }

    // MARK: - Freigaben

    func testShareLifecycle() async throws {
        let api = try await signedInAPI()
        try Data("x".utf8).write(to: server.serverRoot.appendingPathComponent("Bericht.pdf"))
        try FileManager.default.createDirectory(at: server.serverRoot.appendingPathComponent("Fotos"), withIntermediateDirectories: true)

        let publicURL = try await api.createShare(uri: try CloudreveURI.fileURI(root: "cloudreve://my/", relativePath: "Bericht.pdf"), options: .init())
        XCTAssertTrue(publicURL.absoluteString.contains("/s/"))
        let privateURL = try await api.createShare(uri: "cloudreve://my/Fotos",
                                                   options: .init(isPrivate: true, password: "abc123", expiresIn: 3600, downloadLimit: 5, shareView: true))
        XCTAssertTrue(privateURL.absoluteString.hasSuffix("/abc123"))

        let shares = try await api.listShares()
        XCTAssertEqual(shares.count, 2)
        let folder = try XCTUnwrap(shares.first { $0.name == "Fotos" })
        XCTAssertTrue(folder.isFolder)
        XCTAssertTrue(folder.isPrivate)
        XCTAssertEqual(folder.password, "abc123")
        XCTAssertEqual(folder.remainDownloads, 5)
        XCTAssertNotNil(folder.expires)
        XCTAssertEqual(folder.urlWithPassword.absoluteString, privateURL.absoluteString)
        let file = try XCTUnwrap(shares.first { $0.name == "Bericht.pdf" })
        XCTAssertFalse(file.isPrivate)
        XCTAssertEqual(file.urlWithPassword, file.url)

        // Lokaler Cache im Store
        let store = try makeStore()
        try await store.replaceShares(shares, accountID: "acc")
        let cached = try await store.shares(accountID: "acc")
        XCTAssertEqual(cached.count, 2)
        XCTAssertNil(cached.first { $0.id == folder.id }?.password, "Freigabe-Passwörter dürfen nicht in SQLite zwischengespeichert werden")
        let unusualPrivate = CloudreveShare(
            id: "andere-id",
            name: "Privat",
            url: URL(string: "https://example.org/custom/secret-passwort/weiter")!,
            isPrivate: true,
            password: "secret-passwort"
        )
        try await store.saveShare(unusualPrivate, accountID: "acc")
        let cachedWithUnusual = try await store.shares(accountID: "acc")
        let scrubbed = try XCTUnwrap(cachedWithUnusual.first { $0.id == unusualPrivate.id })
        XCTAssertFalse(scrubbed.url.absoluteString.contains("secret-passwort"))
        try await store.deleteShare(id: unusualPrivate.id)

        try await api.deleteShare(id: folder.id)
        let remainingShares = try await api.listShares()
        XCTAssertEqual(remainingShares.count, 1)
        try await store.deleteShare(id: folder.id)
        let cachedAfter = try await store.shares(accountID: "acc")
        XCTAssertEqual(cachedAfter.count, 1)

        do {
            _ = try await api.createShare(uri: "cloudreve://my/fehlt.txt", options: .init())
            XCTFail("Fehlende Datei muss scheitern")
        } catch let error as CloudreveError {
            guard case .api(let code, _) = error, code == CloudreveError.Code.fileNotFound else { return XCTFail("Unerwartet: \(error)") }
        }
    }

    // MARK: - URIs & Persistenz

    func testCloudreveURIEncoding() throws {
        XCTAssertEqual(try CloudreveURI.fileURI(root: "cloudreve://my/", relativePath: "Ordner ä/Datei+1 #2.txt"), "cloudreve://my/Ordner%20%C3%A4/Datei%2B1%20%232.txt")
        XCTAssertEqual(try CloudreveURI.fileURI(root: "cloudreve://my/Sync", relativePath: ""), "cloudreve://my/Sync")
        XCTAssertEqual(try CloudreveURI.fileURI(root: "cloudreve://my", relativePath: ""), "cloudreve://my/")
        XCTAssertEqual(CloudreveURI.rootURI(folderPath: "/Sync/Projekte A/"), "cloudreve://my/Sync/Projekte%20A")
        XCTAssertEqual(CloudreveURI.rootURI(folderPath: ""), "cloudreve://my/")
        XCTAssertEqual(CloudreveURI.folderPath(from: "cloudreve://my/Sync/Projekte%20A"), "/Sync/Projekte A")
        XCTAssertEqual(CloudreveURI.folderPath(from: "cloudreve://my/"), "/")
        XCTAssertThrowsError(try CloudreveURI.fileURI(root: "cloudreve://my/", relativePath: "../ausbruch"))
        XCTAssertThrowsError(try CloudreveURI.fileURI(root: "cloudreve://other/Sync", relativePath: "datei"))
        XCTAssertThrowsError(try CloudreveURI.fileURI(root: "cloudreve://my/../fremd", relativePath: "datei"))
        XCTAssertThrowsError(try CloudreveURI.validatedRootURI(folderPath: "/Sync/../fremd"))
        XCTAssertThrowsError(try CloudreveURI.validatedRootURI(folderPath: "/Sync//fremd"))
        XCTAssertNil(CloudreveAPIClient.parseShare(["id": "s", "url": "javascript:alert(1)"]))
        XCTAssertNil(CloudreveAPIClient.parseShare(["id": "s", "url": "https://user:pass@example.org/s/s"]))
    }

    func testUploadStatePersistence() async throws {
        let store = try makeStore()
        let session = CloudreveUploadSession(sessionID: "s1", chunkSize: 1024, expires: Date().addingTimeInterval(3600),
                                             uploadURLs: ["https://storage.example/signed"], credential: "secret-credential",
                                             policy: CloudreveStoragePolicy(id: "p", name: "local", type: "local", relay: false, chunkConcurrency: 1, maxSize: 0),
                                             uri: "cloudreve://my/a.bin")
        let info = UploadRequestInfo(path: "a.bin", rawPath: "a.bin", fileURL: URL(fileURLWithPath: "/tmp/a.bin"), size: 2500, modified: 1_700_000_000, hash: "h", replacingValidator: "\"entity-a\"")
        var state = ResumableUploadState(path: "a.bin", uri: "cloudreve://my/a.bin", session: session, info: info)
        XCTAssertTrue(state.uploadURLs.isEmpty)
        XCTAssertNil(state.credential)
        XCTAssertEqual(state.totalChunks, 3)
        state.uploadedChunks = 2
        state.uploadURLs = ["https://storage.example/signed?token=secret"]
        state.credential = "secret-credential"
        try await store.saveUploadState(state, mappingID: "m")
        let loadedState = try await store.uploadState(path: "a.bin", mappingID: "m")
        let loaded = try XCTUnwrap(loadedState)
        XCTAssertEqual(loaded.uploadedChunks, state.uploadedChunks)
        XCTAssertTrue(loaded.uploadURLs.isEmpty)
        XCTAssertNil(loaded.credential)
        XCTAssertEqual(loaded.replacingValidator, "\"entity-a\"")
        XCTAssertTrue(loaded.matches(info, uri: "cloudreve://my/a.bin"))
        var other = info
        other.modified += 1
        XCTAssertFalse(loaded.matches(other, uri: "cloudreve://my/a.bin"))
        other = info
        other.replacingValidator = "\"entity-b\""
        XCTAssertFalse(loaded.matches(other, uri: "cloudreve://my/a.bin"), "Eine Sitzung darf nicht gegen eine andere Serverversion fortgesetzt werden")
        var malformed = loaded
        malformed.uploadedChunks = -1
        XCTAssertFalse(malformed.matches(info, uri: "cloudreve://my/a.bin"))
        malformed = loaded
        malformed.chunkSize = ResumableUploadState.maximumChunkSize + 1
        XCTAssertFalse(malformed.matches(info, uri: "cloudreve://my/a.bin"))
        XCTAssertFalse(loaded.matches(info, uri: "cloudreve://my/b.bin"))
        XCTAssertFalse(loaded.matches(info, uri: "cloudreve://my/a.bin", now: Date().addingTimeInterval(3500)), "Kurz vor Ablauf nicht fortsetzen")
        let all = try await store.uploadStates(mappingID: "m")
        XCTAssertEqual(all.count, 1)
        try await store.removeUploadState(path: "a.bin", mappingID: "m")
        let removed = try await store.uploadState(path: "a.bin", mappingID: "m")
        XCTAssertNil(removed)
    }

    func testAccountConfigurationDefaultsAndDecoding() throws {
        XCTAssertEqual(AccountConfiguration.defaultSiteURL.absoluteString, "https://reichi.cloud")
        let legacy = """
        {"id":"a","name":"Alt","serverURL":"https://example.org/dav/","username":"u","localRootPath":"/x","pollInterval":60,"exclusionPatterns":[],
         "allowInsecureHTTP":false,"deletionGuardThreshold":25,"deletionGuardFraction":0.2,"maxConcurrentTransfers":3,"notificationsEnabled":true,
         "createdAt":0}
        """
        let decoded = try JSONDecoder().decode(AccountConfiguration.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.serverKind, .webdav)
        XCTAssertFalse(decoded.isCloudreve)
        XCTAssertTrue(decoded.chunkedUploadsEnabled)
        XCTAssertEqual(decoded.chunkedUploadThreshold, AccountConfiguration.defaultChunkedUploadThreshold)

        let cloudreve = AccountConfiguration(name: "C", serverURL: URL(string: "https://reichi.cloud/dav/")!, username: "a@b.de", localRootPath: "/y",
                                             serverKind: .cloudreve, cloudreveSiteURL: AccountConfiguration.defaultSiteURL, cloudreveEmail: "a@b.de",
                                             davAccountID: "1", davAccountURI: "cloudreve://my/Sync")
        let roundTrip = try JSONDecoder().decode(AccountConfiguration.self, from: JSONEncoder().encode(cloudreve))
        XCTAssertTrue(roundTrip.isCloudreve)
        XCTAssertEqual(roundTrip.davAccountURI, "cloudreve://my/Sync")
    }
}

/// Thread-sicherer Sammler für Callback-Werte in Tests.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private var storage: [T] = []
    private let lock = NSLock()
    func append(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

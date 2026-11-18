import XCTest
@testable import ReichiSyncCore

final class SHA256Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(SHA256Hasher.hash(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Hasher.hash(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Hasher.hash(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256Hasher.hash(Data(repeating: 0x61, count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testIncrementalMatchesOneShot() {
        var hasher = SHA256Hasher()
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        var offset = 0
        for chunk in [1, 63, 64, 65, 1000, 7777, 1030] where offset + chunk <= data.count {
            hasher.update(data[offset..<offset + chunk])
            offset += chunk
        }
        hasher.update(data[offset...])
        XCTAssertEqual(hasher.finalizeHex(), SHA256Hasher.hash(data))
    }

    func testFileHashing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try SHA256Hasher.hashFile(at: url, bufferSize: 2), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class PathSafetyTests: XCTestCase {
    func testNormalizationAndSegments() throws {
        XCTAssertEqual(try RelativePath.normalize("/a/b/"), "a/b")
        XCTAssertEqual(try RelativePath.normalize("a/b"), "a/b")
        // NFD → NFC
        let nfd = "u\u{0308}ber.txt"
        XCTAssertEqual(try RelativePath.normalize(nfd), "über.txt")
        XCTAssertThrowsError(try RelativePath.normalize("a/../b"))
        XCTAssertThrowsError(try RelativePath.normalize("a//b"))
        XCTAssertThrowsError(try RelativePath.normalize("./a"))
    }

    func testLocalURLStaysInsideRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/sync-root")
        let ok = try RelativePath.localURL(root: root, relativePath: "Ordner/Datei mit Leerzeichen 😀.txt")
        XCTAssertTrue(ok.path.hasPrefix("/tmp/sync-root/"))
        XCTAssertThrowsError(try RelativePath.localURL(root: root, relativePath: "../außerhalb.txt"))
        XCTAssertThrowsError(try RelativePath.localURL(root: root, relativePath: "a/../../b"))
    }

    func testHelpers() {
        XCTAssertEqual(RelativePath.parent(of: "a/b/c"), "a/b")
        XCTAssertEqual(RelativePath.parent(of: "a"), "")
        XCTAssertNil(RelativePath.parent(of: ""))
        XCTAssertEqual(RelativePath.name(of: "a/b/c.txt"), "c.txt")
        XCTAssertEqual(RelativePath.ancestors(of: "a/b/c"), ["a", "a/b"])
        XCTAssertTrue(RelativePath.isDescendant("a/b", of: "a"))
        XCTAssertFalse(RelativePath.isDescendant("ab", of: "a"))
        XCTAssertTrue(RelativePath.isDescendant("x", of: ""))
    }

    func testConflictCopyName() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = RelativePath.conflictCopyName(for: "Bericht.final.pdf", deviceName: "Annas MacBook", date: date)
        XCTAssertTrue(name.hasPrefix("Bericht.final (Konfliktkopie von Annas MacBook "), name)
        XCTAssertTrue(name.hasSuffix(").pdf"), name)
        let noExt = RelativePath.conflictCopyName(for: "Notizen", deviceName: "Mac/Pro:1", date: date)
        XCTAssertTrue(noExt.hasPrefix("Notizen (Konfliktkopie von Mac-Pro-1 "), noExt)
        XCTAssertFalse(noExt.contains("/"))

        let long = RelativePath.conflictCopyName(
            for: String(repeating: "ä", count: 120) + "." + String(repeating: "x", count: 80),
            deviceName: String(repeating: "Mac😀", count: 30),
            date: date
        )
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertTrue(long.contains("Konfliktkopie"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(long))
        let unique = try LocalFileSystem(root: root).uniqueRelativePath(long)
        XCTAssertNotEqual(unique, long)
        XCTAssertLessThanOrEqual(RelativePath.name(of: unique).utf8.count, 255)
    }

    func testLocalFileSystemRejectsSymlinkAncestor() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        let fileSystem = LocalFileSystem(root: root)
        XCTAssertThrowsError(try fileSystem.createDirectory("link/server-ordner")) { error in
            guard case LocalFileError.symbolicLink = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("server-ordner").path))
    }

    func testLocalFileSystemRejectsReplacedRootDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        let original = base.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let expectedRootID = try XCTUnwrap(POSIXFileMetadata.read(atPath: root.path)?.fileID)
        let fileSystem = LocalFileSystem(root: root)
        try FileManager.default.moveItem(at: root, to: original)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertFalse(fileSystem.rootExists())
        XCTAssertFalse(
            LocalFileSystem(root: root, expectedRootFileID: expectedRootID).rootExists(),
            "Auch eine neu erzeugte Engine muss die persistierte Ordneridentität prüfen"
        )
        XCTAssertThrowsError(try fileSystem.url("nicht-hier.txt")) { error in
            XCTAssertEqual(error as? LocalFileError, .rootMissing)
        }
    }

    func testLocalFileSystemPinsRootAfterTransientlyMissingDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        let original = base.appendingPathComponent("original")
        defer { try? FileManager.default.removeItem(at: base) }

        let fileSystem = LocalFileSystem(root: root)
        XCTAssertFalse(fileSystem.rootExists())

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(fileSystem.rootExists(), "Die erste lesbare Wurzelidentität muss nachträglich gebunden werden")

        try FileManager.default.moveItem(at: root, to: original)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertFalse(fileSystem.rootExists(), "Nach der Bindung darf ein Ersatzordner nicht akzeptiert werden")
    }

    func testMappingKeyChangesWhenRootDirectoryIsReplaced() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        let oldRoot = base.appendingPathComponent("old-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = AccountConfiguration(
            name: "Test",
            serverURL: URL(string: "https://example.org/dav/")!,
            username: "anna",
            localRootPath: root.path
        )

        try FileManager.default.moveItem(at: root, to: oldRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let replacement = AccountConfiguration(
            id: first.id,
            name: first.name,
            serverURL: first.serverURL,
            username: first.username,
            localRootPath: root.path
        )

        XCTAssertNotEqual(first.localRootIdentity, replacement.localRootIdentity)
        XCTAssertNotEqual(first.mappingKey, replacement.mappingKey)
        XCTAssertFalse(first.matchesLocalRootIdentity(atPath: root.path))
        XCTAssertTrue(replacement.matchesLocalRootIdentity(atPath: root.path))
    }

    func testRemoveDirectoryIfEmptyNeverRemovesChildren() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("d/neu.txt")
        try Data("neu".utf8).write(to: child)
        let fileSystem = LocalFileSystem(root: root)

        XCTAssertFalse(try fileSystem.removeDirectoryIfEmpty("d", rules: ExclusionRules()))
        XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), "neu")
        try FileManager.default.removeItem(at: child)
        XCTAssertTrue(try fileSystem.removeDirectoryIfEmpty("d", rules: ExclusionRules()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("d").path))
    }

    func testVerifiedTrashRestoresUnexpectedFileVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("wichtig.txt")
        try Data("neu".utf8).write(to: file)
        let fileSystem = LocalFileSystem(root: root)

        XCTAssertThrowsError(
            try fileSystem.trashVerifiedFile(
                "wichtig.txt",
                expectedHash: SHA256Hasher.hash(Data("alt".utf8)),
                recoveryDirectory: nil
            )
        ) { error in
            XCTAssertEqual(error as? LocalFileError, .changedSinceScan("wichtig.txt"))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "neu")
    }

    func testScannerInvalidatesHashCacheWhenSizeAndMtimeArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("gleich.txt")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("AAAA".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        let scanner = LocalScanner(fileSystem: LocalFileSystem(root: root), rules: ExclusionRules(), settleTime: 0)
        let first = try scanner.scan(previousIndex: [:])
        Thread.sleep(forTimeInterval: 0.01)
        try Data("BBBB".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let second = try scanner.scan(previousIndex: first.hashIndex)

        XCTAssertNotEqual(first.snapshot.items["gleich.txt"]?.hash, second.snapshot.items["gleich.txt"]?.hash)
        XCTAssertEqual(second.snapshot.items["gleich.txt"]?.hash, SHA256Hasher.hash(Data("BBBB".utf8)))
    }

    func testScannerFreezesCanonicallyEquivalentNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nfc = "über.txt"
        let nfd = "u\u{308}ber.txt"
        try Data("nfc".utf8).write(to: root.appendingPathComponent(nfc))
        try Data("nfd".utf8).write(to: root.appendingPathComponent(nfd))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard Set(names.map { Data($0.utf8) }).count == 2 else {
            throw XCTSkip("Das Dateisystem unterscheidet NFC und NFD nicht")
        }

        let scanner = LocalScanner(fileSystem: LocalFileSystem(root: root), rules: ExclusionRules(), settleTime: 0)
        let result = try scanner.scan(previousIndex: [:])

        XCTAssertEqual(result.collisions, [nfc])
        XCTAssertNil(result.snapshot.items[nfc])
        XCTAssertNotNil(result.snapshot.skippedPaths[nfc])
    }

    func testRemoteEnumeratorRejectsCanonicallyEquivalentServerNames() async throws {
        let server = FakeWebDAVServer()
        let nfc = "über.txt"
        let nfd = "u\u{308}ber.txt"
        await server.setAdditionalListItems([
            RemoteItem(path: nfc, rawPath: nfc, kind: .file, size: 1, validator: "\"a\"", validatorIsStrong: true),
            RemoteItem(path: nfd, rawPath: nfd, kind: .file, size: 1, validator: "\"b\"", validatorIsStrong: true),
        ])

        let snapshot = try await RemoteEnumerator(client: server, rules: ExclusionRules()).fullWalk()

        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(snapshot.collisions, [nfc])
        XCTAssertNil(snapshot.items[nfc])
        XCTAssertTrue(snapshot.failedPrefixes.contains(""))
    }
}

final class ExclusionRulesTests: XCTestCase {
    func testDefaults() {
        let rules = ExclusionRules()
        XCTAssertTrue(rules.isExcluded(relativePath: ".DS_Store"))
        XCTAssertTrue(rules.isExcluded(relativePath: "Ordner/.DS_Store"))
        XCTAssertTrue(rules.isExcluded(relativePath: "Ordner/._Datei.txt"))
        XCTAssertTrue(rules.isExcluded(relativePath: "~$Dokument.docx"))
        XCTAssertTrue(rules.isExcluded(relativePath: ".reichi-sync-tmp/x.part"))
        XCTAssertTrue(rules.isExcluded(relativePath: "a/.reichi-sync-abc.part"))
        XCTAssertFalse(rules.isExcluded(relativePath: "Dokument.docx"))
        XCTAssertFalse(rules.isExcluded(relativePath: "DS_Store.txt"))
    }

    func testUserPatterns() {
        let rules = ExclusionRules(userPatterns: ["*.tmp", "/Archiv", "node_modules", "**/*.log"])
        XCTAssertTrue(rules.isExcluded(relativePath: "a/b/test.tmp"))
        XCTAssertTrue(rules.isExcluded(relativePath: "Archiv/alt.txt"))
        XCTAssertFalse(rules.isExcluded(relativePath: "Projekt/Archiv/alt.txt"))
        XCTAssertTrue(rules.isExcluded(relativePath: "web/node_modules/x/y.js"))
        XCTAssertTrue(rules.isExcluded(relativePath: "logs/deep/er/app.log"))
        XCTAssertFalse(rules.isExcluded(relativePath: "logs/app.log.txt"))
    }

    func testGlob() {
        XCTAssertTrue(ExclusionRules.match(pattern: "*.txt", text: "a.txt"))
        XCTAssertFalse(ExclusionRules.match(pattern: "*.txt", text: "dir/a.txt"))
        XCTAssertTrue(ExclusionRules.match(pattern: "**/a.txt", text: "x/y/a.txt"))
        XCTAssertTrue(ExclusionRules.match(pattern: "a?c", text: "abc"))
        XCTAssertFalse(ExclusionRules.match(pattern: "a?c", text: "abbc"))
        XCTAssertTrue(ExclusionRules.match(pattern: "Foto.JPG", text: "foto.jpg"))
    }
}

final class LoggerRedactionTests: XCTestCase {
    func testRedaction() {
        let logger = SyncLogger()
        logger.registerSecret("geheim123")
        XCTAssertEqual(logger.redact("Passwort geheim123 gesendet"), "Passwort ••• gesendet")
        logger.registerSecret("xy")
        XCTAssertEqual(logger.redact("Token xy"), "Token •••")
        XCTAssertEqual(logger.redact("Authorization: Basic dXNlcjpwYXNz"), "Authorization: Basic •••")
        XCTAssertEqual(logger.redact("https://anna:pw@example.org/dav"), "https://•••@example.org/dav")
    }
}

final class RetryAndGuardTests: XCTestCase {
    func testBackoffGrowsAndCaps() {
        var policy = RetryPolicy(baseDelay: 5, maxDelay: 300)
        let d1 = policy.recordFailure()
        let d2 = policy.recordFailure()
        let d3 = policy.recordFailure()
        XCTAssertTrue(d1 < d2 && d2 < d3)
        for _ in 0..<20 { _ = policy.recordFailure() }
        XCTAssertLessThanOrEqual(policy.recordFailure(), 330)
        policy.reset()
        XCTAssertEqual(policy.failureCount, 0)
    }

    func testDeletionGuard() {
        let guardRule = DeletionGuard(threshold: 25, fraction: 0.2)
        XCTAssertFalse(guardRule.requiresConfirmation(deletionImpact: 0, baselineCount: 100, localItemCount: 100))
        XCTAssertFalse(guardRule.requiresConfirmation(deletionImpact: 3, baselineCount: 100, localItemCount: 97))
        XCTAssertTrue(guardRule.requiresConfirmation(deletionImpact: 30, baselineCount: 100, localItemCount: 70))
        XCTAssertTrue(guardRule.requiresConfirmation(deletionImpact: 30, baselineCount: 1000, localItemCount: 970),
                      "Die absolute Schwelle gilt unabhängig vom Anteil")
        XCTAssertTrue(guardRule.requiresConfirmation(deletionImpact: 9, baselineCount: 10, localItemCount: 1),
                      "Ein großer Anteil kleiner Bestände muss ebenfalls bestätigt werden")
        XCTAssertTrue(guardRule.requiresConfirmation(deletionImpact: 5, baselineCount: 5, localItemCount: 0), "Leerer lokaler Ordner muss nachfragen")
    }
}

final class TransportSafetyTests: XCTestCase {
    func testRedirectOriginIncludesEffectivePort() {
        XCTAssertTrue(TransportDelegate.hasSameOrigin(
            URL(string: "https://example.org/dav")!,
            URL(string: "https://EXAMPLE.org:443/other")!
        ))
        XCTAssertFalse(TransportDelegate.hasSameOrigin(
            URL(string: "https://example.org/dav")!,
            URL(string: "https://example.org:8443/other")!
        ))
        XCTAssertFalse(TransportDelegate.hasSameOrigin(
            URL(string: "https://example.org/dav")!,
            URL(string: "http://example.org/dav")!
        ))
    }
}

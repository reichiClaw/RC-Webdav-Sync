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

    func testConflictCopyName() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = RelativePath.conflictCopyName(for: "Bericht.final.pdf", deviceName: "Annas MacBook", date: date)
        XCTAssertTrue(name.hasPrefix("Bericht.final (Konfliktkopie von Annas MacBook "), name)
        XCTAssertTrue(name.hasSuffix(").pdf"), name)
        let noExt = RelativePath.conflictCopyName(for: "Notizen", deviceName: "Mac/Pro:1", date: date)
        XCTAssertTrue(noExt.hasPrefix("Notizen (Konfliktkopie von Mac-Pro-1 "), noExt)
        XCTAssertFalse(noExt.contains("/"))
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
        XCTAssertFalse(guardRule.requiresConfirmation(deletionImpact: 30, baselineCount: 1000, localItemCount: 970))
        XCTAssertTrue(guardRule.requiresConfirmation(deletionImpact: 5, baselineCount: 5, localItemCount: 0), "Leerer lokaler Ordner muss nachfragen")
    }
}

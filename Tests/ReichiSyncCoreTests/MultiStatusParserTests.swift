import XCTest
@testable import ReichiSyncCore

final class MultiStatusParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testNextcloudPropfind() throws {
        let response = try MultiStatusParser.parse(try fixture("nextcloud-propfind"))
        XCTAssertEqual(response.resources.count, 4)

        let root = response.resources[0]
        XCTAssertEqual(root.hrefPath, "/remote.php/dav/files/anna/Projekte/")
        XCTAssertTrue(root.isCollection)
        XCTAssertEqual(root.etag, "\"5f3a1c2b9d8e7\"")
        // Eigenschaften aus dem 404-propstat dürfen nicht übernommen werden.
        XCTAssertNil(root.contentLength)
        XCTAssertEqual(root.properties["{http://owncloud.org/ns}fileid"], "1234")

        let pdf = response.resources[1]
        XCTAssertEqual(pdf.hrefPath, "/remote.php/dav/files/anna/Projekte/Bericht Q4 – Entwurf ü.pdf")
        XCTAssertFalse(pdf.isCollection)
        XCTAssertEqual(pdf.contentLength, 204800)
        XCTAssertEqual(pdf.contentType, "application/pdf")
        XCTAssertTrue(pdf.hasStrongETag)
        XCTAssertEqual(pdf.lastModified, MultiStatusParser.parseHTTPDate("Mon, 16 Nov 2026 18:45:10 GMT"))

        let emoji = response.resources[2]
        XCTAssertEqual(emoji.hrefPath, "/remote.php/dav/files/anna/Projekte/Unterordner 📁/")
        XCTAssertTrue(emoji.isCollection)

        let weak = response.resources[3]
        XCTAssertEqual(weak.etag, "W/\"weak-etag\"")
        XCTAssertFalse(weak.hasStrongETag)
        XCTAssertEqual(weak.validator, "W/\"weak-etag\"")
    }

    func testSyncCollection() throws {
        let response = try MultiStatusParser.parse(try fixture("sync-collection"))
        XCTAssertEqual(response.syncToken, "http://example.com/ns/sync/1234")
        XCTAssertEqual(response.resources.count, 3)
        XCTAssertEqual(response.resources[0].etag, "\"etag-neu\"")
        XCTAssertEqual(response.resources[1].status, 404)
        XCTAssertEqual(response.resources[1].hrefPath, "/dav/root/geloescht.txt")
        XCTAssertTrue(response.resources[2].isCollection)
    }

    func testSupportedReportSet() throws {
        let response = try MultiStatusParser.parse(try fixture("supported-report-set"))
        let root = try XCTUnwrap(response.resources.first)
        XCTAssertTrue(root.supportsSyncCollection)
        XCTAssertEqual(root.properties["sync-token"], "http://sabre.io/ns/sync/42")
    }

    func testAbsoluteHrefAndPrefixedNamespace() throws {
        let xml = """
        <?xml version="1.0"?>
        <multistatus xmlns="DAV:">
          <response>
            <href>https://example.org/dav/Ordner%20A/Datei.txt</href>
            <propstat>
              <prop><resourcetype/><getetag>"x"</getetag><getcontentlength>5</getcontentlength></prop>
              <status>HTTP/1.1 200 OK</status>
            </propstat>
          </response>
        </multistatus>
        """
        let response = try MultiStatusParser.parse(Data(xml.utf8))
        XCTAssertEqual(response.resources.first?.hrefPath, "/dav/Ordner A/Datei.txt")
        XCTAssertEqual(response.resources.first?.contentLength, 5)
    }

    func testValidatorFallbackWithoutETag() throws {
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>/x/a.txt</D:href>
        <D:propstat><D:prop><D:resourcetype/><D:getlastmodified>Mon, 16 Nov 2026 10:00:00 GMT</D:getlastmodified><D:getcontentlength>7</D:getcontentlength></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
        """
        let response = try MultiStatusParser.parse(Data(xml.utf8))
        let res = try XCTUnwrap(response.resources.first)
        XCTAssertNil(res.etag)
        XCTAssertFalse(res.hasStrongETag)
        XCTAssertEqual(res.validator, "mtime:\(Int(MultiStatusParser.parseHTTPDate("Mon, 16 Nov 2026 10:00:00 GMT")!.timeIntervalSince1970));size:7")
    }

    func testInvalidXMLThrows() {
        XCTAssertThrowsError(try MultiStatusParser.parse(Data("<not-xml".utf8)))
    }

    func testRelativePathMapping() throws {
        let client = try WebDAVClient(baseURL: URL(string: "https://cloud.example.org/remote.php/dav/files/anna/Projekte")!,
                                      credentials: WebDAVCredentials(username: "anna", password: "pw"))
        XCTAssertEqual(client.relativePath(fromHrefPath: "/remote.php/dav/files/anna/Projekte/"), "")
        XCTAssertEqual(client.relativePath(fromHrefPath: "/remote.php/dav/files/anna/Projekte/Sub/Datei ä.txt"), "Sub/Datei ä.txt")
        XCTAssertEqual(client.relativePath(fromHrefPath: "/remote.php/dav/files/anna/Projekte/Sub/"), "Sub")
        XCTAssertNil(client.relativePath(fromHrefPath: "/remote.php/dav/files/bob/Projekte/x"))
        XCTAssertEqual(client.url(for: "Ordner A/Datei ü.txt").absoluteString, "https://cloud.example.org/remote.php/dav/files/anna/Projekte/Ordner%20A/Datei%20%C3%BC.txt")
        XCTAssertEqual(client.url(for: "Sub", isCollection: true).absoluteString, "https://cloud.example.org/remote.php/dav/files/anna/Projekte/Sub/")
    }

    func testInsecureURLRejected() {
        XCTAssertThrowsError(try WebDAVClient(baseURL: URL(string: "http://example.org/dav")!, credentials: WebDAVCredentials(username: "a", password: "b")))
        XCTAssertNoThrow(try WebDAVClient(baseURL: URL(string: "http://localhost:8080/dav")!, credentials: WebDAVCredentials(username: "a", password: "b")))
        XCTAssertNoThrow(try WebDAVClient(baseURL: URL(string: "http://example.org/dav")!, credentials: WebDAVCredentials(username: "a", password: "b"), allowInsecureHTTP: true))
    }
}

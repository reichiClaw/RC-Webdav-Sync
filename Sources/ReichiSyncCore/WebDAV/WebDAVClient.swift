import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fortschrittsrückmeldung (übertragene Bytes, erwartete Gesamtbytes oder -1).
public typealias TransferProgress = @Sendable (Int64, Int64) -> Void

/// Ergebnis eines Uploads.
public struct UploadResult: Sendable {
    public var etag: String?
    public var status: Int
    public init(etag: String?, status: Int) {
        self.etag = etag
        self.status = status
    }
}

/// Ergebnis eines Downloads.
public struct DownloadResult: Sendable {
    public var etag: String?
    public var lastModified: Date?
    public var contentLength: Int64
    public init(etag: String?, lastModified: Date?, contentLength: Int64) {
        self.etag = etag
        self.lastModified = lastModified
        self.contentLength = contentLength
    }
}

/// Änderung aus einer `sync-collection`-Antwort.
public struct SyncCollectionChange: Sendable, Hashable {
    public var item: RemoteItem?
    /// Relativer Pfad (normalisiert); bei Löschungen ist `item` `nil`.
    public var path: String
    public var deleted: Bool
    public init(item: RemoteItem?, path: String, deleted: Bool) {
        self.item = item
        self.path = path
        self.deleted = deleted
    }
}

public struct SyncCollectionResult: Sendable {
    public var changes: [SyncCollectionChange]
    public var newToken: String
    public init(changes: [SyncCollectionChange], newToken: String) {
        self.changes = changes
        self.newToken = newToken
    }
}

/// Abstraktion des WebDAV-Zugriffs. Alle Pfade sind relativ zum konfigurierten
/// Server-Ordner (`""` = Wurzel), unkodiert und mit „/“ getrennt.
public protocol WebDAVClientProtocol: Sendable {
    func detectCapabilities() async throws -> WebDAVCapabilities
    /// Prüft die Erreichbarkeit und den Zugriff auf den entfernten Wurzelordner.
    func probe() async throws -> RemoteItem
    /// Listet die direkten Kinder eines Ordners (`PROPFIND Depth: 1`).
    func list(directory rawPath: String) async throws -> [RemoteItem]
    /// Liefert die Eigenschaften einer einzelnen Ressource oder `nil` bei 404.
    func stat(_ rawPath: String) async throws -> RemoteItem?
    /// `REPORT sync-collection` (RFC 6578). `token == nil` liefert den Gesamtbestand.
    func syncCollection(token: String?) async throws -> SyncCollectionResult
    /// Aktueller `DAV:sync-token` des Wurzelordners (falls der Server ihn als Property liefert).
    func currentSyncToken() async throws -> String?
    func download(_ rawPath: String, to destination: URL, progress: TransferProgress?) async throws -> DownloadResult
    /// Lädt eine Datei hoch. `ifMatch` schützt bestehende Ressourcen, `ifNoneMatchAll` das Anlegen neuer.
    func upload(file: URL, to rawPath: String, ifMatch: String?, ifNoneMatchAll: Bool, progress: TransferProgress?) async throws -> UploadResult
    func makeDirectory(_ rawPath: String) async throws
    func delete(_ rawPath: String, ifMatch: String?) async throws
    /// Verschiebt/benennt um. Mit `overwrite == false` schlägt der Vorgang bei Zielkonflikt mit 412 fehl.
    func move(from rawPath: String, to destinationRawPath: String, overwrite: Bool, ifMatch: String?) async throws
}

/// Zugangsdaten für HTTP Basic Authentication.
public struct WebDAVCredentials: Sendable {
    public var username: String
    public var password: String
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    var authorizationHeader: String {
        let raw = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(raw)"
    }
}

/// URLSession-basierter WebDAV-Client.
public final class WebDAVClient: WebDAVClientProtocol, @unchecked Sendable {
    public let baseURL: URL
    private let credentials: WebDAVCredentials
    private let session: URLSession
    private let delegate: TransportDelegate
    private let logger: SyncLogger
    private let basePathDecoded: String

    public init(baseURL: URL, credentials: WebDAVCredentials, allowInsecureHTTP: Bool = false, logger: SyncLogger = .shared,
                sessionConfiguration: URLSessionConfiguration? = nil) throws {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw WebDAVError.invalidResponse("Ungültiges URL-Schema")
        }
        if scheme == "http" && !allowInsecureHTTP && !WebDAVClient.isLoopback(baseURL) {
            throw WebDAVError.insecureURL
        }
        var normalized = baseURL.absoluteString
        if !normalized.hasSuffix("/") { normalized += "/" }
        self.baseURL = URL(string: normalized) ?? baseURL
        self.credentials = credentials
        self.logger = logger
        logger.registerSecret(credentials.password)
        let decodedPath = self.baseURL.path
        self.basePathDecoded = decodedPath.hasSuffix("/") ? String(decodedPath.dropLast()) : decodedPath
        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "reichi-Sync/1.0 (macOS)"]
        let delegate = TransportDelegate(allowedHost: self.baseURL.host ?? "", logger: logger)
        self.delegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - URL-Bildung

    /// Baut die vollständige URL für einen relativen Pfad (jedes Segment einzeln kodiert).
    /// Verbindungen zu localhost dürfen auch ohne TLS aufgebaut werden (Testserver).
    public static func isLoopback(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    public func url(for rawPath: String, isCollection: Bool = false) -> URL {
        var result = baseURL
        for seg in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
            result.appendPathComponent(String(seg), isDirectory: false)
        }
        if isCollection && !rawPath.isEmpty {
            // Collections mit abschließendem Schrägstrich ansprechen (vermeidet Redirects).
            if let withSlash = URL(string: result.absoluteString + "/") { return withSlash }
        }
        return result
    }

    /// Wandelt ein dekodiertes `href` in einen relativen Pfad um. `nil`, wenn der Pfad
    /// nicht unterhalb der Basis liegt.
    func relativePath(fromHrefPath hrefPath: String) -> String? {
        var path = hrefPath
        if path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        if path == basePathDecoded || (basePathDecoded.isEmpty && path == "/") { return "" }
        let prefix = basePathDecoded + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        // Manche Server liefern hrefs ohne den Mount-Präfix. Versuch: letzte Komponenten vergleichen.
        return nil
    }

    // MARK: - Requests

    private func makeRequest(_ method: String, path rawPath: String, isCollection: Bool = false, headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url(for: rawPath, isCollection: isCollection))
        request.httpMethod = method
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        return request
    }

    private struct Response {
        var status: Int
        var headers: [String: String]
        var data: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    private func perform(_ request: URLRequest) async throws -> Response {
        let path = request.url?.path ?? "?"
        logger.debug("webdav", "\(request.httpMethod ?? "?") \(path)")
        let delegate = self.delegate
        let session = self.session
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: Self.mapTransportError(error, authChallenged: holder.task.map { delegate.wasAuthChallenged(taskIdentifier: $0.taskIdentifier) } ?? false))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: WebDAVError.invalidResponse("Keine HTTP-Antwort"))
                        return
                    }
                    let refused = holder.task.map { delegate.wasRedirectRefused(taskIdentifier: $0.taskIdentifier) } ?? false
                    if refused || (300..<400).contains(http.statusCode) {
                        continuation.resume(throwing: WebDAVError.redirectRefused("HTTP \(http.statusCode) → \(http.value(forHTTPHeaderField: "Location") ?? "?")"))
                        return
                    }
                    var headers: [String: String] = [:]
                    for (k, v) in http.allHeaderFields {
                        if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
                    }
                    continuation.resume(returning: Response(status: http.statusCode, headers: headers, data: data ?? Data()))
                }
                holder.task = task
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    static func mapTransportError(_ error: Error, authChallenged: Bool = false) -> WebDAVError {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled: return authChallenged ? .authenticationRequired(status: 401) : .cancelled
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication: return .authenticationRequired(status: 401)
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed:
                return .network("TLS-Zertifikat konnte nicht geprüft werden (\(ns.code))")
            default:
                return .network(ns.localizedDescription + " (\(ns.code))")
            }
        }
        if let dav = error as? WebDAVError { return dav }
        return .network(error.localizedDescription)
    }

    private func check(_ response: Response, accept: Set<Int>, context: String) throws {
        if accept.contains(response.status) { return }
        throw Self.error(for: response.status, body: response.data, context: context)
    }

    static func error(for status: Int, body: Data, context: String) -> WebDAVError {
        let text = String(decoding: body.prefix(300), as: UTF8.self)
        switch status {
        case 401: return .authenticationRequired(status: 401)
        case 403:
            if text.contains("valid-sync-token") { return .invalidSyncToken }
            return .forbidden(context)
        case 404: return .notFound
        case 405, 409: return .conflict(status: status, context)
        case 410: return .invalidSyncToken
        case 412: return .preconditionFailed
        case 423: return .locked
        case 507: return .insufficientStorage
        default: return .unexpectedStatus(status, context)
        }
    }

    // MARK: - WebDAVClientProtocol

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:resourcetype/>
        <d:getetag/>
        <d:getcontentlength/>
        <d:getlastmodified/>
        <d:getcontenttype/>
      </d:prop>
    </d:propfind>
    """

    private static let capabilitiesBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:resourcetype/>
        <d:getetag/>
        <d:supported-report-set/>
        <d:sync-token/>
      </d:prop>
    </d:propfind>
    """

    public func detectCapabilities() async throws -> WebDAVCapabilities {
        var caps = WebDAVCapabilities()
        let options = try await perform(makeRequest("OPTIONS", path: "", isCollection: true))
        if options.status == 401 { throw WebDAVError.authenticationRequired(status: 401) }
        if let dav = options.header("DAV") {
            caps.davClasses = Set(dav.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        caps.serverSoftware = options.header("Server")
        let software = (caps.serverSoftware ?? "").lowercased()
        caps.likelyHasServerTrash = software.contains("nextcloud") || software.contains("owncloud")

        let response = try await perform(makeRequest("PROPFIND", path: "", isCollection: true, headers: ["Depth": "0"], body: Data(Self.capabilitiesBody.utf8)))
        try check(response, accept: [207], context: "PROPFIND /")
        let multi = try MultiStatusParser.parse(response.data)
        if let root = multi.resources.first {
            caps.supportsSyncCollection = root.supportsSyncCollection || root.properties["sync-token"] != nil
            caps.providesETags = root.etag != nil
            caps.strongETags = root.hasStrongETag
        }
        // ETag-Stärke anhand einer Datei verifizieren (Collections liefern nicht immer ETags).
        if !caps.strongETags {
            let listing = try await perform(makeRequest("PROPFIND", path: "", isCollection: true, headers: ["Depth": "1"], body: Data(Self.propfindBody.utf8)))
            if listing.status == 207, let parsed = try? MultiStatusParser.parse(listing.data) {
                let files = parsed.resources.filter { !$0.isCollection }
                if let first = files.first {
                    caps.providesETags = first.etag != nil
                    caps.strongETags = first.hasStrongETag
                } else if !files.isEmpty || caps.providesETags {
                    // keine Dateien zur Prüfung: optimistisch bleiben
                }
            }
        }
        if software.contains("nextcloud") || software.contains("owncloud") || software.contains("apache") || software.contains("nginx") || software.contains("sabre") {
            // Diese Server liefern starke ETags für Dateien.
            if caps.providesETags { caps.strongETags = true }
        }
        logger.info("webdav", "Fähigkeiten: DAV=\(caps.davClasses.sorted()) sync=\(caps.supportsSyncCollection) etags=\(caps.providesETags) strong=\(caps.strongETags) server=\(caps.serverSoftware ?? "?")")
        return caps
    }

    public func probe() async throws -> RemoteItem {
        let response = try await perform(makeRequest("PROPFIND", path: "", isCollection: true, headers: ["Depth": "0"], body: Data(Self.propfindBody.utf8)))
        try check(response, accept: [207], context: "PROPFIND /")
        let multi = try MultiStatusParser.parse(response.data)
        guard let root = multi.resources.first else { throw WebDAVError.invalidResponse("Leere Multi-Status-Antwort") }
        guard root.isCollection else { throw WebDAVError.invalidResponse("Die Adresse zeigt nicht auf einen Ordner") }
        return RemoteItem(path: "", rawPath: "", kind: .directory, validator: root.validator, validatorIsStrong: root.hasStrongETag)
    }

    public func list(directory rawPath: String) async throws -> [RemoteItem] {
        let response = try await perform(makeRequest("PROPFIND", path: rawPath, isCollection: true, headers: ["Depth": "1"], body: Data(Self.propfindBody.utf8)))
        try check(response, accept: [207], context: "PROPFIND \(rawPath)")
        let multi = try MultiStatusParser.parse(response.data)
        var items: [RemoteItem] = []
        let selfKey = (try? RelativePath.normalize(rawPath)) ?? rawPath
        for res in multi.resources {
            if let status = res.status, !(200..<300).contains(status) { continue }
            guard let rel = relativePath(fromHrefPath: res.hrefPath) else {
                logger.warning("webdav", "Unerwartetes href außerhalb der Basis: \(res.hrefPath)")
                continue
            }
            guard let key = try? RelativePath.normalize(rel) else {
                logger.warning("webdav", "Ungültiger Pfad vom Server übersprungen: \(rel)")
                continue
            }
            if key == selfKey { continue }
            items.append(Self.makeItem(key: key, raw: rel, res))
        }
        return items
    }

    static func makeItem(key: String, raw: String, _ res: DAVResource) -> RemoteItem {
        RemoteItem(path: key, rawPath: raw, kind: res.isCollection ? .directory : .file, size: res.contentLength ?? 0,
                   modified: res.lastModified?.timeIntervalSince1970, validator: res.validator,
                   validatorIsStrong: res.hasStrongETag, contentType: res.contentType)
    }

    public func stat(_ rawPath: String) async throws -> RemoteItem? {
        let response = try await perform(makeRequest("PROPFIND", path: rawPath, headers: ["Depth": "0"], body: Data(Self.propfindBody.utf8)))
        if response.status == 404 { return nil }
        try check(response, accept: [207], context: "PROPFIND \(rawPath)")
        let multi = try MultiStatusParser.parse(response.data)
        guard let res = multi.resources.first else { return nil }
        if let status = res.status, status == 404 { return nil }
        let key = (try? RelativePath.normalize(rawPath)) ?? rawPath
        return Self.makeItem(key: key, raw: rawPath, res)
    }

    public func syncCollection(token: String?) async throws -> SyncCollectionResult {
        let tokenXML = token.map { "<d:sync-token>\(Self.escapeXML($0))</d:sync-token>" } ?? "<d:sync-token/>"
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:sync-collection xmlns:d="DAV:">
          \(tokenXML)
          <d:sync-level>infinite</d:sync-level>
          <d:prop>
            <d:resourcetype/>
            <d:getetag/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:getcontenttype/>
          </d:prop>
        </d:sync-collection>
        """
        let response = try await perform(makeRequest("REPORT", path: "", isCollection: true, headers: ["Depth": "0"], body: Data(body.utf8)))
        try check(response, accept: [207], context: "REPORT sync-collection")
        let multi = try MultiStatusParser.parse(response.data)
        guard let newToken = multi.syncToken, !newToken.isEmpty else {
            throw WebDAVError.invalidResponse("sync-collection ohne sync-token")
        }
        var changes: [SyncCollectionChange] = []
        for res in multi.resources {
            guard let rel = relativePath(fromHrefPath: res.hrefPath), let key = try? RelativePath.normalize(rel) else { continue }
            if key.isEmpty { continue }
            if let status = res.status, status == 404 {
                changes.append(SyncCollectionChange(item: nil, path: key, deleted: true))
            } else if let status = res.status, !(200..<300).contains(status) {
                continue
            } else {
                changes.append(SyncCollectionChange(item: Self.makeItem(key: key, raw: rel, res), path: key, deleted: false))
            }
        }
        return SyncCollectionResult(changes: changes, newToken: newToken)
    }

    public func currentSyncToken() async throws -> String? {
        let response = try await perform(makeRequest("PROPFIND", path: "", isCollection: true, headers: ["Depth": "0"], body: Data(Self.capabilitiesBody.utf8)))
        try check(response, accept: [207], context: "PROPFIND /")
        let multi = try MultiStatusParser.parse(response.data)
        guard let token = multi.resources.first?.properties["sync-token"], !token.isEmpty else { return nil }
        return token
    }

    public func download(_ rawPath: String, to destination: URL, progress: TransferProgress?) async throws -> DownloadResult {
        var request = makeRequest("GET", path: rawPath)
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        logger.debug("webdav", "GET \(request.url?.path ?? "?")")
        let session = self.session
        let delegate = self.delegate
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DownloadResult, Error>) in
                let task = session.downloadTask(with: request) { tempURL, response, error in
                    defer { if let id = holder.task?.taskIdentifier { delegate.removeProgress(taskIdentifier: id) } }
                    if let error {
                        continuation.resume(throwing: Self.mapTransportError(error, authChallenged: holder.task.map { delegate.wasAuthChallenged(taskIdentifier: $0.taskIdentifier) } ?? false))
                        return
                    }
                    guard let http = response as? HTTPURLResponse, let tempURL else {
                        continuation.resume(throwing: WebDAVError.invalidResponse("Keine HTTP-Antwort"))
                        return
                    }
                    guard http.statusCode == 200 else {
                        let data = (try? Data(contentsOf: tempURL)) ?? Data()
                        try? FileManager.default.removeItem(at: tempURL)
                        continuation.resume(throwing: Self.error(for: http.statusCode, body: data, context: "GET \(rawPath)"))
                        return
                    }
                    do {
                        let fm = FileManager.default
                        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                        try fm.moveItem(at: tempURL, to: destination)
                        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                        let etag = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "OC-ETag")
                        let lm = http.value(forHTTPHeaderField: "Last-Modified").flatMap(MultiStatusParser.parseHTTPDate)
                        continuation.resume(returning: DownloadResult(etag: etag, lastModified: lm, contentLength: size))
                    } catch {
                        try? FileManager.default.removeItem(at: tempURL)
                        continuation.resume(throwing: error)
                    }
                }
                holder.task = task
                if let progress { delegate.setProgress(progress, taskIdentifier: task.taskIdentifier) }
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    public func upload(file: URL, to rawPath: String, ifMatch: String?, ifNoneMatchAll: Bool, progress: TransferProgress?) async throws -> UploadResult {
        var request = makeRequest("PUT", path: rawPath)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        if ifNoneMatchAll { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        if let mtime = attrs[.modificationDate] as? Date {
            // Nextcloud/ownCloud übernehmen die Änderungszeit aus diesem Header.
            request.setValue(String(Int(mtime.timeIntervalSince1970)), forHTTPHeaderField: "X-OC-Mtime")
        }
        logger.debug("webdav", "PUT \(request.url?.path ?? "?") (\(size) Bytes)")
        let session = self.session
        let delegate = self.delegate
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UploadResult, Error>) in
                let task = session.uploadTask(with: request, fromFile: file) { data, response, error in
                    defer { if let id = holder.task?.taskIdentifier { delegate.removeProgress(taskIdentifier: id) } }
                    if let error {
                        continuation.resume(throwing: Self.mapTransportError(error, authChallenged: holder.task.map { delegate.wasAuthChallenged(taskIdentifier: $0.taskIdentifier) } ?? false))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: WebDAVError.invalidResponse("Keine HTTP-Antwort"))
                        return
                    }
                    guard [200, 201, 204].contains(http.statusCode) else {
                        continuation.resume(throwing: Self.error(for: http.statusCode, body: data ?? Data(), context: "PUT \(rawPath)"))
                        return
                    }
                    let etag = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "OC-ETag")
                    continuation.resume(returning: UploadResult(etag: etag, status: http.statusCode))
                }
                holder.task = task
                if let progress { delegate.setProgress(progress, taskIdentifier: task.taskIdentifier) }
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    public func makeDirectory(_ rawPath: String) async throws {
        var request = makeRequest("MKCOL", path: rawPath, isCollection: true)
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        let response = try await perform(request)
        try check(response, accept: [201], context: "MKCOL \(rawPath)")
    }

    public func delete(_ rawPath: String, ifMatch: String?) async throws {
        var headers: [String: String] = [:]
        if let ifMatch { headers["If-Match"] = ifMatch }
        var request = makeRequest("DELETE", path: rawPath, headers: headers)
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        let response = try await perform(request)
        if response.status == 404 { return } // bereits weg
        try check(response, accept: [200, 202, 204], context: "DELETE \(rawPath)")
    }

    public func move(from rawPath: String, to destinationRawPath: String, overwrite: Bool, ifMatch: String?) async throws {
        var headers: [String: String] = [
            "Destination": url(for: destinationRawPath).absoluteString,
            "Overwrite": overwrite ? "T" : "F",
        ]
        if let ifMatch { headers["If-Match"] = ifMatch }
        var request = makeRequest("MOVE", path: rawPath, headers: headers)
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        let response = try await perform(request)
        try check(response, accept: [201, 204], context: "MOVE \(rawPath) → \(destinationRawPath)")
    }

    static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Hält die laufende Task für die Abbruchbehandlung.
private final class TaskHolder: @unchecked Sendable {
    var task: URLSessionTask?
}

/// Session-Delegate: Fortschritt, Redirect-Schutz.
///
/// Umleitungen werden nur auf denselben Host und nur für lesende Methoden
/// zugelassen. Damit gelangen Zugangsdaten nie an fremde Hosts.
final class TransportDelegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let allowedHost: String
    private let logger: SyncLogger
    private let lock = NSLock()
    private var progressHandlers: [Int: TransferProgress] = [:]
    private var refusedRedirects: Set<Int> = []
    private var authChallenged: Set<Int> = []

    init(allowedHost: String, logger: SyncLogger) {
        self.allowedHost = allowedHost.lowercased()
        self.logger = logger
    }

    func setProgress(_ handler: @escaping TransferProgress, taskIdentifier: Int) {
        lock.lock(); progressHandlers[taskIdentifier] = handler; lock.unlock()
    }

    func removeProgress(taskIdentifier: Int) {
        lock.lock(); progressHandlers[taskIdentifier] = nil; lock.unlock()
    }

    func wasRedirectRefused(taskIdentifier: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return refusedRedirects.contains(taskIdentifier)
    }

    func wasAuthChallenged(taskIdentifier: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return authChallenged.contains(taskIdentifier)
    }

    /// Zugangsdaten werden ausschließlich über den vorab gesetzten Authorization-Header
    /// übertragen. Eine HTTP-Anmeldeaufforderung bedeutet daher, dass der Server sie
    /// abgelehnt hat; sie wird als „Anmeldung erforderlich“ gemeldet. Server-Zertifikate
    /// durchlaufen die reguläre Systemprüfung.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodNTLM {
            lock.lock(); authChallenged.insert(task.taskIdentifier); lock.unlock()
            if method != NSURLAuthenticationMethodHTTPBasic {
                logger.warning("webdav", "Server verlangt \(method); unterstützt wird nur Basic Authentication über HTTPS")
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let newHost = request.url?.host?.lowercased() ?? ""
        let method = task.originalRequest?.httpMethod?.uppercased() ?? "GET"
        let readOnly = ["GET", "HEAD", "OPTIONS", "PROPFIND"].contains(method)
        let sameOrigin = newHost == allowedHost && (request.url?.scheme?.lowercased() == task.originalRequest?.url?.scheme?.lowercased())
        guard sameOrigin, readOnly else {
            logger.warning("webdav", "Umleitung abgelehnt (\(response.statusCode)) → \(request.url?.host ?? "?") für \(method)")
            lock.lock(); refusedRedirects.insert(task.taskIdentifier); lock.unlock()
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.httpMethod = method
        if let original = task.originalRequest {
            for (k, v) in original.allHTTPHeaderFields ?? [:] where redirected.value(forHTTPHeaderField: k) == nil {
                redirected.setValue(v, forHTTPHeaderField: k)
            }
            redirected.httpBody = original.httpBody
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); let handler = progressHandlers[task.taskIdentifier]; lock.unlock()
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let handler = progressHandlers[downloadTask.taskIdentifier]; lock.unlock()
        handler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Wird bei Completion-Handler-Tasks nicht benötigt; Pflichtmethode des Protokolls.
    }
}

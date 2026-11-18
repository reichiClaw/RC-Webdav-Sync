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
    /// `false`, wenn der DAV-Server auf einen fremden Object-Storage
    /// umgeleitet hat; dessen ETag ist kein DAV-Validator.
    public var isDirectDAVResponse: Bool
    public init(etag: String?, lastModified: Date?, contentLength: Int64, isDirectDAVResponse: Bool = true) {
        self.etag = etag
        self.lastModified = lastModified
        self.contentLength = contentLength
        self.isDirectDAVResponse = isDirectDAVResponse
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

    /// Vorgabe für das Serverprodukt (`nil` = automatisch erkennen).
    public let serverKindHint: ServerKind?

    public init(baseURL: URL, credentials: WebDAVCredentials, allowInsecureHTTP: Bool = false, serverKindHint: ServerKind? = nil,
                logger: SyncLogger = .shared, sessionConfiguration: URLSessionConfiguration? = nil) throws {
        self.serverKindHint = serverKindHint
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw WebDAVError.invalidResponse("Ungültiges URL-Schema")
        }
        guard let host = baseURL.host, !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw WebDAVError.invalidResponse("Die Serveradresse muss einen Host enthalten und darf keine Zugangsdaten, Abfrage oder Fragmentangabe enthalten")
        }
        let decodedSegments = baseURL.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !decodedSegments.contains(".."), !decodedSegments.contains(".") else {
            throw WebDAVError.invalidResponse("Die Serveradresse enthält unsichere Pfadsegmente")
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
        let delegate = TransportDelegate(allowedOrigin: self.baseURL, logger: logger)
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

    public func url(for rawPath: String, isCollection: Bool = false) throws -> URL {
        guard !rawPath.hasPrefix("/") else { throw PathError.outsideRoot }
        _ = try RelativePath.normalize(rawPath)
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

    /// Validiert eine servergelieferte URI-Referenz vollständig. Insbesondere dürfen
    /// absolute `href`s nicht auf eine andere Origin zeigen und kodierte Traversals
    /// nicht durch stilles Überspringen eine unvollständige Aufzählung erzeugen.
    func validatedPath(for resource: DAVResource) throws -> (key: String, raw: String) {
        var hrefPath = resource.hrefPath
        if let rawHref = resource.rawHref {
            guard let resolved = URL(string: rawHref, relativeTo: baseURL)?.absoluteURL,
                  resolved.user == nil, resolved.password == nil,
                  resolved.query == nil, resolved.fragment == nil,
                  TransportDelegate.hasSameOrigin(resolved, baseURL) else {
                throw WebDAVError.invalidResponse("Unsicheres oder fremdes DAV-href: \(rawHref)")
            }
            hrefPath = resolved.path
        }
        guard let raw = relativePath(fromHrefPath: hrefPath) else {
            throw WebDAVError.invalidResponse("DAV-href außerhalb der konfigurierten Basis: \(hrefPath)")
        }
        do {
            return (try RelativePath.normalize(raw), raw)
        } catch {
            throw WebDAVError.invalidResponse("Ungültiger DAV-Pfad: \(raw)")
        }
    }

    private static func validate(_ multi: MultiStatusResponse, context: String) throws {
        guard multi.issues.isEmpty else {
            throw WebDAVError.invalidResponse("\(context): \(multi.issues.joined(separator: "; "))")
        }
    }

    private static func validateProperties(_ resource: DAVResource, context: String) throws {
        guard resource.successfulProperties.contains("resourcetype") else {
            throw WebDAVError.invalidResponse("\(context): resourcetype fehlt oder konnte nicht gelesen werden")
        }
    }

    // MARK: - Requests

    private func makeRequest(_ method: String, path rawPath: String, isCollection: Bool = false,
                             headers: [String: String] = [:], body: Data? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url(for: rawPath, isCollection: isCollection))
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
                    defer {
                        if let id = holder.taskIdentifier { delegate.finishTask(taskIdentifier: id) }
                    }
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
            holder.cancel()
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
        try Self.validate(multi, context: "PROPFIND /")
        guard multi.resources.count == 1, let root = multi.resources.first else {
            throw WebDAVError.invalidResponse("PROPFIND / lieferte nicht genau eine Ressource")
        }
        if let status = root.status, !(200..<300).contains(status) {
            throw Self.error(for: status, body: Data(), context: "PROPFIND /")
        }
        try Self.validateProperties(root, context: "PROPFIND /")
        let capabilityRootPath = try validatedPath(for: root)
        guard capabilityRootPath.key.isEmpty else {
            throw WebDAVError.invalidResponse("PROPFIND / lieferte eine fremde Ressource")
        }
        caps.supportsSyncCollection = root.supportsSyncCollection || root.properties["sync-token"] != nil
        caps.providesETags = root.etag != nil
        // Ein Collection-ETag beweist nichts über Datei-ETags.
        caps.strongETags = false
        // ETag-Stärke anhand einer Datei verifizieren (Collections liefern nicht immer ETags).
        if !caps.strongETags {
            let listing = try await perform(makeRequest("PROPFIND", path: "", isCollection: true, headers: ["Depth": "1"], body: Data(Self.propfindBody.utf8)))
            if listing.status == 207 {
                do {
                    let parsed = try MultiStatusParser.parse(listing.data)
                    try Self.validate(parsed, context: "PROPFIND / (Fähigkeitstest)")
                    var files: [DAVResource] = []
                    var seen: Set<String> = []
                    for resource in parsed.resources {
                        if let status = resource.status, !(200..<300).contains(status) {
                            throw Self.error(for: status, body: Data(), context: "PROPFIND / (Fähigkeitstest)")
                        }
                        try Self.validateProperties(resource, context: "PROPFIND / (Fähigkeitstest)")
                        let mapped = try validatedPath(for: resource)
                        guard seen.insert(mapped.key).inserted else {
                            throw WebDAVError.invalidResponse("Doppelter Pfad im Fähigkeitstest")
                        }
                        if !resource.isCollection { files.append(resource) }
                    }
                    if let first = files.first {
                        caps.providesETags = first.etag != nil
                        caps.strongETags = first.hasStrongETag
                    }
                } catch {
                    logger.warning("webdav", "Datei-ETag-Fähigkeit konnte nicht sicher bestimmt werden: \(error)")
                }
            }
        }
        if software.contains("nextcloud") || software.contains("owncloud") { caps.serverKind = .nextcloud }

        // Cloudreve: WebDAV unter <Site>/dav/, Ping-Endpunkt unter <Site>/api/v4/site/ping.
        if serverKindHint == .cloudreve {
            caps.serverKind = .cloudreve
            caps.honorsIfMatch = false
        }
        if let version = await cloudreveVersion() {
            caps.serverKind = .cloudreve
            caps.serverVersion = version
            caps.serverSoftware = caps.serverSoftware ?? "Cloudreve \(version)"
            // `If-Match` wird von Cloudreve-WebDAV nicht ausgewertet. Ob ein
            // konkreter ETag stark ist, wird ausschließlich aus dessen Syntax
            // abgeleitet und nicht aus einem leicht fälschbaren Server-Header.
            caps.honorsIfMatch = false
        } else if caps.serverKind != .cloudreve {
            caps.honorsIfMatch = await probeConditionalWrites()
            if !caps.honorsIfMatch {
                logger.warning(
                    "webdav",
                    "Bedingte PUT/DELETE/MOVE-Zugriffe konnten nicht sicher bestätigt werden; destruktive Änderungen bleiben gesperrt"
                )
            }
        }
        logger.info("webdav", "Fähigkeiten: DAV=\(caps.davClasses.sorted()) sync=\(caps.supportsSyncCollection) etags=\(caps.providesETags) strong=\(caps.strongETags) ifMatch=\(caps.honorsIfMatch) kind=\(caps.serverKind.rawValue) server=\(caps.serverSoftware ?? "?")")
        return caps
    }

    /// Site-Wurzel (Scheme + Host [+ Port]) der WebDAV-Adresse.
    public var siteOrigin: URL? {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        return components.url
    }

    /// Liefert die Cloudreve-Version, wenn hinter der Adresse eine Cloudreve-Instanz steckt.
    private func cloudreveVersion() async -> String? {
        guard let origin = siteOrigin else { return nil }
        var request = URLRequest(url: origin.appendingPathComponent("api/v4/site/ping"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        guard let response = try? await perform(request), response.status == 200,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              (json["code"] as? Int) == 0, let version = json["data"] as? String else { return nil }
        return version
    }

    /// Prüft die für einen verlustfreien Abgleich benötigten HTTP-
    /// Vorbedingungen an zwei zufälligen, intern ausgeschlossenen Dateien.
    /// Ausschließlich diese neu angelegten Probeobjekte werden verändert.
    private func probeConditionalWrites() async -> Bool {
        let nonce = UUID().uuidString.lowercased()
        let source = "\(ExclusionRules.internalPrefix)-capability-\(nonce).tmp"
        let destination = "\(ExclusionRules.internalPrefix)-capability-\(nonce)-moved.tmp"
        let impossibleETag = "\"reichi-sync-never-\(UUID().uuidString)\""

        func cleanup(_ path: String) async {
            guard var request = try? makeRequest("DELETE", path: path) else { return }
            request.setValue(nil, forHTTPHeaderField: "Content-Type")
            _ = try? await perform(request)
        }

        func finish(_ result: Bool) async -> Bool {
            await cleanup(source)
            await cleanup(destination)
            return result
        }

        do {
            let body = Data("reichi-sync-capability-probe".utf8)
            let create = try await perform(makeRequest(
                "PUT",
                path: source,
                headers: ["If-None-Match": "*", "Content-Type": "application/octet-stream"],
                body: body
            ))
            guard [200, 201, 204].contains(create.status) else { return await finish(false) }

            let duplicate = try await perform(makeRequest(
                "PUT",
                path: source,
                headers: ["If-None-Match": "*", "Content-Type": "application/octet-stream"],
                body: body
            ))
            guard duplicate.status == 412 else { return await finish(false) }

            let staleWrite = try await perform(makeRequest(
                "PUT",
                path: source,
                headers: ["If-Match": impossibleETag, "Content-Type": "application/octet-stream"],
                body: body
            ))
            guard staleWrite.status == 412 else { return await finish(false) }

            let staleMove = try await perform(makeRequest(
                "MOVE",
                path: source,
                headers: [
                    "Destination": try url(for: destination).absoluteString,
                    "Overwrite": "F",
                    "If-Match": impossibleETag,
                ]
            ))
            guard staleMove.status == 412 else { return await finish(false) }

            var deleteRequest = try makeRequest("DELETE", path: source, headers: ["If-Match": impossibleETag])
            deleteRequest.setValue(nil, forHTTPHeaderField: "Content-Type")
            let staleDelete = try await perform(deleteRequest)
            guard staleDelete.status == 412 else { return await finish(false) }
            return await finish(true)
        } catch {
            logger.debug("webdav", "Vorbedingungsprobe fehlgeschlagen: \(error)")
            return await finish(false)
        }
    }

    public func probe() async throws -> RemoteItem {
        let response = try await perform(makeRequest("PROPFIND", path: "", isCollection: true, headers: ["Depth": "0"], body: Data(Self.propfindBody.utf8)))
        try check(response, accept: [207], context: "PROPFIND /")
        let multi = try MultiStatusParser.parse(response.data)
        try Self.validate(multi, context: "PROPFIND /")
        guard multi.resources.count == 1, let root = multi.resources.first else {
            throw WebDAVError.invalidResponse("PROPFIND / lieferte nicht genau eine Ressource")
        }
        if let status = root.status, !(200..<300).contains(status) {
            throw Self.error(for: status, body: Data(), context: "PROPFIND /")
        }
        try Self.validateProperties(root, context: "PROPFIND /")
        let rootPath = try validatedPath(for: root)
        guard rootPath.key.isEmpty else { throw WebDAVError.invalidResponse("PROPFIND / lieferte eine fremde Ressource") }
        guard root.isCollection else { throw WebDAVError.invalidResponse("Die Adresse zeigt nicht auf einen Ordner") }
        return RemoteItem(path: "", rawPath: "", kind: .directory, validator: root.validator, validatorIsStrong: root.hasStrongETag)
    }

    public func list(directory rawPath: String) async throws -> [RemoteItem] {
        let response = try await perform(makeRequest("PROPFIND", path: rawPath, isCollection: true, headers: ["Depth": "1"], body: Data(Self.propfindBody.utf8)))
        try check(response, accept: [207], context: "PROPFIND \(rawPath)")
        let multi = try MultiStatusParser.parse(response.data)
        try Self.validate(multi, context: "PROPFIND \(rawPath)")
        var items: [RemoteItem] = []
        let selfKey = try RelativePath.normalize(rawPath)
        var seen: Set<String> = []
        for res in multi.resources {
            if let status = res.status, !(200..<300).contains(status) {
                throw Self.error(for: status, body: Data(), context: "PROPFIND \(rawPath)")
            }
            try Self.validateProperties(res, context: "PROPFIND \(rawPath)")
            let (key, rel) = try validatedPath(for: res)
            guard seen.insert(key).inserted else {
                throw WebDAVError.invalidResponse("PROPFIND \(rawPath): doppelter oder Unicode-kollidierender Pfad \(key)")
            }
            if key == selfKey { continue }
            guard RelativePath.parent(of: key) == selfKey else {
                throw WebDAVError.invalidResponse("PROPFIND Depth: 1 lieferte keinen direkten Nachfolger: \(key)")
            }
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
        try Self.validate(multi, context: "PROPFIND \(rawPath)")
        guard multi.resources.count == 1, let res = multi.resources.first else {
            throw WebDAVError.invalidResponse("PROPFIND \(rawPath) lieferte nicht genau eine Ressource")
        }
        if let status = res.status {
            if status == 404 { return nil }
            if !(200..<300).contains(status) {
                throw Self.error(for: status, body: Data(), context: "PROPFIND \(rawPath)")
            }
        }
        try Self.validateProperties(res, context: "PROPFIND \(rawPath)")
        let (key, rel) = try validatedPath(for: res)
        let expected = try RelativePath.normalize(rawPath)
        guard key == expected else {
            throw WebDAVError.invalidResponse("PROPFIND \(rawPath) lieferte \(key)")
        }
        return Self.makeItem(key: key, raw: rel, res)
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
        try Self.validate(multi, context: "REPORT sync-collection")
        guard let newToken = multi.syncToken, !newToken.isEmpty else {
            throw WebDAVError.invalidResponse("sync-collection ohne sync-token")
        }
        var changes: [SyncCollectionChange] = []
        var seen: Set<String> = []
        for res in multi.resources {
            let (key, rel) = try validatedPath(for: res)
            guard seen.insert(key).inserted else {
                throw WebDAVError.invalidResponse("REPORT sync-collection: doppelter oder Unicode-kollidierender Pfad \(key)")
            }
            if key.isEmpty { continue }
            if let status = res.status, status == 404 {
                changes.append(SyncCollectionChange(item: nil, path: key, deleted: true))
            } else if let status = res.status, !(200..<300).contains(status) {
                throw Self.error(for: status, body: Data(), context: "REPORT sync-collection")
            } else {
                try Self.validateProperties(res, context: "REPORT sync-collection")
                changes.append(SyncCollectionChange(item: Self.makeItem(key: key, raw: rel, res), path: key, deleted: false))
            }
        }
        return SyncCollectionResult(changes: changes, newToken: newToken)
    }

    public func currentSyncToken() async throws -> String? {
        let response = try await perform(makeRequest("PROPFIND", path: "", isCollection: true, headers: ["Depth": "0"], body: Data(Self.capabilitiesBody.utf8)))
        try check(response, accept: [207], context: "PROPFIND /")
        let multi = try MultiStatusParser.parse(response.data)
        try Self.validate(multi, context: "PROPFIND /")
        guard multi.resources.count == 1, let root = multi.resources.first else {
            throw WebDAVError.invalidResponse("PROPFIND / lieferte nicht genau eine Ressource")
        }
        if let status = root.status, !(200..<300).contains(status) {
            throw Self.error(for: status, body: Data(), context: "PROPFIND /")
        }
        let rootPath = try validatedPath(for: root)
        guard rootPath.key.isEmpty else { throw WebDAVError.invalidResponse("PROPFIND / lieferte eine fremde Ressource") }
        guard let token = root.properties["sync-token"], !token.isEmpty else { return nil }
        return token
    }

    public func download(_ rawPath: String, to destination: URL, progress: TransferProgress?) async throws -> DownloadResult {
        var request = try makeRequest("GET", path: rawPath)
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        // Synchronisierte Dateien müssen bytegenau ankommen. Transparente
        // HTTP-Komprimierung würde eine Content-Length-Prüfung unzuverlässig machen.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        logger.debug("webdav", "GET \(request.url?.path ?? "?")")
        let session = self.session
        let delegate = self.delegate
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DownloadResult, Error>) in
                let task = session.downloadTask(with: request) { tempURL, response, error in
                    defer { if let id = holder.taskIdentifier { delegate.finishTask(taskIdentifier: id) } }
                    if let error {
                        continuation.resume(throwing: Self.mapTransportError(error, authChallenged: holder.task.map { delegate.wasAuthChallenged(taskIdentifier: $0.taskIdentifier) } ?? false))
                        return
                    }
                    guard let http = response as? HTTPURLResponse, let tempURL else {
                        continuation.resume(throwing: WebDAVError.invalidResponse("Keine HTTP-Antwort"))
                        return
                    }
                    guard http.statusCode == 200 else {
                        let data: Data
                        if let handle = try? FileHandle(forReadingFrom: tempURL) {
                            data = (try? handle.read(upToCount: 300)) ?? Data()
                            try? handle.close()
                        } else {
                            data = Data()
                        }
                        try? FileManager.default.removeItem(at: tempURL)
                        continuation.resume(throwing: Self.error(for: http.statusCode, body: data, context: "GET \(rawPath)"))
                        return
                    }
                    do {
                        let requestedURL = try self.url(for: rawPath)
                        let finalURL = http.url ?? requestedURL
                        let finalIsDAVOrigin = TransportDelegate.hasSameOrigin(finalURL, self.baseURL)
                        if finalIsDAVOrigin, finalURL.path != requestedURL.path {
                            throw WebDAVError.redirectRefused(
                                "GET \(requestedURL.path) wurde auf eine andere DAV-Ressource umgeleitet (\(finalURL.path))"
                            )
                        }
                        let fm = FileManager.default
                        let attributes = try fm.attributesOfItem(atPath: tempURL.path)
                        guard let number = attributes[.size] as? NSNumber else {
                            throw WebDAVError.invalidResponse("Downloadgröße konnte nicht bestimmt werden")
                        }
                        let size = number.int64Value
                        if http.expectedContentLength >= 0, size != http.expectedContentLength {
                            throw WebDAVError.invalidResponse(
                                "Unvollständiger Download: \(size) statt \(http.expectedContentLength) Bytes"
                            )
                        }
                        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                        try fm.moveItem(at: tempURL, to: destination)
                        let etag = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "OC-ETag")
                        let lm = http.value(forHTTPHeaderField: "Last-Modified").flatMap(MultiStatusParser.parseHTTPDate)
                        continuation.resume(returning: DownloadResult(
                            etag: etag,
                            lastModified: lm,
                            contentLength: size,
                            isDirectDAVResponse: finalIsDAVOrigin
                        ))
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
            holder.cancel()
        }
    }

    public func upload(file: URL, to rawPath: String, ifMatch: String?, ifNoneMatchAll: Bool, progress: TransferProgress?) async throws -> UploadResult {
        var request = try makeRequest("PUT", path: rawPath)
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
                    defer { if let id = holder.taskIdentifier { delegate.finishTask(taskIdentifier: id) } }
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
            holder.cancel()
        }
    }

    public func makeDirectory(_ rawPath: String) async throws {
        var request = try makeRequest("MKCOL", path: rawPath, isCollection: true)
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        let response = try await perform(request)
        try check(response, accept: [201], context: "MKCOL \(rawPath)")
    }

    public func delete(_ rawPath: String, ifMatch: String?) async throws {
        var headers: [String: String] = [:]
        if let ifMatch { headers["If-Match"] = ifMatch }
        var request = try makeRequest("DELETE", path: rawPath, headers: headers)
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        let response = try await perform(request)
        if response.status == 404 { return } // bereits weg
        try check(response, accept: [200, 202, 204], context: "DELETE \(rawPath)")
    }

    public func move(from rawPath: String, to destinationRawPath: String, overwrite: Bool, ifMatch: String?) async throws {
        var headers: [String: String] = [
            "Destination": try url(for: destinationRawPath).absoluteString,
            "Overwrite": overwrite ? "T" : "F",
        ]
        if let ifMatch { headers["If-Match"] = ifMatch }
        var request = try makeRequest("MOVE", path: rawPath, headers: headers)
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
final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTask: URLSessionTask?
    private var cancellationRequested = false

    var task: URLSessionTask? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storedTask
        }
        set {
            lock.lock()
            storedTask = newValue
            let shouldCancel = cancellationRequested
            lock.unlock()
            if shouldCancel { newValue?.cancel() }
        }
    }

    var taskIdentifier: Int? { task?.taskIdentifier }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = storedTask
        lock.unlock()
        task?.cancel()
    }
}

/// Session-Delegate: Fortschritt, Redirect-Schutz.
///
/// Umleitungen bleiben für DAV-Methoden auf derselben Origin. Reine GET/HEAD-
/// Downloads dürfen einer fremden HTTPS-Origin folgen, nachdem sämtliche
/// Zugangsdaten und sensiblen Header entfernt wurden.
final class TransportDelegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL?) {
            guard let url,
                  let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased() else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    private let allowedOrigin: Origin
    private let logger: SyncLogger
    private let lock = NSLock()
    private var progressHandlers: [Int: TransferProgress] = [:]
    private var refusedRedirects: Set<Int> = []
    private var authChallenged: Set<Int> = []

    init(allowedOrigin: URL, logger: SyncLogger) {
        self.allowedOrigin = Origin(allowedOrigin)!
        self.logger = logger
    }

    static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        Origin(lhs) == Origin(rhs)
    }

    func setProgress(_ handler: @escaping TransferProgress, taskIdentifier: Int) {
        lock.lock(); progressHandlers[taskIdentifier] = handler; lock.unlock()
    }

    func finishTask(taskIdentifier: Int) {
        lock.lock()
        progressHandlers[taskIdentifier] = nil
        refusedRedirects.remove(taskIdentifier)
        authChallenged.remove(taskIdentifier)
        lock.unlock()
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
        let method = task.originalRequest?.httpMethod?.uppercased() ?? "GET"
        let readOnly = ["GET", "HEAD", "OPTIONS", "PROPFIND", "REPORT"].contains(method)
        let originalOrigin = Origin(task.originalRequest?.url)
        let redirectOrigin = Origin(request.url)
        let sameOrigin = originalOrigin == allowedOrigin && redirectOrigin == allowedOrigin
        if sameOrigin, readOnly {
            var redirected = request
            redirected.httpMethod = method
            if let original = task.originalRequest {
                for (k, v) in original.allHTTPHeaderFields ?? [:] where redirected.value(forHTTPHeaderField: k) == nil {
                    redirected.setValue(v, forHTTPHeaderField: k)
                }
                redirected.httpBody = original.httpBody
            }
            completionHandler(redirected)
            return
        }

        // Cloudreve kann Downloads zu einer signierten Object-Storage-URL
        // umleiten. Ausschließlich GET/HEAD darf einer fremden HTTPS-Origin
        // folgen; Authentisierung, Cookies und sonstige sensible Header werden
        // dabei explizit entfernt.
        let destination = request.url
        let secureForeignRead = originalOrigin == allowedOrigin
            && (method == "GET" || method == "HEAD")
            && destination?.scheme?.lowercased() == "https"
            && destination?.user == nil
            && destination?.password == nil
        if secureForeignRead {
            var redirected = request
            redirected.httpMethod = method
            for header in ["Authorization", "Proxy-Authorization", "Cookie", "Set-Cookie", "X-API-Key"] {
                redirected.setValue(nil, forHTTPHeaderField: header)
            }
            if let original = task.originalRequest {
                for header in ["Accept", "Accept-Encoding", "Range", "User-Agent"] {
                    if let value = original.value(forHTTPHeaderField: header) {
                        redirected.setValue(value, forHTTPHeaderField: header)
                    }
                }
            }
            completionHandler(redirected)
            return
        }

        logger.warning("webdav", "Umleitung abgelehnt (\(response.statusCode)) → \(request.url?.host ?? "?") für \(method)")
        lock.lock(); refusedRedirects.insert(task.taskIdentifier); lock.unlock()
        completionHandler(nil)
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

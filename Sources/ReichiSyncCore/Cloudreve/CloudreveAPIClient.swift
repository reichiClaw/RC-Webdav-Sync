import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Token-Paar der Cloudreve-REST-API (JWT).
public struct CloudreveTokens: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String
    public var accessExpires: Date
    public var refreshExpires: Date

    public init(accessToken: String, refreshToken: String, accessExpires: Date, refreshExpires: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpires = accessExpires
        self.refreshExpires = refreshExpires
    }

    /// Access-Token läuft in weniger als einer Minute ab (oder ist abgelaufen).
    public var accessTokenNeedsRefresh: Bool { accessExpires.timeIntervalSinceNow < 60 }
    public var refreshTokenExpired: Bool { refreshExpires.timeIntervalSinceNow < 0 }
}

/// Fehler der Cloudreve-API.
public enum CloudreveError: Error, Sendable, Equatable {
    /// `code != 0` in der JSON-Antwort.
    case api(code: Int, message: String)
    /// Anmeldung erforderlich (401, 40020 Credential invalid, Refresh fehlgeschlagen).
    case authenticationRequired(String)
    /// Zwei-Faktor-Code erforderlich; `sessionID` für `verifyTwoFactor`.
    case twoFactorRequired(sessionID: String)
    /// Upload-Sitzung abgelaufen oder unbekannt (40011) – Upload muss neu beginnen.
    case uploadSessionExpired
    /// Chunk-Index/-Länge vom Server abgelehnt (40012/40013) – Upload muss neu beginnen.
    case invalidChunk(String)
    /// Zieldatei wurde zwischenzeitlich geändert (40076 Stale version / 40061) oder existiert bereits (40004).
    case versionConflict(String)
    /// Speicherplatz des Kontos erschöpft (40051).
    case insufficientCapacity
    /// Die Speicherrichtlinie verlangt direkte Uploads an einen Drittanbieter (S3, OneDrive …),
    /// die nicht implementiert sind.
    case unsupportedStoragePolicy(String)
    case network(String)
    case invalidResponse(String)
    case cancelled

    /// Bekannte Antwortcodes (pkg/serializer/error.go).
    public enum Code {
        public static let success = 0
        public static let notFullySuccess = 203
        public static let checkLogin = 401
        public static let noPermission = 403
        public static let notFound = 404
        public static let conflict = 409
        public static let paramError = 40001
        public static let uploadFailed = 40002
        public static let objectExist = 40004
        public static let uploadSessionExpired = 40011
        public static let invalidChunkIndex = 40012
        public static let invalidContentLength = 40013
        public static let parentNotExist = 40016
        public static let credentialInvalid = 40020
        public static let twoFactorCodeError = 40022
        public static let fileNotFound = 40044
        public static let insufficientCapacity = 40051
        public static let conflictUploadOngoing = 40054
        public static let versionMismatch = 40061
        public static let lockConflict = 40073
        public static let staleVersion = 40076
        public static let entityNotExist = 40077
    }

    public var userDescription: String {
        switch self {
        case .api(let code, let message): return "Cloudreve meldet einen Fehler (\(code)): \(message)"
        case .authenticationRequired: return "Die Anmeldung bei Cloudreve ist abgelaufen oder wurde abgelehnt. Bitte in den Einstellungen erneut anmelden."
        case .twoFactorRequired: return "Für dieses Konto ist ein Zwei-Faktor-Code erforderlich."
        case .uploadSessionExpired: return "Die Upload-Sitzung ist abgelaufen; der Upload wird neu gestartet."
        case .invalidChunk(let detail): return "Der Server hat einen Upload-Teil abgelehnt (\(detail)); der Upload wird neu gestartet."
        case .versionConflict: return "Die Datei wurde auf dem Server zwischenzeitlich geändert – wird neu abgeglichen."
        case .insufficientCapacity: return "Der Speicherplatz des Cloudreve-Kontos ist erschöpft."
        case .unsupportedStoragePolicy(let type): return "Die Speicherrichtlinie „\(type)“ verlangt direkte Uploads an einen Drittanbieter, die nicht unterstützt werden. Es wird per WebDAV hochgeladen."
        case .network(let detail): return "Cloudreve ist nicht erreichbar: \(detail)"
        case .invalidResponse(let detail): return "Unerwartete Antwort von Cloudreve: \(detail)"
        case .cancelled: return "Abgebrochen"
        }
    }

    /// Entsprechender WebDAV-Fehler für die Engine-Logik.
    public var asWebDAVError: WebDAVError {
        switch self {
        case .authenticationRequired, .twoFactorRequired: return .authenticationRequired(status: 401)
        case .versionConflict: return .preconditionFailed
        case .insufficientCapacity: return .insufficientStorage
        case .network(let d): return .network(d)
        case .cancelled: return .cancelled
        case .api(let code, let message): return .unexpectedStatus(code, message)
        case .uploadSessionExpired, .invalidChunk, .unsupportedStoragePolicy, .invalidResponse: return .invalidResponse(userDescription)
        }
    }
}

/// WebDAV-Konto in Cloudreve.
public struct CloudreveDavAccount: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// Relative Wurzel, z. B. `cloudreve://my/Sync`.
    public var uri: String
    public var password: String
    public var readonly: Bool
    public var createdAt: Date?

    public init(id: String, name: String, uri: String, password: String, readonly: Bool = false, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.uri = uri
        self.password = password
        self.readonly = readonly
        self.createdAt = createdAt
    }
}

/// Freigabelink in Cloudreve.
public struct CloudreveShare: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var url: URL
    public var sourceURI: String?
    public var isPrivate: Bool
    public var password: String?
    public var expires: Date?
    public var expired: Bool
    public var visited: Int
    public var downloaded: Int
    public var remainDownloads: Int?
    public var isFolder: Bool
    public var createdAt: Date?

    public init(id: String, name: String, url: URL, sourceURI: String? = nil, isPrivate: Bool = false, password: String? = nil, expires: Date? = nil,
                expired: Bool = false, visited: Int = 0, downloaded: Int = 0, remainDownloads: Int? = nil, isFolder: Bool = false, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.sourceURI = sourceURI
        self.isPrivate = isPrivate
        self.password = password
        self.expires = expires
        self.expired = expired
        self.visited = visited
        self.downloaded = downloaded
        self.remainDownloads = remainDownloads
        self.isFolder = isFolder
        self.createdAt = createdAt
    }

    /// Link inklusive Passwort-Segment, falls Cloudreve das Passwort mitliefert.
    public var urlWithPassword: URL {
        guard isPrivate, let password, !password.isEmpty, !url.path.hasSuffix("/" + password) else { return url }
        return url.appendingPathComponent(password)
    }
}

/// Speicherrichtlinie aus einer Upload-Sitzung.
public struct CloudreveStoragePolicy: Sendable, Hashable {
    public var id: String
    public var name: String
    public var type: String
    public var relay: Bool
    public var chunkConcurrency: Int
    public var maxSize: Int64
}

/// Upload-Sitzung (Antwort von `PUT /api/v4/file/upload`).
public struct CloudreveUploadSession: Sendable, Hashable {
    public var sessionID: String
    /// `0` = kein Chunking, Datei in einer Anfrage.
    public var chunkSize: Int64
    public var expires: Date
    public var uploadURLs: [String]
    public var credential: String?
    public var policy: CloudreveStoragePolicy
    public var uri: String

    /// Chunks werden über Cloudreve selbst angenommen (lokale Richtlinie oder Relay).
    public var usesLocalChunkAPI: Bool { policy.type == "local" || policy.relay }
    /// Chunks gehen an einen Cloudreve-Slave-Knoten (`upload_urls[0]?chunk=N`, Authorization = credential).
    public var usesRemoteChunkAPI: Bool { policy.type == "remote" && !policy.relay }
}

/// Client für die Cloudreve-REST-API (v4). Zuständig für Anmeldung, Token-Erneuerung,
/// WebDAV-Konten und Chunk-Uploads. Alle übrigen Dateioperationen laufen über WebDAV.
public final class CloudreveAPIClient: @unchecked Sendable {
    public let siteURL: URL
    private let session: URLSession
    private let delegate: TransportDelegate
    private let logger: SyncLogger
    private let lock = NSLock()
    private var tokens: CloudreveTokens?
    private var refreshTask: Task<CloudreveTokens, Error>?
    private let onTokensChanged: (@Sendable (CloudreveTokens?) -> Void)?

    public init(siteURL: URL, tokens: CloudreveTokens? = nil, allowInsecureHTTP: Bool = false, logger: SyncLogger = .shared,
                sessionConfiguration: URLSessionConfiguration? = nil, onTokensChanged: (@Sendable (CloudreveTokens?) -> Void)? = nil) throws {
        guard let scheme = siteURL.scheme?.lowercased(), scheme == "https" || scheme == "http", siteURL.host != nil else {
            throw CloudreveError.invalidResponse("Ungültige Server-Adresse")
        }
        if scheme == "http" && !allowInsecureHTTP && !WebDAVClient.isLoopback(siteURL) {
            throw WebDAVError.insecureURL
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = siteURL.host
        components.port = siteURL.port
        self.siteURL = components.url ?? siteURL
        self.tokens = tokens
        self.logger = logger
        self.onTokensChanged = onTokensChanged
        if let tokens {
            logger.registerSecret(tokens.accessToken)
            logger.registerSecret(tokens.refreshToken)
        }
        let config: URLSessionConfiguration
        if let sessionConfiguration {
            config = sessionConfiguration
        } else {
            config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 60 * 60 * 24
        }
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "reichi-Sync/1.0 (macOS)", "Accept": "application/json"]
        let delegate = TransportDelegate(allowedHost: self.siteURL.host ?? "", logger: logger)
        self.delegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Aktuelle Tokens (für Persistierung).
    public var currentTokens: CloudreveTokens? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    public var isSignedIn: Bool {
        guard let t = currentTokens else { return false }
        return !t.refreshTokenExpired
    }

    private func setTokens(_ new: CloudreveTokens?) {
        lock.lock(); tokens = new; lock.unlock()
        if let new {
            logger.registerSecret(new.accessToken)
            logger.registerSecret(new.refreshToken)
        }
        onTokensChanged?(new)
    }

    // MARK: - HTTP

    struct APIResponse {
        var status: Int
        var code: Int
        var message: String
        var data: Any?
        var headers: [String: String]
    }

    private func apiURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: siteURL.appendingPathComponent("api/v4/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil, authorized: Bool) async throws -> URLRequest {
        var request = URLRequest(url: apiURL(path, query: query))
        request.httpMethod = method
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            let token = try await validAccessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Autorisierte Anfrage; antwortet der Server mit 401 (Code 401), wird das Token einmalig
    /// per Refresh-Token erneuert und die Anfrage wiederholt.
    private func sendAuthorized(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil,
                                body: Data? = nil, progress: TransferProgress? = nil) async throws -> APIResponse {
        var request = try await self.request(method, path, query: query, json: json, authorized: true)
        if body != nil {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body?.count ?? 0), forHTTPHeaderField: "Content-Length")
        }
        let response = try await send(request, body: body, progress: progress)
        guard response.code == CloudreveError.Code.checkLogin || response.status == 401 else { return response }
        let (current, _) = snapshotTokenState()
        guard let current, !current.refreshTokenExpired else {
            setTokens(nil)
            throw CloudreveError.authenticationRequired(response.message.isEmpty ? "Anmeldung erforderlich" : response.message)
        }
        logger.notice("cloudreve", "401 bei \(path) – Token wird erneuert")
        let refreshed = try await refresh(using: current.refreshToken)
        request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
        return try await send(request, body: body, progress: progress)
    }

    /// Führt eine Anfrage aus und interpretiert die JSON-Hülle `{code, msg, data}`.
    private func send(_ request: URLRequest, body: Data? = nil, progress: TransferProgress? = nil) async throws -> APIResponse {
        let path = request.url?.path ?? "?"
        logger.debug("cloudreve", "\(request.httpMethod ?? "?") \(path)")
        let session = self.session
        let delegate = self.delegate
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<APIResponse, Error>) in
                let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    defer { if let id = holder.task?.taskIdentifier { delegate.removeProgress(taskIdentifier: id) } }
                    if let error {
                        continuation.resume(throwing: Self.mapTransportError(error))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: CloudreveError.invalidResponse("Keine HTTP-Antwort"))
                        return
                    }
                    if let id = holder.task?.taskIdentifier, delegate.wasRedirectRefused(taskIdentifier: id) {
                        continuation.resume(throwing: CloudreveError.network("Umleitung auf fremden Host abgelehnt"))
                        return
                    }
                    var headers: [String: String] = [:]
                    for (k, v) in http.allHeaderFields {
                        if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
                    }
                    let data = data ?? Data()
                    var code = http.statusCode == 200 ? 0 : http.statusCode
                    var message = ""
                    var payload: Any?
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let c = json["code"] as? Int { code = c }
                        message = (json["msg"] as? String) ?? ""
                        payload = json["data"]
                    } else if http.statusCode == 200 {
                        continuation.resume(throwing: CloudreveError.invalidResponse("Antwort ist kein JSON (\(path))"))
                        return
                    }
                    continuation.resume(returning: APIResponse(status: http.statusCode, code: code, message: message, data: payload, headers: headers))
                }
                let task: URLSessionTask
                if let body {
                    task = session.uploadTask(with: request, from: body, completionHandler: completion)
                } else {
                    task = session.dataTask(with: request, completionHandler: completion)
                }
                holder.task = task
                if let progress { delegate.setProgress(progress, taskIdentifier: task.taskIdentifier) }
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    static func mapTransportError(_ error: Error) -> CloudreveError {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return .cancelled }
            return .network(ns.localizedDescription + " (\(ns.code))")
        }
        if let cr = error as? CloudreveError { return cr }
        return .network(error.localizedDescription)
    }

    /// Wirft bei `code != 0` den passenden Fehler.
    private func check(_ response: APIResponse, context: String) throws {
        guard response.code != CloudreveError.Code.success else { return }
        throw Self.error(code: response.code, message: response.message, status: response.status, context: context)
    }

    static func error(code: Int, message: String, status: Int, context: String) -> CloudreveError {
        let text = message.isEmpty ? context : message
        switch code {
        case CloudreveError.Code.checkLogin, CloudreveError.Code.credentialInvalid: return .authenticationRequired(text)
        case CloudreveError.Code.uploadSessionExpired: return .uploadSessionExpired
        case CloudreveError.Code.invalidChunkIndex, CloudreveError.Code.invalidContentLength: return .invalidChunk(text)
        case CloudreveError.Code.objectExist, CloudreveError.Code.staleVersion, CloudreveError.Code.versionMismatch,
             CloudreveError.Code.conflictUploadOngoing, CloudreveError.Code.lockConflict, CloudreveError.Code.entityNotExist:
            return .versionConflict(text)
        case CloudreveError.Code.insufficientCapacity: return .insufficientCapacity
        default:
            if status == 401 { return .authenticationRequired(text) }
            return .api(code: code, message: text)
        }
    }

    // MARK: - Site

    /// `GET /api/v4/site/ping` → Versionsstring.
    public func ping() async throws -> String {
        let response = try await send(request("GET", "site/ping", authorized: false))
        try check(response, context: "ping")
        guard let version = response.data as? String else { throw CloudreveError.invalidResponse("ping ohne Version") }
        return version
    }

    // MARK: - Anmeldung

    public enum LoginResult: Sendable, Equatable {
        case signedIn(CloudreveTokens)
        case twoFactorRequired(sessionID: String)
    }

    /// Passwort-Anmeldung (`POST /api/v4/session/token`). Liefert bei aktivierter
    /// Zwei-Faktor-Authentifizierung eine Sitzungs-ID für `verifyTwoFactor`.
    public func login(email: String, password: String) async throws -> LoginResult {
        logger.registerSecret(password)
        let response = try await send(request("POST", "session/token", json: ["email": email, "password": password], authorized: false))
        if response.code == CloudreveError.Code.notFullySuccess, let sessionID = response.data as? String {
            return .twoFactorRequired(sessionID: sessionID)
        }
        try check(response, context: "Anmeldung")
        let tokens = try Self.parseTokens(from: response.data, nested: true)
        setTokens(tokens)
        return .signedIn(tokens)
    }

    /// Zweiter Schritt bei 2FA (`POST /api/v4/session/token/2fa`).
    public func verifyTwoFactor(sessionID: String, otp: String) async throws -> CloudreveTokens {
        let response = try await send(request("POST", "session/token/2fa", json: ["session_id": sessionID, "otp": otp], authorized: false))
        try check(response, context: "Zwei-Faktor-Code")
        let tokens = try Self.parseTokens(from: response.data, nested: true)
        setTokens(tokens)
        return tokens
    }

    /// Meldet die API-Sitzung ab (Tokens verwerfen).
    public func signOut() {
        setTokens(nil)
    }

    static func parseTokens(from data: Any?, nested: Bool) throws -> CloudreveTokens {
        guard var dict = data as? [String: Any] else { throw CloudreveError.invalidResponse("Token fehlen") }
        if nested, let token = dict["token"] as? [String: Any] { dict = token }
        guard let access = dict["access_token"] as? String, let refresh = dict["refresh_token"] as? String else {
            throw CloudreveError.invalidResponse("Token fehlen in der Antwort")
        }
        let accessExpires = Self.parseDate(dict["access_expires"]) ?? Date().addingTimeInterval(3600)
        let refreshExpires = Self.parseDate(dict["refresh_expires"]) ?? Date().addingTimeInterval(180 * 86400)
        return CloudreveTokens(accessToken: access, refreshToken: refresh, accessExpires: accessExpires, refreshExpires: refreshExpires)
    }

    static func parseDate(_ value: Any?) -> Date? {
        if let s = value as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
        if let n = value as? Double { return Date(timeIntervalSince1970: n) }
        if let n = value as? Int { return Date(timeIntervalSince1970: TimeInterval(n)) }
        return nil
    }

    /// Liefert ein gültiges Access-Token, erneuert es bei Bedarf (einmalig, auch bei parallelen Aufrufen).
    private func validAccessToken() async throws -> String {
        let (current, running) = snapshotTokenState()
        guard let current else { throw CloudreveError.authenticationRequired("Nicht angemeldet") }
        if !current.accessTokenNeedsRefresh { return current.accessToken }
        if current.refreshTokenExpired {
            setTokens(nil)
            throw CloudreveError.authenticationRequired("Sitzung abgelaufen")
        }
        if let running { return try await running.value.accessToken }
        let task = Task<CloudreveTokens, Error> { [weak self] in
            guard let self else { throw CloudreveError.cancelled }
            return try await self.refresh(using: current.refreshToken)
        }
        setRefreshTask(task)
        defer { setRefreshTask(nil) }
        return try await task.value.accessToken
    }

    private func snapshotTokenState() -> (CloudreveTokens?, Task<CloudreveTokens, Error>?) {
        lock.lock(); defer { lock.unlock() }
        return (tokens, refreshTask)
    }

    private func setRefreshTask(_ task: Task<CloudreveTokens, Error>?) {
        lock.lock(); refreshTask = task; lock.unlock()
    }

    /// `POST /api/v4/session/token/refresh`.
    private func refresh(using refreshToken: String) async throws -> CloudreveTokens {
        let response = try await send(request("POST", "session/token/refresh", json: ["refresh_token": refreshToken], authorized: false))
        if response.code != 0 {
            setTokens(nil)
            throw CloudreveError.authenticationRequired(response.message.isEmpty ? "Token-Erneuerung fehlgeschlagen" : response.message)
        }
        let tokens = try Self.parseTokens(from: response.data, nested: false)
        setTokens(tokens)
        logger.info("cloudreve", "Access-Token erneuert (gültig bis \(tokens.accessExpires))")
        return tokens
    }

    // MARK: - WebDAV-Konten

    /// `GET /api/v4/devices/dav` (alle Seiten).
    public func listDavAccounts() async throws -> [CloudreveDavAccount] {
        var accounts: [CloudreveDavAccount] = []
        var nextToken: String?
        repeat {
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let nextToken { query.append(URLQueryItem(name: "next_page_token", value: nextToken)) }
            let response = try await sendAuthorized("GET", "devices/dav", query: query)
            try check(response, context: "WebDAV-Konten")
            guard let data = response.data as? [String: Any] else { break }
            for raw in data["accounts"] as? [[String: Any]] ?? [] {
                if let account = Self.parseDavAccount(raw) { accounts.append(account) }
            }
            let pagination = data["pagination"] as? [String: Any]
            let token = pagination?["next_token"] as? String
            nextToken = (token?.isEmpty == false && (pagination?["is_cursor"] as? Bool ?? true)) ? token : nil
        } while nextToken != nil
        return accounts
    }

    /// `PUT /api/v4/devices/dav` – legt ein WebDAV-Konto mit der angegebenen Wurzel an.
    public func createDavAccount(name: String, uri: String, readonly: Bool = false) async throws -> CloudreveDavAccount {
        let response = try await sendAuthorized("PUT", "devices/dav", json: ["name": name, "uri": uri, "readonly": readonly, "proxy": false, "disable_sys_files": false])
        try check(response, context: "WebDAV-Konto anlegen")
        guard let raw = response.data as? [String: Any], let account = Self.parseDavAccount(raw) else {
            throw CloudreveError.invalidResponse("WebDAV-Konto ohne Daten")
        }
        return account
    }

    static func parseDavAccount(_ raw: [String: Any]) -> CloudreveDavAccount? {
        guard let id = raw["id"] as? String, let uri = raw["uri"] as? String, let password = raw["password"] as? String else { return nil }
        let name = raw["name"] as? String ?? ""
        var readonly = false
        if let options = raw["options"] as? String, let data = Data(base64Encoded: options), let first = data.first {
            // BooleanSet: Bit 0 = Readonly, Bit 1 = Proxy, Bit 2 = DisableSysFiles
            readonly = first & 0x1 != 0
        }
        return CloudreveDavAccount(id: id, name: name, uri: uri, password: password, readonly: readonly, createdAt: parseDate(raw["created_at"]))
    }

    // MARK: - Freigaben

    /// Optionen für einen Freigabelink.
    public struct ShareOptions: Sendable, Hashable {
        /// Passwortschutz. Ohne `password` erzeugt Cloudreve ein zufälliges Passwort.
        public var isPrivate: Bool
        /// Nur alphanumerisch, max. 32 Zeichen.
        public var password: String?
        /// Gültigkeit in Sekunden (`nil` = unbegrenzt).
        public var expiresIn: TimeInterval?
        /// Maximale Downloads (`nil` = unbegrenzt).
        public var downloadLimit: Int?
        /// Ordnerfreigabe: Inhalte in der Freigabe-Ansicht auflisten.
        public var shareView: Bool

        public init(isPrivate: Bool = false, password: String? = nil, expiresIn: TimeInterval? = nil, downloadLimit: Int? = nil, shareView: Bool = true) {
            self.isPrivate = isPrivate
            self.password = password
            self.expiresIn = expiresIn
            self.downloadLimit = downloadLimit
            self.shareView = shareView
        }
    }

    /// `PUT /api/v4/share` – erzeugt einen Freigabelink und liefert dessen URL
    /// (`{site}/s/{id}` bzw. `{site}/s/{id}/{passwort}`).
    public func createShare(uri: String, options: ShareOptions) async throws -> URL {
        var body: [String: Any] = ["uri": uri, "is_private": options.isPrivate, "share_view": options.shareView]
        if options.isPrivate, let password = options.password, !password.isEmpty { body["password"] = password }
        if let expires = options.expiresIn, expires > 0 { body["expire"] = Int(expires) }
        if let limit = options.downloadLimit, limit > 0 { body["downloads"] = limit }
        let response = try await sendAuthorized("PUT", "share", json: body)
        try check(response, context: "Freigabe erstellen")
        guard let link = response.data as? String, let url = URL(string: link) else {
            throw CloudreveError.invalidResponse("Freigabe ohne Link")
        }
        return url
    }

    /// `GET /api/v4/share` – eigene Freigaben (alle Seiten).
    public func listShares() async throws -> [CloudreveShare] {
        var shares: [CloudreveShare] = []
        var nextToken: String?
        repeat {
            var query = [URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "order_by", value: "created_at"),
                         URLQueryItem(name: "order_direction", value: "desc")]
            if let nextToken { query.append(URLQueryItem(name: "next_page_token", value: nextToken)) }
            let response = try await sendAuthorized("GET", "share", query: query)
            try check(response, context: "Freigaben")
            guard let data = response.data as? [String: Any] else { break }
            for raw in data["shares"] as? [[String: Any]] ?? [] {
                if let share = Self.parseShare(raw) { shares.append(share) }
            }
            let pagination = data["pagination"] as? [String: Any]
            let token = pagination?["next_token"] as? String
            nextToken = (token?.isEmpty == false) ? token : nil
        } while nextToken != nil
        return shares
    }

    /// `DELETE /api/v4/share/{id}`.
    public func deleteShare(id: String) async throws {
        let response = try await sendAuthorized("DELETE", "share/\(id)")
        if response.code == CloudreveError.Code.notFound { return }
        try check(response, context: "Freigabe löschen")
    }

    static func parseShare(_ raw: [String: Any]) -> CloudreveShare? {
        guard let id = raw["id"] as? String, let link = raw["url"] as? String, let url = URL(string: link) else { return nil }
        return CloudreveShare(id: id, name: raw["name"] as? String ?? "", url: url, sourceURI: raw["source_uri"] as? String,
                              isPrivate: raw["is_private"] as? Bool ?? (raw["password_protected"] as? Bool ?? false),
                              password: raw["password"] as? String, expires: parseDate(raw["expires"]), expired: raw["expired"] as? Bool ?? false,
                              visited: raw["visited"] as? Int ?? 0, downloaded: raw["downloaded"] as? Int ?? 0,
                              remainDownloads: raw["remain_downloads"] as? Int, isFolder: (raw["source_type"] as? Int) == 1,
                              createdAt: parseDate(raw["created_at"]))
    }

    // MARK: - Ordner

    /// `POST /api/v4/file/create` mit `type: folder`. Ein bereits vorhandener Ordner gilt als Erfolg.
    public func createFolder(uri: String) async throws {
        let response = try await sendAuthorized("POST", "file/create", json: ["type": "folder", "uri": uri])
        if response.code == CloudreveError.Code.objectExist { return }
        try check(response, context: "Ordner anlegen")
    }

    // MARK: - Upload

    /// `PUT /api/v4/file/upload` – erzeugt eine Upload-Sitzung.
    /// - Parameters:
    ///   - overwrite: `entity_type: version` (vorhandene Datei überschreiben). Ohne diese Option
    ///     lehnt Cloudreve den Upload ab, wenn die Datei bereits existiert (`40004`).
    ///   - previousEntityID: bekannte Entity-ID der Serverversion (entspricht dem WebDAV-ETag
    ///     ohne Anführungszeichen). Cloudreve lehnt den Upload ab, wenn inzwischen eine neuere
    ///     Version existiert (`40076`).
    public func createUploadSession(uri: String, size: Int64, lastModified: Date?, mimeType: String? = nil, overwrite: Bool,
                                    previousEntityID: String?) async throws -> CloudreveUploadSession {
        var body: [String: Any] = ["uri": uri, "size": size]
        if let lastModified { body["last_modified"] = Int64(lastModified.timeIntervalSince1970 * 1000) }
        if let mimeType { body["mime_type"] = mimeType }
        if overwrite { body["entity_type"] = "version" }
        if let previousEntityID, !previousEntityID.isEmpty { body["previous"] = previousEntityID }
        let response = try await sendAuthorized("PUT", "file/upload", json: body)
        try check(response, context: "Upload-Sitzung")
        guard let data = response.data as? [String: Any], let sessionID = data["session_id"] as? String,
              let policyRaw = data["storage_policy"] as? [String: Any], let policyID = policyRaw["id"] as? String,
              let policyType = policyRaw["type"] as? String else {
            throw CloudreveError.invalidResponse("Upload-Sitzung unvollständig")
        }
        let policy = CloudreveStoragePolicy(id: policyID, name: policyRaw["name"] as? String ?? "", type: policyType,
                                            relay: policyRaw["relay"] as? Bool ?? false,
                                            chunkConcurrency: max(1, policyRaw["chunk_concurrency"] as? Int ?? 1),
                                            maxSize: (policyRaw["max_size"] as? NSNumber)?.int64Value ?? 0)
        let chunkSize = (data["chunk_size"] as? NSNumber)?.int64Value ?? 0
        let expires = Self.parseDate(data["expires"]) ?? Date().addingTimeInterval(3600)
        return CloudreveUploadSession(sessionID: sessionID, chunkSize: chunkSize, expires: expires,
                                      uploadURLs: data["upload_urls"] as? [String] ?? [], credential: data["credential"] as? String,
                                      policy: policy, uri: data["uri"] as? String ?? uri)
    }

    /// Lädt einen Chunk hoch (`POST /api/v4/file/upload/{session}/{index}` bzw. Slave-URL).
    /// Chunks werden serverseitig am Offset `index * chunkSize` geschrieben; eine Wiederholung
    /// desselben Index ist idempotent.
    public func uploadChunk(_ data: Data, index: Int, session uploadSession: CloudreveUploadSession, progress: TransferProgress?) async throws {
        let response: APIResponse
        if uploadSession.usesLocalChunkAPI {
            response = try await sendAuthorized("POST", "file/upload/\(uploadSession.sessionID)/\(index)", body: data, progress: progress)
        } else if uploadSession.usesRemoteChunkAPI, let base = uploadSession.uploadURLs.first, var components = URLComponents(string: base) {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "chunk", value: String(index)))
            components.queryItems = items
            guard let url = components.url else { throw CloudreveError.invalidResponse("Ungültige Slave-URL") }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            if let credential = uploadSession.credential { request.setValue(credential, forHTTPHeaderField: "Authorization") }
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
            response = try await send(request, body: data, progress: progress)
        } else {
            throw CloudreveError.unsupportedStoragePolicy(uploadSession.policy.type)
        }
        try check(response, context: "Chunk \(index)")
    }

    /// `DELETE /api/v4/file/upload` – verwirft eine Upload-Sitzung (Fehler werden nur protokolliert).
    public func deleteUploadSession(id: String, uri: String) async {
        do {
            let response = try await sendAuthorized("DELETE", "file/upload", json: ["id": id, "uri": uri])
            if response.code != 0 { logger.debug("cloudreve", "Upload-Sitzung \(id) konnte nicht gelöscht werden: \(response.message)") }
        } catch {
            logger.debug("cloudreve", "Upload-Sitzung \(id) konnte nicht gelöscht werden: \(error)")
        }
    }
}

// MARK: - Cloudreve-URIs

public enum CloudreveURI {
    /// Erzeugt eine Datei-URI aus der Konto-Wurzel (z. B. `cloudreve://my/Sync`) und einem
    /// relativen Pfad. Jedes Segment wird einzeln URL-kodiert.
    public static func fileURI(root: String, relativePath: String) throws -> String {
        let segments = try RelativePath.segments(of: relativePath)
        var base = root.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "cloudreve://my" }
        while base.hasSuffix("/") { base.removeLast() }
        if segments.isEmpty { return base.hasPrefix("cloudreve://") && !base.dropFirst("cloudreve://".count).contains("/") ? base + "/" : base }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#+%")
        let encoded = segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        return base + "/" + encoded.joined(separator: "/")
    }

    /// Erzeugt die Konto-Wurzel-URI aus einem Ordnerpfad wie `/Sync/Projekte` (leer = alle Dateien).
    public static func rootURI(folderPath: String) -> String {
        let trimmed = folderPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if trimmed.isEmpty { return "cloudreve://my/" }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#+%")
        let encoded = trimmed.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
        return "cloudreve://my/" + encoded.joined(separator: "/")
    }

    /// Lesbarer Ordnerpfad aus einer URI (`cloudreve://my/Sync%20A` → `/Sync A`).
    public static func folderPath(from uri: String) -> String {
        guard let components = URLComponents(string: uri) else { return uri }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return path.isEmpty ? "/" : path
    }
}

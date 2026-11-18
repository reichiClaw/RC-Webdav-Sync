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
        public static let invalidPassword = 40080
        public static let accessTokenExpired = 40080
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
        case .unsupportedStoragePolicy(let type): return "Die Speicherrichtlinie „\(type)“ kann von der App nicht sicher für diesen Upload verwendet werden."
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
    /// Verschlüsselte Policies benötigen das Cloudreve-Client-
    /// Verschlüsselungsprotokoll und dürfen nicht als Klartext-Chunks bedient werden.
    public var encryption: Bool = false
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
    private var tokenGeneration: UInt64 = 0
    private var refreshGeneration: UInt64?
    private let onTokensChanged: (@Sendable (CloudreveTokens?) -> Void)?

    public init(siteURL: URL, tokens: CloudreveTokens? = nil, allowInsecureHTTP: Bool = false, logger: SyncLogger = .shared,
                sessionConfiguration: URLSessionConfiguration? = nil, onTokensChanged: (@Sendable (CloudreveTokens?) -> Void)? = nil) throws {
        guard let scheme = siteURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = siteURL.host, !host.isEmpty,
              siteURL.user == nil, siteURL.password == nil,
              siteURL.query == nil, siteURL.fragment == nil,
              siteURL.path.isEmpty || siteURL.path == "/" else {
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
        let delegate = TransportDelegate(allowedOrigin: self.siteURL, logger: logger)
        self.delegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        URLSessionLifecycle.invalidate(session)
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
        lock.lock()
        let obsoleteRefresh = refreshTask
        refreshTask = nil
        refreshGeneration = nil
        tokenGeneration &+= 1
        tokens = new
        lock.unlock()
        obsoleteRefresh?.cancel()
        if let new {
            logger.registerSecret(new.accessToken)
            logger.registerSecret(new.refreshToken)
        }
        onTokensChanged?(new)
    }

    @discardableResult
    private func clearTokens(ifMatching expected: CloudreveTokens) -> Bool {
        lock.lock()
        guard tokens == expected else {
            lock.unlock()
            return false
        }
        let obsoleteRefresh = refreshTask
        refreshTask = nil
        refreshGeneration = nil
        tokenGeneration &+= 1
        tokens = nil
        lock.unlock()
        obsoleteRefresh?.cancel()
        onTokensChanged?(nil)
        return true
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
        guard response.code == CloudreveError.Code.checkLogin
                || response.code == CloudreveError.Code.accessTokenExpired
                || response.status == 401 else { return response }
        let (current, _) = snapshotTokenState()
        guard let current, !current.refreshTokenExpired else {
            if let current { clearTokens(ifMatching: current) }
            throw CloudreveError.authenticationRequired(response.message.isEmpty ? "Anmeldung erforderlich" : response.message)
        }
        logger.notice("cloudreve", "401 bei \(path) – Token wird erneuert")
        let rejectedAccessToken = request.value(forHTTPHeaderField: "Authorization")?
            .replacingOccurrences(of: "Bearer ", with: "")
        let refreshedAccessToken = try await refreshAccessToken(rejectedAccessToken: rejectedAccessToken)
        request.setValue("Bearer \(refreshedAccessToken)", forHTTPHeaderField: "Authorization")
        let retried = try await send(request, body: body, progress: progress)
        if retried.code == CloudreveError.Code.checkLogin
            || retried.code == CloudreveError.Code.accessTokenExpired
            || retried.status == 401 {
            let (latest, _) = snapshotTokenState()
            if let latest, latest.accessToken == refreshedAccessToken {
                clearTokens(ifMatching: latest)
            }
            throw CloudreveError.authenticationRequired(
                retried.message.isEmpty ? "Anmeldung erforderlich" : retried.message
            )
        }
        return retried
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
                    defer { if let id = holder.taskIdentifier { delegate.finishTask(taskIdentifier: id) } }
                    if let error {
                        continuation.resume(throwing: Self.mapTransportError(error))
                        return
                    }
                    if let id = holder.task?.taskIdentifier, delegate.wasRedirectRefused(taskIdentifier: id) {
                        continuation.resume(throwing: CloudreveError.network("Umleitung auf fremden Host abgelehnt"))
                        return
                    }
                    do {
                        continuation.resume(returning: try Self.parseResponse(data, response: response, path: path))
                    } catch {
                        continuation.resume(throwing: error)
                    }
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
            holder.cancel()
        }
    }

    /// Variante für einen einzelnen, vom Server verlangten ungeteilten Upload.
    /// `uploadTask(fromFile:)` hält auch große Dateien aus dem Arbeitsspeicher.
    private func sendFile(_ request: URLRequest, file: URL, progress: TransferProgress?) async throws -> APIResponse {
        let path = request.url?.path ?? "?"
        logger.debug("cloudreve", "\(request.httpMethod ?? "?") \(path)")
        let session = self.session
        let delegate = self.delegate
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<APIResponse, Error>) in
                let task = session.uploadTask(with: request, fromFile: file) { data, response, error in
                    defer { if let id = holder.taskIdentifier { delegate.finishTask(taskIdentifier: id) } }
                    if let error {
                        continuation.resume(throwing: Self.mapTransportError(error))
                        return
                    }
                    if let id = holder.task?.taskIdentifier, delegate.wasRedirectRefused(taskIdentifier: id) {
                        continuation.resume(throwing: CloudreveError.network("Umleitung auf fremden Host abgelehnt"))
                        return
                    }
                    do {
                        continuation.resume(returning: try Self.parseResponse(data, response: response, path: path))
                    } catch {
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

    private static func parseResponse(_ responseData: Data?, response: URLResponse?, path: String) throws -> APIResponse {
        guard let http = response as? HTTPURLResponse else {
            throw CloudreveError.invalidResponse("Keine HTTP-Antwort")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let data = responseData ?? Data()
        var code = http.statusCode == 200 ? 0 : http.statusCode
        var message = ""
        var payload: Any?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let parsedCode = json["code"] as? Int { code = parsedCode }
            message = (json["msg"] as? String) ?? ""
            payload = json["data"]
        } else if http.statusCode == 200 {
            throw CloudreveError.invalidResponse("Antwort ist kein JSON (\(path))")
        }
        return APIResponse(status: http.statusCode, code: code, message: message, data: payload, headers: headers)
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

    /// Wirft bei einem HTTP-Fehler oder `code != 0` den passenden Fehler.
    private func check(_ response: APIResponse, context: String) throws {
        guard (200..<300).contains(response.status) else {
            let effectiveCode = response.code == CloudreveError.Code.success ? response.status : response.code
            throw Self.error(code: effectiveCode, message: response.message, status: response.status, context: context)
        }
        guard response.code != CloudreveError.Code.success else { return }
        throw Self.error(code: response.code, message: response.message, status: response.status, context: context)
    }

    static func error(code: Int, message: String, status: Int, context: String) -> CloudreveError {
        let text = message.isEmpty ? context : message
        switch code {
        case CloudreveError.Code.checkLogin, CloudreveError.Code.credentialInvalid,
             CloudreveError.Code.invalidPassword,
             CloudreveError.Code.accessTokenExpired:
            return .authenticationRequired(text)
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
        let (current, _) = snapshotTokenState()
        guard let current else { throw CloudreveError.authenticationRequired("Nicht angemeldet") }
        if !current.accessTokenNeedsRefresh { return current.accessToken }
        if current.refreshTokenExpired {
            clearTokens(ifMatching: current)
            throw CloudreveError.authenticationRequired("Sitzung abgelaufen")
        }
        return try await refreshAccessToken()
    }

    private func snapshotTokenState() -> (CloudreveTokens?, Task<CloudreveTokens, Error>?) {
        lock.lock(); defer { lock.unlock() }
        return (tokens, refreshTask)
    }

    /// Teilt genau einen Refresh zwischen proaktiver Erneuerung und parallelen
    /// 401-Antworten. Hat eine andere Anfrage das abgelehnte Access-Token bereits
    /// ersetzt, wird dessen Ergebnis direkt verwendet.
    private func refreshAccessToken(rejectedAccessToken: String? = nil) async throws -> String {
        let decision = prepareRefresh(rejectedAccessToken: rejectedAccessToken)
        switch decision {
        case .useAccessToken(let access):
            return access
        case .unavailable(let message, let didClear):
            if didClear { onTokensChanged?(nil) }
            throw CloudreveError.authenticationRequired(message)
        case .run(let task, let refreshToken, let generation):
            do {
                let refreshed = try await task.value
                let completion = completeRefresh(refreshed, replacing: refreshToken, generation: generation)
                if completion.installed {
                    logger.registerSecret(refreshed.accessToken)
                    logger.registerSecret(refreshed.refreshToken)
                    onTokensChanged?(refreshed)
                    logger.info("cloudreve", "Access-Token erneuert (gültig bis \(refreshed.accessExpires))")
                }
                guard let access = completion.currentAccess else {
                    throw CloudreveError.authenticationRequired("Sitzung wurde beendet")
                }
                return access
            } catch {
                let invalidCredentials: Bool
                if let cloudreve = error as? CloudreveError,
                   case .authenticationRequired = cloudreve {
                    invalidCredentials = true
                } else {
                    invalidCredentials = false
                }
                if failRefresh(replacing: refreshToken, generation: generation, clearTokens: invalidCredentials) {
                    onTokensChanged?(nil)
                }
                if let cloudreve = error as? CloudreveError { throw cloudreve }
                throw CloudreveError.network(error.localizedDescription)
            }
        }
    }

    private enum RefreshDecision {
        case useAccessToken(String)
        case unavailable(message: String, didClear: Bool)
        case run(task: Task<CloudreveTokens, Error>, refreshToken: String, generation: UInt64)
    }

    private func prepareRefresh(rejectedAccessToken: String?) -> RefreshDecision {
        lock.lock(); defer { lock.unlock() }
        guard let current = tokens else {
            return .unavailable(message: "Nicht angemeldet", didClear: false)
        }
        if let rejectedAccessToken, current.accessToken != rejectedAccessToken {
            return .useAccessToken(current.accessToken)
        }
        if rejectedAccessToken == nil, !current.accessTokenNeedsRefresh {
            return .useAccessToken(current.accessToken)
        }
        guard !current.refreshTokenExpired else {
            tokens = nil
            return .unavailable(message: "Sitzung abgelaufen", didClear: true)
        }
        if let refreshTask {
            guard let refreshGeneration else {
                return .unavailable(message: "Token-Erneuerung hat einen ungültigen Zustand", didClear: false)
            }
            return .run(task: refreshTask, refreshToken: current.refreshToken, generation: refreshGeneration)
        }
        let refreshToken = current.refreshToken
        let generation = tokenGeneration
        let task = Task<CloudreveTokens, Error> { [weak self] in
            guard let self else { throw CloudreveError.cancelled }
            return try await self.performRefresh(using: refreshToken)
        }
        refreshTask = task
        refreshGeneration = generation
        return .run(task: task, refreshToken: refreshToken, generation: generation)
    }

    private func completeRefresh(_ refreshed: CloudreveTokens, replacing refreshToken: String, generation: UInt64)
        -> (currentAccess: String?, installed: Bool) {
        lock.lock(); defer { lock.unlock() }
        let shouldInstall = tokenGeneration == generation
            && refreshGeneration == generation
            && tokens?.refreshToken == refreshToken
        if shouldInstall {
            refreshTask = nil
            refreshGeneration = nil
            tokens = refreshed
            tokenGeneration &+= 1
        }
        return (tokens?.accessToken, shouldInstall)
    }

    private func failRefresh(replacing refreshToken: String, generation: UInt64, clearTokens: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard tokenGeneration == generation,
              refreshGeneration == generation,
              tokens?.refreshToken == refreshToken else { return false }
        refreshTask = nil
        refreshGeneration = nil
        if clearTokens {
            tokens = nil
            tokenGeneration &+= 1
        }
        return clearTokens
    }

    /// `POST /api/v4/session/token/refresh`, ohne gemeinsam genutzten Zustand
    /// selbst zu überschreiben.
    private func performRefresh(using refreshToken: String) async throws -> CloudreveTokens {
        let response = try await send(request("POST", "session/token/refresh", json: ["refresh_token": refreshToken], authorized: false))
        if response.code != 0 {
            throw Self.error(
                code: response.code,
                message: response.message,
                status: response.status,
                context: "Token-Erneuerung"
            )
        }
        return try Self.parseTokens(from: response.data, nested: false)
    }

    // MARK: - WebDAV-Konten

    /// `GET /api/v4/devices/dav` (alle Seiten).
    public func listDavAccounts() async throws -> [CloudreveDavAccount] {
        var accounts: [CloudreveDavAccount] = []
        var nextToken: String?
        var seenTokens: Set<String> = []
        var pages = 0
        repeat {
            pages += 1
            guard pages <= 10_000 else { throw CloudreveError.invalidResponse("WebDAV-Konten: zu viele Seiten") }
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let nextToken { query.append(URLQueryItem(name: "next_page_token", value: nextToken)) }
            let response = try await sendAuthorized("GET", "devices/dav", query: query)
            try check(response, context: "WebDAV-Konten")
            guard let data = response.data as? [String: Any],
                  let rawAccounts = data["accounts"] as? [[String: Any]],
                  let pagination = data["pagination"] as? [String: Any],
                  let isCursor = pagination["is_cursor"] as? Bool else {
                throw CloudreveError.invalidResponse("WebDAV-Konten: Seite unvollständig")
            }
            let token: String
            if let rawToken = pagination["next_token"] {
                guard let value = rawToken as? String else {
                    throw CloudreveError.invalidResponse("WebDAV-Konten: ungültiges next_token")
                }
                token = value
            } else {
                // Cloudreve lässt next_token auf der letzten Seite weg.
                token = ""
            }
            for raw in rawAccounts {
                guard let account = Self.parseDavAccount(raw) else {
                    throw CloudreveError.invalidResponse("WebDAV-Konten: ungültiger Eintrag")
                }
                accounts.append(account)
            }
            if !token.isEmpty {
                guard isCursor, seenTokens.insert(token).inserted else {
                    throw CloudreveError.invalidResponse("WebDAV-Konten: zyklische oder ungültige Seitennavigation")
                }
                nextToken = token
            } else {
                nextToken = nil
            }
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

    /// Widerruft ein WebDAV-Konto, das während einer fehlgeschlagenen
    /// Einrichtung bereits auf dem Server angelegt wurde.
    public func deleteDavAccount(id: String) async throws {
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }) else {
            throw CloudreveError.invalidResponse("Ungültige WebDAV-Konto-ID")
        }
        let response = try await sendAuthorized("DELETE", "devices/dav/\(id)")
        try check(response, context: "WebDAV-Konto löschen")
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
        guard let link = response.data as? String, let url = Self.validatedShareURL(link) else {
            throw CloudreveError.invalidResponse("Freigabe ohne Link")
        }
        return url
    }

    /// `GET /api/v4/share` – eigene Freigaben (alle Seiten).
    public func listShares() async throws -> [CloudreveShare] {
        var shares: [CloudreveShare] = []
        var nextToken: String?
        var seenTokens: Set<String> = []
        var pages = 0
        repeat {
            pages += 1
            guard pages <= 10_000 else { throw CloudreveError.invalidResponse("Freigaben: zu viele Seiten") }
            var query = [URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "order_by", value: "created_at"),
                         URLQueryItem(name: "order_direction", value: "desc")]
            if let nextToken { query.append(URLQueryItem(name: "next_page_token", value: nextToken)) }
            let response = try await sendAuthorized("GET", "share", query: query)
            try check(response, context: "Freigaben")
            guard let data = response.data as? [String: Any],
                  let rawShares = data["shares"] as? [[String: Any]],
                  let pagination = data["pagination"] as? [String: Any],
                  let isCursor = pagination["is_cursor"] as? Bool else {
                throw CloudreveError.invalidResponse("Freigaben: Seite unvollständig")
            }
            let token: String
            if let rawToken = pagination["next_token"] {
                guard let value = rawToken as? String else {
                    throw CloudreveError.invalidResponse("Freigaben: ungültiges next_token")
                }
                token = value
            } else {
                token = ""
            }
            for raw in rawShares {
                guard let share = Self.parseShare(raw) else {
                    throw CloudreveError.invalidResponse("Freigaben: ungültiger Eintrag")
                }
                shares.append(share)
            }
            if !token.isEmpty {
                guard isCursor, seenTokens.insert(token).inserted else {
                    throw CloudreveError.invalidResponse("Freigaben: zyklische oder ungültige Seitennavigation")
                }
                nextToken = token
            } else {
                nextToken = nil
            }
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
        guard let id = raw["id"] as? String,
              let link = raw["url"] as? String,
              let url = validatedShareURL(link) else { return nil }
        return CloudreveShare(id: id, name: raw["name"] as? String ?? "", url: url, sourceURI: raw["source_uri"] as? String,
                              isPrivate: raw["is_private"] as? Bool ?? (raw["password_protected"] as? Bool ?? false),
                              password: raw["password"] as? String, expires: parseDate(raw["expires"]), expired: raw["expired"] as? Bool ?? false,
                              visited: raw["visited"] as? Int ?? 0, downloaded: raw["downloaded"] as? Int ?? 0,
                              remainDownloads: raw["remain_downloads"] as? Int, isFolder: (raw["source_type"] as? Int) == 1,
                              createdAt: parseDate(raw["created_at"]))
    }

    private static func validatedShareURL(_ text: String) -> URL? {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
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
                                            maxSize: (policyRaw["max_size"] as? NSNumber)?.int64Value ?? 0,
                                            encryption: policyRaw["encryption"] as? Bool ?? false)
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

    /// Lädt bei einer Cloudreve-Sitzung mit `chunk_size == 0` die vollständige
    /// Datei als genau einen Chunk, ohne sie in den Arbeitsspeicher einzulesen.
    public func uploadSingleFile(_ file: URL, size: Int64, session uploadSession: CloudreveUploadSession,
                                 progress: TransferProgress?) async throws {
        guard uploadSession.usesLocalChunkAPI else {
            throw CloudreveError.unsupportedStoragePolicy(uploadSession.policy.type)
        }
        var uploadRequest = try await request(
            "POST",
            "file/upload/\(uploadSession.sessionID)/0",
            authorized: true
        )
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue(String(size), forHTTPHeaderField: "Content-Length")

        var response = try await sendFile(uploadRequest, file: file, progress: progress)
        if response.code == CloudreveError.Code.checkLogin
            || response.code == CloudreveError.Code.accessTokenExpired
            || response.status == 401 {
            let (current, _) = snapshotTokenState()
            guard let current, !current.refreshTokenExpired else {
                if let current { clearTokens(ifMatching: current) }
                throw CloudreveError.authenticationRequired(
                    response.message.isEmpty ? "Anmeldung erforderlich" : response.message
                )
            }
            let rejectedAccessToken = uploadRequest.value(forHTTPHeaderField: "Authorization")?
                .replacingOccurrences(of: "Bearer ", with: "")
            let refreshedAccessToken = try await refreshAccessToken(rejectedAccessToken: rejectedAccessToken)
            uploadRequest.setValue("Bearer \(refreshedAccessToken)", forHTTPHeaderField: "Authorization")
            response = try await sendFile(uploadRequest, file: file, progress: progress)
            if response.code == CloudreveError.Code.checkLogin
                || response.code == CloudreveError.Code.accessTokenExpired
                || response.status == 401 {
                let (latest, _) = snapshotTokenState()
                if let latest, latest.accessToken == refreshedAccessToken {
                    clearTokens(ifMatching: latest)
                }
                throw CloudreveError.authenticationRequired(
                    response.message.isEmpty ? "Anmeldung erforderlich" : response.message
                )
            }
        }
        try check(response, context: "Ungeteilter Upload")
    }

    /// `DELETE /api/v4/file/upload` – verwirft eine Upload-Sitzung (Fehler werden nur protokolliert).
    public func deleteUploadSession(id: String, uri: String) async {
        do {
            let response = try await sendAuthorized("DELETE", "file/upload", json: ["id": id, "uri": uri])
            try check(response, context: "Upload-Sitzung löschen")
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
        let rootText = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: rootText.isEmpty ? "cloudreve://my/" : rootText),
              components.scheme?.lowercased() == "cloudreve",
              components.host?.lowercased() == "my",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else {
            throw CloudreveError.invalidResponse("Ungültige Cloudreve-Wurzel-URI")
        }
        let decodedRootPath = components.percentEncodedPath.removingPercentEncoding ?? components.path
        let rootSegments = try RelativePath.segments(of: decodedRootPath)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#+%")
        let encodedRoot = rootSegments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        let encodedPath = segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        let allSegments = encodedRoot + encodedPath
        return "cloudreve://my/" + allSegments.joined(separator: "/")
    }

    /// Erzeugt die Konto-Wurzel-URI aus einem Ordnerpfad wie `/Sync/Projekte` (leer = alle Dateien).
    public static func rootURI(folderPath: String) -> String {
        (try? validatedRootURI(folderPath: folderPath)) ?? "cloudreve://my/"
    }

    /// Prüfende Variante für Eingaben, die anschließend an den Server gesendet
    /// werden. Traversal und leere Zwischensegmente werden abgelehnt.
    public static func validatedRootURI(folderPath: String) throws -> String {
        let trimmed = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = try RelativePath.segments(of: trimmed)
        if segments.isEmpty { return "cloudreve://my/" }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#+%")
        let encoded = segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        return "cloudreve://my/" + encoded.joined(separator: "/")
    }

    /// Lesbarer Ordnerpfad aus einer URI (`cloudreve://my/Sync%20A` → `/Sync A`).
    public static func folderPath(from uri: String) -> String {
        guard let components = URLComponents(string: uri) else { return uri }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return path.isEmpty ? "/" : path
    }
}

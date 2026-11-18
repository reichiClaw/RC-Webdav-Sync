import Foundation

extension String {
    /// RFC 9110 `entity-tag`: Nur ein syntaktisch gültiges, nicht mit `W/`
    /// markiertes Tag darf als atomare Schreibvorbedingung verwendet werden.
    var isStrongHTTPETag: Bool {
        let bytes = Array(utf8)
        guard bytes.count >= 2, bytes.first == 0x22, bytes.last == 0x22 else { return false }
        return bytes.dropFirst().dropLast().allSatisfy { byte in
            byte == 0x21 || (0x23...0x7E).contains(byte) || byte >= 0x80
        }
    }
}

/// Eine Ressource aus einer `207 Multi-Status`-Antwort.
public struct DAVResource: Sendable, Hashable {
    /// Unverändertes `href` zur Origin-Prüfung.
    public var rawHref: String?
    /// Dekodierter Pfad aus `href` (ohne Host), z. B. `/remote.php/dav/files/u/Ordner/Datei.txt`.
    public var hrefPath: String
    /// HTTP-Status der Ressource selbst (bei `sync-collection` z. B. 404 für gelöschte Einträge).
    public var status: Int?
    public var isCollection: Bool
    public var etag: String?
    public var contentLength: Int64?
    public var lastModified: Date?
    public var contentType: String?
    /// Eigenschaften, die mit Status 200 geliefert wurden (lokaler Name → Wert).
    public var properties: [String: String]
    /// `supported-report-set` enthält `sync-collection`.
    public var supportsSyncCollection: Bool
    /// DAV-Properties aus erfolgreichen beziehungsweise fehlgeschlagenen
    /// `propstat`-Blöcken. Insbesondere muss `resourcetype` erfolgreich sein,
    /// bevor Datei/Ordner unterschieden werden dürfen.
    public var successfulProperties: Set<String>
    public var failedProperties: Set<String>
    public var propstatStatuses: [Int]

    public init(hrefPath: String, rawHref: String? = nil, status: Int? = nil, isCollection: Bool = false,
                etag: String? = nil, contentLength: Int64? = nil, lastModified: Date? = nil,
                contentType: String? = nil, properties: [String: String] = [:],
                supportsSyncCollection: Bool = false, successfulProperties: Set<String> = [],
                failedProperties: Set<String> = [], propstatStatuses: [Int] = []) {
        self.hrefPath = hrefPath
        self.rawHref = rawHref
        self.status = status
        self.isCollection = isCollection
        self.etag = etag
        self.contentLength = contentLength
        self.lastModified = lastModified
        self.contentType = contentType
        self.properties = properties
        self.supportsSyncCollection = supportsSyncCollection
        self.successfulProperties = successfulProperties
        self.failedProperties = failedProperties
        self.propstatStatuses = propstatStatuses
    }

    /// `true`, wenn ein syntaktisch gültiger starker HTTP-ETag vorliegt.
    public var hasStrongETag: Bool {
        etag?.isStrongHTTPETag == true
    }

    /// Validator für die Änderungserkennung: ETag oder Ersatz aus Datum und Größe.
    public var validator: String? {
        if let etag, !etag.isEmpty { return etag }
        if let lastModified {
            return "mtime:\(Int(lastModified.timeIntervalSince1970));size:\(contentLength ?? 0)"
        }
        return nil
    }
}

/// Ergebnis einer Multi-Status-Antwort.
public struct MultiStatusResponse: Sendable {
    public var resources: [DAVResource]
    /// Sync-Token (RFC 6578), falls vorhanden.
    public var syncToken: String?
    /// Strukturelle Probleme, bei denen eine Antwort nicht als vollständige
    /// Bestandsaufnahme verwendet werden darf.
    public var issues: [String]

    public init(resources: [DAVResource] = [], syncToken: String? = nil, issues: [String] = []) {
        self.resources = resources
        self.syncToken = syncToken
        self.issues = issues
    }
}

/// Erkanntes Serverprodukt (beeinflusst Verhaltensdetails).
public enum ServerKind: String, Sendable, Codable, Hashable {
    case generic
    case nextcloud
    case cloudreve
}

/// Erkannte Fähigkeiten eines WebDAV-Servers.
public struct WebDAVCapabilities: Sendable, Hashable, Codable {
    public var davClasses: Set<String>
    public var supportsSyncCollection: Bool
    public var providesETags: Bool
    public var strongETags: Bool
    public var serverSoftware: String?
    /// Hinweis, ob der Server vermutlich einen Papierkorb bietet (nur für bekannte Produkte).
    public var likelyHasServerTrash: Bool
    public var serverKind: ServerKind
    /// Ob der Server `If-Match` bei PUT/DELETE/MOVE tatsächlich auswertet. Cloudreve ignoriert
    /// den Header (TODO im Quellcode), daher wird dort vor jedem Schreibzugriff per PROPFIND geprüft.
    public var honorsIfMatch: Bool
    /// Serverversion, falls bekannt (z. B. Cloudreve-Ping).
    public var serverVersion: String?

    public init(davClasses: Set<String> = [], supportsSyncCollection: Bool = false, providesETags: Bool = false, strongETags: Bool = false,
                serverSoftware: String? = nil, likelyHasServerTrash: Bool = false, serverKind: ServerKind = .generic, honorsIfMatch: Bool = false,
                serverVersion: String? = nil) {
        self.davClasses = davClasses
        self.supportsSyncCollection = supportsSyncCollection
        self.providesETags = providesETags
        self.strongETags = strongETags
        self.serverSoftware = serverSoftware
        self.likelyHasServerTrash = likelyHasServerTrash
        self.serverKind = serverKind
        self.honorsIfMatch = honorsIfMatch
        self.serverVersion = serverVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        davClasses = try c.decodeIfPresent(Set<String>.self, forKey: .davClasses) ?? []
        supportsSyncCollection = try c.decodeIfPresent(Bool.self, forKey: .supportsSyncCollection) ?? false
        providesETags = try c.decodeIfPresent(Bool.self, forKey: .providesETags) ?? false
        strongETags = try c.decodeIfPresent(Bool.self, forKey: .strongETags) ?? false
        serverSoftware = try c.decodeIfPresent(String.self, forKey: .serverSoftware)
        likelyHasServerTrash = try c.decodeIfPresent(Bool.self, forKey: .likelyHasServerTrash) ?? false
        serverKind = try c.decodeIfPresent(ServerKind.self, forKey: .serverKind) ?? .generic
        honorsIfMatch = try c.decodeIfPresent(Bool.self, forKey: .honorsIfMatch) ?? false
        serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion)
    }

    /// Ob der Server bedingte Schreibzugriffe auswertet. Der konkrete Eintrag
    /// muss zusätzlich einen starken ETag besitzen.
    public var supportsConditionalWrites: Bool { honorsIfMatch }
}

/// Fehler des WebDAV-Clients.
public enum WebDAVError: Error, Sendable, Equatable {
    /// Server nicht erreichbar, DNS, Timeout, Verbindungsabbruch.
    case network(String)
    /// 401/403
    case authenticationRequired(status: Int)
    case forbidden(String)
    /// 404
    case notFound
    /// 412 Precondition Failed
    case preconditionFailed
    /// 409 (z. B. Elternordner fehlt) oder 405 (MKCOL auf vorhandene Ressource)
    case conflict(status: Int, String)
    /// 423 Locked
    case locked
    /// 507 Insufficient Storage
    case insufficientStorage
    /// Sync-Token ungültig (403 valid-sync-token / 410)
    case invalidSyncToken
    /// Unerwarteter Status
    case unexpectedStatus(Int, String)
    /// Antwort konnte nicht verarbeitet werden
    case invalidResponse(String)
    /// Die URL verwendet kein HTTPS und unsichere Verbindungen sind nicht erlaubt.
    case insecureURL
    /// Umleitung auf einen fremden Host wurde abgelehnt.
    case redirectRefused(String)
    case cancelled

    /// Verständliche Beschreibung für die Oberfläche.
    public var userDescription: String {
        switch self {
        case .network: return "Der Server ist zurzeit nicht erreichbar."
        case .authenticationRequired: return "Anmeldung erforderlich. Bitte Benutzername und Passwort prüfen."
        case .forbidden: return "Der Zugriff wurde vom Server verweigert."
        case .notFound: return "Die Datei oder der Ordner wurde auf dem Server nicht gefunden."
        case .preconditionFailed: return "Die Datei wurde auf dem Server zwischenzeitlich geändert."
        case .conflict: return "Der Server konnte die Änderung an dieser Stelle nicht übernehmen."
        case .locked: return "Die Datei ist auf dem Server gesperrt."
        case .insufficientStorage: return "Auf dem Server ist nicht genügend Speicherplatz frei."
        case .invalidSyncToken: return "Der Änderungsstand des Servers muss neu eingelesen werden."
        case .unexpectedStatus: return "Der Server hat unerwartet geantwortet."
        case .invalidResponse: return "Die Antwort des Servers konnte nicht verarbeitet werden."
        case .insecureURL: return "Die Adresse verwendet kein HTTPS. Unsichere Verbindungen sind deaktiviert."
        case .redirectRefused: return "Der Server hat auf eine fremde Adresse umgeleitet. Aus Sicherheitsgründen wurde abgebrochen."
        case .cancelled: return "Der Vorgang wurde abgebrochen."
        }
    }

    /// Technische Details für die Diagnoseansicht.
    public var technicalDescription: String {
        switch self {
        case .network(let s): return "Netzwerk: \(s)"
        case .authenticationRequired(let status): return "HTTP \(status)"
        case .forbidden(let s): return "HTTP 403: \(s)"
        case .notFound: return "HTTP 404"
        case .preconditionFailed: return "HTTP 412 Precondition Failed"
        case .conflict(let status, let s): return "HTTP \(status): \(s)"
        case .locked: return "HTTP 423 Locked"
        case .insufficientStorage: return "HTTP 507 Insufficient Storage"
        case .invalidSyncToken: return "Sync-Token ungültig"
        case .unexpectedStatus(let code, let s): return "HTTP \(code): \(s)"
        case .invalidResponse(let s): return "Ungültige Antwort: \(s)"
        case .insecureURL: return "Kein HTTPS"
        case .redirectRefused(let s): return "Redirect abgelehnt: \(s)"
        case .cancelled: return "Abgebrochen"
        }
    }

    public var suggestedAction: SuggestedAction {
        switch self {
        case .network: return .checkServer
        case .authenticationRequired: return .checkCredentials
        case .forbidden: return .checkServer
        case .preconditionFailed: return .retry
        case .insufficientStorage: return .freeDiskSpace
        case .locked, .conflict, .unexpectedStatus, .invalidResponse, .notFound, .invalidSyncToken: return .retry
        case .insecureURL, .redirectRefused: return .checkServer
        case .cancelled: return .none
        }
    }

    /// `true`, wenn der Fehler auf ein Verbindungsproblem hinweist (→ Offline-Zustand, Backoff).
    public var isConnectivityProblem: Bool {
        if case .network = self { return true }
        return false
    }

    /// `true`, wenn aus diesem Fehler keinesfalls Löschungen abgeleitet werden dürfen.
    public var forbidsDeletionInference: Bool { true }
}

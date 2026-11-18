import Foundation

/// Art des Servers, mit dem eine Verbindung eingerichtet wurde.
public enum AccountServerKind: String, Codable, Sendable, Hashable {
    /// Beliebiger WebDAV-Server (nur WebDAV-Funktionen).
    case webdav
    /// Cloudreve: WebDAV für Abgleich/Download, REST-API für Chunked/Resumable Uploads.
    case cloudreve
}

/// Konfiguration einer Verbindung.
///
/// Das Modell ist auf mehrere Verbindungen vorbereitet (eigene `id`), die erste
/// Version der App verwendet jedoch genau eine.
public struct AccountConfiguration: Codable, Sendable, Hashable, Identifiable {
    /// Standard-Server für neue Verbindungen.
    public static let defaultSiteURL = URL(string: "https://reichi.cloud")!
    /// Standardschwelle, ab der Uploads in Chunks (wiederaufnehmbar) übertragen werden.
    public static let defaultChunkedUploadThreshold: Int64 = 8 * 1024 * 1024

    public var id: String
    /// Frei wählbarer Name der Verbindung.
    public var name: String
    /// Vollständige WebDAV-Adresse des entfernten Ordners (z. B. `https://reichi.cloud/dav/` oder
    /// `https://cloud.example.org/remote.php/dav/files/user/Projekte/`).
    public var serverURL: URL
    /// WebDAV-Benutzername (bei Cloudreve die E-Mail-Adresse).
    public var username: String
    /// Lokaler Stammordner (Pfad). Der dauerhafte Zugriff wird in der App über ein
    /// Security-Scoped Bookmark hergestellt, das getrennt gespeichert wird.
    public var localRootPath: String
    /// Intervall für die Suche nach Serveränderungen in Sekunden.
    public var pollInterval: TimeInterval
    /// Benutzerdefinierte Ausschlussmuster (zusätzlich zu den Standardausschlüssen).
    public var exclusionPatterns: [String]
    /// Erlaubt `http://` für lokale Testserver. Standard: nur HTTPS.
    public var allowInsecureHTTP: Bool
    /// Schwelle für den Löschschutz (absolute Anzahl).
    public var deletionGuardThreshold: Int
    /// Schwelle für den Löschschutz (Anteil am bekannten Bestand, 0…1).
    public var deletionGuardFraction: Double
    /// Maximale parallele Übertragungen.
    public var maxConcurrentTransfers: Int
    public var notificationsEnabled: Bool
    public var createdAt: Date

    // MARK: Cloudreve

    public var serverKind: AccountServerKind
    /// Wurzel der Cloudreve-Site (z. B. `https://reichi.cloud`); REST-API unter `/api/v4`.
    public var cloudreveSiteURL: URL?
    /// E-Mail-Adresse des Cloudreve-Kontos (für API-Anmeldung).
    public var cloudreveEmail: String?
    /// ID des verwendeten WebDAV-Kontos in Cloudreve.
    public var davAccountID: String?
    /// Relative Wurzel des WebDAV-Kontos als Cloudreve-URI, z. B. `cloudreve://my/Sync`.
    /// Daraus werden die Datei-URIs für die Upload-API gebildet.
    public var davAccountURI: String?
    /// Große Dateien in Chunks über die Cloudreve-API hochladen (wiederaufnehmbar).
    public var chunkedUploadsEnabled: Bool
    /// Ab dieser Dateigröße (Bytes) wird der Chunk-Upload verwendet.
    public var chunkedUploadThreshold: Int64

    public init(id: String = UUID().uuidString, name: String, serverURL: URL, username: String, localRootPath: String,
                pollInterval: TimeInterval = 60, exclusionPatterns: [String] = [], allowInsecureHTTP: Bool = false,
                deletionGuardThreshold: Int = 25, deletionGuardFraction: Double = 0.2, maxConcurrentTransfers: Int = 3,
                notificationsEnabled: Bool = true, createdAt: Date = Date(),
                serverKind: AccountServerKind = .webdav, cloudreveSiteURL: URL? = nil, cloudreveEmail: String? = nil,
                davAccountID: String? = nil, davAccountURI: String? = nil, chunkedUploadsEnabled: Bool = true,
                chunkedUploadThreshold: Int64 = AccountConfiguration.defaultChunkedUploadThreshold) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.localRootPath = localRootPath
        self.pollInterval = pollInterval
        self.exclusionPatterns = exclusionPatterns
        self.allowInsecureHTTP = allowInsecureHTTP
        self.deletionGuardThreshold = deletionGuardThreshold
        self.deletionGuardFraction = deletionGuardFraction
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.notificationsEnabled = notificationsEnabled
        self.createdAt = createdAt
        self.serverKind = serverKind
        self.cloudreveSiteURL = cloudreveSiteURL
        self.cloudreveEmail = cloudreveEmail
        self.davAccountID = davAccountID
        self.davAccountURI = davAccountURI
        self.chunkedUploadsEnabled = chunkedUploadsEnabled
        self.chunkedUploadThreshold = chunkedUploadThreshold
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        serverURL = try c.decode(URL.self, forKey: .serverURL)
        username = try c.decode(String.self, forKey: .username)
        localRootPath = try c.decode(String.self, forKey: .localRootPath)
        pollInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? 60
        exclusionPatterns = try c.decodeIfPresent([String].self, forKey: .exclusionPatterns) ?? []
        allowInsecureHTTP = try c.decodeIfPresent(Bool.self, forKey: .allowInsecureHTTP) ?? false
        deletionGuardThreshold = try c.decodeIfPresent(Int.self, forKey: .deletionGuardThreshold) ?? 25
        deletionGuardFraction = try c.decodeIfPresent(Double.self, forKey: .deletionGuardFraction) ?? 0.2
        maxConcurrentTransfers = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentTransfers) ?? 3
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        serverKind = try c.decodeIfPresent(AccountServerKind.self, forKey: .serverKind) ?? .webdav
        cloudreveSiteURL = try c.decodeIfPresent(URL.self, forKey: .cloudreveSiteURL)
        cloudreveEmail = try c.decodeIfPresent(String.self, forKey: .cloudreveEmail)
        davAccountID = try c.decodeIfPresent(String.self, forKey: .davAccountID)
        davAccountURI = try c.decodeIfPresent(String.self, forKey: .davAccountURI)
        chunkedUploadsEnabled = try c.decodeIfPresent(Bool.self, forKey: .chunkedUploadsEnabled) ?? true
        chunkedUploadThreshold = try c.decodeIfPresent(Int64.self, forKey: .chunkedUploadThreshold) ?? AccountConfiguration.defaultChunkedUploadThreshold
    }

    /// Cloudreve-Konfiguration vollständig (Site, E-Mail, WebDAV-Konto bekannt)?
    public var isCloudreve: Bool { serverKind == .cloudreve && cloudreveSiteURL != nil }

    /// Eindeutiger Schlüssel der Zuordnung „Server-Ordner ↔ lokaler Ordner“.
    /// Ändert sich Server-URL oder lokaler Stammordner, entsteht eine neue
    /// Zuordnung mit leerem Synchronisierungsstand.
    public var mappingKey: String {
        let server = serverURL.absoluteString.hasSuffix("/") ? serverURL.absoluteString : serverURL.absoluteString + "/"
        return "\(server)|\(localRootPath)"
    }
}

/// Zuordnung zwischen Server-Ordner und lokalem Ordner mit eigenem Synchronisierungsstand.
public struct SyncMapping: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var accountID: String
    public var mappingKey: String
    public var createdAt: Date
    public var lastSuccessfulSync: Date?
    public var syncToken: String?
    /// `true`, wenn der zwischengespeicherte Serverbestand (für Sync-Collection) vollständig ist.
    public var remoteIndexIsComplete: Bool

    public init(id: String = UUID().uuidString, accountID: String, mappingKey: String, createdAt: Date = Date(),
                lastSuccessfulSync: Date? = nil, syncToken: String? = nil, remoteIndexIsComplete: Bool = false) {
        self.id = id
        self.accountID = accountID
        self.mappingKey = mappingKey
        self.createdAt = createdAt
        self.lastSuccessfulSync = lastSuccessfulSync
        self.syncToken = syncToken
        self.remoteIndexIsComplete = remoteIndexIsComplete
    }
}

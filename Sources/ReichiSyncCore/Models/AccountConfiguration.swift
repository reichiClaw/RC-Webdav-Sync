import Foundation

/// Konfiguration einer WebDAV-Verbindung.
///
/// Das Modell ist auf mehrere Verbindungen vorbereitet (eigene `id`), die erste
/// Version der App verwendet jedoch genau eine.
public struct AccountConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Frei wählbarer Name der Verbindung.
    public var name: String
    /// Vollständige WebDAV-Adresse des entfernten Ordners (z. B. `https://cloud.example.org/remote.php/dav/files/user/Projekte/`).
    public var serverURL: URL
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

    public init(id: String = UUID().uuidString, name: String, serverURL: URL, username: String, localRootPath: String,
                pollInterval: TimeInterval = 60, exclusionPatterns: [String] = [], allowInsecureHTTP: Bool = false,
                deletionGuardThreshold: Int = 25, deletionGuardFraction: Double = 0.2, maxConcurrentTransfers: Int = 3,
                notificationsEnabled: Bool = true, createdAt: Date = Date()) {
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
    }

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

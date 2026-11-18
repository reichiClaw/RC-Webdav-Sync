import Foundation

/// Art eines synchronisierten Eintrags.
public enum ItemKind: String, Codable, Sendable, Hashable {
    case file
    case directory
}

/// Eintrag des zuletzt erfolgreich synchronisierten gemeinsamen Standes („Baseline“).
///
/// Der Pfad ist ein NFC-normalisierter, mit „/“ getrennter relativer Pfad ohne
/// führenden oder abschließenden Schrägstrich.
public struct BaselineEntry: Codable, Sendable, Hashable {
    public var path: String
    public var kind: ItemKind
    /// SHA-256 (hex) des lokalen Inhalts zum Zeitpunkt der Synchronisierung. Für Ordner `nil`.
    public var localHash: String?
    public var localSize: Int64
    /// Änderungszeit in Sekunden seit 1970 (zur Wiederverwendung des Hash-Caches).
    public var localModified: Double
    /// Undurchsichtiger Server-Validator (ETag oder Ersatzvalidator).
    public var remoteValidator: String?
    /// `true`, wenn der Validator ein starker ETag ist.
    public var remoteValidatorIsStrong: Bool
    public var remoteSize: Int64
    public var remoteModified: Double?
    public var syncedAt: Date

    public init(path: String, kind: ItemKind, localHash: String?, localSize: Int64, localModified: Double,
                remoteValidator: String?, remoteValidatorIsStrong: Bool, remoteSize: Int64,
                remoteModified: Double?, syncedAt: Date = Date()) {
        self.path = path
        self.kind = kind
        self.localHash = localHash
        self.localSize = localSize
        self.localModified = localModified
        self.remoteValidator = remoteValidator
        self.remoteValidatorIsStrong = remoteValidatorIsStrong
        self.remoteSize = remoteSize
        self.remoteModified = remoteModified
        self.syncedAt = syncedAt
    }
}

/// Ein Element der aktuellen lokalen Bestandsaufnahme.
public struct LocalItem: Sendable, Hashable {
    /// Normalisierter Schlüsselpfad (NFC).
    public var path: String
    /// Tatsächlicher relativer Pfad im Dateisystem (Bytes wie vorgefunden).
    public var rawPath: String
    public var kind: ItemKind
    public var size: Int64
    public var modified: Double
    /// SHA-256 (hex) des Inhalts. Für Ordner `nil`.
    public var hash: String?

    public init(path: String, rawPath: String? = nil, kind: ItemKind, size: Int64 = 0, modified: Double = 0, hash: String? = nil) {
        self.path = path
        self.rawPath = rawPath ?? path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.hash = hash
    }
}

/// Ergebnis einer lokalen Bestandsaufnahme.
public struct LocalSnapshot: Sendable {
    public var items: [String: LocalItem]
    /// `true`, wenn der gesamte Baum erfolgreich gelesen wurde.
    public var isComplete: Bool
    /// Pfade, die wegen aktueller Schreibvorgänge übersprungen wurden.
    public var busyPaths: Set<String>
    /// Symbolische Links und andere nicht unterstützte Einträge.
    public var skippedPaths: [String: String]

    public init(items: [String: LocalItem] = [:], isComplete: Bool = true, busyPaths: Set<String> = [], skippedPaths: [String: String] = [:]) {
        self.items = items
        self.isComplete = isComplete
        self.busyPaths = busyPaths
        self.skippedPaths = skippedPaths
    }
}

/// Ein Element der aktuellen Server-Bestandsaufnahme.
public struct RemoteItem: Sendable, Hashable {
    /// Normalisierter Schlüsselpfad (NFC).
    public var path: String
    /// Pfad genau so, wie der Server ihn kennt (für URL-Bildung).
    public var rawPath: String
    public var kind: ItemKind
    public var size: Int64
    public var modified: Double?
    /// ETag oder – falls keiner vorhanden – Ersatzvalidator aus Änderungsdatum und Größe.
    public var validator: String?
    public var validatorIsStrong: Bool
    public var contentType: String?

    public init(path: String, rawPath: String? = nil, kind: ItemKind, size: Int64 = 0, modified: Double? = nil,
                validator: String? = nil, validatorIsStrong: Bool = false, contentType: String? = nil) {
        self.path = path
        self.rawPath = rawPath ?? path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.validator = validator
        self.validatorIsStrong = validatorIsStrong
        self.contentType = contentType
    }
}

/// Ergebnis einer Server-Bestandsaufnahme.
public struct RemoteSnapshot: Sendable {
    public var items: [String: RemoteItem]
    /// `true`, wenn alle Verzeichnisse erfolgreich aufgelistet wurden.
    public var isComplete: Bool
    /// Verzeichnispräfixe, deren Auflistung fehlgeschlagen ist. Unterhalb dieser
    /// Präfixe dürfen keine Löschungen abgeleitet werden.
    public var failedPrefixes: Set<String>
    /// Verschiedene Serverpfade, die nach Unicode-Normalisierung denselben
    /// lokalen Schlüssel ergeben und deshalb nicht verlustfrei abbildbar sind.
    public var collisions: [String]
    /// Neuer Sync-Token (RFC 6578), falls der Server einen geliefert hat.
    public var syncToken: String?

    public init(items: [String: RemoteItem] = [:], isComplete: Bool = true, failedPrefixes: Set<String> = [],
                collisions: [String] = [], syncToken: String? = nil) {
        self.items = items
        self.isComplete = isComplete
        self.failedPrefixes = failedPrefixes
        self.collisions = collisions
        self.syncToken = syncToken
    }

    /// Prüft, ob ein Pfad in einem Bereich liegt, dessen Auflistung fehlgeschlagen ist.
    public func isUnderFailedPrefix(_ path: String) -> Bool {
        for prefix in failedPrefixes {
            if prefix.isEmpty { return true }
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }
        return false
    }
}

/// Richtung einer Übertragung.
public enum TransferDirection: String, Codable, Sendable {
    case upload
    case download
    case remoteDelete
    case localDelete
    case remoteMove
    case localMove
    case mkdirLocal
    case mkdirRemote
}

/// Zustand einer Übertragung in der Aktivitätsansicht.
public enum TransferState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case skipped
    case cancelled
}

/// Protokolleintrag einer Übertragung.
public struct TransferRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var path: String
    public var direction: TransferDirection
    public var state: TransferState
    public var bytesTotal: Int64
    public var bytesDone: Int64
    public var startedAt: Date
    public var finishedAt: Date?
    /// Verständliche Beschreibung des Fehlers.
    public var errorMessage: String?
    /// Technische Details (HTTP-Status, URL-Pfad usw.) für die Diagnoseansicht.
    public var errorDetail: String?
    /// Vorgeschlagene Aktion für den Benutzer.
    public var suggestedAction: SuggestedAction?

    public init(id: String = UUID().uuidString, path: String, direction: TransferDirection, state: TransferState = .queued,
                bytesTotal: Int64 = 0, bytesDone: Int64 = 0, startedAt: Date = Date(), finishedAt: Date? = nil,
                errorMessage: String? = nil, errorDetail: String? = nil, suggestedAction: SuggestedAction? = nil) {
        self.id = id
        self.path = path
        self.direction = direction
        self.state = state
        self.bytesTotal = bytesTotal
        self.bytesDone = bytesDone
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.errorDetail = errorDetail
        self.suggestedAction = suggestedAction
    }
}

/// Handlungsvorschlag für die Oberfläche.
public enum SuggestedAction: String, Codable, Sendable {
    case retry
    case checkCredentials
    case checkServer
    case freeDiskSpace
    case resolveConflict
    case renameFile
    case none
}

/// Grund eines Konflikts.
public enum ConflictReason: String, Codable, Sendable {
    /// Beide Seiten haben unterschiedlichen Inhalt.
    case bothModified
    /// Lokal gelöscht, auf dem Server geändert (Serverversion wurde erhalten).
    case deletedLocallyModifiedRemotely
    /// Lokal geändert, auf dem Server gelöscht (lokale Version wurde erhalten).
    case modifiedLocallyDeletedRemotely
    /// Datei auf einer Seite, Ordner auf der anderen.
    case kindMismatch
    /// Beim ersten Abgleich: gleichnamige Dateien mit unterschiedlichem Inhalt.
    case initialMergeDiffers
}

/// Zustand eines Konflikts.
public enum ConflictStatus: String, Codable, Sendable {
    case open
    case resolved
}

/// Entscheidung des Benutzers zu einem Konflikt.
public enum ConflictResolution: String, Codable, Sendable {
    case keepBoth
    case useLocal
    case useRemote
    /// Nur bei Lösch-Konflikten: Löschung trotz Änderung übernehmen.
    case applyDeletion
}

/// Ein Konflikt, der eine Benutzerentscheidung benötigt.
public struct ConflictRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var path: String
    public var kind: ItemKind
    public var reason: ConflictReason
    public var localHash: String?
    public var localSize: Int64?
    public var localModified: Double?
    public var remoteValidator: String?
    public var remoteSize: Int64?
    public var remoteModified: Double?
    /// Relativer Pfad einer bereits angelegten Konfliktkopie (falls vorhanden).
    public var conflictCopyPath: String?
    public var detectedAt: Date
    public var status: ConflictStatus
    public var resolution: ConflictResolution?

    public init(id: String = UUID().uuidString, path: String, kind: ItemKind, reason: ConflictReason,
                localHash: String? = nil, localSize: Int64? = nil, localModified: Double? = nil,
                remoteValidator: String? = nil, remoteSize: Int64? = nil, remoteModified: Double? = nil,
                conflictCopyPath: String? = nil, detectedAt: Date = Date(), status: ConflictStatus = .open,
                resolution: ConflictResolution? = nil) {
        self.id = id
        self.path = path
        self.kind = kind
        self.reason = reason
        self.localHash = localHash
        self.localSize = localSize
        self.localModified = localModified
        self.remoteValidator = remoteValidator
        self.remoteSize = remoteSize
        self.remoteModified = remoteModified
        self.conflictCopyPath = conflictCopyPath
        self.detectedAt = detectedAt
        self.status = status
        self.resolution = resolution
    }
}

/// Eine geplante Löschung, die auf Bestätigung wartet (Schutz vor großen Löschmengen).
public struct PendingDeletion: Codable, Sendable, Identifiable, Hashable {
    public enum Side: String, Codable, Sendable, Hashable { case local, remote }
    public var id: String { side.rawValue + ":" + path }
    public var path: String
    public var kind: ItemKind
    public var side: Side
    public var plannedAt: Date

    public init(path: String, kind: ItemKind, side: Side, plannedAt: Date = Date()) {
        self.path = path
        self.kind = kind
        self.side = side
        self.plannedAt = plannedAt
    }
}

/// Einmalige Freigabe für genau die geplante Seite und Art einer Löschung.
/// Der Pfad allein reicht nicht: Zwischen Planung und Bestätigung kann sich die
/// Löschrichtung ändern.
public struct DeletionAuthorization: Sendable, Hashable {
    public var path: String
    public var kind: ItemKind
    public var side: PendingDeletion.Side

    public init(path: String, kind: ItemKind, side: PendingDeletion.Side) {
        self.path = path
        self.kind = kind
        self.side = side
    }

    public init(_ pending: PendingDeletion) {
        self.init(path: pending.path, kind: pending.kind, side: pending.side)
    }
}

/// Eintrag der ausstehenden Warteschlange (für Anzeige und Wiederaufnahme).
public struct QueuedItem: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path + "|" + direction.rawValue }
    public var path: String
    public var direction: TransferDirection
    public var size: Int64
    public var createdAt: Date

    public init(path: String, direction: TransferDirection, size: Int64 = 0, createdAt: Date = Date()) {
        self.path = path
        self.direction = direction
        self.size = size
        self.createdAt = createdAt
    }
}

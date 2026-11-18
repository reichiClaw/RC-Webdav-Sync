import Foundation

/// Grobzustand für Menüleiste und Übersicht.
public enum SyncHealth: String, Sendable, Codable {
    /// Keine ausstehenden Änderungen, keine Konflikte, keine Fehler.
    case synced
    case syncing
    case offline
    case paused
    case conflicts
    /// Fehler, Anmeldung erforderlich oder Bestätigung nötig.
    case attention
    case setupRequired
}

/// Grund einer Pause.
public enum PauseReason: String, Sendable, Codable {
    case user
    case localRootMissing
    case diskFull
    case authenticationRequired
}

/// Ein Problem mit verständlicher Beschreibung und technischen Details.
public struct SyncIssue: Sendable, Equatable, Codable, Hashable {
    public var message: String
    public var detail: String?
    public var action: SuggestedAction
    public var date: Date

    public init(message: String, detail: String? = nil, action: SuggestedAction = .none, date: Date = Date()) {
        self.message = message
        self.detail = detail
        self.action = action
        self.date = date
    }
}

/// Vollständiger Statusbericht der Engine.
public struct SyncStatus: Sendable, Equatable {
    public var health: SyncHealth = .setupRequired
    public var isRunning = false
    public var isPaused = false
    public var pauseReason: PauseReason?
    public var lastSuccessfulSync: Date?
    public var lastAttempt: Date?
    /// Ausstehende Übertragungen (geplant, aber noch nicht erfolgreich).
    public var pendingCount = 0
    public var pendingBytes: Int64 = 0
    /// Fortschritt des laufenden Durchgangs.
    public var completedCount = 0
    public var totalCount = 0
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var activeTransfers: [TransferRecord] = []
    public var openConflicts = 0
    public var pendingDeletions = 0
    public var skippedCount = 0
    public var lastIssue: SyncIssue?
    public var nextRetry: Date?
    public var capabilities: WebDAVCapabilities?
    public var currentStep: String?

    public init() {}

    /// Kurzbeschreibung für Menüleiste und Übersicht.
    public var headline: String {
        switch health {
        case .synced: return "Synchronisiert"
        case .syncing: return currentStep ?? "Synchronisierung läuft"
        case .offline: return "Server nicht erreichbar"
        case .paused:
            switch pauseReason {
            case .localRootMissing: return "Pausiert – lokaler Ordner nicht verfügbar"
            case .diskFull: return "Pausiert – zu wenig Speicherplatz"
            case .authenticationRequired: return "Anmeldung erforderlich"
            default: return "Pausiert"
            }
        case .conflicts: return openConflicts == 1 ? "1 Konflikt wartet auf Entscheidung" : "\(openConflicts) Konflikte warten auf Entscheidung"
        case .attention:
            if pendingDeletions > 0 { return "Löschungen warten auf Bestätigung" }
            return lastIssue?.message ?? "Aufmerksamkeit erforderlich"
        case .setupRequired: return "Einrichtung erforderlich"
        }
    }

    /// Fortschritt 0…1 des laufenden Durchgangs.
    public var progressFraction: Double? {
        guard isRunning else { return nil }
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if totalCount > 0 { return min(1, Double(completedCount) / Double(totalCount)) }
        return nil
    }
}

/// Ereignisse für Benachrichtigungen.
public enum SyncEvent: Sendable, Equatable {
    case syncCompleted(transferred: Int, failed: Int)
    case conflictDetected(path: String)
    case deletionConfirmationRequired(count: Int)
    case authenticationRequired
    case diskFull
    case wentOffline
    case cameOnline
}

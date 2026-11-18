import SwiftUI
import ReichiSyncCore

/// Farbliche Zuordnung der Zustände (immer zusammen mit Symbol und Text verwendet).
extension SyncHealth {
    var tint: Color {
        switch self {
        case .synced: return .green
        case .syncing: return .accentColor
        case .offline: return .secondary
        case .paused: return .secondary
        case .conflicts: return .orange
        case .attention: return .orange
        case .setupRequired: return .accentColor
        }
    }
}

/// Große Statusanzeige mit Symbol, Überschrift und Detailtext.
struct StatusHeader: View {
    let status: SyncStatus
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 10 : 14) {
            Image(systemName: status.statusSymbol)
                .font(.system(size: compact ? 26 : 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(status.health.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: status.health == .syncing)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.headline)
                    .font(compact ? .headline : .title2.weight(.semibold))
                if let detail = detailText {
                    Text(detail)
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fraction = status.progressFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: compact ? 220 : 320)
                        .padding(.top, 4)
                        .accessibilityLabel("Fortschritt")
                        .accessibilityValue("\(Int(fraction * 100)) Prozent")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.accessibilityDescription)
    }

    private var detailText: String? {
        switch status.health {
        case .synced:
            return "Letzter Abgleich \(Formatters.relative(status.lastSuccessfulSync))"
        case .syncing:
            if status.totalCount > 0 {
                var text = "\(status.completedCount) von \(status.totalCount) Übertragungen"
                if status.bytesTotal > 0 {
                    text += " · \(Formatters.bytes.string(fromByteCount: status.bytesDone)) von \(Formatters.bytes.string(fromByteCount: status.bytesTotal))"
                }
                return text
            }
            return nil
        case .offline:
            if let retry = status.nextRetry {
                return "Lokale Dateien bleiben verfügbar. Nächster Versuch \(Formatters.relative(retry))."
            }
            return "Lokale Dateien bleiben verfügbar. Die Synchronisierung wird automatisch fortgesetzt."
        case .paused:
            return status.lastIssue?.message ?? "Änderungen werden gesammelt und nach dem Fortsetzen übertragen."
        case .conflicts:
            return "Beide Versionen wurden erhalten. Bitte im Bereich „Konflikte“ entscheiden."
        case .attention:
            if status.pendingDeletions > 0 {
                return "\(status.pendingDeletions) Einträge würden gelöscht. Bitte prüfen und bestätigen."
            }
            if status.pendingCount > 0 && status.lastIssue == nil {
                return "\(status.pendingCount) Übertragungen stehen noch aus."
            }
            return status.lastIssue?.message
        case .setupRequired:
            return "Richte eine WebDAV-Verbindung ein, um zu beginnen."
        }
    }
}

/// Eine Zeile „Bezeichnung – Wert“.
struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// Kennzahl mit Symbol für die Übersicht.
struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// Aufklappbare Diagnose mit technischen Details und Protokoll.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let issue = model.status.lastIssue, let detail = issue.detail {
                    InfoRow(label: "Letzter Fehler (technisch)", value: detail, monospaced: true)
                }
                if let caps = model.status.capabilities {
                    InfoRow(label: "Server", value: caps.serverSoftware ?? "unbekannt")
                    InfoRow(label: "DAV-Klassen", value: caps.davClasses.sorted().joined(separator: ", ").ifEmpty("–"))
                    InfoRow(label: "WebDAV-Sync (RFC 6578)", value: caps.supportsSyncCollection ? "unterstützt" : "nicht unterstützt – vollständige Bestandsaufnahme")
                    InfoRow(label: "ETags", value: caps.strongETags ? "stark – bedingte Schreibzugriffe aktiv" : (caps.providesETags ? "schwach – Prüfung vor jedem Schreibzugriff" : "keine – Ersatzvalidator aus Datum und Größe"))
                    InfoRow(label: "Serverseitiger Papierkorb", value: caps.likelyHasServerTrash ? "vermutlich vorhanden (Nextcloud/ownCloud)" : "unbekannt – keine Wiederherstellung auf dem Server zugesichert")
                }
                InfoRow(label: "Datenbank", value: AppPaths.database.path, monospaced: true)
                InfoRow(label: "Protokoll", value: AppPaths.logFile.path, monospaced: true)
                InfoRow(label: "Wiederherstellungsbereich", value: AppPaths.recovery.path, monospaced: true)
                Divider()
                Text("Protokoll (letzte Einträge)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.logEntries.suffix(200).reversed()) { entry in
                            Text("\(entry.date.formatted(date: .omitted, time: .standard)) [\(entry.level.rawValue)] \(entry.category): \(entry.message)")
                                .font(.caption.monospaced())
                                .foregroundStyle(entry.level >= .warning ? .orange : .secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 180)
                HStack {
                    Button("Protokollordner öffnen") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logFile])
                    }
                    Button("Wiederherstellungsbereich öffnen") {
                        try? FileManager.default.createDirectory(at: AppPaths.recovery, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(AppPaths.recovery)
                    }
                }
                .controlSize(.small)
            }
            .padding(.top, 6)
        } label: {
            Label("Diagnose", systemImage: "stethoscope")
                .font(.headline)
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension TransferDirection {
    var symbol: String {
        switch self {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .remoteDelete: return "trash"
        case .localDelete: return "trash"
        case .remoteMove, .localMove: return "arrow.turn.down.right"
        case .mkdirLocal, .mkdirRemote: return "folder.badge.plus"
        }
    }

    var title: String {
        switch self {
        case .upload: return "Hochladen"
        case .download: return "Herunterladen"
        case .remoteDelete: return "Auf dem Server löschen"
        case .localDelete: return "Lokal entfernen"
        case .remoteMove: return "Auf dem Server umbenennen"
        case .localMove: return "Lokal umbenennen"
        case .mkdirLocal: return "Ordner lokal anlegen"
        case .mkdirRemote: return "Ordner auf dem Server anlegen"
        }
    }
}

extension TransferState {
    var title: String {
        switch self {
        case .queued: return "Wartet"
        case .running: return "Läuft"
        case .succeeded: return "Erledigt"
        case .failed: return "Fehlgeschlagen"
        case .skipped: return "Zurückgestellt"
        case .cancelled: return "Abgebrochen"
        }
    }

    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "arrow.uturn.forward.circle"
        case .cancelled: return "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .queued, .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .skipped, .cancelled: return .secondary
        }
    }
}

extension SuggestedAction {
    var title: String? {
        switch self {
        case .retry: return "Erneut versuchen"
        case .checkCredentials: return "Zugangsdaten prüfen"
        case .checkServer: return "Verbindung prüfen"
        case .freeDiskSpace: return "Speicherplatz freigeben"
        case .resolveConflict: return "Konflikt lösen"
        case .renameFile: return "Im Finder zeigen"
        case .none: return nil
        }
    }
}

extension ConflictReason {
    var title: String {
        switch self {
        case .bothModified: return "Auf beiden Seiten geändert"
        case .deletedLocallyModifiedRemotely: return "Lokal gelöscht, auf dem Server geändert"
        case .modifiedLocallyDeletedRemotely: return "Lokal geändert, auf dem Server gelöscht"
        case .kindMismatch: return "Datei und Ordner mit gleichem Namen"
        case .initialMergeDiffers: return "Beim ersten Abgleich unterschiedlich"
        }
    }

    var explanation: String {
        switch self {
        case .bothModified:
            return "Die Datei wurde seit dem letzten gemeinsamen Stand sowohl auf diesem Mac als auch auf dem Server geändert. Die Serverversion liegt unter dem ursprünglichen Namen, deine lokale Version wurde als Konfliktkopie gesichert. Beide Versionen sind auf beiden Seiten vorhanden."
        case .deletedLocallyModifiedRemotely:
            return "Du hast die Datei lokal gelöscht, während sie auf dem Server geändert wurde. Die geänderte Serverversion wurde wiederhergestellt, damit nichts verloren geht."
        case .modifiedLocallyDeletedRemotely:
            return "Die Datei wurde auf dem Server gelöscht, während du sie lokal geändert hast. Deine Version wurde erhalten und wieder hochgeladen."
        case .kindMismatch:
            return "An derselben Stelle liegt auf einer Seite eine Datei und auf der anderen ein Ordner. Die lokale Version wurde als Konfliktkopie gesichert, die Serverversion übernommen."
        case .initialMergeDiffers:
            return "Beim ersten Abgleich gab es lokal und auf dem Server eine gleichnamige Datei mit unterschiedlichem Inhalt. Die Serverversion liegt unter dem ursprünglichen Namen, die lokale Version als Konfliktkopie."
        }
    }
}

import SwiftUI
import ReichiSyncCore

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !model.isReady {
                ProgressView("reichi Sync wird gestartet …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let storeError = model.storeError {
                ContentUnavailableView {
                    Label("Datenbank nicht verfügbar", systemImage: "externaldrive.badge.xmark")
                } description: {
                    Text(storeError)
                }
            } else if model.needsSetup {
                SetupAssistantView()
            } else {
                NavigationSplitView {
                    List(visibleSections, selection: $model.selectedSection) { section in
                        Label {
                            HStack {
                                Text(section.title)
                                Spacer()
                                if let badge = badge(for: section) {
                                    Text("\(badge)")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.orange))
                                        .foregroundStyle(.white)
                                        .accessibilityLabel("\(badge) offen")
                                }
                            }
                        } icon: {
                            Image(systemName: section.symbol)
                        }
                        .tag(section)
                    }
                    .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                } detail: {
                    switch model.selectedSection {
                    case .overview: OverviewView()
                    case .activity: ActivityView()
                    case .conflicts: ConflictsView()
                    case .shares: SharesView()
                    case .settings: SettingsView()
                    }
                }
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { model.presentedError != nil }, set: { if !$0 { model.presentedError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.presentedError ?? "")
        }
    }

    /// Freigaben gibt es nur bei Cloudreve-Verbindungen.
    private var visibleSections: [AppModel.Section] {
        AppModel.Section.allCases.filter { $0 != .shares || model.isCloudreveAccount }
    }

    private func badge(for section: AppModel.Section) -> Int? {
        switch section {
        case .conflicts: return model.status.openConflicts > 0 ? model.status.openConflicts : nil
        case .activity:
            let failed = model.transfers.filter { $0.state == .failed }.count
            return failed > 0 ? failed : nil
        default: return nil
        }
    }
}

// MARK: - Übersicht

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusHeader(status: model.status)

                HStack(spacing: 12) {
                    Button {
                        model.syncNow()
                    } label: {
                        Label("Jetzt synchronisieren", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.status.isRunning || model.status.isPaused)
                    Button {
                        model.togglePause()
                    } label: {
                        Label(model.status.isPaused ? "Fortsetzen" : "Pausieren", systemImage: model.status.isPaused ? "play" : "pause")
                    }
                    .disabled(model.status.pauseReason == .localRootMissing)
                    Button {
                        model.openLocalFolder()
                    } label: {
                        Label("Im Finder öffnen", systemImage: "folder")
                    }
                }

                if model.status.pendingDeletions > 0 {
                    DeletionConfirmationCard()
                }

                if let issue = model.status.lastIssue, model.status.health == .attention || model.status.health == .paused || model.status.health == .offline {
                    IssueCard(issue: issue)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    MetricTile(title: "Ausstehend", value: "\(model.status.pendingCount)", symbol: "tray.full", tint: model.status.pendingCount == 0 ? .green : .accentColor)
                    MetricTile(title: "Konflikte", value: "\(model.status.openConflicts)", symbol: "exclamationmark.triangle", tint: model.status.openConflicts == 0 ? .green : .orange)
                    MetricTile(title: "Letzter Abgleich", value: Formatters.relative(model.status.lastSuccessfulSync), symbol: "clock", tint: .primary)
                    MetricTile(title: "Zurückgestellt", value: "\(model.status.skippedCount)", symbol: "arrow.uturn.forward", tint: .primary)
                }

                if let account = model.account {
                    GroupBox("Verbindung") {
                        VStack(alignment: .leading, spacing: 6) {
                            InfoRow(label: "Name", value: account.name)
                            InfoRow(label: "Server", value: account.serverURL.absoluteString, monospaced: true)
                            InfoRow(label: "Benutzer", value: account.username)
                            InfoRow(label: "Lokaler Ordner", value: account.localRootPath, monospaced: true)
                            InfoRow(label: "Abfrageintervall", value: "\(Int(account.pollInterval)) Sekunden")
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !model.status.activeTransfers.isEmpty {
                    GroupBox("Aktive Übertragungen") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.status.activeTransfers) { transfer in
                                TransferRow(transfer: transfer, compact: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                DiagnosticsView()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Übersicht")
    }
}

struct IssueCard: View {
    @EnvironmentObject private var model: AppModel
    let issue: SyncIssue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.message)
                    .font(.headline)
                if let detail = issue.detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(Formatters.dateTime(issue.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if let title = issue.action.title {
                        Button(title) { perform(issue.action) }
                    }
                    Button("Erneut versuchen") { model.syncNow() }
                        .disabled(model.status.isRunning)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func perform(_ action: SuggestedAction) {
        switch action {
        case .checkCredentials, .checkServer: model.selectedSection = .settings
        case .resolveConflict: model.selectedSection = .conflicts
        case .freeDiskSpace: model.openLocalFolder()
        case .retry: model.syncNow()
        case .renameFile: model.selectedSection = .activity
        case .none: break
        }
    }
}

/// Vorschau und Bestätigung zurückgehaltener Löschungen.
struct DeletionConfirmationCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.pendingDeletions.count) Löschungen warten auf deine Bestätigung")
                        .font(.headline)
                    Text("Ungewöhnlich viele Einträge würden entfernt. Nichts wird gelöscht, bis du es bestätigst. Lokale Löschungen landen im Papierkorb; auf dem Server hängt eine Wiederherstellung vom Server ab.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            DisclosureGroup("Betroffene Einträge anzeigen", isExpanded: $showPreview) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.pendingDeletions) { deletion in
                            HStack {
                                Image(systemName: deletion.kind == .directory ? "folder" : "doc")
                                    .foregroundStyle(.secondary)
                                Text(deletion.path)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(deletion.side == .local ? "lokal" : "Server")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Button("Löschungen verwerfen – alles behalten") { model.discardDeletions() }
                Button("Löschungen ausführen", role: .destructive) { model.confirmDeletions() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Aktivität

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Alle", running = "Aktiv", failed = "Fehler", skipped = "Zurückgestellt"
        var id: String { rawValue }
    }

    private var filtered: [TransferRecord] {
        switch filter {
        case .all: return model.transfers
        case .running: return model.transfers.filter { $0.state == .running || $0.state == .queued }
        case .failed: return model.transfers.filter { $0.state == .failed }
        case .skipped: return model.transfers.filter { $0.state == .skipped }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                StatusHeader(status: model.status, compact: true)
                Spacer()
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .labelsHidden()
            }
            .padding()
            Divider()
            if !model.queue.isEmpty && filter == .all {
                HStack {
                    Image(systemName: "tray.full")
                    Text("\(model.queue.count) Einträge in der Warteschlange (\(Formatters.bytes.string(fromByteCount: model.queue.reduce(0) { $0 + $1.size })))")
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
            }
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label("Keine Einträge", systemImage: "tray")
                } description: {
                    Text(filter == .all ? "Sobald Dateien übertragen werden, erscheinen sie hier." : "Keine Einträge in dieser Kategorie.")
                }
            } else {
                List(filtered) { transfer in
                    TransferRow(transfer: transfer)
                        .contextMenu {
                            Button("Im Finder zeigen") { model.reveal(path: transfer.path) }
                            if model.isCloudreveAccount {
                                Button("Link teilen …") { model.requestShare(forRelativePath: transfer.path) }
                            }
                        }
                }
                .listStyle(.inset)
            }
            if model.transfers.contains(where: { $0.state == .failed }) {
                Divider()
                HStack {
                    Spacer()
                    Button("Fehlgeschlagene erneut versuchen") { model.retryFailed() }
                        .disabled(model.status.isRunning)
                }
                .padding(10)
            }
        }
        .navigationTitle("Aktivität")
        .task { await model.refreshLists() }
    }
}

struct TransferRow: View {
    @EnvironmentObject private var model: AppModel
    let transfer: TransferRecord
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: transfer.state.symbol)
                .foregroundStyle(transfer.state.tint)
                .frame(width: 20)
                .accessibilityLabel(transfer.state.title)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: transfer.direction.symbol)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(transfer.path)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if transfer.state == .running, transfer.bytesTotal > 0 {
                    ProgressView(value: Double(transfer.bytesDone), total: Double(transfer.bytesTotal))
                        .frame(maxWidth: 240)
                }
                if !compact, let message = transfer.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(transfer.state == .failed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = transfer.errorDetail {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                    if let action = transfer.suggestedAction, let title = action.title {
                        Button(title) { perform(action) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [transfer.direction.title, transfer.state.title]
        if transfer.bytesTotal > 0 {
            parts.append(Formatters.bytes.string(fromByteCount: transfer.bytesTotal))
        }
        parts.append(Formatters.dateTime(transfer.finishedAt ?? transfer.startedAt))
        return parts.joined(separator: " · ")
    }

    private func perform(_ action: SuggestedAction) {
        switch action {
        case .retry: model.syncNow()
        case .checkCredentials, .checkServer: model.selectedSection = .settings
        case .freeDiskSpace: model.openLocalFolder()
        case .resolveConflict: model.selectedSection = .conflicts
        case .renameFile: model.reveal(path: transfer.path)
        case .none: break
        }
    }
}

// MARK: - Konflikte

struct ConflictsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.conflicts.isEmpty {
                ContentUnavailableView {
                    Label("Keine Konflikte", systemImage: "checkmark.seal")
                } description: {
                    Text("Wenn eine Datei auf beiden Seiten geändert wurde, erscheint sie hier. Es werden immer beide Versionen aufbewahrt, bis du entscheidest.")
                }
            } else {
                List(model.conflicts) { conflict in
                    ConflictRow(conflict: conflict)
                        .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Konflikte")
        .task { await model.refreshLists() }
    }
}

struct ConflictRow: View {
    @EnvironmentObject private var model: AppModel
    let conflict: ConflictRecord
    @State private var confirmUseLocal = false
    @State private var confirmUseRemote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(conflict.path)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(conflict.reason.title) · erkannt \(Formatters.dateTime(conflict.detectedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(conflict.reason.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                versionBox(title: "Deine lokale Version", symbol: "desktopcomputer", size: conflict.localSize, modified: conflict.localModified,
                           path: conflict.conflictCopyPath, note: conflict.conflictCopyPath.map { "Gesichert als „\(RelativePath.name(of: $0))“" })
                versionBox(title: "Serverversion", symbol: "externaldrive.connected.to.line.below", size: conflict.remoteSize, modified: conflict.remoteModified,
                           path: conflict.path, note: "Liegt unter dem ursprünglichen Namen")
            }

            HStack {
                Button("Beide behalten") { model.resolve(conflict, with: .keepBoth) }
                    .help("Beide Dateien bleiben bestehen; der Konflikt gilt als erledigt.")
                Button("Lokale Version verwenden") { confirmUseLocal = true }
                    .help("Die lokale Version ersetzt die Datei unter dem ursprünglichen Namen; die Serverversion wandert in den Papierkorb.")
                    .disabled(conflict.conflictCopyPath == nil)
                    .confirmationDialog("Lokale Version verwenden?", isPresented: $confirmUseLocal) {
                        Button("Lokale Version verwenden") { model.resolve(conflict, with: .useLocal) }
                        Button("Abbrechen", role: .cancel) {}
                    } message: {
                        Text("Die Serverversion wird lokal in den Papierkorb gelegt und auf dem Server durch deine Version ersetzt.")
                    }
                Button("Serverversion verwenden") { confirmUseRemote = true }
                    .help("Die Konfliktkopie wandert in den Papierkorb; die Serverversion bleibt.")
                    .disabled(conflict.conflictCopyPath == nil)
                    .confirmationDialog("Serverversion verwenden?", isPresented: $confirmUseRemote) {
                        Button("Serverversion verwenden") { model.resolve(conflict, with: .useRemote) }
                        Button("Abbrechen", role: .cancel) {}
                    } message: {
                        Text("Deine Konfliktkopie wird lokal in den Papierkorb gelegt und beim nächsten Abgleich vom Server entfernt.")
                    }
                Spacer()
                Button("Im Finder zeigen") { model.reveal(path: conflict.path) }
            }
            .controlSize(.small)
        }
    }

    private func versionBox(title: String, symbol: String, size: Int64?, modified: Double?, path: String?, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            if let size { Text("Größe: \(Formatters.bytes.string(fromByteCount: size))").font(.caption) }
            Text("Geändert: \(Formatters.dateTime(modified))").font(.caption)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let path {
                Button("Öffnen") { model.reveal(path: path) }
                    .controlSize(.mini)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

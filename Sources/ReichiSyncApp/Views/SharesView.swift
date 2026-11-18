import AppKit
import SwiftUI
import ReichiSyncCore

/// Freigabelinks (Cloudreve): Übersicht der eigenen Freigaben, Erstellen neuer Links,
/// Kopieren und Löschen.
struct SharesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCreateSheet = false
    @State private var createPath: String?
    @State private var copiedID: String?
    @State private var shareToDelete: CloudreveShare?

    var body: some View {
        VStack(spacing: 0) {
            if !model.isCloudreveAccount {
                ContentUnavailableView {
                    Label("Freigaben nicht verfügbar", systemImage: "link.badge.plus")
                } description: {
                    Text("Freigabelinks lassen sich nur mit einer Cloudreve-Verbindung erstellen.")
                }
            } else if !model.cloudreveSignedIn {
                ContentUnavailableView {
                    Label("Anmeldung erforderlich", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Die Cloudreve-Sitzung ist abgelaufen. Melde dich in den Einstellungen erneut an, um Freigaben zu verwalten. Der Abgleich der Dateien läuft weiter.")
                } actions: {
                    Button("Zu den Einstellungen") { model.selectedSection = .settings }
                }
            } else {
                list
            }
        }
        .navigationTitle("Freigaben")
        .toolbar {
            if model.isCloudreveAccount && model.cloudreveSignedIn {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        createPath = nil
                        showCreateSheet = true
                    } label: {
                        Label("Neue Freigabe", systemImage: "plus")
                    }
                    .help("Freigabelink für eine Datei oder einen Ordner erstellen")
                }
                ToolbarItem {
                    Button {
                        Task { await model.refreshShares() }
                    } label: {
                        Label("Aktualisieren", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.sharesLoading)
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateShareSheet(initialPath: createPath)
        }
        .onChange(of: model.shareRequestPath) { _, path in
            guard let path else { return }
            createPath = path
            showCreateSheet = true
            model.shareRequestPath = nil
        }
        .onAppear {
            if let path = model.shareRequestPath {
                createPath = path
                showCreateSheet = true
                model.shareRequestPath = nil
            } else if model.shares.isEmpty {
                Task { await model.refreshShares() }
            }
        }
        .confirmationDialog("Freigabe löschen?", isPresented: Binding(get: { shareToDelete != nil }, set: { if !$0 { shareToDelete = nil } }), presenting: shareToDelete) { share in
            Button("Freigabe löschen", role: .destructive) { Task { await model.deleteShare(share) } }
            Button("Abbrechen", role: .cancel) {}
        } message: { share in
            Text("Der Link zu „\(share.name)“ funktioniert danach nicht mehr. Die Datei selbst bleibt erhalten.")
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.shares.isEmpty {
            ContentUnavailableView {
                Label("Noch keine Freigaben", systemImage: "link")
            } description: {
                Text("Erstelle einen Link, um eine Datei oder einen Ordner aus deinem synchronisierten Ordner mit anderen zu teilen.")
            } actions: {
                Button("Neue Freigabe …") { createPath = nil; showCreateSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List(model.shares) { share in
                ShareRow(share: share, copied: copiedID == share.id) {
                    model.copyToPasteboard(share.urlWithPassword.absoluteString)
                    copiedID = share.id
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if copiedID == share.id { copiedID = nil }
                    }
                } onDelete: {
                    shareToDelete = share
                }
                .contextMenu {
                    Button("Link kopieren") { model.copyToPasteboard(share.urlWithPassword.absoluteString) }
                    Button("Im Browser öffnen") { NSWorkspace.shared.open(share.urlWithPassword) }
                    if let path = relativePath(of: share) {
                        Button("Im Finder zeigen") { model.reveal(path: path) }
                    }
                    Divider()
                    Button("Freigabe löschen …", role: .destructive) { shareToDelete = share }
                }
            }
            .listStyle(.inset)
            .overlay(alignment: .top) {
                if model.sharesLoading { ProgressView().controlSize(.small).padding(6) }
            }
        }
    }

    /// Relativer Pfad eines freigegebenen Eintrags innerhalb des Sync-Ordners (falls er darin liegt).
    private func relativePath(of share: CloudreveShare) -> String? {
        guard let source = share.sourceURI, let root = model.account?.davAccountURI else { return nil }
        let rootPath = CloudreveURI.folderPath(from: root).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sourcePath = CloudreveURI.folderPath(from: source).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rootPath.isEmpty { return sourcePath }
        guard sourcePath == rootPath || sourcePath.hasPrefix(rootPath + "/") else { return nil }
        return String(sourcePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct ShareRow: View {
    let share: CloudreveShare
    let copied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: share.isFolder ? "folder.fill" : "doc.fill")
                .font(.title2)
                .foregroundStyle(share.expired ? Color.secondary : Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(share.name).font(.headline).lineLimit(1)
                    if share.isPrivate {
                        Label("Passwort", systemImage: "lock.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .help("Passwortgeschützt" + (share.password.map { ": \($0)" } ?? ""))
                    }
                    if share.expired {
                        Text("abgelaufen")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                            .foregroundStyle(.white)
                    }
                }
                Text(share.url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Label("\(share.visited)", systemImage: "eye").help("Aufrufe")
                    Label("\(share.downloaded)", systemImage: "arrow.down.circle").help("Downloads")
                    if let remain = share.remainDownloads, remain >= 0 {
                        Text("noch \(remain) Download\(remain == 1 ? "" : "s")")
                    }
                    if let expires = share.expires {
                        Label(Formatters.dateTime(expires), systemImage: "clock")
                    }
                    if let created = share.createdAt {
                        Text("erstellt \(Formatters.relative(created))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onCopy()
            } label: {
                Label(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .help("Link in die Zwischenablage kopieren")
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Freigabe löschen")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Formular zum Erstellen eines Freigabelinks.
struct CreateShareSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let initialPath: String?

    private enum Expiry: Int, CaseIterable, Identifiable {
        case never = 0, hour = 3600, day = 86400, week = 604_800, month = 2_592_000
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .never: return "Nie"
            case .hour: return "1 Stunde"
            case .day: return "1 Tag"
            case .week: return "7 Tage"
            case .month: return "30 Tage"
            }
        }
    }

    @State private var path: String = ""
    @State private var passwordProtected = false
    @State private var password = ""
    @State private var expiry: Expiry = .never
    @State private var limitDownloads = false
    @State private var downloadLimit = 10
    @State private var shareView = true
    @State private var creating = false
    @State private var createdURL: URL?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(createdURL == nil ? "Freigabelink erstellen" : "Link bereit")
                .font(.title2.weight(.semibold))
            if let createdURL {
                result(createdURL)
            } else {
                form
            }
            HStack {
                if createdURL == nil {
                    Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(creating ? "Erstelle …" : "Link erstellen") { create() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(creating || path.isEmpty && !allowRootShare || (passwordProtected && password.isEmpty))
                } else {
                    Spacer()
                    Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { path = initialPath ?? "" }
    }

    /// Der Sync-Ordner selbst darf geteilt werden, wenn er nicht die Wurzel aller Dateien ist.
    private var allowRootShare: Bool {
        guard let root = model.account?.davAccountURI else { return false }
        return CloudreveURI.rootURI(folderPath: "") != root
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Datei oder Ordner").font(.subheadline.weight(.medium))
                HStack {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(Color.accentColor)
                    Text(path.isEmpty ? (allowRootShare ? "Gesamter synchronisierter Ordner" : "Noch nichts ausgewählt") : path)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Auswählen …") {
                        if let chosen = model.chooseItemToShare() { path = chosen }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Es wird der Stand auf dem Server geteilt. Lokale Änderungen erscheinen nach dem nächsten Abgleich auch im Link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Mit Passwort schützen", isOn: $passwordProtected)
            if passwordProtected {
                HStack {
                    TextField("Passwort (Buchstaben und Ziffern, max. 32)", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onChange(of: password) { _, new in
                            let filtered = String(new.filter { $0.isLetter || $0.isNumber }.prefix(32))
                            if filtered != new { password = filtered }
                        }
                    Button("Zufällig") { password = Self.randomPassword() }
                }
            }
            Picker("Läuft ab nach", selection: $expiry) {
                ForEach(Expiry.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Downloads begrenzen", isOn: $limitDownloads)
            if limitDownloads {
                Stepper("Maximal \(downloadLimit) Download\(downloadLimit == 1 ? "" : "s")", value: $downloadLimit, in: 1...1000)
            }
            Toggle("Vorschau im Browser erlauben", isOn: $shareView)
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func result(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(path.isEmpty ? "Ordner freigegeben" : "„\(RelativePath.name(of: path))“ freigegeben", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            HStack {
                Text(url.absoluteString)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Button(copied ? "Kopiert" : "Kopieren") {
                    model.copyToPasteboard(url.absoluteString)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if passwordProtected {
                Text("Das Passwort „\(password)“ ist Teil des Links. Ohne den Passwort-Teil muss es beim Öffnen eingegeben werden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Im Browser öffnen") { NSWorkspace.shared.open(url) }
        }
    }

    private func create() {
        creating = true
        error = nil
        let options = CloudreveAPIClient.ShareOptions(
            isPrivate: passwordProtected,
            password: passwordProtected ? password : nil,
            expiresIn: expiry == .never ? nil : TimeInterval(expiry.rawValue),
            downloadLimit: limitDownloads ? downloadLimit : nil,
            shareView: shareView
        )
        let target = path
        Task { @MainActor in
            defer { creating = false }
            do {
                createdURL = try await model.createShare(relativePath: target, options: options)
            } catch let err as CloudreveError {
                error = err.userDescription
            } catch let err as WebDAVError {
                error = err.userDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private static func randomPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }
}

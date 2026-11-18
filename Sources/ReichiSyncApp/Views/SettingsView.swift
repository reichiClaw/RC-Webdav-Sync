import SwiftUI
import ReichiSyncCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var name = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var newPassword = ""
    @State private var folderURL: URL?
    @State private var pollInterval: Double = 60
    @State private var exclusions = ""
    @State private var allowInsecureHTTP = false
    @State private var notificationsEnabled = true
    @State private var deletionThreshold = 25
    @State private var maxConcurrent = 3
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmRemove = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var chunkedUploads = true
    @State private var chunkThresholdMB: Int = 8
    @State private var showReauth = false

    var body: some View {
        Group {
            if model.needsSetup {
                ContentUnavailableView {
                    Label("Noch keine Verbindung", systemImage: "link.badge.plus")
                } description: {
                    Text("Richte zuerst im Hauptfenster eine WebDAV-Verbindung ein.")
                }
            } else {
                form
            }
        }
        .navigationTitle("Einstellungen")
        .onAppear { load() }
        .onChange(of: model.account) { _, _ in load(force: true) }
    }

    private var form: some View {
        Form {
            if let account = model.account, account.isCloudreve {
                Section("Cloudreve") {
                    TextField("Bezeichnung", text: $name)
                    LabeledContent("Server", value: account.cloudreveSiteURL?.absoluteString ?? "–")
                    LabeledContent("Konto", value: account.cloudreveEmail ?? "–")
                    LabeledContent("Server-Ordner", value: CloudreveURI.folderPath(from: account.davAccountURI ?? "cloudreve://my/"))
                    LabeledContent("WebDAV-Konto", value: account.username)
                    HStack {
                        if model.cloudreveSignedIn {
                            Label("Angemeldet – sichere Uploads und Freigaben verfügbar", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Sitzung abgelaufen – Uploads und Freigaben sind pausiert; Downloads laufen weiter", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Erneut anmelden …") { showReauth = true }
                    }
                    .font(.callout)
                    Text("Das Cloudreve-Passwort wird nicht gespeichert. Im Schlüsselbund liegen nur die Sitzungs-Tokens und das Passwort des WebDAV-Kontos, das reichi Sync für dieses Gerät angelegt hat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .sheet(isPresented: $showReauth) { CloudreveReauthSheet() }
            } else {
            Section("Verbindung") {
                TextField("Bezeichnung", text: $name)
                TextField("Server-Adresse (WebDAV-URL)", text: $serverURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                TextField("Benutzername", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Neues Passwort (leer lassen, um es zu behalten)", text: $newPassword)
                    .textContentType(.password)
                Toggle("Unverschlüsseltes HTTP erlauben (nur für Testserver)", isOn: $allowInsecureHTTP)
                HStack {
                    Button(testing ? "Prüfe …" : "Verbindung testen") { testConnection() }
                        .disabled(testing || serverURL.isEmpty)
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Text("Das Passwort wird ausschließlich im Schlüsselbund gespeichert. Zertifikate werden regulär vom System geprüft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }

            Section("Lokaler Ordner") {
                HStack {
                    Text(folderURL?.path ?? model.account?.localRootPath ?? "–")
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Ändern …") {
                        if let url = model.chooseFolder() { folderURL = url }
                    }
                }
                Text("Wird der Ordner oder die Server-Adresse geändert, beginnt der Abgleich mit einem neuen gemeinsamen Stand. Es werden dabei keine Dateien gelöscht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Synchronisierung") {
                Picker("Server abfragen alle", selection: $pollInterval) {
                    Text("30 Sekunden").tag(30.0)
                    Text("60 Sekunden").tag(60.0)
                    Text("2 Minuten").tag(120.0)
                    Text("5 Minuten").tag(300.0)
                    Text("15 Minuten").tag(900.0)
                }
                Stepper("Gleichzeitige Übertragungen: \(maxConcurrent)", value: $maxConcurrent, in: 1...8)
                if model.isCloudreveAccount {
                    LabeledContent("Uploads", value: "Cloudreve-API (versioniert und fortsetzbar)")
                    Text("Cloudreve wertet WebDAV If-Match nicht aus. Deshalb verwendet reichi Sync für alle Uploads den atomar versionierten API-Pfad.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Stepper("Löschschutz ab \(deletionThreshold) Einträgen", value: $deletionThreshold, in: 5...500, step: 5)
                Text("Werden in einem Durchgang mindestens so viele Einträge (oder mehr als 20 % des Bestands) gelöscht, wartet reichi Sync auf deine Bestätigung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ausschlüsse") {
                TextEditor(text: $exclusions)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                Text("Ein Muster pro Zeile, z. B. `*.tmp`, `node_modules`, `/Cache` (nur auf oberster Ebene). Systemdateien wie .DS_Store, ._*, Thumbs.db und temporäre Dateien werden immer ausgeschlossen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System") {
                Toggle("Bei der Anmeldung starten", isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem(enabled: $0) }))
                if model.loginItemRequiresApproval {
                    HStack {
                        Text("Der Start bei der Anmeldung muss in den Systemeinstellungen bestätigt werden.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Systemeinstellungen öffnen") { LoginItemManager.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
                Toggle("Benachrichtigungen bei Konflikten und Fehlern", isOn: $notificationsEnabled)
                Toggle("Symbol im Dock anzeigen", isOn: $model.showDockIcon)
            }

            Section {
                HStack {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Text("Verbindung entfernen …")
                    }
                    .confirmationDialog("Verbindung entfernen?", isPresented: $confirmRemove) {
                        Button("Verbindung entfernen", role: .destructive) { Task { await model.removeAccount() } }
                        Button("Abbrechen", role: .cancel) {}
                    } message: {
                        Text("Zugangsdaten und Synchronisierungsstand werden entfernt. Deine Dateien bleiben lokal und auf dem Server unverändert.")
                    }
                    Spacer()
                    Button("Zurücksetzen") { load(force: true) }
                    Button(saving ? "Speichere …" : "Speichern") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving || !isDirty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isDirty: Bool {
        guard let account = model.account else { return false }
        return name != account.name || serverURL != account.serverURL.absoluteString || username != account.username || !newPassword.isEmpty
            || folderURL != nil || pollInterval != account.pollInterval || exclusionList != account.exclusionPatterns || allowInsecureHTTP != account.allowInsecureHTTP
            || notificationsEnabled != account.notificationsEnabled || deletionThreshold != account.deletionGuardThreshold || maxConcurrent != account.maxConcurrentTransfers
            || chunkedUploads != account.chunkedUploadsEnabled || Int64(chunkThresholdMB) * 1024 * 1024 != account.chunkedUploadThreshold
    }

    private var exclusionList: [String] {
        exclusions.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func load(force: Bool = false) {
        guard let account = model.account, force || !loaded else { return }
        loaded = true
        name = account.name
        serverURL = account.serverURL.absoluteString
        username = account.username
        newPassword = ""
        folderURL = nil
        pollInterval = account.pollInterval
        exclusions = account.exclusionPatterns.joined(separator: "\n")
        allowInsecureHTTP = account.allowInsecureHTTP
        notificationsEnabled = account.notificationsEnabled
        deletionThreshold = account.deletionGuardThreshold
        maxConcurrent = account.maxConcurrentTransfers
        chunkedUploads = account.chunkedUploadsEnabled
        chunkThresholdMB = max(1, Int(account.chunkedUploadThreshold / (1024 * 1024)))
        testResult = nil
        model.refreshLoginItemState()
    }

    private func save() {
        guard var account = model.account else { return }
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else {
            model.presentedError = "Die Server-Adresse ist ungültig."
            return
        }
        account.name = name
        account.serverURL = url
        account.username = username
        account.pollInterval = pollInterval
        account.exclusionPatterns = exclusionList
        account.allowInsecureHTTP = allowInsecureHTTP
        account.notificationsEnabled = notificationsEnabled
        account.deletionGuardThreshold = deletionThreshold
        account.maxConcurrentTransfers = maxConcurrent
        account.chunkedUploadsEnabled = chunkedUploads
        account.chunkedUploadThreshold = Int64(chunkThresholdMB) * 1024 * 1024
        saving = true
        Task { @MainActor in
            await model.updateAccount(account, newPassword: newPassword.isEmpty ? nil : newPassword, newFolder: folderURL)
            saving = false
            load(force: true)
        }
    }

    private func testConnection() {
        testing = true
        testResult = nil
        let password = newPassword
        Task { @MainActor in
            defer { testing = false }
            do {
                let pw: String
                if !password.isEmpty {
                    pw = password
                } else {
                    guard let account = model.account,
                          let stored = try KeychainStore().password(accountID: account.id) else {
                        testResult = "Bitte Passwort eingeben."
                        return
                    }
                    pw = stored
                }
                let result = try await model.testConnection(urlString: serverURL, username: username, password: pw, allowInsecureHTTP: allowInsecureHTTP)
                testResult = "Verbindung erfolgreich (\(result.capabilities.serverSoftware ?? "WebDAV")\(result.capabilities.supportsSyncCollection ? ", WebDAV-Sync" : ""))."
            } catch let error as WebDAVError {
                testResult = error.userDescription
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}

/// Erneute Cloudreve-Anmeldung nach Ablauf der Sitzung.
struct CloudreveReauthSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var otp = ""
    @State private var needsOTP = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bei Cloudreve anmelden").font(.title2.weight(.semibold))
            Text("Konto: \(model.account?.cloudreveEmail ?? "–")")
                .foregroundStyle(.secondary)
            SecureField("Passwort", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !password.isEmpty { submit() } }
            if needsOTP {
                TextField("Bestätigungscode (2FA)", text: $otp)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.oneTimeCode)
            }
            if let error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(working ? "Anmeldung …" : "Anmelden") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || password.isEmpty || (needsOTP && otp.count < 6))
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func submit() {
        working = true
        error = nil
        let (pw, code) = (password, otp)
        Task { @MainActor in
            defer { working = false }
            do {
                try await model.reauthenticateCloudreve(password: pw, otp: needsOTP ? code : nil)
                dismiss()
            } catch CloudreveError.twoFactorRequired {
                needsOTP = true
            } catch let err as CloudreveError {
                error = err.userDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

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
        .onAppear(perform: load)
        .onChange(of: model.account) { _, _ in load(force: true) }
    }

    private var form: some View {
        Form {
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
                } else if let account = model.account, let stored = try? KeychainStore().password(accountID: account.id) {
                    pw = stored
                } else {
                    testResult = "Bitte Passwort eingeben."
                    return
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

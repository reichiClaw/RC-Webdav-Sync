import AppKit
import SwiftUI
import ReichiSyncCore

/// Einrichtungsassistent für die erste Verbindung. Standard ist eine Cloudreve-Instanz
/// (reichi.cloud); alternativ lässt sich ein beliebiger WebDAV-Server verbinden.
struct SetupAssistantView: View {
    @EnvironmentObject private var model: AppModel

    enum Mode: String, CaseIterable, Identifiable {
        case cloudreve, webdav
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cloudreve: return "reichi.cloud / Cloudreve"
            case .webdav: return "Anderer WebDAV-Server"
            }
        }
    }

    private enum Step: Hashable {
        case welcome, cloudreveLogin, twoFactor, remoteFolder, server, credentials, folder, check, summary

        var title: String {
            switch self {
            case .welcome: return "Willkommen"
            case .cloudreveLogin: return "Anmeldung"
            case .twoFactor: return "Bestätigungscode"
            case .remoteFolder: return "Server-Ordner"
            case .server: return "Server"
            case .credentials: return "Anmeldung"
            case .folder: return "Lokaler Ordner"
            case .check: return "Verbindung prüfen"
            case .summary: return "Fertigstellen"
            }
        }
    }

    @State private var mode: Mode = .cloudreve
    @State private var step: Step = .welcome
    @State private var name = "reichi.cloud"
    @State private var allowInsecureHTTP = false
    @State private var folder: URL?
    @State private var finishing = false

    // Cloudreve
    @State private var siteURL = AccountConfiguration.defaultSiteURL.absoluteString
    @State private var email = ""
    @State private var cloudrevePassword = ""
    @State private var otp = ""
    @State private var twoFactorSessionID: String?
    @State private var api: CloudreveAPIClient?
    @State private var loggingIn = false
    @State private var loginError: String?
    @State private var davAccounts: [CloudreveDavAccount] = []
    @State private var loadingDavAccounts = false
    @State private var selectedDavAccountID: String? = nil
    @State private var newRemoteFolder = "/reichi Sync"
    @State private var useExistingDavAccount = false

    // Generisches WebDAV
    @State private var serverURL = "https://"
    @State private var username = ""
    @State private var password = ""
    @State private var checking = false
    @State private var checkResult: Result<AppModel.ConnectionCheck, Error>?

    private var steps: [Step] {
        switch mode {
        case .cloudreve:
            var list: [Step] = [.welcome, .cloudreveLogin]
            if twoFactorSessionID != nil { list.append(.twoFactor) }
            list += [.remoteFolder, .folder, .summary]
            return list
        case .webdav:
            return [.welcome, .server, .credentials, .folder, .check, .summary]
        }
    }

    private var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, _ in
                    Capsule()
                        .fill(index <= stepIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            Text("Schritt \(stepIndex + 1) von \(steps.count): \(step.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            ScrollView {
                content
                    .padding(32)
                    .frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                if step != .welcome {
                    Button("Zurück") { go(-1) }
                        .disabled(loggingIn || finishing)
                }
                Spacer()
                Button(nextTitle) { next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
            .padding()
        }
    }

    // MARK: - Inhalte

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .cloudreveLogin: cloudreveLogin
        case .twoFactor: twoFactor
        case .remoteFolder: remoteFolder
        case .server: server
        case .credentials: credentials
        case .folder: localFolder
        case .check: check
        case .summary: summary
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("reichi Sync einrichten")
                .font(.largeTitle.weight(.bold))
            Text("reichi Sync hält einen Ordner auf diesem Mac und einen Ordner auf deinem Server in beide Richtungen auf dem gleichen Stand. Die App läuft unauffällig in der Menüleiste.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                bullet("Konflikte werden nie automatisch zugunsten einer Seite entschieden – es bleiben immer beide Versionen erhalten.")
                bullet("Löschungen werden nur übertragen, wenn sie eindeutig von dir stammen. Große Löschmengen fragen nach.")
                bullet("Zugangsdaten landen ausschließlich im Schlüsselbund von macOS.")
                bullet("Mit Cloudreve: große Dateien in Teilen hochladen, Abbrüche fortsetzen, Freigabelinks erstellen.")
            }
            .font(.callout)
            Picker("Verbinden mit", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: mode) { _, newMode in
                name = newMode == .cloudreve ? "reichi.cloud" : "Mein WebDAV"
            }
        }
    }

    private var cloudreveLogin: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bei Cloudreve anmelden").font(.title2.weight(.semibold))
            Text("Melde dich mit deinem Cloudreve-Konto an. Das Passwort wird nicht gespeichert – reichi Sync legt stattdessen ein eigenes WebDAV-Konto für dieses Gerät an und bewahrt dessen Zugangsdaten im Schlüsselbund auf.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Bezeichnung", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Server", text: $siteURL)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .autocorrectionDisabled()
            TextField("E-Mail-Adresse", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Passwort", text: $cloudrevePassword)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit { if canContinue { next() } }
            if let url = URL(string: siteURL), url.scheme?.lowercased() == "http" {
                Toggle("Unverschlüsseltes HTTP erlauben (nur für lokale Testserver)", isOn: $allowInsecureHTTP)
            }
            if loggingIn {
                HStack { ProgressView().controlSize(.small); Text("Anmeldung läuft …") }
            }
            if let loginError {
                Label(loginError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var twoFactor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Zwei-Faktor-Bestätigung").font(.title2.weight(.semibold))
            Text("Dein Konto ist mit einem zweiten Faktor geschützt. Gib den aktuellen Code aus deiner Authenticator-App ein.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("6-stelliger Code", text: $otp)
                .textFieldStyle(.roundedBorder)
                .textContentType(.oneTimeCode)
                .font(.title3.monospacedDigit())
                .onSubmit { if canContinue { next() } }
            if loggingIn {
                HStack { ProgressView().controlSize(.small); Text("Code wird geprüft …") }
            }
            if let loginError {
                Label(loginError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var remoteFolder: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ordner auf dem Server").font(.title2.weight(.semibold))
            Text("Welcher Teil deiner Cloudreve-Dateien soll synchronisiert werden? reichi Sync legt dafür ein eigenes WebDAV-Konto an, das nur auf diesen Ordner zugreift.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $useExistingDavAccount) {
                Text("Neuen Ordner verwenden").tag(false)
                Text("Vorhandenes WebDAV-Konto verwenden").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if useExistingDavAccount {
                if loadingDavAccounts {
                    HStack { ProgressView().controlSize(.small); Text("WebDAV-Konten werden geladen …") }
                } else if davAccounts.isEmpty {
                    Text("Es sind noch keine WebDAV-Konten vorhanden.").foregroundStyle(.secondary)
                } else {
                    Picker("WebDAV-Konto", selection: $selectedDavAccountID) {
                        ForEach(davAccounts) { account in
                            Text("\(account.name.isEmpty ? "Ohne Namen" : account.name) – \(CloudreveURI.folderPath(from: account.uri))\(account.readonly ? " (nur lesen)" : "")")
                                .tag(Optional(account.id))
                        }
                    }
                    if let selected = davAccounts.first(where: { $0.id == selectedDavAccountID }), selected.readonly {
                        Label("Dieses Konto ist schreibgeschützt und eignet sich nicht für den Abgleich.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
            } else {
                TextField("Ordnerpfad, z. B. /reichi Sync", text: $newRemoteFolder)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Text("Der Ordner wird angelegt, falls er noch nicht existiert. Ein leeres Feld oder „/“ synchronisiert alle deine Dateien.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { if davAccounts.isEmpty { loadDavAccounts() } }
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Server-Adresse").font(.title2.weight(.semibold))
            Text("Gib die WebDAV-Adresse des Ordners an, der synchronisiert werden soll. Bei Nextcloud lautet sie zum Beispiel `https://cloud.example.org/remote.php/dav/files/BENUTZER/Ordner`.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Bezeichnung", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("https://server.example.org/remote.php/dav/files/…", text: $serverURL)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .autocorrectionDisabled()
            Toggle("Unverschlüsseltes HTTP erlauben (nur für lokale Testserver)", isOn: $allowInsecureHTTP)
            if !allowInsecureHTTP, let url = URL(string: serverURL), url.scheme?.lowercased() == "http" {
                Label("Unverschlüsselte Verbindungen sind standardmäßig nicht erlaubt.", systemImage: "lock.open.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Anmeldung").font(.title2.weight(.semibold))
            Text("Benutzername und Passwort (bei Nextcloud idealerweise ein App-Passwort). Das Passwort wird im Schlüsselbund gespeichert und nur an diesen Server gesendet.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Benutzername", text: $username)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Passwort", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
        }
    }

    private var localFolder: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lokaler Ordner").font(.title2.weight(.semibold))
            Text("Wähle den Ordner auf diesem Mac, dessen Inhalt mit dem Server abgeglichen wird. Am besten ein leerer oder neuer Ordner – vorhandene Dateien werden beim ersten Abgleich zusammengeführt, ohne etwas zu löschen.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                Text(folder?.path ?? "Noch kein Ordner gewählt")
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Auswählen …") {
                    if let url = model.chooseFolder(prompt: "Diesen Ordner synchronisieren") { folder = url }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let folder, let count = try? FileManager.default.contentsOfDirectory(atPath: folder.path).count, count > 0 {
                Label("Der Ordner enthält bereits \(count) Einträge. Sie werden mit dem Server zusammengeführt; bei gleichnamigen, unterschiedlichen Dateien entstehen Konfliktkopien.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var check: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verbindung prüfen").font(.title2.weight(.semibold))
            if checking {
                HStack { ProgressView(); Text("Server wird kontaktiert …") }
            } else if let checkResult {
                switch checkResult {
                case .success(let check):
                    Label("Verbindung erfolgreich", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        InfoRow(label: "Server", value: check.capabilities.serverSoftware ?? "unbekannt")
                        InfoRow(label: "WebDAV-Sync", value: check.capabilities.supportsSyncCollection ? "unterstützt (schnelle Änderungsabfrage)" : "nicht unterstützt (vollständige Bestandsaufnahme)")
                        InfoRow(label: "ETags", value: check.capabilities.strongETags ? "stark" : (check.capabilities.providesETags ? "schwach" : "keine"))
                    }
                case .failure(let error):
                    Label("Verbindung fehlgeschlagen", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.headline)
                    Text((error as? WebDAVError)?.userDescription ?? error.localizedDescription)
                        .fixedSize(horizontal: false, vertical: true)
                    if let technical = (error as? WebDAVError)?.technicalDescription {
                        Text(technical)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button("Erneut prüfen") { runCheck() }
                }
            } else {
                Button("Jetzt prüfen") { runCheck() }
            }
        }
        .onAppear { if checkResult == nil { runCheck() } }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Alles bereit").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Bezeichnung", value: name)
                if mode == .cloudreve {
                    InfoRow(label: "Server", value: siteURL, monospaced: true)
                    InfoRow(label: "Konto", value: email)
                    InfoRow(label: "Server-Ordner", value: remoteFolderSummary, monospaced: true)
                } else {
                    InfoRow(label: "Server", value: serverURL, monospaced: true)
                    InfoRow(label: "Benutzer", value: username)
                }
                InfoRow(label: "Lokaler Ordner", value: folder?.path ?? "–", monospaced: true)
            }
            Text(mode == .cloudreve
                 ? "Beim Fertigstellen wird ein WebDAV-Konto für dieses Gerät angelegt und der erste Abgleich gestartet. Vorhandene Dateien beider Seiten werden zusammengeführt; es wird nichts gelöscht."
                 : "Nach dem Fertigstellen beginnt der erste Abgleich. Dabei werden vorhandene Dateien beider Seiten zusammengeführt; es wird nichts gelöscht.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if finishing { ProgressView() }
        }
    }

    private var remoteFolderSummary: String {
        if useExistingDavAccount, let selected = davAccounts.first(where: { $0.id == selectedDavAccountID }) {
            return CloudreveURI.folderPath(from: selected.uri)
        }
        return CloudreveURI.folderPath(from: CloudreveURI.rootURI(folderPath: newRemoteFolder))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Navigation

    private var nextTitle: String {
        switch step {
        case .welcome: return "Los geht's"
        case .cloudreveLogin: return "Anmelden"
        case .twoFactor: return "Bestätigen"
        case .summary: return "Fertigstellen"
        default: return "Weiter"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .cloudreveLogin:
            guard !loggingIn, !email.isEmpty, !cloudrevePassword.isEmpty, let url = try? AppModel.normalizedSiteURL(siteURL) else { return false }
            return url.scheme == "https" || allowInsecureHTTP || WebDAVClient.isLoopback(url)
        case .twoFactor: return !loggingIn && otp.trimmingCharacters(in: .whitespaces).count >= 6
        case .remoteFolder:
            if useExistingDavAccount {
                guard let selected = davAccounts.first(where: { $0.id == selectedDavAccountID }) else { return false }
                return !selected.readonly
            }
            return true
        case .server:
            guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
            return scheme == "https" || (scheme == "http" && (allowInsecureHTTP || WebDAVClient.isLoopback(url)))
        case .credentials: return !username.isEmpty && !password.isEmpty
        case .folder: return folder != nil
        case .check:
            if case .success? = checkResult { return true }
            return false
        case .summary: return !finishing
        }
    }

    private func go(_ delta: Int) {
        let index = stepIndex + delta
        guard steps.indices.contains(index) else { return }
        if step == .twoFactor && delta < 0 {
            twoFactorSessionID = nil
            step = .cloudreveLogin
            return
        }
        step = steps[index]
    }

    private func next() {
        switch step {
        case .cloudreveLogin: login()
        case .twoFactor: verifyTwoFactor()
        case .summary: finish()
        case .folder:
            checkResult = nil
            go(1)
        default: go(1)
        }
    }

    // MARK: - Aktionen

    private func login() {
        loggingIn = true
        loginError = nil
        let (site, mail, pw, insecure) = (siteURL, email, cloudrevePassword, allowInsecureHTTP)
        Task { @MainActor in
            defer { loggingIn = false }
            do {
                switch try await model.cloudreveLogin(siteURLString: site, email: mail, password: pw, allowInsecureHTTP: insecure) {
                case .signedIn(let client):
                    api = client
                    twoFactorSessionID = nil
                    cloudrevePassword = ""
                    davAccounts = []
                    step = .remoteFolder
                case .twoFactorRequired(let client, let sessionID):
                    api = client
                    twoFactorSessionID = sessionID
                    otp = ""
                    step = .twoFactor
                }
            } catch let error as CloudreveError {
                loginError = error.userDescription
            } catch let error as WebDAVError {
                loginError = error.userDescription
            } catch {
                loginError = error.localizedDescription
            }
        }
    }

    private func verifyTwoFactor() {
        guard let api, let sessionID = twoFactorSessionID else { return }
        loggingIn = true
        loginError = nil
        let code = otp
        Task { @MainActor in
            defer { loggingIn = false }
            do {
                try await model.cloudreveVerifyTwoFactor(api: api, sessionID: sessionID, code: code)
                cloudrevePassword = ""
                davAccounts = []
                step = .remoteFolder
            } catch let error as CloudreveError {
                loginError = error.userDescription
            } catch {
                loginError = error.localizedDescription
            }
        }
    }

    private func loadDavAccounts() {
        guard let api else { return }
        loadingDavAccounts = true
        Task { @MainActor in
            defer { loadingDavAccounts = false }
            do {
                davAccounts = try await api.listDavAccounts()
                if selectedDavAccountID == nil { selectedDavAccountID = davAccounts.first(where: { !$0.readonly })?.id }
            } catch {
                davAccounts = []
            }
        }
    }

    private func runCheck() {
        checking = true
        let (u, user, pw, insecure) = (serverURL, username, password, allowInsecureHTTP)
        Task { @MainActor in
            do {
                let result = try await model.testConnection(urlString: u, username: user, password: pw, allowInsecureHTTP: insecure)
                checkResult = .success(result)
            } catch {
                checkResult = .failure(error)
            }
            checking = false
        }
    }

    private func finish() {
        guard let folder else { return }
        finishing = true
        Task { @MainActor in
            defer { finishing = false }
            do {
                switch mode {
                case .cloudreve:
                    guard let api else { throw CloudreveError.authenticationRequired("Bitte zuerst anmelden.") }
                    let existing = useExistingDavAccount ? davAccounts.first(where: { $0.id == selectedDavAccountID }) : nil
                    try await model.completeCloudreveSetup(name: name, api: api, email: email, existingAccount: existing,
                                                           newRemoteFolder: useExistingDavAccount ? nil : newRemoteFolder, folder: folder,
                                                           allowInsecureHTTP: allowInsecureHTTP)
                case .webdav:
                    try await model.completeSetup(name: name, urlString: serverURL, username: username, password: password, folder: folder, allowInsecureHTTP: allowInsecureHTTP)
                }
            } catch let error as CloudreveError {
                model.presentedError = error.userDescription
            } catch {
                model.presentedError = (error as? WebDAVError)?.userDescription ?? error.localizedDescription
            }
        }
    }
}

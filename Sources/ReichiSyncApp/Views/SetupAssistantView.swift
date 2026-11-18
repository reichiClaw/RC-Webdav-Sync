import SwiftUI
import ReichiSyncCore

/// Einrichtungsassistent für die erste Verbindung.
struct SetupAssistantView: View {
    @EnvironmentObject private var model: AppModel

    private enum Step: Int, CaseIterable {
        case welcome, server, credentials, folder, check, summary

        var title: String {
            switch self {
            case .welcome: return "Willkommen"
            case .server: return "Server"
            case .credentials: return "Anmeldung"
            case .folder: return "Lokaler Ordner"
            case .check: return "Verbindung prüfen"
            case .summary: return "Fertigstellen"
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var name = "Mein WebDAV"
    @State private var serverURL = "https://"
    @State private var username = ""
    @State private var password = ""
    @State private var allowInsecureHTTP = false
    @State private var folder: URL?
    @State private var checking = false
    @State private var checkResult: Result<AppModel.ConnectionCheck, Error>?
    @State private var finishing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            Text("Schritt \(step.rawValue + 1) von \(Step.allCases.count): \(step.title)")
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
                }
                Spacer()
                Button(nextTitle) { next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("reichi Sync einrichten")
                    .font(.largeTitle.weight(.bold))
                Text("reichi Sync hält einen Ordner auf diesem Mac und einen WebDAV-Ordner auf deinem Server in beide Richtungen auf dem gleichen Stand. Die App läuft unauffällig in der Menüleiste.")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Konflikte werden nie automatisch zugunsten einer Seite entschieden – es bleiben immer beide Versionen erhalten.")
                    bullet("Löschungen werden nur übertragen, wenn sie eindeutig von dir stammen. Große Löschmengen fragen nach.")
                    bullet("Zugangsdaten landen ausschließlich im Schlüsselbund von macOS.")
                }
                .font(.callout)
            }
        case .server:
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
        case .credentials:
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
        case .folder:
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
        case .check:
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
        case .summary:
            VStack(alignment: .leading, spacing: 14) {
                Text("Alles bereit").font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "Bezeichnung", value: name)
                    InfoRow(label: "Server", value: serverURL, monospaced: true)
                    InfoRow(label: "Benutzer", value: username)
                    InfoRow(label: "Lokaler Ordner", value: folder?.path ?? "–", monospaced: true)
                }
                Text("Nach dem Fertigstellen beginnt der erste Abgleich. Dabei werden vorhandene Dateien beider Seiten zusammengeführt; es wird nichts gelöscht.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if finishing { ProgressView() }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nextTitle: String {
        switch step {
        case .welcome: return "Los geht's"
        case .summary: return "Fertigstellen"
        default: return "Weiter"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .welcome: return true
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
        if let s = Step(rawValue: step.rawValue + delta) { step = s }
    }

    private func next() {
        if step == .summary {
            finish()
        } else {
            if step == .folder { checkResult = nil }
            go(1)
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
            do {
                try await model.completeSetup(name: name, urlString: serverURL, username: username, password: password, folder: folder, allowInsecureHTTP: allowInsecureHTTP)
            } catch {
                model.presentedError = (error as? WebDAVError)?.userDescription ?? error.localizedDescription
            }
            finishing = false
        }
    }
}

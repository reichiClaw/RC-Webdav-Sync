import AppKit
import Foundation
import ReichiSyncCore

@MainActor
private final class CloudreveAPIReference {
    weak var value: CloudreveAPIClient?
}

/// Cloudreve-spezifische Teile des App-Modells: Anmeldung, Token-Verwaltung,
/// WebDAV-Konto-Bereitstellung, Chunk-Upload-Transport und Freigabelinks.
extension AppModel {
    /// Schlüsselbund-Eintrag für die Cloudreve-Tokens (JSON) einer Verbindung.
    nonisolated static func cloudreveTokenKey(accountID: String) -> String { accountID + ".cloudreve" }

    // MARK: - Anmeldung (Einrichtung)

    /// Ergebnis eines Anmeldeversuchs im Einrichtungsassistenten.
    enum CloudreveLoginOutcome: Sendable {
        case signedIn(CloudreveAPIClient)
        case twoFactorRequired(CloudreveAPIClient, sessionID: String)
    }

    /// Meldet sich mit E-Mail und Passwort an. Das Passwort wird nicht gespeichert; die App
    /// arbeitet anschließend ausschließlich mit den erhaltenen Tokens.
    nonisolated func cloudreveLogin(siteURLString: String, email: String, password: String, allowInsecureHTTP: Bool) async throws -> CloudreveLoginOutcome {
        let site = try Self.normalizedSiteURL(siteURLString)
        let api = try CloudreveAPIClient(siteURL: site, allowInsecureHTTP: allowInsecureHTTP)
        _ = try await api.ping()
        switch try await api.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) {
        case .signedIn:
            return .signedIn(api)
        case .twoFactorRequired(let sessionID):
            return .twoFactorRequired(api, sessionID: sessionID)
        }
    }

    nonisolated func cloudreveVerifyTwoFactor(api: CloudreveAPIClient, sessionID: String, code: String) async throws {
        _ = try await api.verifyTwoFactor(sessionID: sessionID, otp: code.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated static func normalizedSiteURL(_ string: String) throws -> URL {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return AccountConfiguration.defaultSiteURL }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), components.host != nil else {
            throw WebDAVError.invalidResponse("Die Server-Adresse ist ungültig")
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw WebDAVError.invalidResponse("Die Server-Adresse ist ungültig") }
        return url
    }

    /// WebDAV-Basis-URL einer Cloudreve-Instanz.
    nonisolated static func davURL(for siteURL: URL) -> URL {
        siteURL.appendingPathComponent("dav", isDirectory: true)
    }

    /// Schließt die Einrichtung einer Cloudreve-Verbindung ab. Entweder wird ein vorhandenes
    /// WebDAV-Konto verwendet oder ein neues für `newRemoteFolder` angelegt (Ordner wird bei
    /// Bedarf erstellt). Danach läuft der Abgleich wie bei jeder WebDAV-Verbindung.
    func completeCloudreveSetup(name: String, api: CloudreveAPIClient, email: String, existingAccount: CloudreveDavAccount?,
                                newRemoteFolder: String?, folder: URL, allowInsecureHTTP: Bool) async throws {
        guard let store else { throw NSError(domain: "reichi", code: 1, userInfo: [NSLocalizedDescriptionKey: storeError ?? "Datenbank nicht verfügbar"]) }
        try validateSyncFolder(folder)
        let bookmarkData = try bookmarks.makeData(folder: folder)
        let davAccount: CloudreveDavAccount
        if let existingAccount {
            davAccount = existingAccount
        } else {
            let rootURI = try CloudreveURI.validatedRootURI(folderPath: newRemoteFolder ?? "")
            if rootURI != "cloudreve://my/" {
                try await api.createFolder(uri: rootURI)
            }
            let device = Host.current().localizedName ?? "Mac"
            davAccount = try await api.createDavAccount(name: "reichi Sync (\(device))", uri: rootURI)
        }
        let createdDavAccount = existingAccount == nil
        do {
        guard !davAccount.readonly else {
            throw WebDAVError.invalidResponse("Das gewählte WebDAV-Konto ist schreibgeschützt. Bitte ein Konto mit Schreibzugriff wählen oder ein neues anlegen.")
        }
        _ = try CloudreveURI.fileURI(root: davAccount.uri, relativePath: "")
        let davClient = try WebDAVClient(
            baseURL: Self.davURL(for: api.siteURL),
            credentials: WebDAVCredentials(
                username: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: davAccount.password
            ),
            allowInsecureHTTP: allowInsecureHTTP,
            serverKindHint: .cloudreve
        )
        _ = try await davClient.probe()

        let newAccount = AccountConfiguration(
            name: name.isEmpty ? "reichi.cloud" : name,
            serverURL: Self.davURL(for: api.siteURL),
            username: email.trimmingCharacters(in: .whitespacesAndNewlines),
            localRootPath: folder.standardizedFileURL.path,
            allowInsecureHTTP: allowInsecureHTTP,
            serverKind: .cloudreve,
            cloudreveSiteURL: api.siteURL,
            cloudreveEmail: email.trimmingCharacters(in: .whitespacesAndNewlines),
            davAccountID: davAccount.id,
            davAccountManaged: createdDavAccount,
            davAccountURI: davAccount.uri
        )
        try keychain.savePassword(davAccount.password, accountID: newAccount.id, label: "reichi Sync – WebDAV (\(newAccount.name))")
        do {
            guard let tokens = api.currentTokens else {
                throw CloudreveError.authenticationRequired("Keine gültige Sitzung")
            }
            try saveCloudreveTokens(tokens, accountID: newAccount.id)
            try await store.saveAccount(newAccount)
        } catch {
            try? keychain.deletePassword(accountID: newAccount.id)
            try? keychain.deletePassword(accountID: Self.cloudreveTokenKey(accountID: newAccount.id))
            throw error
        }
        bookmarks.save(data: bookmarkData, accountID: newAccount.id)
        account = newAccount
        if newAccount.notificationsEnabled { await notifications.requestAuthorizationIfNeeded() }
        await startEngine(for: newAccount)
        } catch {
            if createdDavAccount {
                try? await api.deleteDavAccount(id: davAccount.id)
            }
            throw error
        }
    }

    // MARK: - Tokens

    func loadCloudreveTokens(accountID: String) throws -> CloudreveTokens? {
        guard let json = try keychain.password(accountID: Self.cloudreveTokenKey(accountID: accountID)) else { return nil }
        return try JSONDecoder().decode(CloudreveTokens.self, from: Data(json.utf8))
    }

    func saveCloudreveTokens(_ tokens: CloudreveTokens?, accountID: String) throws {
        let key = Self.cloudreveTokenKey(accountID: accountID)
        if let tokens {
            let json = String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self)
            try keychain.savePassword(json, accountID: key, label: "reichi Sync – Cloudreve-Sitzung")
        } else {
            try keychain.deletePassword(accountID: key)
        }
    }

    /// Erstellt den API-Client für eine Cloudreve-Verbindung aus den gespeicherten Tokens.
    /// Ohne gültiges Refresh-Token bleibt der Client abgemeldet. Uploads und
    /// Freigaben warten dann auf eine erneute Anmeldung; sichere WebDAV-Downloads
    /// und Bestandsaufnahmen laufen weiter.
    func makeCloudreveClient(for account: AccountConfiguration, lifecycleGeneration generation: UInt64) -> CloudreveAPIClient? {
        guard account.isCloudreve, let site = account.cloudreveSiteURL else { return nil }
        var tokens: CloudreveTokens?
        do {
            tokens = try loadCloudreveTokens(accountID: account.id)
        } catch {
            presentedError = "Die Cloudreve-Sitzung im Schlüsselbund konnte nicht gelesen werden: \(error.localizedDescription)"
            SyncLogger.shared.error("app", "Cloudreve-Tokens konnten nicht gelesen werden: \(error.localizedDescription)")
        }
        if let current = tokens, current.refreshTokenExpired {
            tokens = nil
            do {
                try saveCloudreveTokens(nil, accountID: account.id)
            } catch {
                SyncLogger.shared.warning("app", "Abgelaufene Cloudreve-Tokens konnten nicht aus dem Schlüsselbund entfernt werden: \(error.localizedDescription)")
            }
        }
        let accountID = account.id
        do {
            let apiReference = CloudreveAPIReference()
            let api = try CloudreveAPIClient(siteURL: site, tokens: tokens, allowInsecureHTTP: account.allowInsecureHTTP, onTokensChanged: { [weak self] updated in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.lifecycleGeneration == generation,
                          self.account?.id == accountID,
                          let source = apiReference.value,
                          source.currentTokens == updated else { return }
                    do {
                        try self.saveCloudreveTokens(updated, accountID: accountID)
                    } catch {
                        SyncLogger.shared.warning("app", "Cloudreve-Tokens konnten nicht gespeichert werden: \(error.localizedDescription)")
                        self.presentedError = "Die erneuerte Cloudreve-Sitzung konnte nicht im Schlüsselbund gespeichert werden: \(error.localizedDescription)"
                    }
                    self.cloudreveSignedIn = updated != nil
                }
            })
            apiReference.value = api
            cloudreveSignedIn = api.isSignedIn
            return api
        } catch {
            SyncLogger.shared.warning("app", "Cloudreve-Client konnte nicht erstellt werden: \(error.localizedDescription)")
            return nil
        }
    }

    /// Erneute Anmeldung (z. B. nach Ablauf des Refresh-Tokens) aus den Einstellungen.
    func reauthenticateCloudreve(password: String, otp: String?) async throws {
        guard let account, let api = cloudreveAPI, let email = account.cloudreveEmail else {
            throw CloudreveError.authenticationRequired("Keine Cloudreve-Verbindung")
        }
        switch try await api.login(email: email, password: password) {
        case .signedIn:
            break
        case .twoFactorRequired(let sessionID):
            guard let otp, !otp.isEmpty else { throw CloudreveError.twoFactorRequired(sessionID: sessionID) }
            _ = try await api.verifyTwoFactor(sessionID: sessionID, otp: otp)
        }
        cloudreveSignedIn = api.isSignedIn
        await refreshShares()
    }

    // MARK: - Freigaben

    /// Liefert die Cloudreve-URI eines Eintrags des synchronisierten Ordners.
    func shareURI(forRelativePath path: String) throws -> String {
        guard let account, let root = account.davAccountURI else { throw CloudreveError.authenticationRequired("Keine Cloudreve-Verbindung") }
        return try CloudreveURI.fileURI(root: root, relativePath: path)
    }

    /// Relativer Pfad einer lokalen Datei innerhalb des synchronisierten Ordners (oder `nil`).
    func relativePath(for fileURL: URL) -> String? {
        guard let root = localRootURL else { return nil }
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count >= rootComponents.count, Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        let rest = fileComponents.dropFirst(rootComponents.count)
        return rest.isEmpty ? "" : rest.joined(separator: "/")
    }

    /// Erstellt einen Freigabelink für einen Eintrag des synchronisierten Ordners.
    func createShare(relativePath: String, options: CloudreveAPIClient.ShareOptions) async throws -> URL {
        guard let api = cloudreveAPI, api.isSignedIn else { throw CloudreveError.authenticationRequired("Bitte zuerst erneut bei Cloudreve anmelden.") }
        let uri = try shareURI(forRelativePath: relativePath)
        let url = try await api.createShare(uri: uri, options: options)
        SyncLogger.shared.info("app", "Freigabe erstellt für \(relativePath.isEmpty ? "/" : relativePath)")
        await refreshShares()
        return url
    }

    func refreshShares() async {
        guard let account, let api = cloudreveAPI else { shares = []; return }
        let generation = lifecycleGeneration
        let accountID = account.id
        if let store {
            do {
                let cached = try await store.shares(accountID: accountID)
                guard lifecycleGeneration == generation,
                      self.account?.id == accountID,
                      cloudreveAPI === api else { return }
                if !cached.isEmpty, shares.isEmpty { shares = cached }
            } catch {
                guard lifecycleGeneration == generation else { return }
                presentedError = "Der Freigabe-Cache konnte nicht gelesen werden: \(error.localizedDescription)"
                return
            }
        }
        guard api.isSignedIn else { return }
        sharesLoading = true
        defer {
            if lifecycleGeneration == generation, self.account?.id == accountID, cloudreveAPI === api {
                sharesLoading = false
            }
        }
        do {
            let fresh = try await api.listShares()
            guard lifecycleGeneration == generation,
                  self.account?.id == accountID,
                  cloudreveAPI === api else { return }
            shares = fresh
            try await store?.replaceShares(fresh, accountID: accountID)
        } catch let error as CloudreveError {
            guard lifecycleGeneration == generation,
                  self.account?.id == accountID,
                  cloudreveAPI === api else { return }
            if case .authenticationRequired = error { cloudreveSignedIn = false }
            SyncLogger.shared.warning("app", "Freigaben konnten nicht geladen werden: \(error.userDescription)")
            presentedError = error.userDescription
        } catch {
            guard lifecycleGeneration == generation,
                  self.account?.id == accountID,
                  cloudreveAPI === api else { return }
            SyncLogger.shared.warning("app", "Freigaben konnten nicht geladen werden: \(error.localizedDescription)")
            presentedError = "Freigaben konnten nicht geladen werden: \(error.localizedDescription)"
        }
    }

    func deleteShare(_ share: CloudreveShare) async {
        guard let api = cloudreveAPI else { return }
        do {
            try await api.deleteShare(id: share.id)
            shares.removeAll { $0.id == share.id }
            try? await store?.deleteShare(id: share.id)
        } catch let error as CloudreveError {
            presentedError = error.userDescription
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Öffnet einen Dateiauswahldialog, der auf den synchronisierten Ordner beschränkt ist.
    func chooseItemToShare() -> String? {
        guard let root = localRootURL else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Teilen"
        panel.message = "Wähle eine Datei oder einen Ordner aus dem synchronisierten Ordner."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let relative = relativePath(for: url) else {
            presentedError = "Es können nur Dateien und Ordner innerhalb des synchronisierten Ordners geteilt werden."
            return nil
        }
        return relative
    }

    /// Anfrage aus der Oberfläche, für einen Pfad eine Freigabe zu erstellen (öffnet das Formular).
    func requestShare(forRelativePath path: String) {
        shareRequestPath = path
        selectedSection = .shares
        showMainWindow(section: .shares)
    }
}

import AppKit
import Combine
import Foundation
import ReichiSyncCore

/// Bindeglied zwischen Oberfläche und Synchronisierungs-Engine.
@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case overview, activity, conflicts, shares, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Übersicht"
            case .activity: return "Aktivität"
            case .conflicts: return "Konflikte"
            case .shares: return "Freigaben"
            case .settings: return "Einstellungen"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "rectangle.3.group"
            case .activity: return "arrow.up.arrow.down"
            case .conflicts: return "exclamationmark.triangle"
            case .shares: return "link"
            case .settings: return "gearshape"
            }
        }
    }

    @Published var selectedSection: Section = .overview
    @Published private(set) var status = SyncStatus()
    @Published private(set) var account: AccountConfiguration?
    @Published private(set) var transfers: [TransferRecord] = []
    @Published private(set) var conflicts: [ConflictRecord] = []
    @Published private(set) var pendingDeletions: [PendingDeletion] = []
    @Published private(set) var queue: [QueuedItem] = []
    @Published private(set) var logEntries: [LogEntry] = []
    @Published private(set) var loginItemEnabled = false
    @Published private(set) var loginItemRequiresApproval = false
    @Published var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: "showDockIcon")
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        }
    }
    @Published var presentedError: String?
    @Published private(set) var isReady = false
    @Published private(set) var storeError: String?
    /// Cloudreve: API-Sitzung gültig (Chunk-Upload und Freigaben verfügbar).
    @Published var cloudreveSignedIn = false
    @Published var shares: [CloudreveShare] = []
    @Published var sharesLoading = false
    /// Pfad, für den die Oberfläche das Freigabe-Formular öffnen soll.
    @Published var shareRequestPath: String?

    var needsSetup: Bool { isReady && account == nil && storeError == nil }
    var localRootURL: URL? { accessedRoot ?? account.map { URL(fileURLWithPath: $0.localRootPath, isDirectory: true) } }
    /// `true`, wenn die aktuelle Verbindung eine Cloudreve-Instanz ist (Freigaben möglich).
    var isCloudreveAccount: Bool { account?.isCloudreve ?? false }

    var store: SyncStore?
    private var engine: SyncEngine?
    /// Cloudreve-REST-Client (nur bei Cloudreve-Verbindungen).
    var cloudreveAPI: CloudreveAPIClient?
    private var watcher: FolderWatcher?
    private var connectivity: ConnectivityMonitor?
    private var wakeObserver: SleepWakeObserver?
    private var pollTask: Task<Void, Never>?
    private var accessedRoot: URL?
    let keychain = KeychainStore()
    let bookmarks = BookmarkStore()
    let notifications = NotificationService()
    private var logObserver: UUID?
    private var lastStatusRunning = false
    /// Monotoner Lebenszyklus-Token. Jede Start-/Stop-Operation macht alle
    /// älteren Fortsetzungen und Callbacks nach einem `await` wirkungslos.
    private(set) var lifecycleGeneration: UInt64 = 0

    init() {
        showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
        SyncLogger.shared.enableFileLogging(at: AppPaths.logFile)
        do {
            store = try SyncStore(path: AppPaths.database.path)
        } catch {
            storeError = "Die Datenbank konnte nicht geöffnet werden: \(error)"
        }
        logEntries = SyncLogger.shared.recentEntries(limit: 300)
        logObserver = SyncLogger.shared.addObserver { [weak self] entry in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logEntries.append(entry)
                if self.logEntries.count > 500 { self.logEntries.removeFirst(self.logEntries.count - 500) }
            }
        }
    }

    // MARK: - Start

    private var bootstrapped = false
    private var bootstrapTask: Task<Void, Never>?

    /// Startet die Initialisierung als vom Fensterlebenszyklus unabhängige
    /// Aufgabe. Das Schließen des letzten Fensters darf den Menüleistenprozess
    /// nicht in einem halb initialisierten Zustand zurücklassen.
    func beginBootstrap() {
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task { @MainActor [weak self] in
            await self?.bootstrap()
        }
    }

    private func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        refreshLoginItemState()
        guard let store else { isReady = true; return }
        do {
            if let first = (try await store.accounts()).first {
                account = first
                // Beim ersten Start nach einem Schema-Upgrade wird eine aus
                // dem Dateisystem ergänzte Root-Identität dauerhaft gebunden.
                // Sonst könnte ein später ersetzter Ordner am gleichen Pfad
                // bei jedem Neustart als neue legitime Wurzel erscheinen.
                try await store.saveAccount(first)
                if first.notificationsEnabled { await notifications.requestAuthorizationIfNeeded() }
                await startEngine(for: first)
            }
        } catch {
            storeError = "Die gespeicherte Verbindung konnte nicht gelesen werden: \(error.localizedDescription)"
            presentedError = storeError
        }
        isReady = true
    }

    func startEngine(for account: AccountConfiguration) async {
        guard let store else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        await detachAndStopCurrentEngine()
        guard lifecycleGeneration == generation else { return }
        let password: String
        do {
            guard let stored = try keychain.password(accountID: account.id) else {
                var s = SyncStatus()
                s.health = .paused
                s.isPaused = true
                s.pauseReason = .authenticationRequired
                s.lastIssue = SyncIssue(message: "Für diese Verbindung ist kein Passwort im Schlüsselbund hinterlegt.", action: .checkCredentials)
                status = s
                return
            }
            password = stored
        } catch {
            presentedError = error.localizedDescription
            return
        }
        let client: WebDAVClient
        do {
            client = try WebDAVClient(baseURL: account.serverURL, credentials: WebDAVCredentials(username: account.username, password: password),
                                      allowInsecureHTTP: account.allowInsecureHTTP, serverKindHint: account.isCloudreve ? .cloudreve : .generic)
        } catch {
            presentedError = (error as? WebDAVError)?.userDescription ?? error.localizedDescription
            return
        }
        let mapping: SyncMapping
        do {
            mapping = try await store.mapping(for: account)
        } catch {
            if lifecycleGeneration == generation {
                presentedError = "Synchronisierungsstand konnte nicht geladen werden: \(error)"
            }
            return
        }
        guard lifecycleGeneration == generation else { return }
        let api = makeCloudreveClient(for: account, lifecycleGeneration: generation)
        var uploadTransport: ResumableUploadTransport?
        if let api, let rootURI = account.davAccountURI {
            uploadTransport = CloudreveUploadTransport(api: api, dav: client, store: store, mappingID: mapping.id, rootURI: rootURI)
        }
        let config = SyncEngineConfiguration(
            deviceName: Host.current().localizedName ?? "Mac",
            recoveryDirectory: AppPaths.recovery,
            maxConcurrentTransfers: account.maxConcurrentTransfers,
            deletionGuard: DeletionGuard(threshold: account.deletionGuardThreshold, fraction: account.deletionGuardFraction),
            caseInsensitiveLocalFileSystem: true,
            settleTime: 2.0,
            chunkedUploadThreshold: account.chunkedUploadsEnabled ? account.chunkedUploadThreshold : nil
        )
        let root: URL
        do {
            root = try bookmarks.resolveAndStartAccessing(accountID: account.id, fallbackPath: account.localRootPath)
            do {
                try validateSyncFolder(root)
            } catch {
                root.stopAccessingSecurityScopedResource()
                throw error
            }
            let configuredPath = URL(fileURLWithPath: account.localRootPath, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
            let resolvedPath = root.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
            guard configuredPath == resolvedPath else {
                root.stopAccessingSecurityScopedResource()
                throw BookmarkStore.BookmarkError.cannotAccess
            }
            guard account.matchesLocalRootIdentity(atPath: root.path) else {
                root.stopAccessingSecurityScopedResource()
                throw LocalFileError.rootMissing
            }
        } catch {
            var s = SyncStatus()
            s.health = .paused
            s.isPaused = true
            s.pauseReason = .localRootMissing
            s.lastIssue = SyncIssue(
                message: (error as? LocalFileError)?.userDescription
                    ?? "Die Ordnerberechtigung passt nicht zum gespeicherten Synchronisierungsordner. Bitte den Ordner in den Einstellungen erneut auswählen.",
                detail: error.localizedDescription,
                action: .none
            )
            status = s
            return
        }
        guard lifecycleGeneration == generation else {
            root.stopAccessingSecurityScopedResource()
            return
        }
        let candidate = SyncEngine(account: account, mapping: mapping, client: client, store: store, fileSystem: LocalFileSystem(root: root),
                                   rules: ExclusionRules(userPatterns: account.exclusionPatterns), configuration: config, uploadTransport: uploadTransport)
        await candidate.setStatusHandler { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.apply(status)
            }
        }
        let notificationsEnabled = account.notificationsEnabled
        await candidate.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.handle(event, notify: notificationsEnabled)
            }
        }
        await candidate.start()
        guard lifecycleGeneration == generation else {
            await candidate.shutdown()
            root.stopAccessingSecurityScopedResource()
            return
        }

        accessedRoot = root
        cloudreveAPI = api
        engine = candidate
        if api != nil {
            Task { @MainActor [weak self] in
                guard let self, self.lifecycleGeneration == generation else { return }
                await self.refreshShares()
            }
        }
        await refreshLists(generation: generation)
        guard lifecycleGeneration == generation else { return }

        watcher = FolderWatcher(root: root, debounce: 2.0) { [weak candidate] in
            Task { await candidate?.requestSync(trigger: .localChange) }
        }
        if watcher?.start() != true {
            presentedError = "Der lokale Ordner konnte nicht kontinuierlich überwacht werden. Der regelmäßige Abgleich bleibt aktiv."
            watcher = nil
        }
        connectivity = ConnectivityMonitor { [weak candidate] in
            Task { await candidate?.requestSync(trigger: .connectivityRestored) }
        }
        connectivity?.start()
        wakeObserver = SleepWakeObserver { [weak candidate] in
            Task { await candidate?.requestSync(trigger: .wake) }
        }
        let interval = max(15, account.pollInterval)
        pollTask = Task { [weak candidate] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await candidate?.requestSync(trigger: .interval)
            }
        }
        await candidate.requestSync(trigger: .appStart)
    }

    private func stopEngine() async {
        lifecycleGeneration &+= 1
        await detachAndStopCurrentEngine()
    }

    /// Trennt alle Referenzen synchron auf dem Main Actor, bevor auf den alten
    /// Engine-Actor gewartet wird. Dadurch kann eine ältere Stop-Fortsetzung
    /// niemals eine inzwischen installierte neue Engine wieder entfernen.
    private func detachAndStopCurrentEngine() async {
        pollTask?.cancel()
        pollTask = nil
        watcher?.stop()
        watcher = nil
        connectivity?.stop()
        connectivity = nil
        wakeObserver = nil
        let oldEngine = engine
        let oldRoot = accessedRoot
        engine = nil
        cloudreveAPI = nil
        cloudreveSignedIn = false
        accessedRoot = nil
        if let oldEngine { await oldEngine.shutdown() }
        oldRoot?.stopAccessingSecurityScopedResource()
    }

    /// Wird vor dem Beenden aufgerufen: laufende Arbeiten abbrechen, Zustand sichern.
    func prepareForTermination() async {
        await stopEngine()
    }

    // MARK: - Status

    private func apply(_ newStatus: SyncStatus) {
        let finished = lastStatusRunning && !newStatus.isRunning
        let countersChanged = newStatus.openConflicts != status.openConflicts || newStatus.pendingDeletions != status.pendingDeletions
            || newStatus.completedCount != status.completedCount
        lastStatusRunning = newStatus.isRunning
        status = newStatus
        if finished || countersChanged {
            Task { await refreshLists() }
        }
    }

    func refreshLists(generation expectedGeneration: UInt64? = nil) async {
        guard let currentEngine = engine else { return }
        async let newTransfers = currentEngine.transfers()
        async let newConflicts = currentEngine.conflicts()
        async let newPendingDeletions = currentEngine.pendingDeletions()
        async let newQueue = currentEngine.queue()
        let values = await (newTransfers, newConflicts, newPendingDeletions, newQueue)
        guard engine === currentEngine,
              expectedGeneration.map({ $0 == lifecycleGeneration }) != false else { return }
        (transfers, conflicts, pendingDeletions, queue) = values
    }

    private func handle(_ event: SyncEvent, notify: Bool) {
        guard notify else { return }
        switch event {
        case .conflictDetected(let path):
            notifications.post(title: "Konflikt erkannt", body: "„\(RelativePath.name(of: path))“ wurde auf beiden Seiten geändert. Beide Versionen wurden erhalten.", identifier: "conflict-\(path)")
        case .deletionConfirmationRequired(let count):
            notifications.post(title: "Löschungen warten auf Bestätigung", body: "\(count) Einträge würden gelöscht. Bitte in reichi Sync prüfen.", identifier: "deletions")
        case .authenticationRequired:
            notifications.post(title: "Anmeldung erforderlich", body: "Der Server hat die Zugangsdaten abgelehnt. Bitte Benutzername und Passwort prüfen.", identifier: "auth")
        case .diskFull:
            notifications.post(title: "Zu wenig Speicherplatz", body: "Downloads wurden pausiert, bis wieder Speicherplatz frei ist.", identifier: "disk")
        case .syncCompleted(let transferred, let failed) where failed > 0:
            notifications.post(title: "Synchronisierung mit Fehlern", body: "\(transferred) Übertragungen erfolgreich, \(failed) fehlgeschlagen.", identifier: "sync-failed")
        default:
            break
        }
    }

    // MARK: - Aktionen

    func syncNow() {
        Task { await engine?.requestSync(trigger: .manual) }
    }

    func togglePause() {
        Task {
            guard let engine else { return }
            if await engine.currentStatus.isPaused {
                await engine.resume()
            } else {
                await engine.pause()
            }
        }
    }

    func retryFailed() {
        syncNow()
    }

    func openLocalFolder() {
        guard let url = localRootURL else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(path: String) {
        guard let root = localRootURL, let url = try? RelativePath.localURL(root: root, relativePath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func resolve(_ conflict: ConflictRecord, with resolution: ConflictResolution) {
        Task {
            do {
                try await engine?.resolveConflict(id: conflict.id, resolution: resolution)
            } catch SyncEngine.ConflictResolutionError.filesChangedSinceDetection {
                presentedError = "Die beteiligten Dateien wurden seit der Erkennung erneut geändert. Bitte den Konflikt nach dem nächsten Abgleich erneut prüfen."
            } catch SyncEngine.ConflictResolutionError.notApplicable {
                presentedError = "Diese Entscheidung kann für die vorliegenden Datei-/Ordnerarten nicht sicher umgesetzt werden. Bitte beide Versionen behalten oder die Dateien manuell ordnen."
            } catch {
                presentedError = "Die Entscheidung konnte nicht umgesetzt werden: \(error.localizedDescription)"
            }
            await refreshLists()
        }
    }

    func confirmDeletions() {
        Task { await engine?.confirmPendingDeletions(); await refreshLists() }
    }

    func discardDeletions() {
        Task { await engine?.discardPendingDeletions(); await refreshLists() }
    }

    // MARK: - Einrichtung und Einstellungen

    struct ConnectionCheck: Sendable {
        var capabilities: WebDAVCapabilities
    }

    nonisolated func testConnection(urlString: String, username: String, password: String, allowInsecureHTTP: Bool) async throws -> ConnectionCheck {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else {
            throw WebDAVError.invalidResponse("Die Adresse ist ungültig")
        }
        let client = try WebDAVClient(baseURL: url, credentials: WebDAVCredentials(username: username, password: password), allowInsecureHTTP: allowInsecureHTTP)
        _ = try await client.probe()
        let caps = try await client.detectCapabilities()
        return ConnectionCheck(capabilities: caps)
    }

    func validateSyncFolder(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        let path = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: path.path) else {
            throw LocalFileError.io("Der ausgewählte Ordner ist nicht vorhanden oder nicht beschreibbar")
        }
        let folderComponents = path.pathComponents
        let supportComponents = AppPaths.applicationSupport.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let overlapsApplicationState = folderComponents.starts(with: supportComponents)
            || supportComponents.starts(with: folderComponents)
        guard !overlapsApplicationState else {
            throw LocalFileError.io("Der Synchronisierungsordner darf den internen Datenordner von reichi Sync weder enthalten noch darin liegen")
        }
    }

    func completeSetup(name: String, urlString: String, username: String, password: String, folder: URL, allowInsecureHTTP: Bool) async throws {
        guard let store else { throw NSError(domain: "reichi", code: 1, userInfo: [NSLocalizedDescriptionKey: storeError ?? "Datenbank nicht verfügbar"]) }
        try validateSyncFolder(folder)
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw WebDAVError.invalidResponse("Ungültige Adresse") }
        _ = try await testConnection(
            urlString: url.absoluteString,
            username: username,
            password: password,
            allowInsecureHTTP: allowInsecureHTTP
        )
        let newAccount = AccountConfiguration(name: name.isEmpty ? "WebDAV" : name, serverURL: url, username: username,
                                              localRootPath: folder.standardizedFileURL.path, allowInsecureHTTP: allowInsecureHTTP)
        let bookmarkData = try bookmarks.makeData(folder: folder)
        try keychain.savePassword(password, accountID: newAccount.id, label: "reichi Sync – \(newAccount.name)")
        do {
            try await store.saveAccount(newAccount)
        } catch {
            try? keychain.deletePassword(accountID: newAccount.id)
            throw error
        }
        bookmarks.save(data: bookmarkData, accountID: newAccount.id)
        account = newAccount
        if newAccount.notificationsEnabled { await notifications.requestAuthorizationIfNeeded() }
        await startEngine(for: newAccount)
    }

    /// Speichert geänderte Einstellungen. Ändert sich Server-Adresse oder lokaler Ordner,
    /// entsteht automatisch eine neue Zuordnung mit leerem Synchronisierungsstand.
    func updateAccount(_ updated: AccountConfiguration, newPassword: String?, newFolder: URL?) async {
        guard let store else { return }
        var updated = updated
        let oldAccount = account
        do {
            let bookmarkData = try newFolder.map { try bookmarks.makeData(folder: $0) }
            if let newFolder {
                try validateSyncFolder(newFolder)
                updated.setLocalRootPath(newFolder.standardizedFileURL.path)
            }
            let connectionChanged = oldAccount?.serverURL != updated.serverURL
                || oldAccount?.username != updated.username
                || oldAccount?.allowInsecureHTTP != updated.allowInsecureHTTP
                || (newPassword?.isEmpty == false)
            if connectionChanged {
                let effectivePassword: String
                if let newPassword, !newPassword.isEmpty {
                    effectivePassword = newPassword
                } else if let stored = try keychain.password(accountID: updated.id) {
                    effectivePassword = stored
                } else {
                    throw NSError(
                        domain: "de.reichi.sync.settings",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Im Schlüsselbund ist kein Passwort für die Verbindungsprüfung hinterlegt."]
                    )
                }
                let candidate = try WebDAVClient(
                    baseURL: updated.serverURL,
                    credentials: WebDAVCredentials(username: updated.username, password: effectivePassword),
                    allowInsecureHTTP: updated.allowInsecureHTTP,
                    serverKindHint: updated.isCloudreve ? .cloudreve : .generic
                )
                _ = try await candidate.probe()
                guard self.account?.id == updated.id else { return }
            }
            let oldPassword = try newPassword.flatMap { $0.isEmpty ? nil : try keychain.password(accountID: updated.id) }
            if let newPassword, !newPassword.isEmpty {
                try keychain.savePassword(newPassword, accountID: updated.id, label: "reichi Sync – \(updated.name)")
            }
            do {
                try await store.saveAccount(updated)
            } catch {
                if let newPassword, !newPassword.isEmpty {
                    if let oldPassword {
                        try? keychain.savePassword(oldPassword, accountID: updated.id, label: "reichi Sync – \(oldAccount?.name ?? updated.name)")
                    } else {
                        try? keychain.deletePassword(accountID: updated.id)
                    }
                }
                throw error
            }
            if let bookmarkData { bookmarks.save(data: bookmarkData, accountID: updated.id) }
        } catch {
            presentedError = error.localizedDescription
            return
        }
        let needsRestart = account.map { $0.mappingKey != updated.mappingKey || $0.pollInterval != updated.pollInterval || $0.exclusionPatterns != updated.exclusionPatterns
            || $0.maxConcurrentTransfers != updated.maxConcurrentTransfers || $0.allowInsecureHTTP != updated.allowInsecureHTTP || $0.username != updated.username
            || $0.deletionGuardThreshold != updated.deletionGuardThreshold || $0.notificationsEnabled != updated.notificationsEnabled
            || $0.chunkedUploadsEnabled != updated.chunkedUploadsEnabled || $0.chunkedUploadThreshold != updated.chunkedUploadThreshold } ?? true
        account = updated
        if needsRestart || newPassword != nil || newFolder != nil {
            if updated.notificationsEnabled { await notifications.requestAuthorizationIfNeeded() }
            await startEngine(for: updated)
        }
    }

    func removeAccount() async {
        guard let store, let account else { return }
        let apiForRevocation = cloudreveAPI
        await stopEngine()
        do {
            try await store.deleteAccount(id: account.id)
        } catch {
            presentedError = "Die Verbindung konnte nicht entfernt werden: \(error.localizedDescription)"
            await startEngine(for: account)
            return
        }
        var cleanupIssues: [String] = []
        if account.davAccountManaged, let davAccountID = account.davAccountID {
            if let apiForRevocation, apiForRevocation.isSignedIn {
                do {
                    try await apiForRevocation.deleteDavAccount(id: davAccountID)
                } catch {
                    cleanupIssues.append("Das von der App angelegte Cloudreve-WebDAV-Konto konnte nicht widerrufen werden: \(error.localizedDescription)")
                }
            } else {
                cleanupIssues.append("Das von der App angelegte Cloudreve-WebDAV-Konto konnte ohne gültige Anmeldung nicht widerrufen werden. Bitte entferne es in Cloudreve manuell.")
            }
        }
        do {
            try keychain.deletePassword(accountID: account.id)
            try keychain.deletePassword(accountID: Self.cloudreveTokenKey(accountID: account.id))
        } catch {
            cleanupIssues.append("Schlüsselbunddaten konnten nicht vollständig gelöscht werden: \(error.localizedDescription)")
        }
        bookmarks.remove(accountID: account.id)
        self.account = nil
        status = SyncStatus()
        transfers = []
        conflicts = []
        pendingDeletions = []
        queue = []
        shares = []
        if !cleanupIssues.isEmpty {
            presentedError = "Die Verbindung wurde lokal entfernt. " + cleanupIssues.joined(separator: "\n")
        }
    }

    func chooseFolder(prompt: String = "Ordner auswählen") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = "Wähle den Ordner, der mit dem Server synchronisiert werden soll."
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Start bei Anmeldung

    func refreshLoginItemState() {
        loginItemEnabled = LoginItemManager.isEnabled
        loginItemRequiresApproval = LoginItemManager.requiresApproval
    }

    func setLoginItem(enabled: Bool) {
        do {
            try LoginItemManager.setEnabled(enabled)
        } catch {
            presentedError = "Start bei der Anmeldung konnte nicht geändert werden: \(error.localizedDescription)"
        }
        refreshLoginItemState()
    }

    // MARK: - Fenster

    /// Wird von der App-Struktur gesetzt (`openWindow(id: "main")`).
    var openMainWindowHandler: (() -> Void)?

    func showMainWindow(section: Section? = nil) {
        if let section { selectedSection = section }
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "reichi Sync" }), window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowHandler?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

extension SyncStatus {
    /// SF Symbol für die Menüleiste.
    var menuBarSymbol: String {
        switch health {
        case .synced: return "checkmark.circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        case .paused: return "pause.circle"
        case .conflicts: return "exclamationmark.triangle"
        case .attention: return "exclamationmark.circle"
        case .setupRequired: return "gearshape"
        }
    }

    /// Großes Symbol für Übersicht und Popover.
    var statusSymbol: String {
        switch health {
        case .synced: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath.circle.fill"
        case .offline: return "wifi.exclamationmark"
        case .paused: return "pause.circle.fill"
        case .conflicts: return "exclamationmark.triangle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .setupRequired: return "gearshape.circle.fill"
        }
    }

    /// Beschreibung für VoiceOver.
    var accessibilityDescription: String {
        "reichi Sync: \(headline)"
    }
}

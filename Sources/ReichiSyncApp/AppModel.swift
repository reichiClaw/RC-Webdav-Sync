import AppKit
import Combine
import Foundation
import ReichiSyncCore

/// Bindeglied zwischen Oberfläche und Synchronisierungs-Engine.
@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case overview, activity, conflicts, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Übersicht"
            case .activity: return "Aktivität"
            case .conflicts: return "Konflikte"
            case .settings: return "Einstellungen"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "rectangle.3.group"
            case .activity: return "arrow.up.arrow.down"
            case .conflicts: return "exclamationmark.triangle"
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

    var needsSetup: Bool { isReady && account == nil }
    var localRootURL: URL? { accessedRoot ?? account.map { URL(fileURLWithPath: $0.localRootPath, isDirectory: true) } }

    private var store: SyncStore?
    private var engine: SyncEngine?
    private var watcher: FolderWatcher?
    private var connectivity: ConnectivityMonitor?
    private var wakeObserver: SleepWakeObserver?
    private var pollTask: Task<Void, Never>?
    private var accessedRoot: URL?
    private let keychain = KeychainStore()
    private let bookmarks = BookmarkStore()
    private let notifications = NotificationService()
    private var logObserver: UUID?
    private var lastStatusRunning = false

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

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        refreshLoginItemState()
        guard let store else { isReady = true; return }
        if let first = (try? await store.accounts())?.first {
            account = first
            if first.notificationsEnabled { await notifications.requestAuthorizationIfNeeded() }
            await startEngine(for: first)
        }
        isReady = true
    }

    private func startEngine(for account: AccountConfiguration) async {
        guard let store else { return }
        await stopEngine()
        let root: URL
        do {
            root = try bookmarks.resolveAndStartAccessing(accountID: account.id, fallbackPath: account.localRootPath)
            accessedRoot = root
        } catch {
            var s = SyncStatus()
            s.health = .paused
            s.isPaused = true
            s.pauseReason = .localRootMissing
            s.lastIssue = SyncIssue(message: error.localizedDescription, action: .none)
            status = s
            return
        }
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
                                      allowInsecureHTTP: account.allowInsecureHTTP)
        } catch {
            presentedError = (error as? WebDAVError)?.userDescription ?? error.localizedDescription
            return
        }
        let mapping: SyncMapping
        do {
            mapping = try await store.mapping(for: account)
        } catch {
            presentedError = "Synchronisierungsstand konnte nicht geladen werden: \(error)"
            return
        }
        let config = SyncEngineConfiguration(
            deviceName: Host.current().localizedName ?? "Mac",
            recoveryDirectory: AppPaths.recovery,
            maxConcurrentTransfers: account.maxConcurrentTransfers,
            deletionGuard: DeletionGuard(threshold: account.deletionGuardThreshold, fraction: account.deletionGuardFraction),
            caseInsensitiveLocalFileSystem: true,
            settleTime: 2.0
        )
        let engine = SyncEngine(account: account, mapping: mapping, client: client, store: store, fileSystem: LocalFileSystem(root: root),
                                rules: ExclusionRules(userPatterns: account.exclusionPatterns), configuration: config)
        self.engine = engine
        await engine.setStatusHandler { [weak self] status in
            Task { @MainActor [weak self] in self?.apply(status) }
        }
        let notificationsEnabled = account.notificationsEnabled
        await engine.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event, notify: notificationsEnabled) }
        }
        await engine.start()
        await refreshLists()

        watcher = FolderWatcher(root: root, debounce: 2.0) { [weak engine] in
            Task { await engine?.requestSync(trigger: .localChange) }
        }
        watcher?.start()
        connectivity = ConnectivityMonitor { [weak engine] in
            Task { await engine?.requestSync(trigger: .connectivityRestored) }
        }
        connectivity?.start()
        wakeObserver = SleepWakeObserver { [weak self] in
            Task { await self?.engine?.requestSync(trigger: .wake) }
        }
        let interval = max(15, account.pollInterval)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.engine?.requestSync(trigger: .interval)
            }
        }
        await engine.requestSync(trigger: .appStart)
    }

    private func stopEngine() async {
        pollTask?.cancel()
        pollTask = nil
        watcher?.stop()
        watcher = nil
        connectivity?.stop()
        connectivity = nil
        wakeObserver = nil
        if let engine {
            await engine.shutdown()
        }
        engine = nil
        accessedRoot?.stopAccessingSecurityScopedResource()
        accessedRoot = nil
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

    func refreshLists() async {
        guard let engine else { return }
        transfers = await engine.transfers()
        conflicts = await engine.conflicts()
        pendingDeletions = await engine.pendingDeletions()
        queue = await engine.queue()
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

    func completeSetup(name: String, urlString: String, username: String, password: String, folder: URL, allowInsecureHTTP: Bool) async throws {
        guard let store else { throw NSError(domain: "reichi", code: 1, userInfo: [NSLocalizedDescriptionKey: storeError ?? "Datenbank nicht verfügbar"]) }
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw WebDAVError.invalidResponse("Ungültige Adresse") }
        let newAccount = AccountConfiguration(name: name.isEmpty ? "WebDAV" : name, serverURL: url, username: username,
                                              localRootPath: folder.standardizedFileURL.path, allowInsecureHTTP: allowInsecureHTTP)
        try bookmarks.save(folder: folder, accountID: newAccount.id)
        try keychain.savePassword(password, accountID: newAccount.id, label: "reichi Sync – \(newAccount.name)")
        try await store.saveAccount(newAccount)
        account = newAccount
        if newAccount.notificationsEnabled { await notifications.requestAuthorizationIfNeeded() }
        await startEngine(for: newAccount)
    }

    /// Speichert geänderte Einstellungen. Ändert sich Server-Adresse oder lokaler Ordner,
    /// entsteht automatisch eine neue Zuordnung mit leerem Synchronisierungsstand.
    func updateAccount(_ updated: AccountConfiguration, newPassword: String?, newFolder: URL?) async {
        guard let store else { return }
        var updated = updated
        do {
            if let newFolder {
                try bookmarks.save(folder: newFolder, accountID: updated.id)
                updated.localRootPath = newFolder.standardizedFileURL.path
            }
            if let newPassword, !newPassword.isEmpty {
                try keychain.savePassword(newPassword, accountID: updated.id, label: "reichi Sync – \(updated.name)")
            }
            try await store.saveAccount(updated)
        } catch {
            presentedError = error.localizedDescription
            return
        }
        let needsRestart = account.map { $0.mappingKey != updated.mappingKey || $0.pollInterval != updated.pollInterval || $0.exclusionPatterns != updated.exclusionPatterns
            || $0.maxConcurrentTransfers != updated.maxConcurrentTransfers || $0.allowInsecureHTTP != updated.allowInsecureHTTP || $0.username != updated.username
            || $0.deletionGuardThreshold != updated.deletionGuardThreshold || $0.notificationsEnabled != updated.notificationsEnabled } ?? true
        account = updated
        if needsRestart || newPassword != nil || newFolder != nil {
            if updated.notificationsEnabled { await notifications.requestAuthorizationIfNeeded() }
            await startEngine(for: updated)
        }
    }

    func removeAccount() async {
        guard let store, let account else { return }
        await stopEngine()
        try? keychain.deletePassword(accountID: account.id)
        bookmarks.remove(accountID: account.id)
        try? await store.deleteAccount(id: account.id)
        self.account = nil
        status = SyncStatus()
        transfers = []
        conflicts = []
        pendingDeletions = []
        queue = []
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

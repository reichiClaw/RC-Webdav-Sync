import Foundation

/// Auslöser eines Abgleichs (für Protokoll und Priorisierung).
public enum SyncTrigger: String, Sendable {
    case appStart, manual, interval, localChange, wake, connectivityRestored, retry, followUp, conflictResolution
}

/// Konfiguration der Engine.
public struct SyncEngineConfiguration: Sendable {
    public var deviceName: String
    public var recoveryDirectory: URL?
    public var maxConcurrentTransfers: Int
    public var deletionGuard: DeletionGuard
    public var caseInsensitiveLocalFileSystem: Bool
    public var settleTime: TimeInterval
    /// Mindestfreiraum, der nach einem Download auf dem Volume verbleiben soll.
    public var minimumFreeSpace: Int64
    /// Ab dieser Dateigröße wird – falls eine `ResumableUploadTransport` konfiguriert ist – in
    /// Chunks hochgeladen. `nil` deaktiviert den Chunk-Upload.
    public var chunkedUploadThreshold: Int64?

    public init(deviceName: String, recoveryDirectory: URL? = nil, maxConcurrentTransfers: Int = 3, deletionGuard: DeletionGuard = DeletionGuard(),
                caseInsensitiveLocalFileSystem: Bool = true, settleTime: TimeInterval = 2.0, minimumFreeSpace: Int64 = 200 * 1024 * 1024,
                chunkedUploadThreshold: Int64? = AccountConfiguration.defaultChunkedUploadThreshold) {
        self.deviceName = deviceName
        self.recoveryDirectory = recoveryDirectory
        self.maxConcurrentTransfers = max(1, maxConcurrentTransfers)
        self.deletionGuard = deletionGuard
        self.caseInsensitiveLocalFileSystem = caseInsensitiveLocalFileSystem
        self.settleTime = settleTime
        self.minimumFreeSpace = minimumFreeSpace
        self.chunkedUploadThreshold = chunkedUploadThreshold
    }
}

/// Ergebnis eines Abgleichdurchgangs.
public struct SyncRunSummary: Sendable, Equatable {
    public var transferred = 0
    public var failed = 0
    public var skipped = 0
    public var conflictsCreated = 0
    public var deletionsHeld = 0
    public var needsFollowUp = false
    public var offline = false
    public init() {}
}

/// Zentrale Synchronisierungs-Engine.
///
/// Ablauf eines Durchgangs:
/// 1. Lokaler Stammordner vorhanden? Sonst pausieren.
/// 2. Server erreichbar (`PROPFIND Depth: 0`)? Sonst offline mit Backoff.
/// 3. Lokale Bestandsaufnahme (mit Hash-Cache).
/// 4. Server-Bestandsaufnahme (sync-collection oder vollständige Traversierung).
/// 5. Drei-Wege-Planung gegen den gemeinsamen Stand.
/// 6. Löschschutz prüfen.
/// 7. Aktionen ausführen; gemeinsamen Stand nur nach bestätigtem Erfolg aktualisieren.
public actor SyncEngine {
    public let account: AccountConfiguration
    public let mapping: SyncMapping
    private let client: WebDAVClientProtocol
    private let store: SyncStore
    private let fileSystem: LocalFileSystem
    private let rules: ExclusionRules
    private let config: SyncEngineConfiguration
    private let logger: SyncLogger
    private let uploadTransport: ResumableUploadTransport?

    private var status = SyncStatus()
    private var statusHandler: (@Sendable (SyncStatus) -> Void)?
    private var eventHandler: (@Sendable (SyncEvent) -> Void)?

    private var runningTask: Task<Void, Never>?
    private var rerunRequested = false
    private var retryPolicy = RetryPolicy()
    private var retryTask: Task<Void, Never>?
    private var capabilities: WebDAVCapabilities?
    private var allowedDeletions: Set<String>?
    private var downloadsPausedForDiskSpace = false
    private var lastRemoteSnapshot: RemoteSnapshot?
    private var isShutDown = false

    public init(account: AccountConfiguration, mapping: SyncMapping, client: WebDAVClientProtocol, store: SyncStore,
                fileSystem: LocalFileSystem, rules: ExclusionRules, configuration: SyncEngineConfiguration,
                uploadTransport: ResumableUploadTransport? = nil, logger: SyncLogger = .shared) {
        self.uploadTransport = uploadTransport
        self.account = account
        self.mapping = mapping
        self.client = client
        self.store = store
        self.fileSystem = fileSystem
        self.rules = rules
        self.config = configuration
        self.logger = logger
    }

    // MARK: - Öffentliche Schnittstelle

    public func setStatusHandler(_ handler: @escaping @Sendable (SyncStatus) -> Void) {
        statusHandler = handler
        handler(status)
    }

    public func setEventHandler(_ handler: @escaping @Sendable (SyncEvent) -> Void) {
        eventHandler = handler
    }

    public var currentStatus: SyncStatus { status }

    /// Lädt den gespeicherten Zustand und bereitet die Engine vor.
    public func start() async {
        try? await store.markRunningTransfersInterrupted(mappingID: mapping.id)
        fileSystem.cleanupTemporaryFiles()
        status.health = .synced
        status.lastSuccessfulSync = mapping.lastSuccessfulSync
        await refreshCounters()
        if (try? await store.queue(mappingID: mapping.id).count) ?? 0 > 0 { status.health = .attention }
        publish()
    }

    /// Fordert einen Abgleich an. Läuft bereits einer, wird im Anschluss ein weiterer ausgeführt.
    public func requestSync(trigger: SyncTrigger) {
        guard !isShutDown else { return }
        if status.isPaused && status.pauseReason == .user && trigger != .manual {
            return
        }
        if status.isPaused && status.pauseReason == .user && trigger == .manual {
            status.isPaused = false
            status.pauseReason = nil
        }
        retryTask?.cancel()
        retryTask = nil
        if runningTask != nil {
            rerunRequested = true
            logger.debug("engine", "Abgleich angefordert (\(trigger.rawValue)) – läuft bereits, wird wiederholt")
            return
        }
        logger.info("engine", "Abgleich gestartet (\(trigger.rawValue))")
        runningTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(trigger: trigger)
            await self.finishedRunning()
        }
    }

    private func finishedRunning() {
        runningTask = nil
    }

    /// Führt einen Abgleich aus und wartet auf dessen Abschluss (für Tests und Skripte).
    public func syncAndWait(trigger: SyncTrigger = .manual) async {
        while let running = runningTask { _ = await running.value }
        requestSync(trigger: trigger)
        while let running = runningTask { _ = await running.value }
    }

    public func pause() {
        status.isPaused = true
        status.pauseReason = .user
        status.health = .paused
        runningTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        publish()
    }

    public func resume() {
        guard status.isPaused else { return }
        status.isPaused = false
        status.pauseReason = nil
        downloadsPausedForDiskSpace = false
        recomputeHealth()
        publish()
        requestSync(trigger: .manual)
    }

    /// Bricht laufende Arbeiten ab und sichert den Zustand.
    public func shutdown() async {
        isShutDown = true
        retryTask?.cancel()
        runningTask?.cancel()
        _ = await runningTask?.value
        try? await store.markRunningTransfersInterrupted(mappingID: mapping.id)
    }

    public func transfers(limit: Int = 300) async -> [TransferRecord] {
        (try? await store.transfers(mappingID: mapping.id, limit: limit)) ?? []
    }

    public func conflicts() async -> [ConflictRecord] {
        (try? await store.conflicts(mappingID: mapping.id)) ?? []
    }

    public func queue() async -> [QueuedItem] {
        (try? await store.queue(mappingID: mapping.id)) ?? []
    }

    public func pendingDeletions() async -> [PendingDeletion] {
        (try? await store.pendingDeletions(mappingID: mapping.id)) ?? []
    }

    /// Gibt die zurückgehaltenen Löschungen frei (Löschschutz).
    public func confirmPendingDeletions() async {
        let pending = await pendingDeletions()
        allowedDeletions = Set(pending.map(\.path))
        try? await store.clearPendingDeletions(mappingID: mapping.id)
        await refreshCounters()
        publish()
        requestSync(trigger: .manual)
    }

    /// Verwirft die zurückgehaltenen Löschungen: Die betroffenen Einträge werden aus dem
    /// gemeinsamen Stand entfernt, sodass die noch vorhandene Seite als „neu“ gilt und
    /// wiederhergestellt (erneut übertragen) wird.
    public func discardPendingDeletions() async {
        let pending = await pendingDeletions()
        for p in pending {
            try? await store.removeBaselineSubtree(path: p.path, mappingID: mapping.id)
        }
        try? await store.clearPendingDeletions(mappingID: mapping.id)
        allowedDeletions = []
        await refreshCounters()
        publish()
        requestSync(trigger: .manual)
    }

    // MARK: - Konfliktauflösung

    public enum ConflictResolutionError: Error, Sendable, Equatable {
        case notFound
        case filesChangedSinceDetection
        case notApplicable
    }

    /// Setzt eine Benutzerentscheidung um. Vorher wird geprüft, ob die beteiligten
    /// Dateien seit der Erkennung unverändert sind.
    public func resolveConflict(id: String, resolution: ConflictResolution) async throws {
        let all = (try? await store.conflicts(mappingID: mapping.id)) ?? []
        guard var conflict = all.first(where: { $0.id == id }) else { throw ConflictResolutionError.notFound }
        let baseline = (try? await store.baseline(mappingID: mapping.id)) ?? [:]
        switch conflict.reason {
        case .bothModified, .initialMergeDiffers, .kindMismatch:
            // Am Pfad liegt die Serverversion, die lokale Version in der Konfliktkopie.
            guard let copyPath = conflict.conflictCopyPath else { throw ConflictResolutionError.notApplicable }
            let pathAttrs = try fileSystem.attributes(conflict.path)
            let copyAttrs = try fileSystem.attributes(copyPath)
            switch resolution {
            case .keepBoth:
                break
            case .useLocal:
                guard let pathAttrs, let copyAttrs, pathAttrs.kind == .file, copyAttrs.kind == .file else { throw ConflictResolutionError.notApplicable }
                // Serverversion am Pfad darf seit der Erkennung nicht verändert worden sein.
                if let expected = baseline[conflict.path]?.localHash, try fileSystem.hash(conflict.path) != expected {
                    throw ConflictResolutionError.filesChangedSinceDetection
                }
                if let localHash = conflict.localHash, try fileSystem.hash(copyPath) != localHash {
                    throw ConflictResolutionError.filesChangedSinceDetection
                }
                let temp = try fileSystem.makeTemporaryFileURL()
                try FileManager.default.copyItem(at: fileSystem.url(copyPath), to: temp)
                try fileSystem.installDownloadedFile(from: temp, to: conflict.path, expectedHash: baseline[conflict.path]?.localHash,
                                                     expectedSize: nil, expectedModified: nil, modifiedDate: Date())
                try fileSystem.trash(copyPath, recoveryDirectory: config.recoveryDirectory)
            case .useRemote:
                guard copyAttrs != nil else { throw ConflictResolutionError.notApplicable }
                if let localHash = conflict.localHash, copyAttrs?.kind == .file, try fileSystem.hash(copyPath) != localHash {
                    throw ConflictResolutionError.filesChangedSinceDetection
                }
                try fileSystem.trash(copyPath, recoveryDirectory: config.recoveryDirectory)
            case .applyDeletion:
                throw ConflictResolutionError.notApplicable
            }
        case .modifiedLocallyDeletedRemotely, .deletedLocallyModifiedRemotely:
            switch resolution {
            case .keepBoth, .useLocal, .useRemote:
                break // Die erhaltene Version liegt bereits auf beiden Seiten.
            case .applyDeletion:
                guard let attrs = try fileSystem.attributes(conflict.path) else { throw ConflictResolutionError.notApplicable }
                if attrs.kind == .file, let expected = baseline[conflict.path]?.localHash, try fileSystem.hash(conflict.path) != expected {
                    throw ConflictResolutionError.filesChangedSinceDetection
                }
                try fileSystem.trash(conflict.path, recoveryDirectory: config.recoveryDirectory)
                // Der nächste Abgleich erkennt die lokale Löschung und überträgt sie (mit If-Match).
            }
        }
        conflict.status = .resolved
        conflict.resolution = resolution
        try await store.saveConflict(conflict, mappingID: mapping.id)
        await refreshCounters()
        publish()
        requestSync(trigger: .conflictResolution)
    }

    // MARK: - Durchlauf

    private func runLoop(trigger: SyncTrigger) async {
        var iterations = 0
        var currentTrigger = trigger
        repeat {
            rerunRequested = false
            iterations += 1
            let summary = await performSync(trigger: currentTrigger)
            if Task.isCancelled { break }
            if summary.offline { break }
            if summary.needsFollowUp && iterations < 4 {
                rerunRequested = true
                currentTrigger = .followUp
            }
        } while rerunRequested && iterations < 4 && !Task.isCancelled
        if rerunRequested && !Task.isCancelled {
            // Mehr als vier Durchgänge hintereinander: kurz warten und erneut planen.
            scheduleRetry(after: 5, reason: nil)
        }
    }

    private func performSync(trigger: SyncTrigger) async -> SyncRunSummary {
        var summary = SyncRunSummary()
        status.isRunning = true
        status.lastAttempt = Date()
        status.completedCount = 0
        status.totalCount = 0
        status.bytesDone = 0
        status.bytesTotal = 0
        status.activeTransfers = []
        status.lastIssue = nil
        status.health = .syncing
        status.currentStep = "Prüfe lokalen Ordner …"
        publish()

        defer {
            status.isRunning = false
            status.currentStep = nil
            status.activeTransfers = []
            recomputeHealth()
            publish()
        }

        // 1. Lokaler Stammordner
        guard fileSystem.rootExists() else {
            logger.warning("engine", "Lokaler Stammordner fehlt – Abgleich pausiert")
            status.isPaused = true
            status.pauseReason = .localRootMissing
            status.lastIssue = SyncIssue(message: "Der lokale Ordner ist nicht verfügbar. Die Synchronisierung ist pausiert, bis er wieder erreichbar ist.", action: .checkServer)
            summary.failed = 1
            return summary
        }
        if status.pauseReason == .localRootMissing {
            status.isPaused = false
            status.pauseReason = nil
        }

        // 2. Erreichbarkeit
        status.currentStep = "Prüfe Verbindung zum Server …"
        publish()
        do {
            _ = try await client.probe()
            if capabilities == nil {
                capabilities = try? await client.detectCapabilities()
                status.capabilities = capabilities
            }
        } catch {
            return handleConnectivityFailure(error, summary: summary)
        }
        if status.pauseReason == .authenticationRequired {
            status.isPaused = false
            status.pauseReason = nil
        }
        if status.health == .offline { eventHandler?(.cameOnline) }
        retryPolicy.reset()

        // 3. Lokale Bestandsaufnahme
        status.currentStep = "Lese lokalen Ordner …"
        publish()
        let scanner = LocalScanner(fileSystem: fileSystem, rules: rules, settleTime: config.settleTime)
        let previousIndex = (try? await store.localIndex(mappingID: mapping.id)) ?? [:]
        let scanResult: LocalScanner.Result
        do {
            scanResult = try await Task.detached(priority: .utility) { [scanner, previousIndex] in
                try scanner.scan(previousIndex: previousIndex, isCancelled: { Task.isCancelled })
            }.value
        } catch {
            if error is CancellationError { return summary }
            logger.error("engine", "Lokale Bestandsaufnahme fehlgeschlagen: \(error)")
            status.lastIssue = SyncIssue(message: "Der lokale Ordner konnte nicht gelesen werden.", detail: "\(error)", action: .retry)
            summary.failed = 1
            return summary
        }
        try? await store.replaceLocalIndex(scanResult.hashIndex, mappingID: mapping.id)
        if Task.isCancelled { return summary }

        // 4. Server-Bestandsaufnahme
        status.currentStep = "Lese Serverbestand …"
        publish()
        let remoteSnapshot: RemoteSnapshot
        do {
            remoteSnapshot = try await enumerateRemote()
        } catch {
            return handleConnectivityFailure(error, summary: summary)
        }
        lastRemoteSnapshot = remoteSnapshot
        if Task.isCancelled { return summary }

        // 5. Planung
        status.currentStep = "Vergleiche Bestände …"
        publish()
        let baseline = (try? await store.baseline(mappingID: mapping.id)) ?? [:]
        let openConflicts = (try? await store.conflicts(mappingID: mapping.id)) ?? []
        let input = PlannerInput(baseline: baseline, local: scanResult.snapshot, remote: remoteSnapshot,
                                 openConflictPaths: Set(openConflicts.map(\.path)),
                                 caseInsensitiveLocalFileSystem: config.caseInsensitiveLocalFileSystem,
                                 allowedDeletions: allowedDeletions)
        var plan = SyncPlanner.plan(input)
        if let reason = plan.deletionsSuppressedReason {
            logger.warning("engine", reason)
            status.lastIssue = SyncIssue(message: remoteSnapshot.isComplete
                                         ? "Der lokale Ordner konnte nicht vollständig gelesen werden. Löschungen wurden sicherheitshalber nicht übertragen."
                                         : "Teile des Serverbestands konnten nicht gelesen werden. Löschungen wurden sicherheitshalber nicht übertragen.",
                                         detail: remoteSnapshot.failedPrefixes.sorted().joined(separator: ", "), action: .retry)
        }
        let collisions = plan.collisions + scanResult.collisions
        if !collisions.isEmpty {
            status.lastIssue = SyncIssue(message: collisions.count == 1
                                         ? "Ein Eintrag kann wegen eines Namenskonflikts nicht synchronisiert werden."
                                         : "\(collisions.count) Einträge können wegen Namenskonflikten nicht synchronisiert werden.",
                                         detail: collisions.sorted().joined(separator: ", "), action: .renameFile)
        }
        for case .skip(let path, let reason) in plan.skipped where !scanResult.snapshot.busyPaths.contains(path) {
            var record = TransferRecord(id: "skip|" + path, path: path, direction: .upload, state: .skipped)
            record.finishedAt = Date()
            record.errorMessage = reason
            record.suggestedAction = collisions.contains(path) ? SuggestedAction.renameFile : nil
            try? await store.saveTransfer(record, mappingID: mapping.id)
        }

        // 6. Löschschutz
        let impact = plan.deletionImpact(baseline: baseline)
        if allowedDeletions == nil, config.deletionGuard.requiresConfirmation(deletionImpact: impact, baselineCount: baseline.count, localItemCount: scanResult.snapshot.items.count) {
            var held: [PendingDeletion] = []
            for action in plan.deletions {
                switch action {
                case .deleteRemote(let p, let r): held.append(PendingDeletion(path: p, kind: r.kind, side: .remote))
                case .deleteLocal(let p, let l): held.append(PendingDeletion(path: p, kind: l.kind, side: .local))
                default: break
                }
            }
            try? await store.replacePendingDeletions(held, mappingID: mapping.id)
            summary.deletionsHeld = held.count
            logger.notice("engine", "Löschschutz: \(impact) Einträge betroffen – Bestätigung erforderlich")
            plan.deletions.removeAll()
            eventHandler?(.deletionConfirmationRequired(count: held.count))
        } else if allowedDeletions != nil {
            // Freigabe gilt genau für einen Durchgang.
            allowedDeletions = nil
        }

        // Warteschlange für die Anzeige speichern.
        let queued = plan.allActions.compactMap { a -> QueuedItem? in
            guard let dir = a.direction else { return nil }
            return QueuedItem(path: a.path, direction: dir, size: a.estimatedBytes)
        }
        try? await store.replaceQueue(queued, mappingID: mapping.id)
        status.pendingCount = queued.count
        status.pendingBytes = plan.estimatedBytes
        status.totalCount = plan.transferCount
        status.bytesTotal = plan.estimatedBytes
        status.skippedCount = plan.skipped.count
        summary.skipped = plan.skipped.count
        publish()
        logger.info("engine", "Plan: \(plan.directoryCreations.count) Ordner, \(plan.moves.count) Umbenennungen, \(plan.transfers.count) Transfers, \(plan.deletions.count) Löschungen, \(plan.skipped.count) übersprungen")

        // 7. Ausführung
        var failures = 0
        var transferred = 0
        for phase in [plan.directoryCreations, plan.moves] {
            for action in phase {
                if Task.isCancelled { return summary }
                let result = await execute(action, snapshot: remoteSnapshot)
                tally(result, &transferred, &failures, &summary)
            }
        }
        for result in await executeConcurrently(plan.transfers, snapshot: remoteSnapshot) {
            tally(result, &transferred, &failures, &summary)
        }
        if Task.isCancelled { return summary }
        for action in plan.deletions {
            if Task.isCancelled { return summary }
            let result = await execute(action, snapshot: remoteSnapshot)
            tally(result, &transferred, &failures, &summary)
            status.completedCount += 1
        }
        for action in plan.bookkeeping {
            let result = await execute(action, snapshot: remoteSnapshot)
            tally(result, &transferred, &failures, &summary)
        }

        summary.transferred = transferred
        summary.failed = failures
        try? await store.pruneTransfers(mappingID: mapping.id)

        // Verbleibende Warteschlange: nur fehlgeschlagene/zurückgestellte Einträge.
        let remaining = (try? await store.queue(mappingID: mapping.id)) ?? []
        status.pendingCount = remaining.count + scanResult.snapshot.busyPaths.count
        if !scanResult.snapshot.busyPaths.isEmpty { summary.needsFollowUp = true }

        if failures == 0 && scanResult.snapshot.isComplete && remoteSnapshot.isComplete {
            let now = Date()
            try? await store.setLastSuccessfulSync(now, mappingID: mapping.id)
            status.lastSuccessfulSync = now
        }
        await refreshCounters()
        if transferred > 0 || failures > 0 {
            eventHandler?(.syncCompleted(transferred: transferred, failed: failures))
        }
        logger.info("engine", "Abgleich beendet: \(transferred) übertragen, \(failures) fehlgeschlagen, \(summary.conflictsCreated) Konflikte")
        return summary
    }

    private func tally(_ result: ActionResult, _ transferred: inout Int, _ failures: inout Int, _ summary: inout SyncRunSummary) {
        switch result {
        case .succeeded: transferred += 1
        case .failed: failures += 1
        case .deferred: summary.needsFollowUp = true
        case .conflict:
            transferred += 1
            summary.conflictsCreated += 1
            summary.needsFollowUp = true
        case .noop: break
        }
    }

    private func handleConnectivityFailure(_ error: Error, summary: SyncRunSummary) -> SyncRunSummary {
        var summary = summary
        summary.failed = 1
        if error is CancellationError { return summary }
        let dav = (error as? WebDAVError) ?? WebDAVClient.mapTransportError(error)
        logger.warning("engine", "Server nicht verwendbar: \(dav.technicalDescription)")
        switch dav {
        case .authenticationRequired, .forbidden:
            status.isPaused = true
            status.pauseReason = .authenticationRequired
            status.lastIssue = SyncIssue(message: dav.userDescription, detail: dav.technicalDescription, action: .checkCredentials)
            eventHandler?(.authenticationRequired)
        case .cancelled:
            break
        default:
            let wasOnline = status.health != .offline
            summary.offline = true
            status.lastIssue = SyncIssue(message: dav.userDescription, detail: dav.technicalDescription, action: dav.suggestedAction)
            let delay = retryPolicy.recordFailure()
            scheduleRetry(after: delay, reason: dav)
            if wasOnline && dav.isConnectivityProblem { eventHandler?(.wentOffline) }
        }
        return summary
    }

    private func scheduleRetry(after delay: TimeInterval, reason: WebDAVError?) {
        retryTask?.cancel()
        status.nextRetry = Date().addingTimeInterval(delay)
        logger.info("engine", "Nächster Versuch in \(Int(delay)) s")
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.retryFired()
        }
    }

    private func retryFired() {
        retryTask = nil
        status.nextRetry = nil
        requestSync(trigger: .retry)
    }

    // MARK: - Server-Bestandsaufnahme

    private func enumerateRemote() async throws -> RemoteSnapshot {
        let enumerator = RemoteEnumerator(client: client, rules: rules, concurrency: config.maxConcurrentTransfers)
        let current = (try? await store.mapping(id: mapping.id)) ?? mapping
        if capabilities?.supportsSyncCollection == true, let token = current.syncToken, current.remoteIndexIsComplete {
            let cached = (try? await store.remoteIndex(mappingID: mapping.id)) ?? [:]
            do {
                let snapshot = try await enumerator.incremental(cached: cached, token: token)
                try? await store.replaceRemoteIndex(snapshot.items, mappingID: mapping.id)
                try? await store.setSyncToken(snapshot.syncToken, remoteIndexComplete: true, mappingID: mapping.id)
                logger.debug("remote", "sync-collection: \(snapshot.items.count) Einträge im Bestand")
                return snapshot
            } catch let error as WebDAVError {
                switch error {
                case .invalidSyncToken, .invalidResponse, .unexpectedStatus, .forbidden, .conflict:
                    logger.notice("remote", "sync-collection nicht verwendbar (\(error.technicalDescription)) – vollständige Bestandsaufnahme")
                    try? await store.setSyncToken(nil, remoteIndexComplete: false, mappingID: mapping.id)
                default:
                    throw error
                }
            }
        }
        // Token vor der Traversierung holen, damit zwischenzeitliche Änderungen beim nächsten Mal erfasst werden.
        var token: String?
        if capabilities?.supportsSyncCollection == true {
            token = try? await client.currentSyncToken()
        }
        let snapshot = try await enumerator.fullWalk(isCancelled: { Task.isCancelled })
        if snapshot.isComplete, let token {
            try? await store.replaceRemoteIndex(snapshot.items, mappingID: mapping.id)
            try? await store.setSyncToken(token, remoteIndexComplete: true, mappingID: mapping.id)
        } else {
            try? await store.setSyncToken(nil, remoteIndexComplete: false, mappingID: mapping.id)
        }
        logger.debug("remote", "Vollständige Bestandsaufnahme: \(snapshot.items.count) Einträge, vollständig=\(snapshot.isComplete)")
        return snapshot
    }

    // MARK: - Ausführung

    enum ActionResult {
        case succeeded
        case failed
        /// Vorbedingung nicht mehr erfüllt → im nächsten Durchgang neu planen.
        case deferred
        case conflict
        case noop
    }

    private func executeConcurrently(_ actions: [SyncAction], snapshot: RemoteSnapshot) async -> [ActionResult] {
        guard !actions.isEmpty else { return [] }
        let limit = config.maxConcurrentTransfers
        var results: [ActionResult] = []
        await withTaskGroup(of: ActionResult.self) { group in
            var iterator = actions.makeIterator()
            var running = 0
            while running < limit, let action = iterator.next() {
                group.addTask { await self.execute(action, snapshot: snapshot) }
                running += 1
            }
            while let result = await group.next() {
                results.append(result)
                status.completedCount += 1
                publish()
                if Task.isCancelled { continue }
                if let next = iterator.next() {
                    group.addTask { await self.execute(next, snapshot: snapshot) }
                }
            }
        }
        return results
    }

    private func beginTransfer(_ action: SyncAction) async -> TransferRecord? {
        guard let direction = action.direction else { return nil }
        var record = TransferRecord(path: action.path, direction: direction, state: .running, bytesTotal: action.estimatedBytes)
        if case .moveRemote(let from, _, _, _) = action { record.errorDetail = "von \(from)" }
        try? await store.saveTransfer(record, mappingID: mapping.id)
        status.activeTransfers.append(record)
        publish()
        return record
    }

    private func finishTransfer(_ record: TransferRecord?, state: TransferState, error: Error? = nil, note: String? = nil) async {
        guard var record else { return }
        record.state = state
        record.finishedAt = Date()
        if let error {
            let (message, detail, action) = Self.describe(error)
            record.errorMessage = note ?? message
            record.errorDetail = detail
            record.suggestedAction = action
        } else if let note {
            record.errorMessage = note
        }
        if state == .succeeded { record.bytesDone = record.bytesTotal }
        try? await store.saveTransfer(record, mappingID: mapping.id)
        if state == .succeeded || state == .skipped {
            try? await store.removeQueued(path: record.path, direction: record.direction, mappingID: mapping.id)
        }
        status.activeTransfers.removeAll { $0.id == record.id }
        status.bytesDone += record.bytesTotal
        publish()
    }

    private func updateProgress(recordID: String, done: Int64, total: Int64) {
        guard let idx = status.activeTransfers.firstIndex(where: { $0.id == recordID }) else { return }
        status.activeTransfers[idx].bytesDone = done
        if total > 0 { status.activeTransfers[idx].bytesTotal = total }
        publish(throttled: true)
    }

    static func describe(_ error: Error) -> (String, String?, SuggestedAction) {
        if let dav = error as? WebDAVError { return (dav.userDescription, dav.technicalDescription, dav.suggestedAction) }
        if let local = error as? LocalFileError {
            let action: SuggestedAction
            switch local {
            case .diskFull: action = .freeDiskSpace
            case .nameCollision: action = .renameFile
            default: action = .retry
            }
            return (local.userDescription, "\(local)", action)
        }
        if error is CancellationError { return ("Abgebrochen", nil, .none) }
        return ("Unerwarteter Fehler.", "\(error)", .retry)
    }

    private func execute(_ action: SyncAction, snapshot: RemoteSnapshot) async -> ActionResult {
        if Task.isCancelled { return .deferred }
        do {
            switch action {
            case .uploadNew(let path, let local):
                return try await performUpload(path: path, local: local, remote: nil, conflictReason: nil)
            case .uploadChanged(let path, let local, let remote):
                return try await performUpload(path: path, local: local, remote: remote, conflictReason: nil)
            case .keepLocalAfterRemoteDelete(let path, let local):
                return try await performUpload(path: path, local: local, remote: nil, conflictReason: .modifiedLocallyDeletedRemotely)
            case .download(let path, let remote, let replacing):
                return try await performDownload(path: path, remote: remote, replacing: replacing, conflictReason: nil)
            case .keepRemoteAfterLocalDelete(let path, let remote):
                return try await performDownload(path: path, remote: remote, replacing: nil, conflictReason: .deletedLocallyModifiedRemotely)
            case .verifyConflict(let path, let local, let remote, let reason):
                return try await performVerifyConflict(path: path, local: local, remote: remote, reason: reason)
            case .kindMismatch(let path, let local, let remote):
                return try await performKindMismatch(path: path, local: local, remote: remote)
            case .createRemoteDirectory(let path):
                return try await performCreateRemoteDirectory(path: path, snapshot: snapshot)
            case .createLocalDirectory(let path, let remote):
                let record = await beginTransfer(action)
                try fileSystem.createDirectory(path)
                try await store.upsertBaseline(BaselineEntry(path: path, kind: .directory, localHash: nil, localSize: 0, localModified: 0,
                                                             remoteValidator: remote.validator, remoteValidatorIsStrong: remote.validatorIsStrong,
                                                             remoteSize: 0, remoteModified: remote.modified), mappingID: mapping.id)
                await finishTransfer(record, state: .succeeded)
                return .succeeded
            case .deleteRemote(let path, let remote):
                return try await performDeleteRemote(path: path, remote: remote)
            case .deleteLocal(let path, let local):
                return try await performDeleteLocal(path: path, local: local)
            case .moveRemote(let from, let to, let remote, let local):
                return try await performMoveRemote(from: from, to: to, remote: remote, local: local, snapshot: snapshot)
            case .updateBaseline(let path, let local, let remote):
                try await store.upsertBaseline(BaselineEntry(path: path, kind: local.kind, localHash: local.hash, localSize: local.size, localModified: local.modified,
                                                             remoteValidator: remote.validator, remoteValidatorIsStrong: remote.validatorIsStrong,
                                                             remoteSize: remote.size, remoteModified: remote.modified), mappingID: mapping.id)
                return .noop
            case .removeBaseline(let path):
                try await store.removeBaseline(path: path, mappingID: mapping.id)
                return .noop
            case .skip:
                return .noop
            }
        } catch {
            logger.error("engine", "Aktion fehlgeschlagen (\(action.path)): \(error)")
            let record = status.activeTransfers.first { $0.path == action.path }
                ?? TransferRecord(path: action.path, direction: action.direction ?? .upload, state: .failed, startedAt: Date(), finishedAt: Date())
            await finishTransfer(record, state: .failed, error: error)
            if let dav = error as? WebDAVError, dav.isConnectivityProblem {
                status.lastIssue = SyncIssue(message: dav.userDescription, detail: dav.technicalDescription, action: dav.suggestedAction)
            }
            if case LocalFileError.diskFull = error {
                downloadsPausedForDiskSpace = true
                status.lastIssue = SyncIssue(message: LocalFileError.diskFull.userDescription, action: .freeDiskSpace)
                eventHandler?(.diskFull)
            }
            return .failed
        }
    }

    // MARK: Upload

    private func performUpload(path: String, local: LocalItem, remote: RemoteItem?, conflictReason: ConflictReason?) async throws -> ActionResult {
        let record = await beginTransfer(.uploadNew(path: path, local: local))
        let localPath = local.rawPath
        // Version festlegen, die hochgeladen wird.
        guard let attrs = try fileSystem.attributes(localPath), attrs.kind == .file else {
            await finishTransfer(record, state: .skipped, note: "Datei ist lokal nicht mehr vorhanden")
            return .deferred
        }
        var version = local
        if attrs.size != local.size || attrs.modified != local.modified {
            version.size = attrs.size
            version.modified = attrs.modified
            version.hash = try fileSystem.hash(localPath)
        }
        let fileURL = try fileSystem.url(localPath)
        var ifMatch: String?
        var ifNoneMatchAll = false
        if let remote {
            if remote.validatorIsStrong && capabilities?.supportsConditionalWrites != false {
                ifMatch = remote.validator
            } else {
                // Ohne starke ETags: unmittelbar vor dem Schreiben den Serverstand prüfen.
                let current = try await client.stat(remote.rawPath)
                if current?.validator != remote.validator {
                    await finishTransfer(record, state: .skipped, note: "Serverversion hat sich geändert – wird neu abgeglichen")
                    return .deferred
                }
            }
        } else {
            ifNoneMatchAll = true
        }
        let rawPath = remote?.rawPath ?? path
        let recordID = record?.id
        let progressHandler: TransferProgress = { [weak self] done, total in
            guard let self, let recordID else { return }
            Task { await self.updateProgress(recordID: recordID, done: done, total: total) }
        }
        let result: UploadResult
        do {
            if let transport = uploadTransport, let threshold = config.chunkedUploadThreshold, version.size >= threshold, await transport.isAvailable() {
                if version.hash == nil { version.hash = try fileSystem.hash(localPath) }
                let info = UploadRequestInfo(path: path, rawPath: localPath, fileURL: fileURL, size: version.size, modified: version.modified,
                                             hash: version.hash ?? "", replacingValidator: remote?.validator)
                logger.info("engine", "Chunk-Upload für \(path) (\(version.size) Bytes)")
                result = try await transport.upload(info, progress: progressHandler)
            } else {
                result = try await client.upload(file: fileURL, to: rawPath, ifMatch: ifMatch, ifNoneMatchAll: ifNoneMatchAll, progress: progressHandler)
            }
        } catch let error as WebDAVError where error == .preconditionFailed {
            logger.notice("engine", "412 beim Upload von \(path) – Server hat sich geändert, neuer Abgleich")
            await finishTransfer(record, state: .skipped, note: "Serverversion hat sich zwischenzeitlich geändert – wird neu abgeglichen")
            return .deferred
        } catch LocalFileError.changedSinceScan {
            await finishTransfer(record, state: .skipped, note: "Datei wurde während der Übertragung geändert – wird erneut hochgeladen")
            return .deferred
        } catch let error as CloudreveError {
            if case .unsupportedStoragePolicy = error {
                logger.warning("engine", "\(error.userDescription) – Rückfall auf WebDAV-PUT für \(path)")
                result = try await client.upload(file: fileURL, to: rawPath, ifMatch: ifMatch, ifNoneMatchAll: ifNoneMatchAll, progress: progressHandler)
            } else {
                throw error.asWebDAVError
            }
        }
        // Validator ermitteln (Antwort-Header oder PROPFIND).
        var validator = result.etag
        var strong = validator.map { !$0.hasPrefix("W/") } ?? false
        var remoteSize = version.size
        var remoteModified: Double?
        if validator == nil, let stat = try? await client.stat(rawPath) {
            validator = stat.validator
            strong = stat.validatorIsStrong
            remoteSize = stat.size
            remoteModified = stat.modified
        }
        // Wurde die Datei während des Uploads verändert? Dann bleibt sie ausstehend.
        var note: String?
        if let after = try fileSystem.attributes(localPath), after.size != version.size || after.modified != version.modified {
            note = "Datei wurde während der Übertragung erneut geändert – wird erneut hochgeladen"
        }
        try await store.upsertBaseline(BaselineEntry(path: path, kind: .file, localHash: version.hash, localSize: version.size, localModified: version.modified,
                                                     remoteValidator: validator, remoteValidatorIsStrong: strong, remoteSize: remoteSize,
                                                     remoteModified: remoteModified), mappingID: mapping.id)
        await finishTransfer(record, state: .succeeded, note: note)
        if let conflictReason {
            let conflict = ConflictRecord(path: path, kind: .file, reason: conflictReason, localHash: version.hash, localSize: version.size,
                                          localModified: version.modified, remoteValidator: nil, remoteSize: nil, remoteModified: nil)
            try await store.saveConflict(conflict, mappingID: mapping.id)
            eventHandler?(.conflictDetected(path: path))
            logger.notice("engine", "Konflikt (lokal geändert, Server gelöscht): \(path) – lokale Version erhalten")
            return .conflict
        }
        if note != nil { return .deferred }
        return .succeeded
    }

    // MARK: Download

    private func checkDiskSpace(for size: Int64) throws {
        if let free = fileSystem.availableCapacity(), free < size + config.minimumFreeSpace {
            throw LocalFileError.diskFull
        }
    }

    private func downloadToTemp(_ remote: RemoteItem, recordID: String?) async throws -> (URL, DownloadResult, String) {
        try checkDiskSpace(for: remote.size)
        let temp = try fileSystem.makeTemporaryFileURL()
        do {
            let result = try await client.download(remote.rawPath, to: temp, progress: { [weak self] done, total in
                guard let self, let recordID else { return }
                Task { await self.updateProgress(recordID: recordID, done: done, total: total) }
            })
            let hash = try SHA256Hasher.hashFile(at: temp)
            return (temp, result, hash)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            if error is WebDAVError || error is CancellationError { throw error }
            throw LocalFileSystem.mapError(error)
        }
    }

    private func remoteValidatorAfterDownload(_ remote: RemoteItem, result: DownloadResult) async -> (String?, Bool, Double?) {
        if let etag = result.etag { return (etag, !etag.hasPrefix("W/"), result.lastModified?.timeIntervalSince1970 ?? remote.modified) }
        if let stat = try? await client.stat(remote.rawPath) { return (stat.validator, stat.validatorIsStrong, stat.modified) }
        return (remote.validator, remote.validatorIsStrong, remote.modified)
    }

    private func performDownload(path: String, remote: RemoteItem, replacing: LocalItem?, conflictReason: ConflictReason?) async throws -> ActionResult {
        if downloadsPausedForDiskSpace { throw LocalFileError.diskFull }
        let record = await beginTransfer(.download(path: path, remote: remote, replacing: replacing))
        if replacing == nil, let existing = try fileSystem.attributes(path), existing.kind == .file {
            // Zwischenzeitlich ist lokal eine Datei entstanden → als Konflikt neu bewerten.
            await finishTransfer(record, state: .skipped, note: "Lokal ist inzwischen eine gleichnamige Datei entstanden – wird neu abgeglichen")
            return .deferred
        }
        let targetPath = replacing?.rawPath ?? path
        let (temp, result, hash) = try await downloadToTemp(remote, recordID: record?.id)
        let (validator, strong, remoteModified) = await remoteValidatorAfterDownload(remote, result: result)
        let modifiedDate = remoteModified.map { Date(timeIntervalSince1970: $0) }
        if let replacing, replacing.hash == hash {
            // Inhalt identisch – nur gemeinsamen Stand aktualisieren.
            try? FileManager.default.removeItem(at: temp)
            try await store.upsertBaseline(BaselineEntry(path: path, kind: .file, localHash: hash, localSize: replacing.size, localModified: replacing.modified,
                                                         remoteValidator: validator, remoteValidatorIsStrong: strong, remoteSize: result.contentLength,
                                                         remoteModified: remoteModified), mappingID: mapping.id)
            await finishTransfer(record, state: .succeeded, note: "Inhalt war bereits identisch")
            return .succeeded
        }
        do {
            try fileSystem.installDownloadedFile(from: temp, to: targetPath, expectedHash: replacing?.hash, expectedSize: replacing?.size,
                                                 expectedModified: replacing?.modified, modifiedDate: modifiedDate)
        } catch LocalFileError.changedSinceScan {
            await finishTransfer(record, state: .skipped, note: "Lokale Datei wurde zwischenzeitlich geändert – wird neu abgeglichen")
            return .deferred
        }
        let installed = try fileSystem.attributes(targetPath)
        try await store.upsertBaseline(BaselineEntry(path: path, kind: .file, localHash: hash, localSize: installed?.size ?? result.contentLength,
                                                     localModified: installed?.modified ?? 0, remoteValidator: validator, remoteValidatorIsStrong: strong,
                                                     remoteSize: result.contentLength, remoteModified: remoteModified), mappingID: mapping.id)
        await finishTransfer(record, state: .succeeded)
        if let conflictReason {
            let conflict = ConflictRecord(path: path, kind: .file, reason: conflictReason, localHash: nil, localSize: nil, localModified: nil,
                                          remoteValidator: validator, remoteSize: result.contentLength, remoteModified: remoteModified)
            try await store.saveConflict(conflict, mappingID: mapping.id)
            eventHandler?(.conflictDetected(path: path))
            logger.notice("engine", "Konflikt (lokal gelöscht, Server geändert): \(path) – Serverversion erhalten")
            return .conflict
        }
        return .succeeded
    }

    // MARK: Konflikte

    private func performVerifyConflict(path: String, local: LocalItem, remote: RemoteItem, reason: ConflictReason) async throws -> ActionResult {
        if downloadsPausedForDiskSpace { throw LocalFileError.diskFull }
        let record = await beginTransfer(.verifyConflict(path: path, local: local, remote: remote, reason: reason))
        let (temp, result, remoteHash) = try await downloadToTemp(remote, recordID: record?.id)
        let (validator, strong, remoteModified) = await remoteValidatorAfterDownload(remote, result: result)
        // Lokale Version muss noch dem geplanten Stand entsprechen.
        let localPath = local.rawPath
        guard let attrs = try fileSystem.attributes(localPath), attrs.kind == .file else {
            try? FileManager.default.removeItem(at: temp)
            await finishTransfer(record, state: .skipped, note: "Lokale Datei nicht mehr vorhanden – wird neu abgeglichen")
            return .deferred
        }
        var localHash = local.hash
        if attrs.size != local.size || attrs.modified != local.modified {
            localHash = try fileSystem.hash(localPath)
        }
        if localHash == remoteHash {
            try? FileManager.default.removeItem(at: temp)
            try await store.upsertBaseline(BaselineEntry(path: path, kind: .file, localHash: remoteHash, localSize: attrs.size, localModified: attrs.modified,
                                                         remoteValidator: validator, remoteValidatorIsStrong: strong, remoteSize: result.contentLength,
                                                         remoteModified: remoteModified), mappingID: mapping.id)
            await finishTransfer(record, state: .succeeded, note: "Beide Seiten hatten denselben Inhalt – zusammengeführt")
            return .succeeded
        }
        // Beide Versionen erhalten: lokale Version wird zur Konfliktkopie, Serverversion übernimmt den Pfad.
        let copyName = RelativePath.conflictCopyName(for: RelativePath.name(of: path), deviceName: config.deviceName)
        let copyPath = RelativePath.join(RelativePath.parent(of: path) ?? "", copyName)
        try fileSystem.move(localPath, to: copyPath)
        do {
            try fileSystem.installDownloadedFile(from: temp, to: path, expectedHash: nil, expectedSize: nil, expectedModified: nil,
                                                 modifiedDate: remoteModified.map { Date(timeIntervalSince1970: $0) })
        } catch {
            // Rückgängig machen, damit keine Version verloren geht.
            try? fileSystem.move(copyPath, to: localPath)
            throw error
        }
        let installed = try fileSystem.attributes(path)
        try await store.upsertBaseline(BaselineEntry(path: path, kind: .file, localHash: remoteHash, localSize: installed?.size ?? result.contentLength,
                                                     localModified: installed?.modified ?? 0, remoteValidator: validator, remoteValidatorIsStrong: strong,
                                                     remoteSize: result.contentLength, remoteModified: remoteModified), mappingID: mapping.id)
        let conflict = ConflictRecord(path: path, kind: .file, reason: reason, localHash: localHash, localSize: attrs.size, localModified: attrs.modified,
                                      remoteValidator: validator, remoteSize: result.contentLength, remoteModified: remoteModified, conflictCopyPath: copyPath)
        try await store.saveConflict(conflict, mappingID: mapping.id)
        await finishTransfer(record, state: .succeeded, note: "Konflikt: lokale Version als „\(copyName)“ gesichert")
        eventHandler?(.conflictDetected(path: path))
        logger.notice("engine", "Konflikt: \(path) – Konfliktkopie \(copyPath)")
        return .conflict
    }

    private func performKindMismatch(path: String, local: LocalItem, remote: RemoteItem) async throws -> ActionResult {
        let record = await beginTransfer(.kindMismatch(path: path, local: local, remote: remote))
        let copyName = RelativePath.conflictCopyName(for: RelativePath.name(of: path), deviceName: config.deviceName)
        let copyPath = RelativePath.join(RelativePath.parent(of: path) ?? "", copyName)
        try fileSystem.move(local.rawPath, to: copyPath)
        try await store.removeBaselineSubtree(path: path, mappingID: mapping.id)
        if remote.kind == .directory {
            try fileSystem.createDirectory(path)
            try await store.upsertBaseline(BaselineEntry(path: path, kind: .directory, localHash: nil, localSize: 0, localModified: 0,
                                                         remoteValidator: remote.validator, remoteValidatorIsStrong: remote.validatorIsStrong,
                                                         remoteSize: 0, remoteModified: remote.modified), mappingID: mapping.id)
        } else {
            let (temp, result, hash) = try await downloadToTemp(remote, recordID: record?.id)
            let (validator, strong, remoteModified) = await remoteValidatorAfterDownload(remote, result: result)
            try fileSystem.installDownloadedFile(from: temp, to: path, expectedHash: nil, expectedSize: nil, expectedModified: nil,
                                                 modifiedDate: remoteModified.map { Date(timeIntervalSince1970: $0) })
            let installed = try fileSystem.attributes(path)
            try await store.upsertBaseline(BaselineEntry(path: path, kind: .file, localHash: hash, localSize: installed?.size ?? result.contentLength,
                                                         localModified: installed?.modified ?? 0, remoteValidator: validator, remoteValidatorIsStrong: strong,
                                                         remoteSize: result.contentLength, remoteModified: remoteModified), mappingID: mapping.id)
        }
        let conflict = ConflictRecord(path: path, kind: local.kind, reason: .kindMismatch, localHash: local.hash, localSize: local.size,
                                      localModified: local.modified, remoteValidator: remote.validator, remoteSize: remote.size,
                                      remoteModified: remote.modified, conflictCopyPath: copyPath)
        try await store.saveConflict(conflict, mappingID: mapping.id)
        await finishTransfer(record, state: .succeeded, note: "Datei/Ordner-Konflikt: lokale Version als „\(copyName)“ gesichert")
        eventHandler?(.conflictDetected(path: path))
        return .conflict
    }

    // MARK: Ordner, Löschungen, Umbenennungen

    private func performCreateRemoteDirectory(path: String, snapshot: RemoteSnapshot) async throws -> ActionResult {
        let record = await beginTransfer(.createRemoteDirectory(path: path))
        var validator: String?
        var strong = false
        var modified: Double?
        do {
            try await client.makeDirectory(path)
        } catch let error as WebDAVError {
            if case .conflict(let status, _) = error, status == 405 {
                // existiert bereits
            } else {
                throw error
            }
        }
        if let stat = try? await client.stat(path) {
            if stat.kind != .directory {
                await finishTransfer(record, state: .skipped, note: "Auf dem Server liegt an dieser Stelle eine Datei – wird neu abgeglichen")
                return .deferred
            }
            validator = stat.validator
            strong = stat.validatorIsStrong
            modified = stat.modified
        }
        try await store.upsertBaseline(BaselineEntry(path: path, kind: .directory, localHash: nil, localSize: 0, localModified: 0,
                                                     remoteValidator: validator, remoteValidatorIsStrong: strong, remoteSize: 0, remoteModified: modified), mappingID: mapping.id)
        await finishTransfer(record, state: .succeeded)
        return .succeeded
    }

    private func performDeleteRemote(path: String, remote: RemoteItem) async throws -> ActionResult {
        let record = await beginTransfer(.deleteRemote(path: path, remote: remote))
        // Sicherheitsprüfung: Lokal darf der Eintrag nicht wieder aufgetaucht sein.
        if try fileSystem.attributes(path) != nil {
            await finishTransfer(record, state: .skipped, note: "Eintrag ist lokal wieder vorhanden – wird neu abgeglichen")
            return .deferred
        }
        var ifMatch: String?
        if remote.kind == .file {
            if remote.validatorIsStrong {
                ifMatch = remote.validator
            } else {
                let current = try await client.stat(remote.rawPath)
                if let current, current.validator != remote.validator {
                    await finishTransfer(record, state: .skipped, note: "Serverversion hat sich geändert – wird neu abgeglichen")
                    return .deferred
                }
            }
        } else {
            // Ordner: unmittelbar vor dem Löschen nochmals prüfen, dass keine neuen Einträge entstanden sind.
            let children = try await client.list(directory: remote.rawPath)
            let baseline = try await store.baseline(mappingID: mapping.id)
            for child in children where !rules.isExcluded(relativePath: child.path) {
                guard let b = baseline[child.path] else {
                    await finishTransfer(record, state: .skipped, note: "Im Ordner sind auf dem Server neue Einträge entstanden – wird neu abgeglichen")
                    return .deferred
                }
                if child.kind == .file, child.validator != b.remoteValidator {
                    await finishTransfer(record, state: .skipped, note: "Im Ordner wurden auf dem Server Dateien geändert – wird neu abgeglichen")
                    return .deferred
                }
            }
        }
        do {
            try await client.delete(remote.rawPath, ifMatch: ifMatch)
        } catch let error as WebDAVError where error == .preconditionFailed {
            await finishTransfer(record, state: .skipped, note: "Serverversion hat sich zwischenzeitlich geändert – wird neu abgeglichen")
            return .deferred
        }
        try await store.removeBaselineSubtree(path: path, mappingID: mapping.id)
        await finishTransfer(record, state: .succeeded)
        return .succeeded
    }

    private func performDeleteLocal(path: String, local: LocalItem) async throws -> ActionResult {
        let record = await beginTransfer(.deleteLocal(path: path, local: local))
        let localPath = local.rawPath
        // Sicherheitsprüfung: Der Eintrag muss lokal noch dem bekannten Stand entsprechen.
        guard let attrs = try fileSystem.attributes(localPath) else {
            try await store.removeBaselineSubtree(path: path, mappingID: mapping.id)
            await finishTransfer(record, state: .succeeded, note: "War lokal bereits entfernt")
            return .succeeded
        }
        if attrs.kind == .file {
            if attrs.size != local.size || attrs.modified != local.modified, try fileSystem.hash(localPath) != local.hash {
                await finishTransfer(record, state: .skipped, note: "Lokale Datei wurde zwischenzeitlich geändert – wird neu abgeglichen")
                return .deferred
            }
        } else {
            let baseline = try await store.baseline(mappingID: mapping.id)
            if try !directoryMatchesBaseline(localPath, baseline: baseline) {
                await finishTransfer(record, state: .skipped, note: "Im Ordner gibt es lokal neue oder geänderte Dateien – wird neu abgeglichen")
                return .deferred
            }
        }
        let destination = try fileSystem.trash(localPath, recoveryDirectory: config.recoveryDirectory)
        try await store.removeBaselineSubtree(path: path, mappingID: mapping.id)
        let note = destination.map { $0.path.contains("/.Trash") ? "In den Papierkorb verschoben" : "In den Wiederherstellungsbereich verschoben" }
        await finishTransfer(record, state: .succeeded, note: note)
        return .succeeded
    }

    /// Prüft, ob alle Dateien eines lokalen Ordners noch dem gemeinsamen Stand entsprechen.
    private func directoryMatchesBaseline(_ dir: String, baseline: [String: BaselineEntry]) throws -> Bool {
        let url = try fileSystem.url(dir)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: []) else { return true }
        let rootPath = fileSystem.root.path
        for case let child as URL in enumerator {
            var rel = child.standardizedFileURL.path
            guard rel.hasPrefix(rootPath + "/") else { continue }
            rel = String(rel.dropFirst(rootPath.count + 1)).precomposedStringWithCanonicalMapping
            if rules.isExcluded(relativePath: rel) { continue }
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return false }
            if values.isDirectory == true { continue }
            guard let b = baseline[rel] else { return false }
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            if size != b.localSize || mtime != b.localModified {
                if try SHA256Hasher.hashFile(at: child) != b.localHash { return false }
            }
        }
        return true
    }

    private func performMoveRemote(from: String, to: String, remote: RemoteItem, local: LocalItem, snapshot: RemoteSnapshot) async throws -> ActionResult {
        let record = await beginTransfer(.moveRemote(from: from, to: to, remote: remote, local: local))
        if try fileSystem.attributes(from) != nil {
            await finishTransfer(record, state: .skipped, note: "Quelle ist lokal wieder vorhanden – wird neu abgeglichen")
            return .deferred
        }
        do {
            try await client.move(from: remote.rawPath, to: to, overwrite: false, ifMatch: remote.validatorIsStrong ? remote.validator : nil)
        } catch {
            logger.notice("engine", "MOVE \(from) → \(to) fehlgeschlagen (\(error)); Rückfall auf Upload + Löschung")
            await finishTransfer(record, state: .skipped, note: "Umbenennung auf dem Server nicht möglich – wird als Upload und Löschung übertragen")
            let up = try await performUpload(path: to, local: local, remote: nil, conflictReason: nil)
            if up == .succeeded {
                _ = try await performDeleteRemote(path: from, remote: remote)
            }
            return up
        }
        let stat = try await client.stat(to)
        try await store.removeBaselineSubtree(path: from, mappingID: mapping.id)
        try await store.upsertBaseline(BaselineEntry(path: to, kind: .file, localHash: local.hash, localSize: local.size, localModified: local.modified,
                                                     remoteValidator: stat?.validator, remoteValidatorIsStrong: stat?.validatorIsStrong ?? false,
                                                     remoteSize: stat?.size ?? local.size, remoteModified: stat?.modified), mappingID: mapping.id)
        await finishTransfer(record, state: .succeeded)
        return .succeeded
    }

    // MARK: - Status

    private var lastPublish = Date.distantPast

    private func publish(throttled: Bool = false) {
        if throttled, Date().timeIntervalSince(lastPublish) < 0.15 { return }
        lastPublish = Date()
        statusHandler?(status)
    }

    private func refreshCounters() async {
        status.openConflicts = (try? await store.openConflictCount(mappingID: mapping.id)) ?? 0
        status.pendingDeletions = (try? await store.pendingDeletions(mappingID: mapping.id).count) ?? 0
        if !status.isRunning {
            status.pendingCount = (try? await store.queue(mappingID: mapping.id).count) ?? 0
        }
        recomputeHealth()
    }

    private func recomputeHealth() {
        if status.isRunning {
            status.health = .syncing
        } else if status.isPaused {
            status.health = .paused
        } else if status.nextRetry != nil {
            status.health = .offline
        } else if status.pendingDeletions > 0 || status.lastIssue != nil {
            status.health = .attention
        } else if status.openConflicts > 0 {
            status.health = .conflicts
        } else if status.pendingCount > 0 {
            status.health = .attention
        } else {
            status.health = .synced
        }
    }
}

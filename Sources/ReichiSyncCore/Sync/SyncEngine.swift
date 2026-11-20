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
        self.minimumFreeSpace = max(0, minimumFreeSpace)
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
    var authenticationFailure = false
    var connectivityFailure = false
    var diskFullFailure = false
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
    private var retryRepresentsOffline = false
    private var capabilities: WebDAVCapabilities?
    /// Persistent bestätigte Einzelaktionen. Unbestätigte Löschungen werden
    /// unabhängig davon geplant und separat in der UI angeboten.
    private var confirmedDeletions: Set<DeletionAuthorization> = []
    private var downloadsPausedForDiskSpace = false
    private var reservedTemporaryBytes: Int64 = 0
    private var resolvingConflictIDs: Set<String> = []
    private var lastRemoteSnapshot: RemoteSnapshot?
    private var isShutDown = false
    private var userPauseKey: String { "user-pause.\(mapping.id)" }

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
        do {
            try await store.markRunningTransfersInterrupted(mappingID: mapping.id)
        } catch {
            reportPersistenceIssue(error)
            return
        }
        fileSystem.cleanupTemporaryFiles()
        status.health = .synced
        status.lastSuccessfulSync = mapping.lastSuccessfulSync
        await refreshCounters()
        do {
            if try await store.meta(userPauseKey) == "1" {
                status.isPaused = true
                status.pauseReason = .user
                status.health = .paused
            }
            let confirmed = try await store.confirmedPendingDeletions(mappingID: mapping.id)
            confirmedDeletions = Set(confirmed.map(DeletionAuthorization.init))
        } catch {
            reportPersistenceIssue(error)
            return
        }
        do {
            if try await store.queue(mappingID: mapping.id).count > 0 { status.health = .attention }
        } catch {
            reportPersistenceIssue(error)
            return
        }
        recomputeHealth()
        publish()
    }

    /// Fordert einen Abgleich an. Läuft bereits einer, wird im Anschluss ein weiterer ausgeführt.
    public func requestSync(trigger: SyncTrigger) {
        guard !isShutDown else { return }
        if status.isPaused && status.pauseReason == .user { return }
        if retryTask != nil,
           trigger != .manual,
           trigger != .connectivityRestored,
           trigger != .retry {
            logger.debug("engine", "Abgleich (\(trigger.rawValue)) wartet auf den geplanten Wiederholungszeitpunkt")
            return
        }
        retryTask?.cancel()
        retryTask = nil
        retryRepresentsOffline = false
        status.nextRetry = nil
        if runningTask != nil {
            rerunRequested = true
            logger.debug("engine", "Abgleich angefordert (\(trigger.rawValue)) – läuft bereits, wird wiederholt")
            return
        }
        logger.info("engine", "Abgleich gestartet (\(trigger.rawValue))")
        runningTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(trigger: trigger)
        }
    }

    /// Führt einen Abgleich aus und wartet auf dessen Abschluss (für Tests und Skripte).
    public func syncAndWait(trigger: SyncTrigger = .manual) async {
        while let running = runningTask { _ = await running.value }
        requestSync(trigger: trigger)
        while let running = runningTask { _ = await running.value }
    }

    public func pause() async {
        status.isPaused = true
        status.pauseReason = .user
        status.health = .paused
        runningTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        retryRepresentsOffline = false
        status.nextRetry = nil
        do {
            try await store.setMeta(userPauseKey, "1")
        } catch {
            reportPersistenceIssue(error)
        }
        recomputeHealth()
        publish()
    }

    public func resume() async {
        guard status.isPaused else { return }
        do {
            try await store.setMeta(userPauseKey, nil)
        } catch {
            reportPersistenceIssue(error)
            return
        }
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
        do { return try await store.transfers(mappingID: mapping.id, limit: limit) }
        catch { reportPersistenceIssue(error); return [] }
    }

    public func conflicts() async -> [ConflictRecord] {
        do { return try await store.conflicts(mappingID: mapping.id) }
        catch { reportPersistenceIssue(error); return [] }
    }

    public func queue() async -> [QueuedItem] {
        do { return try await store.queue(mappingID: mapping.id) }
        catch { reportPersistenceIssue(error); return [] }
    }

    public func pendingDeletions() async -> [PendingDeletion] {
        do { return try await store.pendingDeletionsAwaitingConfirmation(mappingID: mapping.id) }
        catch { reportPersistenceIssue(error); return [] }
    }

    /// Gibt die zurückgehaltenen Löschungen frei (Löschschutz).
    public func confirmPendingDeletions() async {
        do {
            let pending = try await store.confirmPendingDeletions(mappingID: mapping.id)
            confirmedDeletions = Set(pending.map(DeletionAuthorization.init))
        } catch {
            reportPersistenceIssue(error)
            return
        }
        await refreshCounters()
        publish()
        requestSync(trigger: .manual)
    }

    /// Verwirft die zurückgehaltenen Löschungen: Die betroffenen Einträge werden aus dem
    /// gemeinsamen Stand entfernt, sodass die noch vorhandene Seite als „neu“ gilt und
    /// wiederhergestellt (erneut übertragen) wird.
    public func discardPendingDeletions() async {
        do {
            try await store.discardPendingDeletions(mappingID: mapping.id)
            let confirmed = try await store.confirmedPendingDeletions(mappingID: mapping.id)
            confirmedDeletions = Set(confirmed.map(DeletionAuthorization.init))
        } catch {
            reportPersistenceIssue(error)
            return
        }
        await refreshCounters()
        publish()
        requestSync(trigger: .manual)
    }

    private func reportPersistenceIssue(_ error: Error) {
        status.lastIssue = SyncIssue(
            message: "Der lokale Synchronisierungsstand konnte nicht zuverlässig gelesen oder gespeichert werden.",
            detail: error.localizedDescription,
            action: .retry
        )
        status.health = .attention
        logger.error("store", "Persistenzfehler: \(error)")
        publish()
    }

    /// Führt blockierende Dateioperationen außerhalb des Engine-Actors aus und
    /// koppelt deren Lebenszyklus an den aufrufenden Sync-Task.
    private func performFileOperation<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
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
        guard resolvingConflictIDs.insert(id).inserted else {
            throw ConflictResolutionError.notApplicable
        }
        defer { resolvingConflictIDs.remove(id) }
        let all = try await store.conflicts(mappingID: mapping.id)
        guard var conflict = all.first(where: { $0.id == id }) else { throw ConflictResolutionError.notFound }
        let baseline = try await store.baseline(mappingID: mapping.id)
        guard let expected = baseline[conflict.path] else {
            throw ConflictResolutionError.filesChangedSinceDetection
        }
        try await validateLocalConflictArtifact(path: conflict.path, kind: expected.kind, expectedHash: expected.localHash)

        switch conflict.reason {
        case .bothModified, .initialMergeDiffers, .kindMismatch:
            // Am Pfad liegt die Serverversion, die lokale Version in der Konfliktkopie.
            guard let copyPath = conflict.conflictCopyPath else { throw ConflictResolutionError.notApplicable }
            guard let copyAttrs = try fileSystem.attributes(copyPath) else {
                throw ConflictResolutionError.filesChangedSinceDetection
            }
            if copyAttrs.kind == .file {
                let fileSystem = self.fileSystem
                guard let localHash = conflict.localHash,
                      try await performFileOperation({ try fileSystem.hash(copyPath) }) == localHash else {
                    throw ConflictResolutionError.filesChangedSinceDetection
                }
            }
            switch resolution {
            case .keepBoth:
                break
            case .useLocal:
                guard conflict.reason != .kindMismatch,
                      expected.kind == .file,
                      copyAttrs.kind == .file,
                      let localHash = conflict.localHash else { throw ConflictResolutionError.notApplicable }
                try await validateRemoteConflictArtifact(path: conflict.path, expected: expected)
                let temp = try fileSystem.makeTemporaryFileURL()
                let fileSystem = self.fileSystem
                let conflictPath = conflict.path
                let expectedOriginalHash = expected.localHash
                try await performFileOperation {
                    let source = try fileSystem.url(copyPath)
                    guard let before = try POSIXFileMetadata.read(atPath: source.path),
                          !before.isSymbolicLink else {
                        throw ConflictResolutionError.filesChangedSinceDetection
                    }
                    try FileManager.default.copyItem(at: source, to: temp)
                    let temporaryFileID = try POSIXFileMetadata.read(atPath: temp.path)?.fileID
                    defer {
                        if let current = try? POSIXFileMetadata.read(atPath: temp.path),
                           current.fileID == temporaryFileID {
                            try? FileManager.default.removeItem(at: temp)
                        }
                    }
                    guard let after = try POSIXFileMetadata.read(atPath: source.path),
                          after.cacheToken == before.cacheToken,
                          try SHA256Hasher.hashFile(at: temp) == localHash else {
                        throw ConflictResolutionError.filesChangedSinceDetection
                    }
                    try fileSystem.installDownloadedFile(from: temp, to: conflictPath, expectedHash: expectedOriginalHash,
                                                         expectedSize: nil, expectedModified: nil, modifiedDate: Date())
                }
                _ = try fileSystem.trashVerifiedFile(
                    copyPath,
                    expectedHash: localHash,
                    recoveryDirectory: config.recoveryDirectory
                )
            case .useRemote:
                // Ein Ordner hat keinen gespeicherten Inhalts-Hash. Ihn aufgrund
                // einer alten Konfliktentscheidung rekursiv zu verwerfen wäre
                // nicht verlustfrei prüfbar.
                guard copyAttrs.kind == .file,
                      let localHash = conflict.localHash else { throw ConflictResolutionError.notApplicable }
                try await validateRemoteConflictArtifact(path: conflict.path, expected: expected)
                _ = try fileSystem.trashVerifiedFile(
                    copyPath,
                    expectedHash: localHash,
                    recoveryDirectory: config.recoveryDirectory
                )
            case .applyDeletion:
                throw ConflictResolutionError.notApplicable
            }
        case .modifiedLocallyDeletedRemotely, .deletedLocallyModifiedRemotely:
            try await validateRemoteConflictArtifact(path: conflict.path, expected: expected)
            switch resolution {
            case .keepBoth, .useLocal, .useRemote:
                break // Die erhaltene Version liegt bereits auf beiden Seiten.
            case .applyDeletion:
                guard let attrs = try fileSystem.attributes(conflict.path) else { throw ConflictResolutionError.notApplicable }
                guard attrs.kind == .file,
                      expected.kind == .file,
                      let expectedHash = expected.localHash else {
                    throw ConflictResolutionError.filesChangedSinceDetection
                }
                _ = try fileSystem.trashVerifiedFile(
                    conflict.path,
                    expectedHash: expectedHash,
                    recoveryDirectory: config.recoveryDirectory
                )
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

    private func validateLocalConflictArtifact(path: String, kind: ItemKind, expectedHash: String?) async throws {
        guard let attrs = try fileSystem.attributes(path), attrs.kind == kind else {
            throw ConflictResolutionError.filesChangedSinceDetection
        }
        if kind == .file {
            let fileSystem = self.fileSystem
            guard let expectedHash,
                  try await performFileOperation({ try fileSystem.hash(path) }) == expectedHash else {
                throw ConflictResolutionError.filesChangedSinceDetection
            }
        }
    }

    private func validateRemoteConflictArtifact(path: String, expected: BaselineEntry) async throws {
        let rawPath = lastRemoteSnapshot?.items[path]?.rawPath ?? path
        guard let current = try await client.stat(rawPath),
              Self.sameRemoteVersion(current, expected) else {
            throw ConflictResolutionError.filesChangedSinceDetection
        }
        // Schwache Validatoren beweisen keine Bytegleichheit. Vor einer
        // Entscheidung, die eine lokale Alternative verwirft, wird deshalb der
        // aktuelle Serverinhalt erneut gehasht.
        if expected.kind == .file,
           !(expected.remoteValidatorIsStrong && current.validatorIsStrong) {
            let temp = try fileSystem.makeTemporaryFileURL()
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                _ = try await client.download(current.rawPath, to: temp, progress: nil)
            } catch {
                if error is WebDAVError || error is CancellationError { throw error }
                throw LocalFileSystem.mapError(error)
            }
            guard let expectedHash = expected.localHash,
                  try await performFileOperation({ try SHA256Hasher.hashFile(at: temp) }) == expectedHash else {
                throw ConflictResolutionError.filesChangedSinceDetection
            }
        }
    }

    // MARK: - Durchlauf

    private func runLoop(trigger: SyncTrigger) async {
        var iterations = 0
        var currentTrigger = trigger
        var restartIfRequested = true
        defer {
            runningTask = nil
            if restartIfRequested, rerunRequested, !isShutDown, !status.isPaused {
                rerunRequested = false
                requestSync(trigger: .followUp)
            }
        }
        repeat {
            rerunRequested = false
            iterations += 1
            let summary = await performSync(trigger: currentTrigger)
            if Task.isCancelled { break }
            if summary.offline {
                restartIfRequested = false
                break
            }
            if summary.needsFollowUp && iterations < 4 {
                rerunRequested = true
                currentTrigger = .followUp
            }
        } while rerunRequested && iterations < 4 && !Task.isCancelled
        if rerunRequested && !Task.isCancelled {
            // Mehr als vier Durchgänge hintereinander: kurz warten und erneut planen.
            restartIfRequested = false
            scheduleRetry(after: 5)
        }
    }

    private func performSync(trigger: SyncTrigger) async -> SyncRunSummary {
        var summary = SyncRunSummary()
        // Actor-Reentrancy: Bestätigungen, die während eines `await` eintreffen,
        // gelten erst nach einer erneuten Planung.
        let runConfirmedDeletions = confirmedDeletions
        let wasOffline = status.health == .offline || status.nextRetry != nil
        downloadsPausedForDiskSpace = false
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
                capabilities = try await client.detectCapabilities()
                status.capabilities = capabilities
            }
        } catch {
            return handleConnectivityFailure(error, summary: summary)
        }
        // Der Server ist wieder erreichbar. Offene Konflikte oder blockierte
        // Aktionen dürfen den Netzwerk-Backoff nicht künstlich hoch halten.
        retryPolicy.reset()
        if status.pauseReason == .authenticationRequired {
            status.isPaused = false
            status.pauseReason = nil
        }
        if wasOffline { eventHandler?(.cameOnline) }

        // 3. Lokale Bestandsaufnahme
        status.currentStep = "Lese lokalen Ordner …"
        publish()
        let scanner = LocalScanner(fileSystem: fileSystem, rules: rules, settleTime: config.settleTime)
        let previousIndex: [String: SyncStore.LocalIndexEntry]
        do {
            previousIndex = try await store.localIndex(mappingID: mapping.id)
        } catch {
            return handlePersistenceFailure(error, summary: summary)
        }
        let scanResult: LocalScanner.Result
        do {
            let scanTask = Task.detached(priority: .utility) { [scanner, previousIndex] in
                try scanner.scan(previousIndex: previousIndex, isCancelled: { Task.isCancelled })
            }
            scanResult = try await withTaskCancellationHandler {
                try await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
        } catch {
            if error is CancellationError { return summary }
            if let local = error as? LocalFileError, local == .rootMissing {
                logger.warning("engine", "Lokaler Stammordner wurde während der Bestandsaufnahme ausgetauscht oder getrennt")
                status.isPaused = true
                status.pauseReason = .localRootMissing
                status.lastIssue = SyncIssue(
                    message: "Der lokale Ordner ist nicht mehr derselbe wie zu Beginn des Abgleichs. Bitte den Sync-Ordner erneut auswählen.",
                    action: .checkServer
                )
                summary.failed = 1
                return summary
            }
            logger.error("engine", "Lokale Bestandsaufnahme fehlgeschlagen: \(error)")
            status.lastIssue = SyncIssue(message: "Der lokale Ordner konnte nicht gelesen werden.", detail: "\(error)", action: .retry)
            summary.failed = 1
            return summary
        }
        do {
            try await store.replaceLocalIndex(scanResult.hashIndex, mappingID: mapping.id)
        } catch {
            return handlePersistenceFailure(error, summary: summary)
        }
        if Task.isCancelled { return summary }

        // 4. Server-Bestandsaufnahme
        status.currentStep = "Lese Serverbestand …"
        publish()
        let remoteSnapshot: RemoteSnapshot
        do {
            remoteSnapshot = try await enumerateRemote()
        } catch {
            if error is SyncStoreError || error is SQLiteError {
                return handlePersistenceFailure(error, summary: summary)
            }
            return handleConnectivityFailure(error, summary: summary)
        }
        lastRemoteSnapshot = remoteSnapshot
        if Task.isCancelled { return summary }

        // 5. Planung
        status.currentStep = "Vergleiche Bestände …"
        publish()
        let baseline: [String: BaselineEntry]
        let openConflicts: [ConflictRecord]
        do {
            baseline = try await store.baseline(mappingID: mapping.id)
            openConflicts = try await store.conflicts(mappingID: mapping.id)
        } catch {
            return handlePersistenceFailure(error, summary: summary)
        }
        let input = PlannerInput(baseline: baseline, local: scanResult.snapshot, remote: remoteSnapshot,
                                 openConflictPaths: Set(openConflicts.map(\.path)),
                                 caseInsensitiveLocalFileSystem: config.caseInsensitiveLocalFileSystem)
        var plan = SyncPlanner.plan(input)
        if let reason = plan.deletionsSuppressedReason {
            logger.warning("engine", reason)
            status.lastIssue = SyncIssue(message: remoteSnapshot.isComplete
                                         ? "Der lokale Ordner konnte nicht vollständig gelesen werden. Löschungen wurden sicherheitshalber nicht übertragen."
                                         : "Teile des Serverbestands konnten nicht gelesen werden. Löschungen wurden sicherheitshalber nicht übertragen.",
                                         detail: remoteSnapshot.failedPrefixes.sorted().joined(separator: ", "), action: .retry)
        }
        let collisions = Array(Set(plan.collisions + scanResult.collisions)).sorted()
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
        let unresolvedSkipped = plan.skipped.filter { skipped in
            !scanResult.snapshot.busyPaths.contains(skipped.path)
                && !openConflicts.contains(where: { $0.path == skipped.path })
        }
        if !unresolvedSkipped.isEmpty, status.lastIssue == nil {
            status.lastIssue = SyncIssue(
                message: unresolvedSkipped.count == 1
                    ? "Ein Eintrag wurde aus Sicherheitsgründen übersprungen."
                    : "\(unresolvedSkipped.count) Einträge wurden aus Sicherheitsgründen übersprungen.",
                detail: unresolvedSkipped.map(\.path).sorted().joined(separator: ", "),
                action: .retry
            )
        }

        // 6. Löschschutz
        //
        // Bestätigungen gelten pro Aktion. Ein dauerhaft nicht sicher
        // ausführbares DELETE darf dadurch weder neue Löschungen freigeben noch
        // verhindern, dass diese separat in der Oberfläche erscheinen.
        var activeConfirmedDeletions = runConfirmedDeletions
        var confirmationSetChangedDuringRun = confirmedDeletions != runConfirmedDeletions
        let currentlyPlannedDeletions = Set(plan.deletions.compactMap(\.deletionAuthorization))
        if !confirmationSetChangedDuringRun,
           scanResult.snapshot.isComplete,
           remoteSnapshot.isComplete {
            let staleConfirmations = activeConfirmedDeletions.subtracting(currentlyPlannedDeletions)
            if !staleConfirmations.isEmpty {
                do {
                    let remaining = try await store.consumeConfirmedPendingDeletions(
                        staleConfirmations,
                        mappingID: mapping.id
                    )
                    let remainingAuthorizations = Set(remaining.map(DeletionAuthorization.init))
                    if confirmedDeletions == activeConfirmedDeletions {
                        confirmedDeletions = remainingAuthorizations
                        activeConfirmedDeletions = remainingAuthorizations
                    } else {
                        confirmationSetChangedDuringRun = true
                    }
                } catch {
                    return handlePersistenceFailure(error, summary: summary)
                }
            }
        }

        let unconfirmedDeletionActions = plan.deletions.filter { action in
            guard let authorization = action.deletionAuthorization else { return true }
            return !activeConfirmedDeletions.contains(authorization)
        }
        var unconfirmedDeletionPlan = SyncPlan()
        unconfirmedDeletionPlan.deletions = unconfirmedDeletionActions
        let impact = unconfirmedDeletionPlan.deletionImpact(baseline: baseline)
        let baselineFileCount = baseline.values.lazy.filter { $0.kind == .file }.count
        let localFileCount = scanResult.snapshot.items.values.lazy.filter { $0.kind == .file }.count
        let guardBaselineCount = baselineFileCount > 0 ? baselineFileCount : baseline.count
        let guardLocalCount = baselineFileCount > 0 ? localFileCount : scanResult.snapshot.items.count
        if confirmationSetChangedDuringRun {
            // Eine parallel getroffene Benutzerentscheidung darf niemals auf
            // einen davor erstellten Plan angewendet werden.
            plan.deletions.removeAll()
            summary.needsFollowUp = true
        } else if config.deletionGuard.requiresConfirmation(
               deletionImpact: impact,
               baselineCount: guardBaselineCount,
               localItemCount: guardLocalCount
           ) {
            var held: [PendingDeletion] = []
            for action in unconfirmedDeletionActions {
                switch action {
                case .deleteRemote(let p, let r) where r.kind == .file:
                    held.append(PendingDeletion(path: p, kind: r.kind, side: .remote))
                case .deleteLocal(let p, let l): held.append(PendingDeletion(path: p, kind: l.kind, side: .local))
                default: break
                }
            }
            do {
                try await store.replacePendingDeletions(held, mappingID: mapping.id)
            } catch {
                return handlePersistenceFailure(error, summary: summary)
            }
            summary.deletionsHeld = held.count
            logger.notice("engine", "Löschschutz: \(impact) Einträge betroffen – Bestätigung erforderlich")
            plan.deletions.removeAll { action in
                guard let authorization = action.deletionAuthorization else { return true }
                return !activeConfirmedDeletions.contains(authorization)
            }
            eventHandler?(.deletionConfirmationRequired(count: held.count))
        } else {
            do {
                try await store.clearPendingDeletionsAwaitingConfirmation(mappingID: mapping.id)
            } catch {
                return handlePersistenceFailure(error, summary: summary)
            }
        }

        // Warteschlange für die Anzeige speichern.
        let queued = plan.allActions.compactMap { a -> QueuedItem? in
            guard let dir = a.direction else { return nil }
            return QueuedItem(path: a.path, direction: dir, size: a.estimatedBytes)
        }
        do {
            try await store.replaceQueue(queued, mappingID: mapping.id)
        } catch {
            return handlePersistenceFailure(error, summary: summary)
        }
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
        var haltRemainingActions = false
        for phase in [plan.directoryCreations, plan.moves] {
            for action in phase {
                if Task.isCancelled { return summary }
                let result = await execute(action, snapshot: remoteSnapshot)
                tally(result, &transferred, &failures, &summary)
                if Self.isTerminalFailure(result) {
                    haltRemainingActions = true
                    break
                }
            }
            if haltRemainingActions { break }
        }
        if !haltRemainingActions {
            for result in await executeConcurrently(plan.transfers, snapshot: remoteSnapshot) {
                tally(result, &transferred, &failures, &summary)
                if Self.isTerminalFailure(result) { haltRemainingActions = true }
            }
        }
        // Löschungen sind die einzige irreversible Phase. Sobald eine vorherige
        // Aktion fehlgeschlagen oder zurückgestellt wurde, wird in diesem
        // Durchgang nichts mehr gelöscht – auch nicht bei einem generischen
        // Einzeldateifehler.
        if failures > 0 || summary.needsFollowUp || summary.skipped > plan.skipped.count {
            haltRemainingActions = true
        }
        if confirmedDeletions != activeConfirmedDeletions {
            // Eine während dieses Durchgangs ergänzte Benutzerentscheidung
            // darf nicht aus einem älteren Plan wirken.
            haltRemainingActions = true
            summary.needsFollowUp = true
        }
        if Task.isCancelled { return summary }
        if !haltRemainingActions {
            for action in plan.deletions {
                if Task.isCancelled { return summary }
                if confirmedDeletions != activeConfirmedDeletions {
                    haltRemainingActions = true
                    summary.needsFollowUp = true
                    break
                }
                let authorization = action.deletionAuthorization
                let wasConfirmed = authorization.map(activeConfirmedDeletions.contains) == true
                let result = await execute(action, snapshot: remoteSnapshot)
                tally(result, &transferred, &failures, &summary)
                if wasConfirmed,
                   let authorization,
                   result.settlesDeletionConfirmation {
                    do {
                        let remaining = try await store.consumeConfirmedPendingDeletions(
                            [authorization],
                            mappingID: mapping.id
                        )
                        let remainingAuthorizations = Set(remaining.map(DeletionAuthorization.init))
                        if confirmedDeletions == activeConfirmedDeletions {
                            confirmedDeletions = remainingAuthorizations
                            activeConfirmedDeletions = remainingAuthorizations
                        } else {
                            haltRemainingActions = true
                            summary.needsFollowUp = true
                        }
                    } catch {
                        return handlePersistenceFailure(error, summary: summary)
                    }
                } else if confirmedDeletions != activeConfirmedDeletions {
                    haltRemainingActions = true
                    summary.needsFollowUp = true
                }
                status.completedCount += 1
                if Self.isTerminalFailure(result) {
                    haltRemainingActions = true
                    break
                }
            }
        }
        if !haltRemainingActions {
            for action in plan.bookkeeping {
                let result = await execute(action, snapshot: remoteSnapshot)
                tally(result, &transferred, &failures, &summary)
            }
        }

        summary.transferred = transferred
        summary.failed = failures
        try? await store.pruneTransfers(mappingID: mapping.id)

        // Verbleibende Warteschlange: nur fehlgeschlagene/zurückgestellte Einträge.
        let remaining: [QueuedItem]
        do {
            remaining = try await store.queue(mappingID: mapping.id)
        } catch {
            return handlePersistenceFailure(error, summary: summary)
        }
        status.pendingCount = remaining.count + scanResult.snapshot.busyPaths.count
        if !scanResult.snapshot.busyPaths.isEmpty { summary.needsFollowUp = true }

        if summary.authenticationFailure {
            status.isPaused = true
            status.pauseReason = .authenticationRequired
            eventHandler?(.authenticationRequired)
        } else if summary.connectivityFailure {
            summary.offline = true
            let delay = retryPolicy.recordFailure()
            scheduleRetry(after: delay, offline: true)
            eventHandler?(.wentOffline)
        } else if summary.diskFullFailure {
            // Der freie Speicher wird beim nächsten Durchgang erneut geprüft;
            // ein einzelner ENOSPC-Fehler darf Downloads nicht dauerhaft sperren.
            scheduleRetry(after: 30)
        }

        if failures == 0,
           !summary.needsFollowUp,
           summary.deletionsHeld == 0,
           summary.skipped == 0,
           remaining.isEmpty,
           scanResult.snapshot.isComplete,
           remoteSnapshot.isComplete {
            let now = Date()
            do {
                try await store.setLastSuccessfulSync(now, mappingID: mapping.id)
            } catch {
                return handlePersistenceFailure(error, summary: summary)
            }
            status.lastSuccessfulSync = now
            retryPolicy.reset()
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
        case .failed(let failure):
            failures += 1
            switch failure {
            case .connectivity: summary.connectivityFailure = true
            case .authentication: summary.authenticationFailure = true
            case .diskFull: summary.diskFullFailure = true
            case .other: break
            }
        case .deferred: summary.needsFollowUp = true
        case .blocked: summary.skipped += 1
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
            status.lastIssue = SyncIssue(message: dav.userDescription, detail: dav.technicalDescription, action: dav.suggestedAction)
            let delay = retryPolicy.recordFailure()
            let isOffline = dav.isConnectivityProblem
            if isOffline {
                let wasOnline = status.health != .offline
                summary.offline = true
                if wasOnline { eventHandler?(.wentOffline) }
            }
            scheduleRetry(after: delay, offline: isOffline)
        }
        return summary
    }

    private func handlePersistenceFailure(_ error: Error, summary: SyncRunSummary) -> SyncRunSummary {
        var summary = summary
        summary.failed += 1
        status.lastIssue = SyncIssue(
            message: "Der lokale Synchronisierungsstand konnte nicht zuverlässig gelesen oder gespeichert werden. Es wurden sicherheitshalber keine weiteren Änderungen ausgeführt.",
            detail: error.localizedDescription,
            action: .retry
        )
        logger.error("store", "Persistenzfehler – Abgleich abgebrochen: \(error)")
        return summary
    }

    private func scheduleRetry(after delay: TimeInterval, offline: Bool = false) {
        retryTask?.cancel()
        retryRepresentsOffline = offline
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
        retryRepresentsOffline = false
        status.nextRetry = nil
        requestSync(trigger: .retry)
    }

    // MARK: - Server-Bestandsaufnahme

    private func enumerateRemote() async throws -> RemoteSnapshot {
        let enumerator = RemoteEnumerator(client: client, rules: rules, concurrency: config.maxConcurrentTransfers)
        let current = try await store.mapping(id: mapping.id) ?? mapping
        if capabilities?.supportsSyncCollection == true, let token = current.syncToken, current.remoteIndexIsComplete {
            let cached = try await store.remoteIndex(mappingID: mapping.id)
            do {
                let snapshot = try await enumerator.incremental(cached: cached, token: token)
                guard let nextToken = snapshot.syncToken else {
                    throw WebDAVError.invalidResponse("sync-collection lieferte keinen Folgetoken")
                }
                try await store.replaceRemoteIndex(snapshot.items, syncToken: nextToken, mappingID: mapping.id)
                logger.debug("remote", "sync-collection: \(snapshot.items.count) Einträge im Bestand")
                return snapshot
            } catch let error as WebDAVError {
                switch error {
                case .invalidSyncToken, .invalidResponse, .unexpectedStatus, .forbidden, .conflict:
                    logger.notice("remote", "sync-collection nicht verwendbar (\(error.technicalDescription)) – vollständige Bestandsaufnahme")
                    try await store.setSyncToken(nil, remoteIndexComplete: false, mappingID: mapping.id)
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
            try await store.replaceRemoteIndex(snapshot.items, syncToken: token, mappingID: mapping.id)
        } else {
            try await store.setSyncToken(nil, remoteIndexComplete: false, mappingID: mapping.id)
        }
        logger.debug("remote", "Vollständige Bestandsaufnahme: \(snapshot.items.count) Einträge, vollständig=\(snapshot.isComplete)")
        return snapshot
    }

    // MARK: - Ausführung

    enum ActionFailure: Sendable, Equatable {
        case connectivity
        case authentication
        case diskFull
        case other
    }

    enum ActionResult: Sendable {
        case succeeded
        case failed(ActionFailure)
        /// Vorbedingung nicht mehr erfüllt → im nächsten Durchgang neu planen.
        case deferred
        /// Serverfähigkeit fehlt dauerhaft; in der Queue behalten, aber keinen
        /// unmittelbaren Wiederholungs-Loop auslösen.
        case blocked
        case conflict
        case noop

        /// Eine bestätigte Löschung ist nur nach einem erfolgreichen bzw.
        /// bereits erledigten Ergebnis verbraucht. Dauerhaft blockierte
        /// Aktionen behalten ihre pfadgenaue Freigabe, ohne andere Löschungen
        /// zu beeinflussen.
        var settlesDeletionConfirmation: Bool {
            switch self {
            case .succeeded, .noop:
                return true
            case .failed, .deferred, .blocked, .conflict:
                return false
            }
        }
    }

    private func executeConcurrently(_ actions: [SyncAction], snapshot: RemoteSnapshot) async -> [ActionResult] {
        guard !actions.isEmpty else { return [] }
        let limit = config.maxConcurrentTransfers
        var results: [ActionResult] = []
        await withTaskGroup(of: ActionResult.self) { group in
            var iterator = actions.makeIterator()
            var running = 0
            var shouldStop = false
            while running < limit, let action = iterator.next() {
                group.addTask { await self.execute(action, snapshot: snapshot) }
                running += 1
            }
            while let result = await group.next() {
                results.append(result)
                status.completedCount += 1
                publish()
                if Self.isTerminalFailure(result) {
                    shouldStop = true
                    group.cancelAll()
                }
                if Task.isCancelled { continue }
                if !shouldStop, let next = iterator.next() {
                    group.addTask { await self.execute(next, snapshot: snapshot) }
                }
            }
        }
        return results
    }

    private static func isTerminalFailure(_ result: ActionResult) -> Bool {
        if case .failed(let failure) = result {
            return failure == .connectivity || failure == .authentication || failure == .diskFull
        }
        return false
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
        let observedBytes = status.activeTransfers.first(where: { $0.id == record.id })?.bytesDone ?? record.bytesDone
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
        record.bytesDone = state == .succeeded ? record.bytesTotal : observedBytes
        try? await store.saveTransfer(record, mappingID: mapping.id)
        if state == .succeeded {
            try? await store.removeQueued(path: record.path, direction: record.direction, mappingID: mapping.id)
        }
        status.activeTransfers.removeAll { $0.id == record.id }
        status.bytesDone += record.bytesDone
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
                return try await performUpload(path: path, local: local, remote: nil, conflictReason: nil, snapshot: snapshot)
            case .uploadChanged(let path, let local, let remote):
                return try await performUpload(path: path, local: local, remote: remote, conflictReason: nil, snapshot: snapshot)
            case .keepLocalAfterRemoteDelete(let path, let local):
                return try await performUpload(path: path, local: local, remote: nil, conflictReason: .modifiedLocallyDeletedRemotely, snapshot: snapshot)
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
                return try await performDeleteLocal(path: path, local: local, snapshot: snapshot)
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
            let davError = (error as? WebDAVError) ?? (error as? CloudreveError)?.asWebDAVError
            if Task.isCancelled || error is CancellationError || davError == .cancelled {
                let record = status.activeTransfers.first { $0.path == action.path }
                await finishTransfer(record, state: .cancelled, error: error)
                return .deferred
            }
            logger.error("engine", "Aktion fehlgeschlagen (\(action.path)): \(error)")
            let record = status.activeTransfers.first { $0.path == action.path }
                ?? TransferRecord(path: action.path, direction: action.direction ?? .upload, state: .failed, startedAt: Date(), finishedAt: Date())
            await finishTransfer(record, state: .failed, error: error)
            var failure: ActionFailure = .other
            if let davError {
                switch davError {
                case .authenticationRequired:
                    failure = .authentication
                default:
                    if davError.isConnectivityProblem { failure = .connectivity }
                }
                status.lastIssue = SyncIssue(
                    message: davError.userDescription,
                    detail: davError.technicalDescription,
                    action: davError.suggestedAction
                )
            }
            if case LocalFileError.diskFull = error {
                downloadsPausedForDiskSpace = true
                status.lastIssue = SyncIssue(message: LocalFileError.diskFull.userDescription, action: .freeDiskSpace)
                eventHandler?(.diskFull)
                failure = .diskFull
            }
            return .failed(failure)
        }
    }

    // MARK: Upload

    /// Konservative Versionsprüfung für Server, die bedingte Schreibzugriffe
    /// nicht zuverlässig unterstützen. `nil == nil` ist kein Versionsbeweis.
    private static func sameRemoteVersion(_ current: RemoteItem?, _ expected: RemoteItem) -> Bool {
        guard let current, current.kind == expected.kind else { return false }
        guard let expectedValidator = expected.validator,
              current.validator == expectedValidator,
              current.size == expected.size else { return false }
        switch (current.modified, expected.modified) {
        case let (lhs?, rhs?):
            return abs(lhs - rhs) < 0.001
        case (nil, nil):
            return expected.validator != nil
        case (.some, nil), (nil, .some):
            return expected.validator != nil
        }
    }

    /// Variante für einen gespeicherten gemeinsamen Stand. Dateien ohne
    /// Validator dürfen zunächst über Größe und Zeit gebunden werden; der
    /// Aufrufer verifiziert ihren Inhalt anschließend per SHA-256. Für Ordner
    /// gibt es diesen Inhaltsbeweis nicht.
    private static func sameRemoteVersion(_ current: RemoteItem, _ expected: BaselineEntry) -> Bool {
        guard current.kind == expected.kind, current.size == expected.remoteSize else { return false }
        if let expectedValidator = expected.remoteValidator {
            // Ein passender starker ETag ist der Versionsbeweis. Bei schwachen
            // ETags verifiziert der Aufrufer zusätzlich den Inhalt; ein
            // fehlendes Last-Modified-Feld darf diese Prüfung nicht verhindern.
            return current.validator == expectedValidator
        }
        if expected.kind == .directory {
            return false
        }
        switch (current.modified, expected.remoteModified) {
        case let (lhs?, rhs?):
            return abs(lhs - rhs) < 0.001
        default:
            return false
        }
    }

    private struct VerifiedRemoteContent {
        var validator: String
        var strong: Bool
        var size: Int64
        var modified: Double?
    }

    /// Unveränderliche Arbeitskopie für einen Upload. So kann ein Editor die
    /// Originaldatei während einer laufenden URLSession-Übertragung ersetzen
    /// oder weiterschreiben, ohne dass eine Mischversion auf dem Server landet.
    private struct StagedUpload {
        var fileURL: URL
        var size: Int64
        var modified: Double
        var hash: String
        var stagedCacheToken: String
    }

    private func stageUpload(path: String) async throws -> StagedUpload {
        guard let attributes = try fileSystem.attributes(path), attributes.kind == .file,
              let source = try POSIXFileMetadata.read(atPath: fileSystem.url(path).path),
              !source.isSymbolicLink else {
            throw LocalFileError.changedSinceScan(path)
        }
        try reserveTemporarySpace(for: attributes.size)
        var temporary: URL?
        do {
            let generated = try fileSystem.makeTemporaryFileURL()
            temporary = generated
            let fileSystem = self.fileSystem
            return try await performFileOperation {
                let sourceURL = try fileSystem.url(path)
                try FileManager.default.copyItem(at: sourceURL, to: generated)
                if let timestamp = try POSIXFileMetadata.modificationTime(atPath: sourceURL.path) {
                    try POSIXFileMetadata.setModificationTime(atPath: generated.path, timestamp)
                }
                let stagedModified = (try FileManager.default.attributesOfItem(atPath: generated.path)[.modificationDate] as? Date)?
                    .timeIntervalSince1970 ?? -1
                guard POSIXFileMetadata.sameModificationTime(stagedModified, attributes.modified) else {
                    throw LocalFileError.changedSinceScan(path)
                }
                guard let currentAttributes = try fileSystem.attributes(path),
                      currentAttributes.kind == .file,
                      currentAttributes.size == attributes.size,
                      currentAttributes.modified == attributes.modified,
                      let current = try POSIXFileMetadata.read(atPath: fileSystem.url(path).path),
                      current.cacheToken == source.cacheToken,
                      !current.isSymbolicLink else {
                    throw LocalFileError.changedSinceScan(path)
                }
                let stagedSize = ((try FileManager.default.attributesOfItem(atPath: generated.path)[.size]) as? NSNumber)?.int64Value ?? -1
                guard stagedSize == attributes.size else {
                    throw LocalFileError.changedSinceScan(path)
                }
                guard let stagedBeforeHash = try POSIXFileMetadata.read(atPath: generated.path),
                      !stagedBeforeHash.isSymbolicLink else {
                    throw LocalFileError.changedSinceScan(path)
                }
                let hash = try SHA256Hasher.hashFile(at: generated)
                guard let stagedMetadata = try POSIXFileMetadata.read(atPath: generated.path),
                      stagedMetadata.cacheToken == stagedBeforeHash.cacheToken,
                      !stagedMetadata.isSymbolicLink else {
                    throw LocalFileError.changedSinceScan(path)
                }
                return StagedUpload(
                    fileURL: generated,
                    size: attributes.size,
                    modified: attributes.modified,
                    hash: hash,
                    stagedCacheToken: stagedMetadata.cacheToken
                )
            }
        } catch {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            releaseTemporarySpace(attributes.size)
            throw LocalFileSystem.mapError(error)
        }
    }

    /// Baut einen Zielpfad unter Verwendung der exakten Schreibweise des
    /// tiefsten bereits vorhandenen Serverordners (wichtig für NFD/NFC).
    private static func rawRemotePath(for path: String, snapshot: RemoteSnapshot) -> String {
        if let exact = snapshot.items[path] { return exact.rawPath }
        for ancestor in RelativePath.ancestors(of: path).reversed() {
            guard let item = snapshot.items[ancestor], item.kind == .directory else { continue }
            let suffix = String(path.dropFirst(ancestor.count + 1))
            return RelativePath.join(item.rawPath, suffix)
        }
        return path
    }

    /// Verknüpft Inhalt und Validator über dieselbe GET-Antwort. Damit kann kein
    /// zwischen Mutation und nachträglichem PROPFIND eingeschobener Fremdstand
    /// versehentlich als eigener Upload in die Baseline gelangen.
    private func verifyRemoteContent(rawPath: String, expectedHash: String?, expectedSize: Int64) async throws -> VerifiedRemoteContent? {
        guard let expectedHash else { return nil }
        guard let before = try await client.stat(rawPath), before.kind == .file, before.size == expectedSize else {
            return nil
        }
        try reserveTemporarySpace(for: expectedSize)
        let temp: URL
        do {
            temp = try fileSystem.makeTemporaryFileURL()
        } catch {
            releaseTemporarySpace(expectedSize)
            throw error
        }
        defer {
            try? FileManager.default.removeItem(at: temp)
            releaseTemporarySpace(expectedSize)
        }
        let result: DownloadResult
        do {
            result = try await client.download(rawPath, to: temp, progress: nil)
        } catch {
            if error is WebDAVError || error is CancellationError { throw error }
            throw LocalFileSystem.mapError(error)
        }
        guard result.contentLength == expectedSize,
              try await performFileOperation({ try SHA256Hasher.hashFile(at: temp) }) == expectedHash else {
            return nil
        }
        guard let after = try await client.stat(rawPath),
              after.kind == before.kind,
              after.size == before.size,
              after.validator == before.validator,
              after.modified == before.modified else { return nil }
        if result.isDirectDAVResponse, let responseETag = result.etag,
           let currentETag = after.validator, responseETag != currentETag {
            return nil
        }
        if let etag = after.validator, !etag.isEmpty {
            return VerifiedRemoteContent(
                validator: etag,
                strong: after.validatorIsStrong,
                size: result.contentLength,
                modified: after.modified
            )
        }
        if let modified = after.modified ?? result.lastModified?.timeIntervalSince1970 {
            return VerifiedRemoteContent(
                validator: "mtime:\(Int(modified));size:\(result.contentLength)",
                strong: false,
                size: result.contentLength,
                modified: modified
            )
        }
        return nil
    }

    private func performUpload(path: String, local: LocalItem, remote: RemoteItem?, conflictReason: ConflictReason?,
                               snapshot: RemoteSnapshot) async throws -> ActionResult {
        let record = await beginTransfer(.uploadNew(path: path, local: local))
        let localPath = local.rawPath
        // Version festlegen, die hochgeladen wird.
        guard let attrs = try fileSystem.attributes(localPath), attrs.kind == .file else {
            await finishTransfer(record, state: .skipped, note: "Datei ist lokal nicht mehr vorhanden")
            return .deferred
        }
        var version = local
        version.size = attrs.size
        version.modified = attrs.modified
        var ifMatch: String?
        var ifNoneMatchAll = false
        let hasAtomicWebDAVPrecondition = remote?.validatorIsStrong == true
            && capabilities?.supportsConditionalWrites == true
        let needsVersionedTransport = capabilities?.honorsIfMatch == false
            || (remote != nil && !hasAtomicWebDAVPrecondition)
        let uploadTransportAvailable: Bool
        if let uploadTransport {
            uploadTransportAvailable = await uploadTransport.isAvailable()
        } else {
            uploadTransportAvailable = false
        }
        let versionedTransportAvailable = needsVersionedTransport && uploadTransportAvailable
        if let remote {
            if hasAtomicWebDAVPrecondition {
                ifMatch = remote.validator
            } else if !versionedTransportAvailable {
                if uploadTransport != nil {
                    throw WebDAVError.authenticationRequired(status: 401)
                }
                await finishTransfer(record, state: .skipped, note: "Der Server bietet keinen atomaren Versionsschutz; Überschreiben wurde sicherheitshalber zurückgestellt")
                return .blocked
            } else {
                // Zusätzliche Vorprüfung; die eigentliche Atomarität liefert der
                // versionierte Upload-Endpunkt.
                let current = try await client.stat(remote.rawPath)
                if !Self.sameRemoteVersion(current, remote) {
                    await finishTransfer(record, state: .skipped, note: "Serverversion hat sich geändert – wird neu abgeglichen")
                    return .deferred
                }
            }
        } else {
            ifNoneMatchAll = true
            if capabilities?.honorsIfMatch == false, !versionedTransportAvailable {
                if uploadTransport != nil {
                    throw WebDAVError.authenticationRequired(status: 401)
                }
                await finishTransfer(record, state: .skipped, note: "Der Server bietet keinen atomaren Schutz beim Anlegen; Upload wurde sicherheitshalber zurückgestellt")
                return .blocked
            }
        }
        let rawPath = remote?.rawPath ?? Self.rawRemotePath(for: path, snapshot: snapshot)
        let staged: StagedUpload
        do {
            staged = try await stageUpload(path: localPath)
        } catch LocalFileError.changedSinceScan {
            try await store.removeLocalIndex(path: path, mappingID: mapping.id)
            await finishTransfer(record, state: .skipped, note: "Datei wurde während der Vorbereitung geändert – wird erneut geprüft")
            return .deferred
        }
        defer {
            try? FileManager.default.removeItem(at: staged.fileURL)
            releaseTemporarySpace(staged.size)
        }
        version.size = staged.size
        version.modified = staged.modified
        version.hash = staged.hash
        let fileURL = staged.fileURL
        let recordID = record?.id
        let progressHandler: TransferProgress = { [weak self] done, total in
            guard let self, let recordID else { return }
            Task { await self.updateProgress(recordID: recordID, done: done, total: total) }
        }
        let result: UploadResult
        do {
            let exceedsChunkThreshold = config.chunkedUploadThreshold.map { version.size >= $0 } ?? false
            if let transport = uploadTransport,
               (needsVersionedTransport || exceedsChunkThreshold),
               uploadTransportAvailable {
                let info = UploadRequestInfo(path: path, rawPath: localPath, remotePath: rawPath, fileURL: fileURL, size: version.size, modified: version.modified,
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
            try await store.removeLocalIndex(path: path, mappingID: mapping.id)
            await finishTransfer(record, state: .skipped, note: "Datei wurde während der Übertragung geändert – wird erneut hochgeladen")
            return .deferred
        } catch let error as CloudreveError {
            if case .unsupportedStoragePolicy = error {
                guard !needsVersionedTransport else {
                    logger.warning("engine", "\(error.userDescription) – unsicherer WebDAV-Rückfall für \(path) abgelehnt")
                    await finishTransfer(record, state: .skipped, note: "Die Serverrichtlinie unterstützt keinen atomar geschützten Upload; Datei bleibt ausstehend")
                    return .blocked
                }
                logger.warning("engine", "\(error.userDescription) – Rückfall auf WebDAV-PUT für \(path)")
                result = try await client.upload(file: fileURL, to: rawPath, ifMatch: ifMatch, ifNoneMatchAll: ifNoneMatchAll, progress: progressHandler)
            } else {
                throw error.asWebDAVError
            }
        }
        let expectedVersionHash = version.hash
        let stagedStillMatches = try await performFileOperation {
            guard let stagedMetadata = try POSIXFileMetadata.read(atPath: staged.fileURL.path),
                  stagedMetadata.cacheToken == staged.stagedCacheToken,
                  !stagedMetadata.isSymbolicLink else { return false }
            return try SHA256Hasher.hashFile(at: staged.fileURL) == expectedVersionHash
        }
        guard stagedStillMatches else {
            await finishTransfer(record, state: .skipped, note: "Upload-Arbeitskopie wurde unerwartet verändert – wird erneut geprüft")
            return .deferred
        }
        // Nur ein Validator aus der Mutationsantwort ist kausal mit den
        // hochgeladenen Bytes verknüpft. Fehlt er, wird die tatsächlich
        // auslieferbare Repräsentation per GET gehasht; ein späteres PROPFIND
        // allein könnte bereits die Version eines fremden Schreibers sehen.
        var validator = result.etag
        var strong = validator?.isStrongHTTPETag == true
        var remoteSize = version.size
        var remoteModified: Double?
        if validator == nil {
            guard let verified = try await verifyRemoteContent(rawPath: rawPath, expectedHash: version.hash, expectedSize: version.size) else {
                await finishTransfer(record, state: .skipped, note: "Serverversion konnte nach dem Upload nicht eindeutig bestätigt werden – wird neu abgeglichen")
                return .deferred
            }
            validator = verified.validator
            strong = verified.strong
            remoteSize = verified.size
            remoteModified = verified.modified
        }
        // Der hochgeladene Inhalt bleibt nur dann der aktuelle lokale Stand,
        // wenn die Bytes noch übereinstimmen. macOS kann während des Uploads
        // erweiterte Attribute schreiben und damit ctime oder die gelesene
        // mtime minimal verändern, ohne die Datei zu bearbeiten.
        let fileSystem = self.fileSystem
        let expectedSize = version.size
        let expectedHash = version.hash
        let sourceUnchanged = (try? await performFileOperation {
            let sourceURL = try fileSystem.url(localPath)
            guard let before = try fileSystem.attributes(localPath),
                  before.kind == .file,
                  before.size == expectedSize,
                  let beforeMetadata = try POSIXFileMetadata.read(atPath: sourceURL.path),
                  !beforeMetadata.isSymbolicLink else { return false }
            guard try fileSystem.hash(localPath) == expectedHash else { return false }
            guard let afterMetadata = try POSIXFileMetadata.read(atPath: sourceURL.path),
                  afterMetadata.cacheToken == beforeMetadata.cacheToken,
                  !afterMetadata.isSymbolicLink else { return false }
            return true
        }) == true
        // Die Arbeitskopie wurde nachweislich installiert. Auch wenn das
        // Original währenddessen weiterbearbeitet wurde, ist diese Version nun
        // der gemeinsame Stand; der Folgelauf erkennt die lokale Folgeänderung
        // dadurch als normalen Upload statt als künstlichen Erstkonflikt.
        try await store.upsertBaseline(BaselineEntry(path: path, kind: .file, localHash: version.hash, localSize: version.size, localModified: version.modified,
                                                     remoteValidator: validator, remoteValidatorIsStrong: strong, remoteSize: remoteSize,
                                                     remoteModified: remoteModified), mappingID: mapping.id)
        if !sourceUnchanged {
            try await store.removeLocalIndex(path: path, mappingID: mapping.id)
            await finishTransfer(record, state: .skipped, note: "Datei wurde während der Übertragung erneut geändert – wird erneut abgeglichen")
            return .deferred
        }
        await finishTransfer(record, state: .succeeded)
        if let conflictReason {
            let conflict = ConflictRecord(path: path, kind: .file, reason: conflictReason, localHash: version.hash, localSize: version.size,
                                          localModified: version.modified, remoteValidator: nil, remoteSize: nil, remoteModified: nil)
            try await store.saveConflict(conflict, mappingID: mapping.id)
            eventHandler?(.conflictDetected(path: path))
            logger.notice("engine", "Konflikt (lokal geändert, Server gelöscht): \(path) – lokale Version erhalten")
            return .conflict
        }
        return .succeeded
    }

    // MARK: Download

    private func checkDiskSpace(for size: Int64) throws {
        guard size >= 0 else { throw LocalFileError.io("Server meldet eine ungültige Dateigröße") }
        let (temporaryTotal, temporaryOverflow) = reservedTemporaryBytes.addingReportingOverflow(size)
        let (required, overflow) = temporaryTotal.addingReportingOverflow(config.minimumFreeSpace)
        if temporaryOverflow || overflow || fileSystem.availableCapacity().map({ $0 < required }) == true {
            throw LocalFileError.diskFull
        }
    }

    private func reserveTemporarySpace(for size: Int64) throws {
        // Absichtlich synchron actor-isoliert: Zwischen Prüfung und Erhöhung
        // darf kein paralleler Transfer auf dem Actor fortgesetzt werden.
        try checkDiskSpace(for: size)
        reservedTemporaryBytes += size
    }

    private func releaseTemporarySpace(_ size: Int64) {
        reservedTemporaryBytes = max(0, reservedTemporaryBytes - max(0, size))
    }

    private func downloadToTemp(_ remote: RemoteItem, recordID: String?) async throws -> (URL, DownloadResult, String) {
        try reserveTemporarySpace(for: remote.size)
        let temp: URL
        do {
            temp = try fileSystem.makeTemporaryFileURL()
        } catch {
            releaseTemporarySpace(remote.size)
            throw error
        }
        do {
            let result = try await client.download(remote.rawPath, to: temp, progress: { [weak self] done, total in
                guard let self, let recordID else { return }
                Task { await self.updateProgress(recordID: recordID, done: done, total: total) }
            })
            let hash = try await performFileOperation { try SHA256Hasher.hashFile(at: temp) }
            return (temp, result, hash)
        } catch {
            releaseTemporarySpace(remote.size)
            try? FileManager.default.removeItem(at: temp)
            if error is WebDAVError || error is CancellationError { throw error }
            throw LocalFileSystem.mapError(error)
        }
    }

    private func remoteValidatorAfterDownload(_ remote: RemoteItem, result: DownloadResult) async throws -> (String?, Bool, Double?)? {
        guard let current = try await client.stat(remote.rawPath),
              current.kind == remote.kind,
              current.size == remote.size,
              current.size == result.contentLength else { return nil }
        if let expectedValidator = remote.validator {
            guard current.validator == expectedValidator else { return nil }
        } else {
            guard current.validator == nil,
                  let before = remote.modified,
                  let after = current.modified,
                  abs(before - after) < 0.001 else { return nil }
        }
        // Bei einer fremden Object-Storage-Antwort gehört der GET-ETag nicht
        // zum DAV-Namensraum. Bei einer direkten Antwort muss ein vorhandener
        // GET-ETag dagegen mit dem anschließenden PROPFIND übereinstimmen.
        if result.isDirectDAVResponse, let responseETag = result.etag,
           let currentETag = current.validator, responseETag != currentETag {
            return nil
        }
        let modified = current.modified ?? result.lastModified?.timeIntervalSince1970
        if let validator = current.validator {
            return (validator, current.validatorIsStrong, modified)
        }
        if let modified {
            return ("mtime:\(Int(modified));size:\(result.contentLength)", false, modified)
        }
        return nil
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
        let temporaryFileID = try POSIXFileMetadata.read(atPath: temp.path)?.fileID
        defer {
            if let current = try? POSIXFileMetadata.read(atPath: temp.path),
               current.fileID == temporaryFileID {
                try? FileManager.default.removeItem(at: temp)
            }
            releaseTemporarySpace(remote.size)
        }
        guard let (validator, strong, remoteModified) = try await remoteValidatorAfterDownload(remote, result: result) else {
            await finishTransfer(record, state: .skipped, note: "Serverdatei hat sich während des Downloads geändert – wird neu abgeglichen")
            return .deferred
        }
        let modifiedDate = remoteModified.map { Date(timeIntervalSince1970: $0) }
        let fileSystem = self.fileSystem
        if replacing != nil,
           let current = try fileSystem.attributes(targetPath),
           current.kind == .file,
           try await performFileOperation({ try fileSystem.hash(targetPath) }) == hash {
            // Inhalt identisch – nur gemeinsamen Stand aktualisieren.
            try? FileManager.default.removeItem(at: temp)
            try await store.upsertBaseline(BaselineEntry(path: path, kind: .file, localHash: hash, localSize: current.size, localModified: current.modified,
                                                         remoteValidator: validator, remoteValidatorIsStrong: strong, remoteSize: result.contentLength,
                                                         remoteModified: remoteModified), mappingID: mapping.id)
            await finishTransfer(record, state: .succeeded, note: "Inhalt war bereits identisch")
            return .succeeded
        }
        do {
            let expectedHash = replacing?.hash
            let expectedSize = replacing?.size
            let expectedModified = replacing?.modified
            try await performFileOperation {
                try fileSystem.installDownloadedFile(from: temp, to: targetPath, expectedHash: expectedHash, expectedSize: expectedSize,
                                                     expectedModified: expectedModified, modifiedDate: modifiedDate)
            }
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
        let temporaryFileID = try POSIXFileMetadata.read(atPath: temp.path)?.fileID
        defer {
            if let current = try? POSIXFileMetadata.read(atPath: temp.path),
               current.fileID == temporaryFileID {
                try? FileManager.default.removeItem(at: temp)
            }
            releaseTemporarySpace(remote.size)
        }
        guard let (validator, strong, remoteModified) = try await remoteValidatorAfterDownload(remote, result: result) else {
            await finishTransfer(record, state: .skipped, note: "Serverdatei hat sich während des Downloads geändert – wird neu abgeglichen")
            return .deferred
        }
        // Lokale Version muss noch dem geplanten Stand entsprechen.
        let localPath = local.rawPath
        guard let attrs = try fileSystem.attributes(localPath), attrs.kind == .file else {
            try? FileManager.default.removeItem(at: temp)
            await finishTransfer(record, state: .skipped, note: "Lokale Datei nicht mehr vorhanden – wird neu abgeglichen")
            return .deferred
        }
        let fileSystem = self.fileSystem
        let localHash = try await performFileOperation { try fileSystem.hash(localPath) }
        if localHash == remoteHash {
            try? FileManager.default.removeItem(at: temp)
            try await store.upsertBaseline(BaselineEntry(path: path, kind: .file, localHash: remoteHash, localSize: attrs.size, localModified: attrs.modified,
                                                         remoteValidator: validator, remoteValidatorIsStrong: strong, remoteSize: result.contentLength,
                                                         remoteModified: remoteModified), mappingID: mapping.id)
            await finishTransfer(record, state: .succeeded, note: "Beide Seiten hatten denselben Inhalt – zusammengeführt")
            return .succeeded
        }
        if reason == .bothModified,
           let baseline = try await store.baseline(mappingID: mapping.id)[path],
           baseline.localHash == remoteHash {
            // Ein schwacher oder fehlender Validator ließ die Serverseite nur
            // vorsorglich als geändert erscheinen. Der Inhaltsvergleich zeigt,
            // dass sie weiterhin dem gemeinsamen Stand entspricht. Die lokale
            // Fassung darf deshalb nicht in eine künstliche Konfliktkopie
            // verschoben werden; der geschützte Uploadpfad entscheidet, ob der
            // Server ein atomar abgesichertes Überschreiben erlaubt.
            await finishTransfer(record, state: .skipped, note: "Serverinhalt ist unverändert; lokaler Upload wird sicher geprüft")
            return try await performUpload(path: path, local: local, remote: remote, conflictReason: nil, snapshot: lastRemoteSnapshot ?? RemoteSnapshot())
        }
        // Beide Versionen erhalten: lokale Version wird zur Konfliktkopie, Serverversion übernimmt den Pfad.
        let copyName = RelativePath.conflictCopyName(for: RelativePath.name(of: path), deviceName: config.deviceName)
        let desiredCopyPath = RelativePath.join(RelativePath.parent(of: path) ?? "", copyName)
        let copyPath = try fileSystem.uniqueRelativePath(desiredCopyPath)
        let actualCopyName = RelativePath.name(of: copyPath)
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
        let baseline = BaselineEntry(
            path: path,
            kind: .file,
            localHash: remoteHash,
            localSize: installed?.size ?? result.contentLength,
            localModified: installed?.modified ?? 0,
            remoteValidator: validator,
            remoteValidatorIsStrong: strong,
            remoteSize: result.contentLength,
            remoteModified: remoteModified
        )
        let conflict = ConflictRecord(path: path, kind: .file, reason: reason, localHash: localHash, localSize: attrs.size, localModified: attrs.modified,
                                      remoteValidator: validator, remoteSize: result.contentLength, remoteModified: remoteModified, conflictCopyPath: copyPath)
        do {
            try await store.saveConflict(conflict, baseline: baseline, mappingID: mapping.id)
        } catch {
            // Der Datenbankzustand wurde transaktional nicht verändert. Stelle
            // den lokalen Ausgangszustand best-effort wieder her; beide
            // Fassungen bleiben selbst bei einem Rollback-Fehler erhalten.
            do {
                _ = try fileSystem.trashVerifiedFile(
                    path,
                    expectedHash: remoteHash,
                    recoveryDirectory: config.recoveryDirectory
                )
                try fileSystem.move(copyPath, to: localPath)
            } catch let rollbackError {
                logger.error(
                    "engine",
                    "Konflikt-Persistenz für \(path) fehlgeschlagen; beide Fassungen bleiben am Ziel, als Konfliktkopie oder im Wiederherstellungsbereich erhalten: \(rollbackError)"
                )
            }
            throw error
        }
        await finishTransfer(record, state: .succeeded, note: "Konflikt: lokale Version als „\(actualCopyName)“ gesichert")
        eventHandler?(.conflictDetected(path: path))
        logger.notice("engine", "Konflikt: \(path) – Konfliktkopie \(copyPath)")
        return .conflict
    }

    private func performKindMismatch(path: String, local: LocalItem, remote: RemoteItem) async throws -> ActionResult {
        let record = await beginTransfer(.kindMismatch(path: path, local: local, remote: remote))
        let copyName = RelativePath.conflictCopyName(for: RelativePath.name(of: path), deviceName: config.deviceName)
        let desiredCopyPath = RelativePath.join(RelativePath.parent(of: path) ?? "", copyName)
        let copyPath = try fileSystem.uniqueRelativePath(desiredCopyPath)

        var downloaded: (temp: URL, tempFileID: String, result: DownloadResult, hash: String,
                         validator: String?, strong: Bool, modified: Double?)?
        defer {
            if let downloaded {
                if let current = try? POSIXFileMetadata.read(atPath: downloaded.temp.path),
                   current.fileID == downloaded.tempFileID {
                    try? FileManager.default.removeItem(at: downloaded.temp)
                }
                releaseTemporarySpace(remote.size)
            }
        }
        if remote.kind == .file {
            let value = try await downloadToTemp(remote, recordID: record?.id)
            guard let validator = try await remoteValidatorAfterDownload(remote, result: value.1) else {
                try? FileManager.default.removeItem(at: value.0)
                releaseTemporarySpace(remote.size)
                await finishTransfer(record, state: .skipped, note: "Serverdatei hat sich während des Downloads geändert – wird neu abgeglichen")
                return .deferred
            }
            guard let tempFileID = try POSIXFileMetadata.read(atPath: value.0.path)?.fileID else {
                try? FileManager.default.removeItem(at: value.0)
                releaseTemporarySpace(remote.size)
                throw LocalFileError.io("Temporäre Download-Datei ist verschwunden")
            }
            downloaded = (value.0, tempFileID, value.1, value.2, validator.0, validator.1, validator.2)
        }

        try fileSystem.move(local.rawPath, to: copyPath)
        let replacementBaseline: BaselineEntry
        do {
            if remote.kind == .directory {
                try fileSystem.createDirectory(path)
                replacementBaseline = BaselineEntry(
                    path: path,
                    kind: .directory,
                    localHash: nil,
                    localSize: 0,
                    localModified: 0,
                    remoteValidator: remote.validator,
                    remoteValidatorIsStrong: remote.validatorIsStrong,
                    remoteSize: 0,
                    remoteModified: remote.modified
                )
            } else {
                guard let downloaded else {
                    throw LocalFileError.io("Heruntergeladene Serverdatei fehlt")
                }
                try fileSystem.installDownloadedFile(from: downloaded.temp, to: path, expectedHash: nil, expectedSize: nil, expectedModified: nil,
                                                     modifiedDate: downloaded.modified.map { Date(timeIntervalSince1970: $0) })
                let installed = try fileSystem.attributes(path)
                replacementBaseline = BaselineEntry(
                    path: path,
                    kind: .file,
                    localHash: downloaded.hash,
                    localSize: installed?.size ?? downloaded.result.contentLength,
                    localModified: installed?.modified ?? 0,
                    remoteValidator: downloaded.validator,
                    remoteValidatorIsStrong: downloaded.strong,
                    remoteSize: downloaded.result.contentLength,
                    remoteModified: downloaded.modified
                )
            }
        } catch {
            if let temp = downloaded?.temp { try? FileManager.default.removeItem(at: temp) }
            // Ist die Serverversion bereits am Ziel installiert, bleibt sie
            // zusammen mit der lokalen Konfliktkopie erhalten. Ein pauschales
            // Entfernen könnte Benutzeränderungen löschen, die zwischenzeitlich
            // im neuen Ziel entstanden sind. Nur wenn noch kein Ersatz existiert,
            // kann die ursprüngliche Version gefahrlos zurückgeschoben werden.
            if (try? fileSystem.attributes(path)) == nil {
                try? fileSystem.move(copyPath, to: local.rawPath)
            }
            throw error
        }
        let conflict = ConflictRecord(path: path, kind: local.kind, reason: .kindMismatch, localHash: local.hash, localSize: local.size,
                                      localModified: local.modified, remoteValidator: remote.validator, remoteSize: remote.size,
                                      remoteModified: remote.modified, conflictCopyPath: copyPath)
        do {
            try await store.saveConflict(
                conflict,
                baseline: replacementBaseline,
                replacingBaselineSubtree: true,
                mappingID: mapping.id
            )
        } catch {
            do {
                if replacementBaseline.kind == .file, let hash = replacementBaseline.localHash {
                    _ = try fileSystem.trashVerifiedFile(
                        path,
                        expectedHash: hash,
                        recoveryDirectory: config.recoveryDirectory
                    )
                } else {
                    guard try fileSystem.removeDirectoryIfEmpty(path, rules: rules) else {
                        throw LocalFileError.changedSinceScan(path)
                    }
                }
                try fileSystem.move(copyPath, to: local.rawPath)
            } catch let rollbackError {
                logger.error(
                    "engine",
                    "Datei/Ordner-Konflikt für \(path) konnte nicht persistiert oder vollständig zurückgerollt werden; beide Fassungen bleiben erhalten: \(rollbackError)"
                )
            }
            throw error
        }
        await finishTransfer(record, state: .succeeded, note: "Datei/Ordner-Konflikt: lokale Version als „\(RelativePath.name(of: copyPath))“ gesichert")
        eventHandler?(.conflictDetected(path: path))
        return .conflict
    }

    // MARK: Ordner, Löschungen, Umbenennungen

    private func performCreateRemoteDirectory(path: String, snapshot: RemoteSnapshot) async throws -> ActionResult {
        let record = await beginTransfer(.createRemoteDirectory(path: path))
        let rawPath = Self.rawRemotePath(for: path, snapshot: snapshot)
        var validator: String?
        var strong = false
        var modified: Double?
        do {
            try await client.makeDirectory(rawPath)
        } catch let error as WebDAVError {
            if case .conflict(let status, _) = error, status == 405 {
                // existiert bereits
            } else {
                throw error
            }
        }
        guard let stat = try await client.stat(rawPath) else {
            throw WebDAVError.invalidResponse("Der neu angelegte Ordner „\(path)“ ist nicht auffindbar")
        }
        if stat.kind != .directory {
            await finishTransfer(record, state: .skipped, note: "Auf dem Server liegt an dieser Stelle eine Datei – wird neu abgeglichen")
            return .deferred
        }
        validator = stat.validator
        strong = stat.validatorIsStrong
        modified = stat.modified
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
        if remote.kind == .directory {
            await finishTransfer(
                record,
                state: .skipped,
                note: "Rekursive Server-Löschungen besitzen keine atomare Vorbedingung für neue Kinder; der leere Ordner bleibt sicherheitshalber bestehen"
            )
            return .blocked
        }
        guard remote.validatorIsStrong, capabilities?.supportsConditionalWrites == true else {
            await finishTransfer(record, state: .skipped, note: "Der Server kann diese Löschung nicht atomar gegen parallele Änderungen schützen; sie wurde nicht ausgeführt")
            return .blocked
        }
        let ifMatch = remote.validator
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

    private func performDeleteLocal(path: String, local: LocalItem, snapshot: RemoteSnapshot) async throws -> ActionResult {
        let record = await beginTransfer(.deleteLocal(path: path, local: local))
        let localPath = local.rawPath
        // Ein einzelnes still ausgelassenes PROPFIND-Kind darf niemals als
        // bestätigte Serverlöschung gelten. Auch ein nach dem Listing neu
        // angelegter Eintrag wird so vor der lokalen Mutation erkannt.
        let rawPath = Self.rawRemotePath(for: path, snapshot: snapshot)
        if try await client.stat(rawPath) != nil {
            await finishTransfer(record, state: .skipped, note: "Servereintrag ist wieder vorhanden – wird neu abgeglichen")
            return .deferred
        }
        // Sicherheitsprüfung: Der Eintrag muss lokal noch dem bekannten Stand entsprechen.
        guard let attrs = try fileSystem.attributes(localPath) else {
            try await store.removeBaselineSubtree(path: path, mappingID: mapping.id)
            await finishTransfer(record, state: .succeeded, note: "War lokal bereits entfernt")
            return .succeeded
        }
        if attrs.kind == .file {
            guard let expectedHash = local.hash else {
                await finishTransfer(record, state: .skipped, note: "Lokale Datei wurde zwischenzeitlich geändert – wird neu abgeglichen")
                return .deferred
            }
            let destination: URL?
            do {
                destination = try fileSystem.trashVerifiedFile(
                    localPath,
                    expectedHash: expectedHash,
                    recoveryDirectory: config.recoveryDirectory
                )
            } catch LocalFileError.changedSinceScan {
                await finishTransfer(record, state: .skipped, note: "Lokale Datei wurde zwischenzeitlich geändert – wird neu abgeglichen")
                return .deferred
            }
            try await store.removeBaselineSubtree(path: path, mappingID: mapping.id)
            let note = destination.map {
                $0.path.contains("/.Trash") ? "In den Papierkorb verschoben" : "In den Wiederherstellungsbereich verschoben"
            }
            await finishTransfer(record, state: .succeeded, note: note)
            return .succeeded
        } else {
            guard try fileSystem.removeDirectoryIfEmpty(localPath, rules: rules) else {
                await finishTransfer(record, state: .skipped, note: "Ordner ist nicht leer – Inhalte werden neu abgeglichen")
                return .deferred
            }
            try await store.removeBaselineSubtree(path: path, mappingID: mapping.id)
            await finishTransfer(record, state: .succeeded, note: "Leeren Ordner entfernt")
            return .succeeded
        }
    }

    private func performMoveRemote(from: String, to: String, remote: RemoteItem, local: LocalItem, snapshot: RemoteSnapshot) async throws -> ActionResult {
        let record = await beginTransfer(.moveRemote(from: from, to: to, remote: remote, local: local))
        if try fileSystem.attributes(from) != nil {
            await finishTransfer(record, state: .skipped, note: "Quelle ist lokal wieder vorhanden – wird neu abgeglichen")
            return .deferred
        }
        guard remote.validatorIsStrong, capabilities?.supportsConditionalWrites == true else {
            await finishTransfer(record, state: .skipped, note: "Der Server kann die Umbenennung nicht atomar gegen parallele Änderungen schützen; sie wurde nicht ausgeführt")
            return .blocked
        }
        let rawDestination = Self.rawRemotePath(for: to, snapshot: snapshot)
        if try await client.stat(rawDestination) != nil {
            await finishTransfer(record, state: .skipped, note: "Am Serverziel ist inzwischen ein Eintrag entstanden – wird neu abgeglichen")
            return .deferred
        }
        do {
            try await client.move(from: remote.rawPath, to: rawDestination, overwrite: false, ifMatch: remote.validatorIsStrong ? remote.validator : nil)
        } catch let error as WebDAVError where error == .preconditionFailed {
            await finishTransfer(record, state: .skipped, note: "Serverquelle oder -ziel hat sich geändert – wird neu abgeglichen")
            return .deferred
        } catch let error as WebDAVError {
            let supportsFallback: Bool
            switch error {
            case .conflict(let status, _):
                supportsFallback = status == 405 || status == 501
            case .unexpectedStatus(let status, _):
                supportsFallback = status == 405 || status == 501
            default:
                supportsFallback = false
            }
            guard supportsFallback else { throw error }
            logger.notice("engine", "MOVE \(from) → \(to) fehlgeschlagen (\(error)); Rückfall auf Upload + Löschung")
            let up = try await performUpload(path: to, local: local, remote: nil, conflictReason: nil, snapshot: snapshot)
            guard case .succeeded = up else {
                await finishTransfer(record, state: .skipped, note: "Ersatzupload der Umbenennung bleibt ausstehend")
                return up
            }
            let deletion = try await performDeleteRemote(path: from, remote: remote)
            if case .succeeded = deletion {
                await finishTransfer(record, state: .succeeded, note: "Als Upload und geschützte Quelllöschung übertragen")
            } else {
                await finishTransfer(record, state: .skipped, note: "Ziel wurde hochgeladen; die geschützte Quelllöschung bleibt ausstehend")
            }
            return deletion
        }
        guard let verified = try await verifyRemoteContent(rawPath: rawDestination, expectedHash: local.hash, expectedSize: local.size) else {
            await finishTransfer(record, state: .skipped, note: "Ziel der Server-Umbenennung konnte nicht eindeutig bestätigt werden – wird neu abgeglichen")
            return .deferred
        }
        try await store.removeBaselineSubtree(path: from, mappingID: mapping.id)
        try await store.upsertBaseline(BaselineEntry(path: to, kind: .file, localHash: local.hash, localSize: local.size, localModified: local.modified,
                                                     remoteValidator: verified.validator, remoteValidatorIsStrong: verified.strong,
                                                     remoteSize: verified.size, remoteModified: verified.modified), mappingID: mapping.id)
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
        do {
            status.openConflicts = try await store.openConflictCount(mappingID: mapping.id)
            status.pendingDeletions = try await store.pendingDeletionsAwaitingConfirmation(mappingID: mapping.id).count
            if !status.isRunning {
                status.pendingCount = try await store.queue(mappingID: mapping.id).count
            }
        } catch {
            reportPersistenceIssue(error)
            return
        }
        recomputeHealth()
    }

    private func recomputeHealth() {
        if status.isRunning {
            status.health = .syncing
        } else if status.isPaused {
            status.health = .paused
        } else if downloadsPausedForDiskSpace {
            status.health = .attention
        } else if status.nextRetry != nil {
            status.health = retryRepresentsOffline ? .offline : .attention
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

import Foundation

/// Eine geplante Aktion des Abgleichs.
public enum SyncAction: Sendable, Hashable {
    /// Neue lokale Datei hochladen (`If-None-Match: *`).
    case uploadNew(path: String, local: LocalItem)
    /// Geänderte lokale Datei hochladen (`If-Match` auf den bekannten Validator).
    case uploadChanged(path: String, local: LocalItem, remote: RemoteItem)
    /// Serverdatei herunterladen. `replacing` ist die lokale Datei, die ersetzt wird (muss unverändert sein).
    case download(path: String, remote: RemoteItem, replacing: LocalItem?)
    case createRemoteDirectory(path: String)
    case createLocalDirectory(path: String, remote: RemoteItem)
    /// Serverseitig löschen (nach Sicherheitsprüfungen).
    case deleteRemote(path: String, remote: RemoteItem)
    /// Lokal in den Papierkorb verschieben (nach Sicherheitsprüfungen).
    case deleteLocal(path: String, local: LocalItem)
    /// Serverseitig verschieben (lokale Umbenennung erkannt).
    case moveRemote(from: String, to: String, remote: RemoteItem, local: LocalItem)
    /// Beide Seiten geändert: Inhalt vergleichen; bei Gleichheit zusammenführen, sonst beide Versionen erhalten.
    case verifyConflict(path: String, local: LocalItem, remote: RemoteItem, reason: ConflictReason)
    /// Lokal geändert, auf dem Server gelöscht: lokale Version erhalten (als neu hochladen) und Konflikt melden.
    case keepLocalAfterRemoteDelete(path: String, local: LocalItem)
    /// Lokal gelöscht, auf dem Server geändert: Serverversion erhalten (herunterladen) und Konflikt melden.
    case keepRemoteAfterLocalDelete(path: String, remote: RemoteItem)
    /// Datei gegen Ordner: lokale Version als Konfliktkopie sichern, Serverversion übernehmen.
    case kindMismatch(path: String, local: LocalItem, remote: RemoteItem)
    /// Nur den gemeinsamen Stand aktualisieren (z. B. zwei gleiche Ordner).
    case updateBaseline(path: String, local: LocalItem, remote: RemoteItem)
    /// Eintrag aus dem gemeinsamen Stand entfernen (beidseitig gelöscht).
    case removeBaseline(path: String)
    /// Keine Aktion möglich; Begründung für die Oberfläche.
    case skip(path: String, reason: String)

    public var path: String {
        switch self {
        case .uploadNew(let p, _), .uploadChanged(let p, _, _), .download(let p, _, _), .createRemoteDirectory(let p),
             .createLocalDirectory(let p, _), .deleteRemote(let p, _), .deleteLocal(let p, _), .verifyConflict(let p, _, _, _),
             .keepLocalAfterRemoteDelete(let p, _), .keepRemoteAfterLocalDelete(let p, _), .kindMismatch(let p, _, _),
             .updateBaseline(let p, _, _), .removeBaseline(let p), .skip(let p, _):
            return p
        case .moveRemote(_, let to, _, _):
            return to
        }
    }

    public var isDeletion: Bool {
        switch self {
        case .deleteRemote, .deleteLocal: return true
        default: return false
        }
    }

    public var direction: TransferDirection? {
        switch self {
        case .uploadNew, .uploadChanged, .keepLocalAfterRemoteDelete: return .upload
        case .download, .verifyConflict, .keepRemoteAfterLocalDelete, .kindMismatch: return .download
        case .createRemoteDirectory: return .mkdirRemote
        case .createLocalDirectory: return .mkdirLocal
        case .deleteRemote: return .remoteDelete
        case .deleteLocal: return .localDelete
        case .moveRemote: return .remoteMove
        case .updateBaseline, .removeBaseline, .skip: return nil
        }
    }

    /// Erwartete Transfergröße (für Fortschrittsanzeige).
    public var estimatedBytes: Int64 {
        switch self {
        case .uploadNew(_, let l), .uploadChanged(_, let l, _), .keepLocalAfterRemoteDelete(_, let l): return l.size
        case .download(_, let r, _), .verifyConflict(_, _, let r, _), .keepRemoteAfterLocalDelete(_, let r), .kindMismatch(_, _, let r): return r.size
        default: return 0
        }
    }
}

/// Ergebnis der Planung, in Ausführungsphasen gegliedert.
public struct SyncPlan: Sendable {
    /// Ordner anlegen (Eltern zuerst).
    public var directoryCreations: [SyncAction] = []
    /// Umbenennungen (vor Uploads/Löschungen).
    public var moves: [SyncAction] = []
    /// Up-/Downloads und Konfliktprüfungen.
    public var transfers: [SyncAction] = []
    /// Löschungen (tiefste zuerst).
    public var deletions: [SyncAction] = []
    /// Reine Baseline-Aktualisierungen.
    public var bookkeeping: [SyncAction] = []
    /// Übersprungene Pfade mit Begründung.
    public var skipped: [SyncAction] = []
    /// `true`, wenn Löschungen wegen unvollständiger Bestandsaufnahme unterdrückt wurden.
    public var deletionsSuppressed = false
    public var deletionsSuppressedReason: String?
    /// Pfade, die wegen Namenskollisionen (Groß-/Kleinschreibung, Normalisierung) nicht synchronisiert werden können.
    public var collisions: [String] = []

    public init() {}

    public var allActions: [SyncAction] { directoryCreations + moves + transfers + deletions + bookkeeping }
    public var isEmpty: Bool { directoryCreations.isEmpty && moves.isEmpty && transfers.isEmpty && deletions.isEmpty && bookkeeping.isEmpty }
    public var transferCount: Int { directoryCreations.count + moves.count + transfers.count + deletions.count }
    public var estimatedBytes: Int64 { transfers.reduce(0) { $0 + $1.estimatedBytes } }

    /// Anzahl Dateien, die eine Löschung betrifft (Ordner zählen mit ihren bekannten Inhalten).
    public func deletionImpact(baseline: [String: BaselineEntry]) -> Int {
        var count = 0
        for action in deletions {
            switch action {
            case .deleteRemote(let p, let r):
                count += r.kind == .file ? 1 : max(1, baseline.keys.filter { RelativePath.isDescendant($0, of: p) }.count)
            case .deleteLocal(let p, let l):
                count += l.kind == .file ? 1 : max(1, baseline.keys.filter { RelativePath.isDescendant($0, of: p) }.count)
            default: break
            }
        }
        return count
    }
}

/// Eingaben für die Planung.
public struct PlannerInput: Sendable {
    public var baseline: [String: BaselineEntry]
    public var local: LocalSnapshot
    public var remote: RemoteSnapshot
    /// Pfade mit offenen Konflikten (werden nicht angefasst).
    public var openConflictPaths: Set<String>
    /// Lokales Dateisystem unterscheidet keine Groß-/Kleinschreibung (APFS-Standard).
    public var caseInsensitiveLocalFileSystem: Bool
    /// Vom Benutzer bestätigte Löschungen (siehe Löschschutz). `nil` = keine Einschränkung.
    public var allowedDeletions: Set<String>?

    public init(baseline: [String: BaselineEntry], local: LocalSnapshot, remote: RemoteSnapshot, openConflictPaths: Set<String> = [],
                caseInsensitiveLocalFileSystem: Bool = true, allowedDeletions: Set<String>? = nil) {
        self.baseline = baseline
        self.local = local
        self.remote = remote
        self.openConflictPaths = openConflictPaths
        self.caseInsensitiveLocalFileSystem = caseInsensitiveLocalFileSystem
        self.allowedDeletions = allowedDeletions
    }
}

/// Reine Drei-Wege-Planung ohne Seiteneffekte.
public enum SyncPlanner {
    enum SideState: Equatable {
        case absent      // weder jetzt noch im gemeinsamen Stand vorhanden
        case new         // jetzt vorhanden, nicht im gemeinsamen Stand
        case unchanged
        case changed
        case deleted     // im gemeinsamen Stand, jetzt fehlend
        case unknown     // Bestandsaufnahme unvollständig – keine Aussage möglich
    }

    public static func plan(_ input: PlannerInput) -> SyncPlan {
        var plan = SyncPlan()
        let baseline = input.baseline
        let local = input.local
        let remote = input.remote

        // 1. Eingefrorene Pfade: beschäftigte oder übersprungene lokale Dateien, offene Konflikte,
        //    serverseitige Namenskollisionen.
        var frozen: Set<String> = local.busyPaths
        frozen.formUnion(local.skippedPaths.keys)
        frozen.formUnion(input.openConflictPaths)
        for p in local.busyPaths { plan.skipped.append(.skip(path: p, reason: "Datei wird gerade geschrieben; wird beim nächsten Abgleich übertragen")) }
        for (p, reason) in local.skippedPaths { plan.skipped.append(.skip(path: p, reason: reason)) }
        for p in input.openConflictPaths { plan.skipped.append(.skip(path: p, reason: "Konflikt wartet auf Entscheidung")) }

        if input.caseInsensitiveLocalFileSystem {
            var groups: [String: [String]] = [:]
            for key in remote.items.keys { groups[RelativePath.caseInsensitiveKey(key), default: []].append(key) }
            for (_, paths) in groups where paths.count > 1 {
                for p in paths {
                    frozen.insert(p)
                    plan.collisions.append(p)
                    let others = paths.filter { $0 != p }.joined(separator: ", ")
                    plan.skipped.append(.skip(path: p, reason: "Name kollidiert auf dem Mac mit „\(others)“ (Groß-/Kleinschreibung). Bitte eine Datei umbenennen."))
                }
            }
        }

        func isFrozen(_ path: String) -> Bool {
            if frozen.contains(path) { return true }
            for a in RelativePath.ancestors(of: path) where frozen.contains(a) { return true }
            return false
        }

        // 2. Zustände je Pfad ermitteln.
        var allPaths = Set(baseline.keys)
        allPaths.formUnion(local.items.keys)
        allPaths.formUnion(remote.items.keys)

        let localDeletionsAllowed = local.isComplete
        if !local.isComplete {
            plan.deletionsSuppressed = true
            plan.deletionsSuppressedReason = "Die lokale Bestandsaufnahme war unvollständig; Löschungen werden nicht übertragen."
        }
        if !remote.isComplete {
            plan.deletionsSuppressed = true
            plan.deletionsSuppressedReason = "Die Server-Bestandsaufnahme war unvollständig; Löschungen werden nicht übertragen."
        }

        func localState(_ p: String) -> SideState {
            let b = baseline[p]
            if let l = local.items[p] {
                guard let b else { return .new }
                if l.kind != b.kind { return .changed }
                if l.kind == .directory { return .unchanged }
                return l.hash == b.localHash ? .unchanged : .changed
            }
            guard b != nil else { return .absent }
            return localDeletionsAllowed ? .deleted : .unknown
        }

        func remoteState(_ p: String) -> SideState {
            let b = baseline[p]
            if let r = remote.items[p] {
                guard let b else { return .new }
                if r.kind != b.kind { return .changed }
                if r.kind == .directory { return .unchanged }
                if let v = r.validator { return v == b.remoteValidator ? .unchanged : .changed }
                // Kein Validator: nur Größe als Hinweis verfügbar.
                return r.size == b.remoteSize ? .unchanged : .changed
            }
            guard b != nil else { return .absent }
            if remote.isUnderFailedPrefix(p) { return .unknown }
            return .deleted
        }

        var decisions: [String: SyncAction] = [:]
        let sortedPaths = allPaths.sorted { a, b in
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            return da != db ? da < db : a < b
        }

        for p in sortedPaths where !p.isEmpty {
            if isFrozen(p) { continue }
            let ls = localState(p), rs = remoteState(p)
            let l = local.items[p], r = remote.items[p]
            switch (ls, rs) {
            case (.unknown, _), (_, .unknown):
                continue
            case (.absent, .absent):
                if baseline[p] != nil { decisions[p] = .removeBaseline(path: p) }
            case (.deleted, .deleted):
                decisions[p] = .removeBaseline(path: p)
            case (.new, .absent), (.new, .deleted):
                guard let l else { continue }
                if l.kind == .directory {
                    decisions[p] = .createRemoteDirectory(path: p)
                } else {
                    decisions[p] = .uploadNew(path: p, local: l)
                }
            case (.absent, .new), (.deleted, .new):
                guard let r else { continue }
                if r.kind == .directory {
                    decisions[p] = .createLocalDirectory(path: p, remote: r)
                } else {
                    decisions[p] = .download(path: p, remote: r, replacing: nil)
                }
            case (.new, .new):
                guard let l, let r else { continue }
                if l.kind != r.kind {
                    decisions[p] = .kindMismatch(path: p, local: l, remote: r)
                } else if l.kind == .directory {
                    decisions[p] = .updateBaseline(path: p, local: l, remote: r)
                } else {
                    decisions[p] = .verifyConflict(path: p, local: l, remote: r, reason: .initialMergeDiffers)
                }
            case (.unchanged, .unchanged):
                continue
            case (.changed, .unchanged):
                guard let l, let r else { continue }
                if l.kind != r.kind {
                    decisions[p] = .kindMismatch(path: p, local: l, remote: r)
                } else {
                    decisions[p] = .uploadChanged(path: p, local: l, remote: r)
                }
            case (.unchanged, .changed):
                guard let l, let r else { continue }
                if l.kind != r.kind {
                    decisions[p] = .kindMismatch(path: p, local: l, remote: r)
                } else {
                    decisions[p] = .download(path: p, remote: r, replacing: l)
                }
            case (.changed, .changed):
                guard let l, let r else { continue }
                if l.kind != r.kind {
                    decisions[p] = .kindMismatch(path: p, local: l, remote: r)
                } else if l.kind == .directory {
                    decisions[p] = .updateBaseline(path: p, local: l, remote: r)
                } else {
                    decisions[p] = .verifyConflict(path: p, local: l, remote: r, reason: .bothModified)
                }
            case (.deleted, .unchanged):
                guard let r else { continue }
                decisions[p] = .deleteRemote(path: p, remote: r)
            case (.unchanged, .deleted):
                guard let l else { continue }
                decisions[p] = .deleteLocal(path: p, local: l)
            case (.deleted, .changed):
                guard let r else { continue }
                if r.kind == .directory {
                    decisions[p] = .createLocalDirectory(path: p, remote: r)
                } else {
                    decisions[p] = .keepRemoteAfterLocalDelete(path: p, remote: r)
                }
            case (.changed, .deleted):
                guard let l else { continue }
                if l.kind == .directory {
                    decisions[p] = .createRemoteDirectory(path: p)
                } else {
                    decisions[p] = .keepLocalAfterRemoteDelete(path: p, local: l)
                }
            case (.new, .unchanged), (.new, .changed), (.unchanged, .new), (.changed, .new), (.absent, .unchanged), (.absent, .changed),
                 (.absent, .deleted), (.unchanged, .absent), (.changed, .absent), (.deleted, .absent):
                // Inkonsistente Kombinationen (Baseline vorhanden ↔ nicht vorhanden); konservativ überspringen.
                continue
            }
        }

        // 3. Ordnerlöschungen: nur, wenn innerhalb des Ordners keine neuen oder geänderten Einträge existieren.
        for p in sortedPaths {
            guard let action = decisions[p] else { continue }
            switch action {
            case .deleteRemote(let dir, let r) where r.kind == .directory:
                let descendants = remote.items.keys.filter { RelativePath.isDescendant($0, of: dir) }
                let survivors = descendants.filter { d in
                    if isFrozen(d) { return true }
                    if let a = decisions[d] {
                        if case .deleteRemote = a { return false }
                        if case .removeBaseline = a { return false }
                        return true
                    }
                    // Ohne Entscheidung: unverändert und nicht gelöscht? Dann wäre lokal vorhanden – sollte bei gelöschtem Ordner nicht vorkommen.
                    return local.items[d] != nil
                }
                if survivors.isEmpty {
                    for d in descendants { decisions[d] = nil }
                } else {
                    // Ordner bleibt; er wird lokal wieder benötigt.
                    decisions[dir] = .createLocalDirectory(path: dir, remote: r)
                }
            case .deleteLocal(let dir, let l) where l.kind == .directory:
                let descendants = local.items.keys.filter { RelativePath.isDescendant($0, of: dir) }
                let survivors = descendants.filter { d in
                    if isFrozen(d) { return true }
                    if let a = decisions[d] {
                        if case .deleteLocal = a { return false }
                        if case .removeBaseline = a { return false }
                        return true
                    }
                    return remote.items[d] != nil
                }
                if survivors.isEmpty {
                    for d in descendants { decisions[d] = nil }
                } else {
                    decisions[dir] = .createRemoteDirectory(path: dir)
                }
            default:
                break
            }
        }

        // 4. Umbenennungen erkennen: gelöschte lokale Datei + neue lokale Datei mit identischem Inhalt,
        //    Server am alten Ort unverändert → MOVE statt Upload + Delete.
        var deletedByHash: [String: [String]] = [:]
        var newByHash: [String: [String]] = [:]
        for (p, a) in decisions {
            if case .deleteRemote(_, let r) = a, r.kind == .file, let h = baseline[p]?.localHash { deletedByHash[h, default: []].append(p) }
            if case .uploadNew(_, let l) = a, let h = l.hash { newByHash[h, default: []].append(p) }
        }
        for (hash, olds) in deletedByHash {
            guard olds.count == 1, let news = newByHash[hash], news.count == 1 else { continue }
            let from = olds[0], to = news[0]
            guard case .deleteRemote(_, let r)? = decisions[from], case .uploadNew(_, let l)? = decisions[to] else { continue }
            guard remote.items[to] == nil else { continue }
            decisions[from] = nil
            decisions[to] = .moveRemote(from: from, to: to, remote: r, local: l)
        }

        // 5. Löschschutz: nur freigegebene Löschungen ausführen.
        if let allowed = input.allowedDeletions {
            for (p, a) in decisions where a.isDeletion && !allowed.contains(p) {
                decisions[p] = nil
                plan.skipped.append(.skip(path: p, reason: "Löschung wartet auf Bestätigung"))
            }
        }

        // 6. In Phasen einsortieren.
        for p in sortedPaths {
            guard let a = decisions[p] else { continue }
            switch a {
            case .createRemoteDirectory, .createLocalDirectory:
                plan.directoryCreations.append(a)
            case .moveRemote:
                plan.moves.append(a)
            case .uploadNew, .uploadChanged, .download, .verifyConflict, .keepLocalAfterRemoteDelete, .keepRemoteAfterLocalDelete, .kindMismatch:
                plan.transfers.append(a)
            case .deleteRemote, .deleteLocal:
                plan.deletions.append(a)
            case .updateBaseline, .removeBaseline:
                plan.bookkeeping.append(a)
            case .skip:
                plan.skipped.append(a)
            }
        }
        // Löschungen tiefste zuerst.
        plan.deletions.sort { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }
        // Eltern-Ordner für Uploads sicherstellen (falls der Zielordner auf dem Server fehlt).
        var remoteDirs = Set(remote.items.filter { $0.value.kind == .directory }.keys)
        for a in plan.directoryCreations { if case .createRemoteDirectory(let p) = a { remoteDirs.insert(p) } }
        var extraCreations: [SyncAction] = []
        for a in plan.transfers + plan.moves {
            let targetPath: String
            switch a {
            case .uploadNew(let p, _), .uploadChanged(let p, _, _), .keepLocalAfterRemoteDelete(let p, _): targetPath = p
            case .moveRemote(_, let to, _, _): targetPath = to
            default: continue
            }
            for ancestor in RelativePath.ancestors(of: targetPath) where !remoteDirs.contains(ancestor) && !isFrozen(ancestor) {
                remoteDirs.insert(ancestor)
                extraCreations.append(.createRemoteDirectory(path: ancestor))
            }
        }
        plan.directoryCreations.append(contentsOf: extraCreations)
        plan.directoryCreations.sort { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }
        return plan
    }
}

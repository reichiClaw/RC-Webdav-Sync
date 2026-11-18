import AppKit
import Foundation
import Network
import ServiceManagement
@preconcurrency import UserNotifications
import ReichiSyncCore

/// Pfade für Datenbank, Protokolle und Wiederherstellungsbereich – außerhalb des
/// synchronisierten Ordners, innerhalb des App-Containers.
enum AppPaths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("reichi Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var database: URL { applicationSupport.appendingPathComponent("sync.sqlite") }
    static var logFile: URL { applicationSupport.appendingPathComponent("Logs/reichi-sync.log") }
    static var recovery: URL { applicationSupport.appendingPathComponent("Wiederherstellung", isDirectory: true) }
}

/// Überwacht die Netzwerkverfügbarkeit. Die tatsächliche Erreichbarkeit des
/// Servers prüft die Engine zusätzlich mit einer echten Anfrage.
final class ConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "de.reichi.sync.network")
    private var wasSatisfied: Bool?
    private let onRestored: @Sendable () -> Void

    init(onRestored: @escaping @Sendable () -> Void) {
        self.onRestored = onRestored
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied, self.wasSatisfied == false {
                self.onRestored()
            }
            self.wasSatisfied = satisfied
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}

/// Reagiert auf das Aufwachen des Macs.
final class SleepWakeObserver {
    private var token: NSObjectProtocol?

    init(onWake: @escaping @MainActor @Sendable () -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in onWake() }
        }
    }

    deinit {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}

/// Start bei der Anmeldung über `SMAppService` (macOS 13+).
enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Systembenachrichtigungen für wichtige Ereignisse.
@MainActor
final class NotificationService {
    private var authorized = false

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .authorized, .provisional:
            authorized = true
        default:
            authorized = false
        }
    }

    func post(title: String, body: String, identifier: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Darstellung von Werten für die Oberfläche.
@MainActor
enum Formatters {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func relative(_ date: Date?) -> String {
        guard let date else { return "Noch nie" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "–" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func dateTime(_ seconds: Double?) -> String {
        guard let seconds else { return "–" }
        return dateTime(Date(timeIntervalSince1970: seconds))
    }
}

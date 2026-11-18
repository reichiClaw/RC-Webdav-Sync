import AppKit
import SwiftUI
import ReichiSyncCore

@main
struct ReichiSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("reichi Sync", id: "main") {
            MainWindow()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 500)
                .onAppear {
                    appDelegate.model = model
                    model.openMainWindowHandler = { openWindow(id: "main") }
                    model.beginBootstrap()
                }
        }
        .defaultSize(width: 920, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Synchronisierung") {
                Button("Jetzt synchronisieren") { model.syncNow() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.needsSetup)
                Button(model.status.isPaused ? "Synchronisierung fortsetzen" : "Synchronisierung pausieren") { model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.needsSetup)
                Divider()
                Button("Lokalen Ordner im Finder öffnen") { model.openLocalFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.needsSetup)
                Divider()
                Button("Link teilen …") {
                    if let path = model.chooseItemToShare() { model.requestShare(forRelativePath: path) }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!model.isCloudreveAccount || !model.cloudreveSignedIn)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.status.menuBarSymbol)
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel(model.status.accessibilityDescription)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 560)
        }
    }
}

/// Hält die App nach dem Schließen des Hauptfensters in der Menüleiste am Leben
/// und sichert beim Beenden den Zustand der Engine.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationCleanupTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    private var terminationReplySent = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            model?.showMainWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard terminationCleanupTask == nil else { return .terminateLater }
        terminationCleanupTask = Task { @MainActor [weak self, weak sender] in
            await model.prepareForTermination()
            guard let self, let sender else { return }
            finishTermination(sender)
        }
        terminationTimeoutTask = Task { @MainActor [weak self, weak sender] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, let sender else { return }
            terminationCleanupTask?.cancel()
            SyncLogger.shared.warning("app", "Beenden nach Zeitlimit fortgesetzt; ausstehende Arbeit wird beim nächsten Start erneut geprüft")
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard !terminationReplySent else { return }
        terminationReplySent = true
        terminationTimeoutTask?.cancel()
        sender.reply(toApplicationShouldTerminate: true)
    }
}

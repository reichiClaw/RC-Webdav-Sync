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
                .task {
                    appDelegate.model = model
                    model.openMainWindowHandler = { openWindow(id: "main") }
                    await model.bootstrap()
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

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
        Task { @MainActor in
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

import SwiftUI
import ReichiSyncCore

/// Kompaktes Menü unter dem Menüleistensymbol.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeader(status: model.status, compact: true)
                .padding(.bottom, 2)

            if !model.needsSetup {
                VStack(alignment: .leading, spacing: 3) {
                    menuInfo("Letzter Abgleich", Formatters.relative(model.status.lastSuccessfulSync))
                    menuInfo("Ausstehend", pendingText)
                    if model.status.openConflicts > 0 {
                        menuInfo("Konflikte", "\(model.status.openConflicts)")
                    }
                    if model.status.pendingDeletions > 0 {
                        menuInfo("Löschungen zu bestätigen", "\(model.status.pendingDeletions)")
                    }
                }
                .font(.callout)

                Divider()

                menuButton("Jetzt synchronisieren", symbol: "arrow.triangle.2.circlepath") { model.syncNow() }
                    .disabled(model.status.isRunning || model.status.isPaused)
                menuButton(model.status.isPaused ? "Synchronisierung fortsetzen" : "Synchronisierung pausieren",
                           symbol: model.status.isPaused ? "play" : "pause") { model.togglePause() }
                    .disabled(model.status.pauseReason == .localRootMissing)
                menuButton("Ordner im Finder öffnen", symbol: "folder") { model.openLocalFolder() }

                Divider()

                menuButton("Aktivität anzeigen", symbol: "arrow.up.arrow.down") { open(.activity) }
                menuButton(model.status.openConflicts > 0 ? "Konflikte anzeigen (\(model.status.openConflicts))" : "Konflikte anzeigen",
                           symbol: "exclamationmark.triangle") { open(.conflicts) }
                if model.status.pendingDeletions > 0 {
                    menuButton("Löschungen prüfen", symbol: "trash") { open(.overview) }
                }
                if model.isCloudreveAccount {
                    menuButton("Link teilen …", symbol: "link.badge.plus") {
                        open(.shares)
                        if let path = model.chooseItemToShare() { model.requestShare(forRelativePath: path) }
                    }
                    menuButton("Freigaben anzeigen", symbol: "link") { open(.shares) }
                }
            } else {
                Divider()
                menuButton("Einrichtung starten", symbol: "wand.and.stars") { open(.overview) }
            }

            menuButton("Einstellungen …", symbol: "gearshape") { open(.settings) }

            Divider()

            menuButton("reichi Sync beenden", symbol: "power") { model.quit() }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var pendingText: String {
        if model.status.pendingCount == 0 { return "nichts" }
        var text = "\(model.status.pendingCount) Einträge"
        if model.status.pendingBytes > 0 { text += " · \(Formatters.bytes.string(fromByteCount: model.status.pendingBytes))" }
        return text
    }

    private func menuInfo(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func menuButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    private func open(_ section: AppModel.Section) {
        model.selectedSection = section
        openWindow(id: "main")
        model.showMainWindow()
    }
}

/// Schaltflächen mit Hervorhebung wie in Menüs.
struct MenuRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.3 : 0.18) : Color.clear)
            )
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .onHover { hovering = $0 }
    }
}

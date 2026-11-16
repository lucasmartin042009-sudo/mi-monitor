// Point d'entrée : app de barre des menus (pas d'icône dans le Dock, cf. LSUIElement)
// avec un panneau type Centre de contrôle et une fenêtre Réglages.

import SwiftUI

@main
struct XiaomiDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }
}

/// Icône de la barre des menus : écran ; triangle d'alerte seulement si l'écran ne répond pas
/// (maquette), lune s'il a été mis en veille. Connexion et débranchement gardent l'écran.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.displays.selected?.connection
        Image(systemName: Self.symbol(for: state))
            .accessibilityLabel(state.map { "Mi Monitor, \($0.label)" } ?? "Mi Monitor, aucun écran")
    }

    static func symbol(for state: ConnectionState?) -> String {
        switch state {
        case .unresponsive: "exclamationmark.triangle"
        case .asleep: "moon"
        default: "display"
        }
    }
}

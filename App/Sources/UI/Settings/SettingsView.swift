// Fenêtre Réglages (planche 3 de la maquette) : style Réglages Système, barre latérale
// à carrés colorés (Général, Profils, Raccourcis, À propos), état de l'écran en bas de la barre,
// contenu en Form groupé natif.

import SwiftUI

/// Onglets de la fenêtre Réglages.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, profiles, shortcuts, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Général"
        case .profiles: "Profils"
        case .shortcuts: "Raccourcis"
        case .about: "À propos"
        }
    }

    /// SF Symbol dessiné en blanc dans le carré coloré.
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .profiles: "square.stack.3d.up.fill"
        case .shortcuts: "bolt.fill"
        case .about: "info.circle.fill"
        }
    }

    /// Couleur du carré (mêmes teintes que la maquette).
    var tint: Color {
        switch self {
        case .general: Color(.systemGray)
        case .profiles: Color(.systemBlue)
        case .shortcuts: Color(.systemPink)
        case .about: Color(.systemIndigo)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Onglet affiché, retenu d'une ouverture à l'autre.
    @AppStorage("settings.selectedPane") private var pane: SettingsPane = .general

    /// Écran imposé (aperçus SwiftUI) ; sinon l'écran sélectionné du modèle.
    private let displayOverride: DisplayController?

    init(display: DisplayController? = nil) {
        self.displayOverride = display
    }

    private var display: DisplayController? { displayOverride ?? model.displays.selected }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsPane?>(get: { pane }, set: { if let p = $0 { pane = p } })) {
                ForEach(SettingsPane.allCases) { item in
                    Label {
                        Text(item.title)
                    } icon: {
                        SettingsIconSquare(symbol: item.symbol, tint: item.tint)
                    }
                    .tag(item)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                SettingsDisplayStatusCard(display: display, hasScanned: model.displays.hasScanned || displayOverride != nil)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: SettingsGeneralPane(display: display)
                case .profiles: SettingsProfilesPane(display: display)
                case .shortcuts: SettingsShortcutsPane(display: display)
                case .about: SettingsAboutPane(display: display)
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(width: 720, height: 560)
    }
}

#if DEBUG
#Preview("Réglages — Général") {
    SettingsView(display: .preview())
        .environment(AppModel.shared)
}

#Preview("Réglages — sans écran") {
    SettingsView()
        .environment(AppModel.shared)
}
#endif

// Panneau de la barre des menus (planches 1 et 2 de la maquette validée) :
// rangée de sélection d'écran (s'il y en a plusieurs), en-tête, profils, curseurs Luminosité / Contraste / Son, rangées Couleur et Source,
// interrupteur « Suivre le MacBook », puis Réglages et Quitter.
// Selon l'état de la liaison DDC, le panneau montre à la place une carte d'erreur,
// une carte compacte (débranché, en veille) ou « aucun écran détecté ».
// Tout le panneau montre l'écran sélectionné (DisplayManager.selected), avec ses propres états.
// La fenêtre MenuBarExtra (.window) est déjà en Liquid Glass sur macOS 26 et suivants :
// aucun fond n'est ajouté, les modules y flottent en verre (panelModule).

import AppKit
import SwiftUI

struct PanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let manager = model.displays
        PanelContent(displays: manager.displays, selected: manager.selected, hasScanned: manager.hasScanned) { display in
            withAnimation(.snappy) { manager.select(display) }
        }
        // Les réglages ont pu changer via les boutons de l'écran : relecture à l'ouverture,
        // et à chaque changement d'écran affiché.
        .onAppear { manager.selected?.refreshIfStale() }
        .onChange(of: manager.selected?.id) { _, _ in manager.selected?.refreshIfStale() }
        // Repère la fenêtre du panneau, pour pouvoir la fermer avant d'ouvrir les Réglages.
        .background(PanelWindowReader())
    }
}

/// Fenêtre du panneau MenuBarExtra, retenue faiblement.
/// Elle ne se ferme d'elle-même que sur un clic à l'extérieur : ouvrir les Réglages depuis le
/// panneau la laissait au premier plan, par-dessus la fenêtre Réglages.
@MainActor
enum PanelWindow {
    static weak var current: NSWindow?

    /// Ferme le panneau (close et non orderOut : l'icône de la barre des menus perd aussi son surlignage).
    static func close() {
        current?.close()
    }
}

/// Vue invisible qui relève la fenêtre qui l'héberge.
private struct PanelWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // La vue n'est rattachée à sa fenêtre qu'après ce passage.
        Task { @MainActor in PanelWindow.current = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { PanelWindow.current = window }
    }
}

/// Contenu du panneau pour l'écran sélectionné (séparé de PanelView pour les aperçus).
struct PanelContent: View {
    /// Tous les écrans connus (rangée de sélection affichée s'il y en a plus d'un).
    var displays: [DisplayController] = []
    /// Écran affiché.
    let selected: DisplayController?
    let hasScanned: Bool
    /// Choix d'un autre écran dans la rangée de sélection.
    var select: (DisplayController) -> Void = { _ in }

    /// Largeur du panneau (maquette : 340 pt).
    static let width: CGFloat = 340

    var body: some View {
        VStack(spacing: 10) {
            if displays.count > 1 {
                DisplayPickerRow(displays: displays, selectedID: selected?.id, select: select)
            }
            if let selected {
                // Identité par écran : l'état local (rangée dépliée, source en attente de
                // confirmation, saisie d'un profil) ne passe pas d'un écran à l'autre.
                DisplaySection(display: selected)
                    .id(selected.id)
            } else {
                NoDisplayCard(hasScanned: hasScanned)
            }
            PanelFooter()
        }
        .padding(12)
        .frame(width: Self.width)
    }
}

/// Partie centrale du panneau selon l'état de connexion de l'écran.
private struct DisplaySection: View {
    let display: DisplayController

    var body: some View {
        switch display.connection {
        case .connected:
            connectedContent
        case .connecting:
            if display.hasReadValues {
                // Relecture après un rebranchement : on garde les commandes affichées.
                connectedContent
            } else {
                PanelHeader(display: display)
                ReadingPlaceholder()
            }
        case .unresponsive(let reason):
            PanelHeader(display: display)
            UnresponsiveCard(display: display, reason: reason)
            SlidersModule(display: display, isFrozen: true)
        case .disconnected:
            CompactStatusCard(display: display, kind: .disconnected)
        case .asleep:
            CompactStatusCard(display: display, kind: .asleep)
        }
    }

    @ViewBuilder
    private var connectedContent: some View {
        PanelHeader(display: display)
        ProfilesModule(display: display)
        SlidersModule(display: display, isFrozen: false)
        SettingsRowsModule(display: display)
    }
}

// MARK: - En-tête

/// Icône, nom de l'écran et pastille d'état.
struct PanelHeader: View {
    let display: DisplayController

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: isUnresponsive ? "exclamationmark.triangle.fill" : "display",
                      background: isUnresponsive ? .orange : .accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(1)
                status
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    private var isUnresponsive: Bool {
        if case .unresponsive = display.connection { return true }
        return false
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 5) {
            switch display.connection {
            case .connecting:
                MiniSpinner()
                Text("Connexion…")
            case .connected:
                StatusDot(color: .green)
                Text("Connecté · \(display.longTitle(for: display.input))")
            case .unresponsive:
                StatusDot(color: .orange)
                Text("Détecté · DDC/CI ne répond pas")
            case .asleep:
                StatusDot(color: .orange)
                Text("En veille")
            case .disconnected:
                StatusDot(color: Color.secondary.opacity(0.6))
                Text("Débranché · en attente")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Première lecture des réglages : indicateur discret à la place des modules.
private struct ReadingPlaceholder: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Lecture des réglages de l'écran…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .panelModule()
    }
}

// MARK: - Pied

/// « Réglages de Mi Monitor… ⌘, » et « Quitter Mi Monitor ⌘Q ».
struct PanelFooter: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            FooterItem(symbol: "slider.horizontal.3", title: "Réglages de Mi Monitor…", shortcut: "⌘,") {
                showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            FooterItem(symbol: nil, title: "Quitter Mi Monitor", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .overlay(alignment: .top) { Divider() }
    }

    /// App de barre des menus (sans Dock) : il faut l'activer pour que la fenêtre Réglages passe devant.
    /// Le panneau est fermé d'abord (sinon il reste par-dessus les Réglages).
    private func showSettings() {
        // Repli : au moment du clic, la fenêtre clé est celle du panneau.
        let panel = PanelWindow.current ?? NSApp.keyWindow
        panel?.close()
        NSApp.activate()
        openSettings()
        // La fenêtre est créée de façon asynchrone : on la passe devant une fois qu'elle existe.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?
                .makeKeyAndOrderFront(nil)
        }
    }
}

private struct FooterItem: View {
    let symbol: String?
    let title: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Colonne d'icône toujours réservée pour aligner les deux libellés.
                Group {
                    if let symbol { Image(systemName: symbol) } else { Color.clear }
                }
                .frame(width: 16)
                .accessibilityHidden(true)
                Text(title)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            // Survol façon menu : remplissage système, pas de couleur maison.
            .background(isHovered ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Aides d'affichage

extension DisplayController {
    /// Nom de l'écran précédé de l'article défini, élidé devant une voyelle :
    /// « le Mi Monitor », « l'AOC Q27G3XMN » (« Le » / « L' » en début de phrase).
    func nameWithArticle(capitalized: Bool = false) -> String {
        let name = displayName
        let vowels = Set("AEIOUYÀÂÄÉÈÊËÎÏÔÖÙÛÜaeiouyàâäéèêëîïôöùûü")
        if let first = name.first, vowels.contains(first) {
            return (capitalized ? "L'" : "l'") + name
        }
        return (capitalized ? "Le " : "le ") + name
    }
}

// MARK: - Aperçus

#if DEBUG
#Preview("Connecté") {
    PanelContent(selected: .preview(), hasScanned: true)
        .environment(AppModel.shared)
}

#Preview("Connecté · sombre") {
    PanelContent(selected: .preview(), hasScanned: true)
        .environment(AppModel.shared)
        .preferredColorScheme(.dark)
}

#Preview("Ne répond pas") {
    PanelContent(selected: .preview(connection: .unresponsive(reason: "pas de réponse valide de l'écran (délai)")),
                 hasScanned: true)
        .environment(AppModel.shared)
}

#Preview("Connexion") {
    PanelContent(selected: .preview(connection: .connecting), hasScanned: true)
        .environment(AppModel.shared)
}

#Preview("Débranché") {
    PanelContent(selected: .preview(connection: .disconnected), hasScanned: true)
        .environment(AppModel.shared)
}

#Preview("En veille") {
    PanelContent(selected: .preview(connection: .asleep), hasScanned: true)
        .environment(AppModel.shared)
        .preferredColorScheme(.dark)
}

#Preview("Aucun écran") {
    PanelContent(selected: nil, hasScanned: true)
        .environment(AppModel.shared)
}

/// Modèle d'aperçu à deux écrans : le Mi Monitor factice et l'écran simulé (AOC Q27G3XMN),
/// avec des préférences et des profils isolés. L'écran simulé lit ses valeurs en mémoire.
@MainActor
private func twoDisplayModel(miMonitor: ConnectionState = .connected, showsSimulated: Bool = false) -> AppModel {
    let defaults = UserDefaults(suiteName: "preview.multi-ecran")!
    let manager = DisplayManager(defaults: defaults, observeSystem: false)
    let mi = DisplayController.preview(connection: miMonitor)
    let aoc = SimulatedDDC.makeController(defaults: defaults)
    manager.register(mi)
    manager.register(aoc)
    manager.select(showsSimulated ? aoc : mi)
    Task { await aoc.refresh() }
    let profilesURL = FileManager.default.temporaryDirectory.appending(path: "mi-monitor-apercu-profils.json")
    return AppModel(displays: manager, settings: AppSettings(defaults: defaults),
                    profiles: ProfileStore(url: profilesURL))
}

#Preview("Deux écrans · Mi Monitor") {
    PanelView()
        .environment(twoDisplayModel())
}

#Preview("Deux écrans · AOC simulé") {
    PanelView()
        .environment(twoDisplayModel(showsSimulated: true))
        .preferredColorScheme(.dark)
}

#Preview("Deux écrans · Mi Monitor ne répond pas") {
    PanelView()
        .environment(twoDisplayModel(miMonitor: .unresponsive(reason: "pas de réponse valide de l'écran (délai)")))
}
#endif

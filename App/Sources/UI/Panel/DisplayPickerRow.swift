// Rangée de sélection d'écran, en haut du panneau quand plusieurs écrans sont connus :
// un bouton en verre par écran (SF Symbol « display », nom court, pastille d'état).
// L'écran choisi est teinté d'accent système ; les boutons partagent un conteneur de verre
// et se morphosent (glassEffectID) à la sélection, à l'arrivée ou au départ d'un écran.
// Avec un seul écran, la rangée n'est pas affichée (cf. PanelContent).

import SwiftUI

struct DisplayPickerRow: View {
    let displays: [DisplayController]
    /// Écran affiché par le panneau (DisplayManager.selected).
    let selectedID: String?
    let select: (DisplayController) -> Void

    /// Morphoses du verre des boutons.
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(displays) { display in
                    DisplayPickerButton(display: display, isSelected: display.id == selectedID,
                                        glassNamespace: glassNamespace) {
                        select(display)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Écrans")
    }
}

/// Bouton d'un écran : icône, nom et état de la liaison.
private struct DisplayPickerButton: View {
    let display: DisplayController
    let isSelected: Bool
    let glassNamespace: Namespace.ID
    let action: () -> Void

    /// Nom court pour le bouton (le nom complet est dans l'en-tête, l'infobulle et VoiceOver) :
    /// sans la mention « (simulé) », qui faisait tronquer « AOC Q27G3XMN » au test réel.
    static func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: " (simulé)", with: "")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(Self.shortName(display.displayName))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    // Garde la fin du nom : elle distingue deux écrans de même modèle (« … · 0001 »).
                    .truncationMode(.middle)
                stateIndicator
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Capsule())
            .glassEffect(isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                         in: .capsule)
            .glassEffectID(display.id, in: glassNamespace)
        }
        .buttonStyle(.plain)
        // Un écran débranché ne peut pas être affiché (le panneau montrerait un autre écran) :
        // son bouton reste visible, grisé, pour signaler son état.
        .disabled(isDisconnected)
        .opacity(isDisconnected ? 0.5 : 1)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .help("\(display.displayName) · \(display.connection.label)")
        .accessibilityLabel("\(display.displayName), \(display.connection.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Écran affiché" : "Affiche les réglages de cet écran")
    }

    private var isDisconnected: Bool { display.connection == .disconnected }

    /// Pastille d'état : vert connecté, orange en veille ou sans réponse DDC/CI, gris débranché ;
    /// petit indicateur d'activité pendant la connexion.
    @ViewBuilder
    private var stateIndicator: some View {
        switch display.connection {
        case .connecting:
            MiniSpinner()
        case .connected:
            StatusDot(color: .green)
        case .unresponsive, .asleep:
            StatusDot(color: .orange)
        case .disconnected:
            StatusDot(color: Color.secondary.opacity(0.6))
        }
    }
}

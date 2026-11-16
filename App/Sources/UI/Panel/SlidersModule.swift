// Module Luminosité / Contraste / Son : curseurs épais façon Centre de contrôle, sur rail de verre.
// À droite du titre : la valeur, « Application… » pendant l'écriture DDC, « suit le MacBook »
// quand la synchronisation écrit vraiment (« synchro en pause » après un réglage manuel),
// ou « — dernière : 45 % » quand l'écran ne répond pas.
// Seuls les réglages que l'écran prend en charge (supportedControls) sont affichés ;
// sans aucun des trois, le module disparaît.

import SwiftUI

struct SlidersModule: View {
    @Environment(AppModel.self) private var model
    let display: DisplayController
    /// Écran injoignable : curseurs grisés qui gardent la dernière valeur connue.
    let isFrozen: Bool

    /// Curseurs proposés par ce module.
    static let sliderControls: [Control] = [.brightness, .contrast, .volume]

    /// Curseurs à afficher : ceux que l'écran prend en charge. Écran injoignable dont rien n'a
    /// pu être lu : les trois, grisés, comme avant le multi-écran (« dernière : inconnue »).
    static func visibleControls(of display: DisplayController, isFrozen: Bool) -> [Control] {
        let supported = sliderControls.filter(display.supportedControls.contains)
        return supported.isEmpty && isFrozen ? sliderControls : supported
    }

    var body: some View {
        let controls = Self.visibleControls(of: display, isFrozen: isFrozen)
        if !controls.isEmpty {
            // Rails et bouton de sourdine sont du verre posé sur le verre du module : le conteneur
            // les rend ensemble. Espacement (4) inférieur aux écarts réels (8 pt et plus) pour que
            // le rail et la sourdine restent deux formes distinctes au lieu de fusionner.
            GlassEffectContainer(spacing: 4) {
                VStack(alignment: .leading, spacing: 12) {
                    if controls.contains(.brightness) {
                        block(.brightness, symbol: brightnessSymbol)
                    }
                    if controls.contains(.contrast) {
                        block(.contrast, symbol: "circle.lefthalf.filled")
                    }
                    if controls.contains(.volume) {
                        // Sourdine émulée par le cœur (son à 0 puis restauration) : liée au son.
                        block(.volume, symbol: volumeSymbol, showsMute: true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .panelModule()
        }
    }

    // MARK: Un réglage

    private func block(_ control: Control, symbol: String, showsMute: Bool = false) -> some View {
        let value = display.value(of: control)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(control.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isFrozen ? .secondary : .primary)
                Spacer()
                trailing(for: control, value: value)
            }
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                ControlCenterSlider(value: value,
                                    accessibilityLabel: control.title,
                                    symbol: symbol,
                                    isApplying: display.applying.contains(control),
                                    accessibilityStatus: accessibilityStatus(for: control)) { newValue in
                    display.set(control, percent: newValue)
                }
                if showsMute {
                    MuteButton(isMuted: display.isMuted) { display.toggleMute() }
                }
            }
            .dimmed(isFrozen)
            .disabled(isFrozen)
        }
    }

    @ViewBuilder
    private func trailing(for control: Control, value: Int) -> some View {
        HStack(spacing: 5) {
            if isFrozen {
                Text(display.hasReadValues ? "— dernière : \(value.panelPercent)" : "— dernière : inconnue")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if display.applying.contains(control) {
                MiniSpinner()
                Text("Application… \(value.panelPercent)")
            } else if control == .brightness && syncState == .following {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("suit le MacBook · \(value.panelPercent)")
            } else if control == .brightness && syncState == .paused {
                Text("synchro en pause · \(value.panelPercent)")
            } else if control == .volume && display.isMuted {
                Text("Sourdine")
            } else {
                Text(value.panelPercent)
            }
        }
        .font(.system(size: 12, weight: followsMacBook(control) ? .medium : .regular))
        .foregroundStyle(followsMacBook(control) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .monospacedDigit()
        .lineLimit(1)
        .contentTransition(.numericText())
    }

    /// Libellé bleu « suit le MacBook » (seulement s'il n'y a pas d'écriture en cours).
    private func followsMacBook(_ control: Control) -> Bool {
        control == .brightness && syncState == .following && !isFrozen
            && !display.applying.contains(.brightness)
    }

    /// État réel de la synchro avec le MacBook (option active ne veut pas dire suivi effectif).
    private var syncState: FollowSyncState { FollowSyncState(model: model, display: display) }

    /// Complément lu par VoiceOver après la valeur (la ligne de titre est masquée).
    private func accessibilityStatus(for control: Control) -> String? {
        if isFrozen {
            return display.hasReadValues ? "dernière valeur connue, écran injoignable" : "valeur inconnue, écran injoignable"
        }
        if control == .volume && display.isMuted { return "Sourdine" }
        if control == .brightness {
            switch syncState {
            case .following: return "suit le MacBook"
            case .paused: return "synchro avec le MacBook en pause"
            case .off, .unavailable: return nil
            }
        }
        return nil
    }

    // MARK: Symboles variables

    private var brightnessSymbol: String {
        display.brightness < 34 ? "sun.min.fill" : "sun.max.fill"
    }

    private var volumeSymbol: String {
        if display.isMuted || display.volume == 0 { return "speaker.slash.fill" }
        if display.volume < 34 { return "speaker.wave.1.fill" }
        if display.volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// État de « Suivre le MacBook » tel que l'utilisateur doit le voir.
enum FollowSyncState: Equatable {
    /// Option coupée.
    case off
    /// La synchro recopie la luminosité du MacBook.
    case following
    /// Réglage manuel : la synchro attend un net changement sur le MacBook.
    case paused
    /// Luminosité du MacBook illisible (capot fermé, Mac de bureau) : rien n'est suivi.
    case unavailable

    @MainActor
    init(model: AppModel, display: DisplayController) {
        guard model.settings.followsMacBook(display.id) else { self = .off; return }
        let sync = model.brightnessSync
        if sync.isSuspended(display.id) { self = .paused }
        else if sync.macBookPercent == nil { self = .unavailable }
        else { self = .following }
    }
}

/// Bouton rond de sourdine (émulée par le cœur : son à 0 puis restauration),
/// en verre interactif, teinté d'accent quand la sourdine est active.
private struct MuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isMuted ? Color.white : Color.primary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .glassEffect(isMuted ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                             in: .circle)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isMuted)
        .accessibilityLabel(isMuted ? "Rétablir le son" : "Couper le son")
        .accessibilityAddTraits(isMuted ? .isSelected : [])
        .help(isMuted ? "Rétablir le son" : "Couper le son")
    }
}

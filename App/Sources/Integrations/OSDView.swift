// Vue SwiftUI de l'OSD maison (planche 2 de la maquette) : capsule Liquid Glass 384 × 62 pt
// avec pastille d'icône (SF Symbol), titre, nom de l'écran visé (ou « Application… »),
// jauge à crans francs et pourcentage. L'ancien carré centré « Façon système » a été retiré.
// Le contenu est calculé à chaque rendu à partir du DisplayController observé :
// la jauge et l'état « Application… » suivent donc les valeurs en direct.

import Observation
import SwiftUI

/// État partagé entre OSDController (qui le remplit) et OSDView (qui l'affiche).
@Observable
final class OSDState {
    var control: Control = .brightness
    var display: DisplayController?
    /// Nombre de crans de la jauge (AppSettings.keyboardSteps).
    var steps: Int = 16
    /// Position choisie (haut ou bas) ; la vue est la même capsule dans les deux cas.
    var style: OSDStyle = .capsuleTop
}

/// Ce qu'affiche l'OSD, calculé de façon pure (testable) à partir des valeurs de l'écran.
struct OSDContent: Equatable {
    var symbol: String
    var title: String
    /// « 45 % », ou « — » en sourdine.
    var valueText: String
    var filled: Int
    var total: Int
    /// Écriture lente en cours (son, gains) : affiche « Application… ».
    var applying: Bool
    /// Nom de l'écran réglé (utile dès qu'il y a deux écrans externes).
    var displayName: String

    /// - Parameter isSlow: réglage lent sur cet écran ; par défaut, les réglages lents prudents (son, gains).
    /// - Parameter displayName: nom affiché à droite du titre.
    init(control: Control, value: Int, isMuted: Bool, applying: Bool, isSlow: Bool? = nil, steps: Int,
         displayName: String = "Mi Monitor") {
        self.displayName = displayName
        let total = max(1, steps)
        let muted = control == .volume && isMuted
        self.total = total
        self.applying = applying && (isSlow ?? DisplayQuirks.prudentSlowControls.contains(control))
        self.title = muted ? "Sourdine" : control.title
        self.filled = muted ? 0 : Self.filledNotches(value: value, steps: total)
        // Espace fine insécable avant « % », comme dans la maquette.
        self.valueText = muted ? "—" : "\(value)\u{202F}%"
        self.symbol = Self.symbol(for: control, value: value, muted: muted)
    }

    init(control: Control, display: DisplayController, steps: Int) {
        self.init(control: control, value: display.value(of: control), isMuted: display.isMuted,
                  applying: display.applying.contains(control), isSlow: display.isSlow(control), steps: steps,
                  displayName: display.displayName)
    }

    /// Nombre de crans pleins : arrondi au plus proche (45 % sur 16 crans → 7, 12 % → 2).
    static func filledNotches(value: Int, steps: Int) -> Int {
        let v = min(100, max(0, value))
        return min(steps, Int((Double(v) / 100 * Double(steps)).rounded()))
    }

    static func symbol(for control: Control, value: Int, muted: Bool) -> String {
        switch control {
        case .brightness:
            // Petit soleil quand la luminosité est basse (maquette, vignette 4).
            return value < 25 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if muted { return "speaker.slash.fill" }
            switch value {
            case 0: return "speaker.fill"
            case ..<34: return "speaker.wave.1.fill"
            case ..<67: return "speaker.wave.2.fill"
            default: return "speaker.wave.3.fill"
            }
        default:
            return control.symbol
        }
    }
}

/// Racine affichée dans le panneau de l'OSD.
struct OSDView: View {
    let state: OSDState

    var body: some View {
        if let display = state.display {
            let content = OSDContent(control: state.control, display: display, steps: state.steps)
            OSDCapsule(content: content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Capsule de verre

struct OSDCapsule: View {
    let content: OSDContent

    static let size = CGSize(width: 384, height: 62)

    var body: some View {
        HStack(spacing: 12) {
            // Pastille de l'icône : SF Symbol sur un remplissage système discret.
            Image(systemName: content.symbol)
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)
                .background(.fill.tertiary, in: Circle())

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(content.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        if content.applying {
                            ProgressView().controlSize(.mini)
                            Text("Application…")
                        } else {
                            Text(content.displayName)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                OSDNotches(filled: content.filled, total: content.total, height: 6)
            }

            Text(content.valueText)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .frame(width: Self.size.width, height: Self.size.height)
        // Verre Liquid Glass natif : il porte lui-même sa lumière et son ombre.
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Jauge à crans

/// Jauge à crans francs. Au-delà de 48 crans, ils deviendraient illisibles : barre continue.
struct OSDNotches: View {
    let filled: Int
    let total: Int
    let height: CGFloat

    var body: some View {
        if total > 48 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.fill.tertiary)
                    Capsule().fill(.primary)
                        .frame(width: geo.size.width * CGFloat(filled) / CGFloat(max(1, total)))
                }
            }
            .frame(height: height)
        } else {
            HStack(spacing: total > 24 ? 1.5 : 3) {
                ForEach(0..<total, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(i < filled ? AnyShapeStyle(.primary) : AnyShapeStyle(.fill.tertiary))
                        .frame(height: height)
                }
            }
            .animation(.snappy(duration: 0.12), value: filled)
        }
    }
}

#if DEBUG
#Preview("OSD") {
    VStack(spacing: 20) {
        OSDCapsule(content: OSDContent(control: .brightness, value: 45, isMuted: false, applying: false, steps: 16))
        OSDCapsule(content: OSDContent(control: .volume, value: 12, isMuted: false, applying: true, steps: 16))
        OSDCapsule(content: OSDContent(control: .volume, value: 0, isMuted: true, applying: false, steps: 16))
    }
    .padding(40)
}
#endif

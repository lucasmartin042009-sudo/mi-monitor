// Curseur du panneau : le Slider système de macOS 26/27, avec son bouton en Liquid Glass natif
// et sa piste remplie à la couleur d'accent (contraste net en clair comme en sombre).
// Un SF Symbol est posé à gauche (ou une lettre pour les gains R / V / B).
//
// Le curseur appelle onChange à chaque changement de valeur entière ; le cœur regroupe
// et limite lui-même les écritures DDC, il n'y a donc pas de temporisation ici.
// L'état « Application… » (écriture DDC lente en cours) est affiché par le libellé au-dessus
// du curseur ; ici, la piste s'estompe légèrement pendant ce temps.

import SwiftUI

struct ControlCenterSlider: View {
    /// Valeur affichée, 0–100.
    let value: Int
    /// Libellé VoiceOver (« Luminosité »…).
    let accessibilityLabel: String
    /// SF Symbol posé à gauche (nil pour aucun).
    var symbol: String? = nil
    /// Lettre posée à gauche à la place du symbole (gains R / V / B).
    var badgeText: String? = nil
    /// Hauteur indicative : ≥ 24 pt = curseur normal, sinon petit curseur (gains).
    var height: CGFloat = 28
    /// Teinte de la piste remplie ; nil = couleur d'accent du système.
    var fillColor: Color? = nil
    /// Écriture DDC en cours ou en attente.
    var isApplying = false
    /// Pas des actions VoiceOver « augmenter / diminuer ».
    var accessibilityStep = 5
    /// État ajouté à la valeur lue par VoiceOver (« Sourdine », « suit le MacBook »…).
    var accessibilityStatus: String? = nil
    let onChange: (Int) -> Void

    @Environment(\.isEnabled) private var isEnabled

    private var isSmall: Bool { height < 24 }

    var body: some View {
        HStack(spacing: isSmall ? 6 : 8) {
            leadingMark
                .frame(width: isSmall ? 14 : 18)
            Slider(value: binding, in: 0...100)
                .labelsHidden()
                .controlSize(isSmall ? .small : .regular)
                .tint(fillColor ?? .accentColor)
                .opacity(isApplying ? 0.7 : 1)
                .animation(.easeInOut(duration: 0.2), value: isApplying)
        }
        .frame(minHeight: isSmall ? 20 : 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue([value.panelPercent, isApplying ? "application en cours" : nil, accessibilityStatus]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: emit(value + accessibilityStep)
            case .decrement: emit(value - accessibilityStep)
            @unknown default: break
            }
        }
    }

    /// Le Slider travaille en Double ; on n'émet qu'aux changements de valeur entière.
    private var binding: Binding<Double> {
        Binding(get: { Double(value) }, set: { emit(Int($0.rounded())) })
    }

    @ViewBuilder
    private var leadingMark: some View {
        if let badgeText {
            Text(badgeText)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(fillColor ?? .secondary)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private func emit(_ newValue: Int) {
        // Les actions VoiceOver passent aussi par ici : rien si le curseur est désactivé.
        guard isEnabled else { return }
        let clamped = min(100, max(0, newValue))
        guard clamped != value else { return }
        onChange(clamped)
    }
}

#if DEBUG
#Preview("Curseurs") {
    VStack(spacing: 12) {
        ControlCenterSlider(value: 45, accessibilityLabel: "Luminosité", symbol: "sun.max.fill") { _ in }
        ControlCenterSlider(value: 12, accessibilityLabel: "Son", symbol: "speaker.wave.2.fill", isApplying: true) { _ in }
        ControlCenterSlider(value: 54, accessibilityLabel: "Rouge", badgeText: "R", height: 20, fillColor: .red) { _ in }
        ControlCenterSlider(value: 70, accessibilityLabel: "Contraste", symbol: "circle.lefthalf.filled") { _ in }
            .dimmed(true)
    }
    .padding()
    .frame(width: 320)
}
#endif

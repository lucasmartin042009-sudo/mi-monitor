// Petits éléments de style communs au panneau, en Liquid Glass (macOS 26 et suivants).
// La fenêtre MenuBarExtra (.window) est déjà en verre : on n'y empile aucun fond opaque ni
// matériau ; les modules y flottent en verre natif (glassEffect) et tout le reste utilise
// les couleurs et remplissages système (.fill, .separator, accent système), qui suivent
// automatiquement le mode clair / sombre et le contraste renforcé.

import SwiftUI

/// Teintes propres au panneau qui n'ont pas d'équivalent système direct.
struct PanelPalette {
    let scheme: ColorScheme
    private var dark: Bool { scheme == .dark }

    /// Remplissage blanc des curseurs, comme dans le Centre de contrôle.
    var fill: Color { dark ? .white.opacity(0.95) : .white }
    /// Rayures de l'état « Application… » (accent système).
    var hatch: Color { Color.accentColor.opacity(dark ? 0.42 : 0.22) }
}

extension View {
    /// Module du panneau : plateau Liquid Glass arrondi qui flotte sur le verre de la fenêtre.
    /// Le contenu est découpé à la forme du module : le survol pleine largeur des rangées
    /// (Couleur, Source) ne déborde pas des coins arrondis du verre.
    func panelModule(cornerRadius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return clipShape(shape).glassEffect(.regular, in: shape)
    }

    /// Aspect grisé des commandes inactives (écran qui ne répond pas).
    func dimmed(_ isDimmed: Bool) -> some View {
        self.opacity(isDimmed ? 0.42 : 1)
            .saturation(isDimmed ? 0 : 1)
            .allowsHitTesting(!isDimmed)
    }
}

/// Pastille d'état (connexion) : SF Symbol « circle.fill » dans une couleur système.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// Pastille ronde avec un SF Symbol (en-tête, rangées, cartes d'état).
/// Sans couleur de fond, la pastille prend le remplissage système discret (.fill.tertiary).
struct IconBadge: View {
    let symbol: String
    var background: Color? = .accentColor
    var foreground: Color = .white
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.fill.tertiary), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Petit indicateur d'activité (écriture en cours, connexion).
struct MiniSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

extension Int {
    /// « 45 % » avec l'espace fine insécable de la typographie française.
    var panelPercent: String { "\(self)\u{202F}%" }
}

// Petites briques partagées par les onglets de la fenêtre Réglages.
// Tous les noms sont préfixés « Settings » pour ne pas entrer en conflit avec les autres modules.

import SwiftUI

// MARK: - Mise en forme

enum SettingsFormat {
    /// Espace fine insécable avant « % », comme dans la maquette (« 45 % »).
    static func percent(_ value: Int) -> String { "\(value)\u{202F}%" }

    /// Écart signé avec le vrai signe moins : « −10 % », « +5 % », « 0 % ».
    static func signedPercent(_ value: Int) -> String {
        if value > 0 { return "+\(value)\u{202F}%" }
        if value < 0 { return "\u{2212}\(-value)\u{202F}%" }
        return "0\u{202F}%"
    }

    /// Nombre décimal à la française (« 6,25 »).
    static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)).locale(Locale(identifier: "fr_FR")))
    }
}

// MARK: - Carré coloré de la barre latérale

/// Carré arrondi coloré avec un symbole blanc, comme dans Réglages Système.
struct SettingsIconSquare: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Pastille de profil

/// Couleur associée à l'icône d'un profil (la maquette colore chaque profil).
enum SettingsProfileTint {
    static func color(for symbol: String) -> Color {
        switch symbol {
        case "camera.aperture", "photo": Color(.systemBlue)
        case "moon.fill": Color(.systemIndigo)
        case "gamecontroller.fill": Color(.systemOrange)
        case "sun.max.fill": Color(.systemYellow)
        case "display": Color(.systemTeal)
        case "film": Color(.systemPink)
        case "book.fill": Color(.systemBrown)
        default: Color(.systemGray)
        }
    }
}

/// Rond coloré portant le symbole du profil.
struct SettingsProfileBadge: View {
    let symbol: String
    var size: CGFloat = 28

    var body: some View {
        Circle()
            .fill(SettingsProfileTint.color(for: symbol).gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Touche façon clavier

/// Raccourci affiché dans une capsule grise (« ⌃⌥1 »).
struct SettingsKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - État de l'écran en bas de la barre latérale

struct SettingsDisplayStatusCard: View {
    let display: DisplayController?
    /// Faux tant que la première détection n'est pas finie (évite « aucun écran » au lancement).
    let hasScanned: Bool

    var body: some View {
        HStack(spacing: 9) {
            IconBadge(symbol: "display", size: 30)
            VStack(alignment: .leading, spacing: 1) {
                // Écran sélectionné (nom unique parmi les écrans connus).
                Text(display?.displayName ?? "Mi Monitor")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    StatusDot(color: dotColor)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        // Remplissage système translucide : la barre latérale reste en verre dessous.
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        guard let display else { return hasScanned ? "Aucun écran externe" : "Recherche…" }
        if display.connection == .connected {
            // « Connecté · USB-C » : on précise l'entrée active.
            return "\(display.connection.label) · \(display.title(for: display.input))"
        }
        return display.connection.label
    }

    private var dotColor: Color {
        switch display?.connection {
        case .connected: .green
        case .connecting, .asleep: .orange
        case .unresponsive: .red
        case .disconnected, nil: .gray
        }
    }
}

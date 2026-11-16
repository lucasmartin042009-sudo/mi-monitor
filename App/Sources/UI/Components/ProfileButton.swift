// Bouton rond de profil (40 pt) avec son nom dessous, en Liquid Glass interactif :
// le profil actif est teinté de la couleur d'accent système.
// À placer dans un GlassEffectContainer (voir ProfilesModule) pour que les boutons voisins
// se fondent et se morphosent entre eux.

import SwiftUI

struct ProfileButton: View {
    let name: String
    let symbol: String
    let isActive: Bool
    /// Espace de noms des morphoses de verre (ajout / retrait d'un profil) ; nil pour aucun.
    var glassNamespace: Namespace.ID? = nil
    /// Identifiant stable du verre dans cet espace de noms (identifiant du profil).
    var glassID: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                glassCircle
                Text(name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isActive)
        .accessibilityLabel("Profil \(name)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(isActive ? "Profil actif" : "Applique ce profil")
    }

    /// Rond de verre interactif (réagit au survol et au clic), teinté d'accent s'il est actif.
    @ViewBuilder
    private var glassCircle: some View {
        let circle = Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .frame(width: 40, height: 40)
            .glassEffect(isActive ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                         in: .circle)
        if let glassNamespace {
            circle.glassEffectID(glassID, in: glassNamespace)
        } else {
            circle
        }
    }
}

#if DEBUG
#Preview("Profils") {
    GlassEffectContainer(spacing: 10) {
        HStack {
            ProfileButton(name: "Montage photo sRGB", symbol: "camera.aperture", isActive: true) {}
            ProfileButton(name: "Nuit", symbol: "moon.fill", isActive: false) {}
            ProfileButton(name: "Jeu", symbol: "gamecontroller.fill", isActive: false) {}
        }
    }
    .padding()
    .frame(width: 320)
}
#endif

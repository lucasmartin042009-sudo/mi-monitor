// Rangée repliable du panneau (Couleur, Source) : pastille colorée, titre, sous-titre,
// valeur courante à droite et chevron qui pivote ; le contenu déplié s'affiche dessous.

import SwiftUI

struct DisclosureRow<Expanded: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    /// Sous-titre affiché sous le titre (souvent seulement une fois déplié).
    var subtitle: String? = nil
    /// Valeur courante affichée à droite (« 6500 K · Neutre »).
    var value: String? = nil
    /// Trait de séparation au-dessus de la rangée (rangées suivantes d'un même module).
    var showsTopSeparator = false
    @Binding var isExpanded: Bool
    @ViewBuilder let expanded: () -> Expanded

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    IconBadge(symbol: symbol, background: tint, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    if let value {
                        Text(value)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(minHeight: 46)
                // Survol : remplissage système le plus discret.
                .background(isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .overlay(alignment: .top) {
                if showsTopSeparator {
                    Divider()
                        .padding(.leading, 50).padding(.trailing, 12)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "Replie" : "Déplie")

            if isExpanded {
                expanded()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

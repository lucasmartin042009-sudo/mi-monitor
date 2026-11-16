// Module « Profils » : boutons ronds en verre interactif (profil actif teinté d'accent),
// « + Enregistrer » avec une petite saisie du nom en place, et ligne résumé sous les boutons.
// Profils listés : ceux de l'écran affiché et les profils globaux (sans écran).
// Un profil enregistré ici est lié à l'écran affiché.

import SwiftUI

struct ProfilesModule: View {
    @Environment(AppModel.self) private var model
    let display: DisplayController

    /// Profils proposés pour cet écran.
    private var profiles: [Profile] { model.profiles.profiles(for: display) }
    /// Morphoses du verre des boutons de profil (ajout, retrait).
    @Namespace private var glassNamespace

    /// Saisie du nom d'un nouveau profil en cours.
    @State private var isNaming = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        let active = model.profiles.activeProfile(for: display)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Profils")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !isNaming {
                    // Lien d'accent système, comme les actions secondaires du Centre de contrôle.
                    Button {
                        startNaming()
                    } label: {
                        Label("Enregistrer", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .tint(.accentColor)
                    .accessibilityLabel("Enregistrer les réglages actuels comme profil")
                }
            }
            .frame(minHeight: 16)
            .padding(.bottom, 8)

            if profiles.isEmpty {
                Text("Aucun profil. Enregistrez les réglages actuels pour en créer un.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Conteneur de verre : les ronds voisins partagent un même rendu et se morphosent.
                GlassEffectContainer(spacing: 10) {
                    LazyVGrid(columns: columns, alignment: .center, spacing: 10) {
                        ForEach(profiles) { profile in
                            ProfileButton(name: profile.name, symbol: profile.symbol,
                                          isActive: profile.id == active?.id,
                                          glassNamespace: glassNamespace,
                                          glassID: profile.id.uuidString) {
                                model.apply(profile, to: display)
                            }
                        }
                    }
                }
                // Pendant une relecture (rebranchement), AppModel.apply ignorerait le clic : on le montre.
                .dimmed(!display.connection.isUsable)
                .disabled(!display.connection.isUsable)
            }

            Group {
                if isNaming {
                    nameEntry
                } else {
                    summary(active: active)
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .panelModule()
        .animation(.snappy, value: isNaming)
    }

    // MARK: Résumé

    /// « ✓ 6500 K · lum. 45 % · contraste 70 » ou « Réglages modifiés · aucun profil actif ».
    private func summary(active: Profile?) -> some View {
        HStack(spacing: 6) {
            if let active {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text(active.settings.summary)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10))
                Text("Réglages modifiés · aucun profil actif")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(active.map { "Profil actif : \($0.name), \($0.settings.summary)" }
                            ?? "Réglages modifiés, aucun profil actif")
    }

    // MARK: Saisie du nom

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Nom du profil", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($nameFocused)
                .onSubmit(save)
                .onExitCommand(perform: cancelNaming)
                // Le champ n'existe qu'une fois inséré : on lui donne le focus à son apparition.
                .onAppear { nameFocused = true }
                .accessibilityLabel("Nom du nouveau profil")

            HStack(spacing: 8) {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Annuler", action: cancelNaming)
                    .buttonStyle(.glass)
                Button("Enregistrer", action: save)
                    .buttonStyle(.glassProminent)
                    .disabled(trimmedName.isEmpty)
            }
            .controlSize(.small)
        }
    }

    /// Rappel de ce qui sera enregistré (ou du profil remplacé si le nom existe déjà).
    private var caption: String {
        if let existing = existingProfile(named: trimmedName), !trimmedName.isEmpty {
            return "Remplace « \(existing.name) »"
        }
        return display.currentSettings.summary
    }

    /// Profil de même nom parmi ceux proposés pour cet écran (un homonyme lié à un autre écran
    /// n'est pas remplacé : ses réglages viennent de cet autre écran).
    private func existingProfile(named name: String) -> Profile? {
        profiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private func startNaming() {
        newName = ""
        isNaming = true
    }

    private func cancelNaming() {
        isNaming = false
        newName = ""
    }

    /// Crée le profil depuis les valeurs courantes, lié à cet écran ; un nom existant (de cet écran
    /// ou global) est mis à jour en gardant l'écran qu'il vise.
    private func save() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        let settings = display.currentSettings
        if var existing = existingProfile(named: name) {
            existing.settings = settings
            model.profiles.update(existing)
        } else {
            model.profiles.add(Profile(name: name, symbol: nextSymbol(), settings: settings, displayID: display.id))
        }
        cancelNaming()
    }

    /// Premier symbole proposé pas encore utilisé par un autre profil.
    private func nextSymbol() -> String {
        let used = Set(model.profiles.profiles.map(\.symbol))
        return Profile.symbolChoices.first { !used.contains($0) } ?? "display"
    }
}

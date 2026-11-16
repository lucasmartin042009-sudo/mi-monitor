// Onglet Profils : liste des profils enregistrés (actif, raccourci), ajout / suppression /
// réordonnancement, création depuis les réglages actuels, et éditeur du profil sélectionné.
// Chaque modification est enregistrée aussitôt (profiles.update) puis les raccourcis globaux
// sont réenregistrés (hotKeys.reload).
// Multi-écran : un profil vise « l'écran sélectionné » (displayID nil) ou un écran précis ;
// l'éditeur ne propose que les réglages que cet écran prend en charge.

import SwiftUI

struct SettingsProfilesPane: View {
    @Environment(AppModel.self) private var model
    let display: DisplayController?

    @State private var selectedID: Profile.ID?

    private var profiles: [Profile] { model.profiles.profiles }

    /// Profil correspondant à l'état actuel de l'écran (badge « Actif »).
    private var activeID: Profile.ID? {
        guard let display, display.hasReadValues else { return nil }
        return model.profiles.activeProfile(for: display)?.id
    }

    private var selected: Profile? { selectedID.flatMap { model.profiles.profile(id: $0) } }

    var body: some View {
        Form {
            Section("Profils enregistrés") {
                if profiles.isEmpty {
                    Text("Aucun profil. Créez-en un avec + ou depuis les réglages actuels.")
                        .foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    SettingsProfileRow(profile: profile,
                                       isActive: profile.id == activeID,
                                       isSelected: profile.id == selectedID)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = profile.id }
                        .listRowBackground(profile.id == selectedID ? Color.accentColor.opacity(0.14) : nil)
                        .contextMenu { contextMenu(for: profile) }
                }
                .onMove { from, to in
                    model.profiles.move(fromOffsets: from, toOffset: to)
                }

                // Barre du bas : + / − et création depuis l'écran.
                HStack(spacing: 4) {
                    Button { addEmpty() } label: { Image(systemName: "plus").frame(width: 18, height: 16) }
                        .help("Nouveau profil")
                        .accessibilityLabel("Nouveau profil")
                    Button { removeSelected() } label: { Image(systemName: "minus").frame(width: 18, height: 16) }
                        .help("Supprimer le profil sélectionné")
                        .accessibilityLabel("Supprimer le profil")
                        .disabled(selected == nil)
                    Spacer()
                    Button("Créer depuis les réglages actuels") { addFromCurrent() }
                        .buttonStyle(.glass)
                        .disabled(!(display?.hasReadValues ?? false))
                }
                // + / − sans bordure, comme sous les listes de Réglages Système.
                .buttonStyle(.borderless)
            }

            if let selected {
                SettingsProfileEditor(profileID: selected.id, display: display)
                    .id(selected.id)
            }
        }
        .formStyle(.grouped)
        .onAppear { if selectedID == nil { selectedID = activeID ?? profiles.first?.id } }
        .onChange(of: profiles.map(\.id)) { _, ids in
            // Sélection supprimée : on retombe sur le premier profil.
            if let id = selectedID, !ids.contains(id) { selectedID = ids.first }
        }
    }

    @ViewBuilder private func contextMenu(for profile: Profile) -> some View {
        // Cible : l'écran du profil s'il est connecté, sinon l'écran sélectionné (AppModel.target).
        Button("Appliquer") { model.apply(profile) }
            .disabled(!(model.target(for: profile)?.connection.isUsable ?? false))
        Divider()
        // Alternative au glisser-déposer pour réordonner.
        if let i = profiles.firstIndex(of: profile) {
            Button("Monter") { model.profiles.move(fromOffsets: [i], toOffset: i - 1) }
                .disabled(i == 0)
            Button("Descendre") { model.profiles.move(fromOffsets: [i], toOffset: i + 2) }
                .disabled(i >= profiles.count - 1)
        }
        Divider()
        Button("Supprimer", role: .destructive) { remove(profile.id) }
    }

    // MARK: - Actions

    private func addEmpty() {
        let p = Profile(name: uniqueName("Nouveau profil"), symbol: "display", settings: ProfileSettings())
        model.profiles.add(p)
        selectedID = p.id
    }

    /// Comme « + Enregistrer » du panneau : le profil est lié à l'écran dont il copie les réglages
    /// (son préréglage, ses gains n'ont de sens que sur lui).
    private func addFromCurrent() {
        guard let display else { return }
        let p = Profile(name: uniqueName("Réglages actuels"), symbol: "display", settings: display.currentSettings,
                        displayID: display.id)
        model.profiles.add(p)
        selectedID = p.id
    }

    private func removeSelected() {
        guard let selectedID else { return }
        remove(selectedID)
    }

    private func remove(_ id: Profile.ID) {
        let index = profiles.firstIndex { $0.id == id }
        model.profiles.remove(id: id)
        model.hotKeys.reload()
        // Sélectionne le voisin, comme dans les listes du Finder.
        if let index, !profiles.isEmpty {
            selectedID = profiles[min(index, profiles.count - 1)].id
        } else {
            selectedID = nil
        }
    }

    /// « Nouveau profil », « Nouveau profil 2 »…
    private func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while model.profiles.profile(named: name) != nil { name = "\(base) \(n)"; n += 1 }
        return name
    }
}

// MARK: - Ligne de la liste

struct SettingsProfileRow: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    let isActive: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            SettingsProfileBadge(symbol: profile.symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name.isEmpty ? "Sans nom" : profile.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isActive {
                Text("Actif")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
            if let hotKey = profile.hotKey {
                // Raccourci refusé par le système : il ne fera rien, on le signale.
                if model.hotKeys.failedProfileIDs.contains(profile.id) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Raccourci indisponible (déjà utilisé par le système ou une autre app)")
                        .accessibilityLabel("Raccourci indisponible")
                }
                SettingsKeyCap(text: hotKey.display)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Résumé des valeurs, précédé du nom de l'écran si le profil en vise un précis.
    private var subtitle: String {
        let summary = profile.settings.summary.isEmpty ? "Ne modifie rien" : profile.settings.summary
        guard let id = profile.displayID else { return summary }
        let name = model.displays.controller(id: id)?.displayName ?? "Écran inconnu"
        return "\(name) · \(summary)"
    }
}

// MARK: - Éditeur

struct SettingsProfileEditor: View {
    @Environment(AppModel.self) private var model
    let profileID: Profile.ID
    /// Écran sélectionné (valeurs de départ des profils sans écran).
    let display: DisplayController?

    /// Écran précis visé par le profil, s'il est connu (même débranché) ; nil = « écran sélectionné ».
    private var profileDisplay: DisplayController? {
        profile.wrappedValue.displayID.flatMap { model.displays.controller(id: $0) }
    }

    /// Écran dont on lit les valeurs de départ : celui du profil, sinon le sélectionné.
    private var sourceDisplay: DisplayController? {
        profile.wrappedValue.displayID == nil ? display : profileDisplay
    }

    /// Le réglage est-il proposé ? « Écran sélectionné » : tous. Écran précis : selon ses capacités
    /// (tous tant qu'il n'a rien lu, faute de savoir). Une valeur déjà fixée dans le profil reste
    /// toujours affichée, pour pouvoir la retirer.
    private func offers(_ control: Control, alreadySet: Bool = false) -> Bool {
        if alreadySet || profile.wrappedValue.displayID == nil { return true }
        guard let c = profileDisplay, c.hasReadValues else { return true }
        return c.supportedControls.contains(control)
    }

    /// Choix du sélecteur « Écran » : identifiant de l'écran, "" pour « Écran sélectionné ».
    private var displayChoice: Binding<String> {
        Binding {
            profile.wrappedValue.displayID ?? ""
        } set: { id in
            profile.wrappedValue.displayID = id.isEmpty ? nil : id
        }
    }

    /// Nom d'un écran dans le menu, avec son état s'il n'est pas branché.
    private func menuTitle(_ c: DisplayController) -> String {
        c.connection == .disconnected ? "\(c.displayName) (débranché)" : c.displayName
    }

    /// Lien vers le profil stocké : chaque écriture l'enregistre et recharge les raccourcis.
    private var profile: Binding<Profile> {
        Binding {
            model.profiles.profile(id: profileID)
                ?? Profile(id: profileID, name: "", symbol: "display", settings: ProfileSettings())
        } set: { newValue in
            let hotKeyChanged = model.profiles.profile(id: profileID)?.hotKey != newValue.hotKey
            model.profiles.update(newValue)
            // Réenregistrer les raccourcis Carbon seulement si la combinaison a changé (pas à chaque frappe du nom).
            if hotKeyChanged { model.hotKeys.reload() }
        }
    }

    /// Nom en cours de saisie : un nom vidé n'est pas enregistré (bouton sans libellé dans le panneau).
    @State private var nameDraft: String?
    @FocusState private var isNameFocused: Bool

    private var nameField: Binding<String> {
        Binding {
            nameDraft ?? profile.wrappedValue.name
        } set: { text in
            nameDraft = text
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { profile.wrappedValue.name = trimmed == text ? text : trimmed }
        }
    }

    /// Validation (Entrée, perte de focus) : un nom vide revient au dernier nom enregistré.
    private func commitName() {
        nameDraft = nil
    }

    /// Préréglage couleur ; passer à « Utilisateur » initialise les gains depuis l'écran.
    private var colorPreset: Binding<ColorPreset?> {
        Binding {
            profile.wrappedValue.settings.colorPreset
        } set: { preset in
            var p = profile.wrappedValue
            p.settings.colorPreset = preset
            if preset?.isUser == true && p.settings.gains == nil {
                p.settings.gains = .init(red: readDisplay?.redGain ?? 50, green: readDisplay?.greenGain ?? 50,
                                         blue: readDisplay?.blueGain ?? 50)
            }
            profile.wrappedValue = p
        }
    }

    /// Profil qui utilise déjà le même raccourci (avertissement).
    private var hotKeyConflict: Profile? {
        guard let key = profile.wrappedValue.hotKey else { return nil }
        return model.profiles.profiles.first { $0.id != profileID && $0.hotKey == key }
    }

    var body: some View {
        let p = profile.wrappedValue

        Section {
            TextField("Nom", text: nameField)
                .focused($isNameFocused)
                .onSubmit(commitName)
                .onChange(of: isNameFocused) { _, focused in if !focused { commitName() } }
                .onDisappear(perform: commitName)

            // Écran visé : « Écran sélectionné » ou un écran connu (même débranché).
            Picker("Écran", selection: displayChoice) {
                Text("Écran sélectionné").tag("")
                ForEach(model.displays.displays) { c in
                    Text(menuTitle(c)).tag(c.id)
                }
                // Écran retenu par le profil mais inconnu à ce lancement (pas rebranché depuis).
                if let id = p.displayID, model.displays.controller(id: id) == nil {
                    Text("Écran inconnu").tag(id)
                }
            }

            LabeledContent("Icône") {
                // Pastilles de verre voisines : rendues ensemble par le conteneur.
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(Profile.symbolChoices, id: \.self) { symbol in
                            SettingsSymbolChoice(symbol: symbol, isSelected: p.symbol == symbol) {
                                profile.wrappedValue.symbol = symbol
                            }
                        }
                    }
                }
            }

            // Cinq segments (avec « Ne pas modifier ») : si la largeur manque, menu déroulant.
            if offers(.colorPreset, alreadySet: p.settings.colorPreset != nil) {
                LabeledContent("Préréglage couleur") {
                    ViewThatFits(in: .horizontal) {
                        colorPresetPicker.pickerStyle(.segmented).fixedSize()
                        colorPresetPicker.pickerStyle(.menu).fixedSize()
                    }
                }
            }

            if offers(.brightness, alreadySet: p.settings.brightness != nil) {
                SettingsOptionalPercentRow(title: "Luminosité", keepLabel: "Ne pas modifier la luminosité",
                                           value: profile.settings.brightness, fallback: readDisplay?.brightness ?? 50)
            }
            if offers(.contrast, alreadySet: p.settings.contrast != nil) {
                SettingsOptionalPercentRow(title: "Contraste", keepLabel: "Ne pas modifier le contraste",
                                           value: profile.settings.contrast, fallback: readDisplay?.contrast ?? 50)
            }
            if offers(.volume, alreadySet: p.settings.volume != nil) {
                SettingsOptionalPercentRow(title: "Son", keepLabel: "Ne pas modifier le volume",
                                           value: profile.settings.volume, fallback: readDisplay?.volume ?? 20)
            }

            // Gains R/V/B : seulement en préréglage Utilisateur, et si l'écran a les trois gains.
            if p.settings.colorPreset?.isUser == true, offersGains {
                gainRow("Rouge", tint: .red, \.red)
                gainRow("Vert", tint: .green, \.green)
                gainRow("Bleu", tint: .blue, \.blue)
            }

            LabeledContent("Raccourci clavier") {
                KeyRecorderView(combo: profile.hotKey)
            }
            if let other = hotKeyConflict {
                Label("Déjà utilisé par « \(other.name) » : un seul des deux profils réagira.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.hotKeys.failedProfileIDs.contains(profileID) {
                Label("Raccourci indisponible (déjà utilisé par le système ou une autre app).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                // Cible : l'écran du profil s'il est connecté, sinon l'écran sélectionné.
                Button("Appliquer") { model.apply(p) }
                    .buttonStyle(.glassProminent)
                    .disabled(!(model.target(for: p)?.connection.isUsable ?? false))
            }
        } header: {
            Text("Modifier « \(p.name.isEmpty ? "Sans nom" : p.name) »")
        } footer: {
            if let note = sRGBNote(for: p) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var colorPresetPicker: some View {
        Picker("Préréglage couleur", selection: colorPreset) {
            Text("Ne pas modifier").tag(ColorPreset?.none)
            ForEach(presetChoices) { preset in
                Text(presetTitle(preset)).tag(ColorPreset?.some(preset))
            }
        }
        .labelsHidden()
    }

    /// Gains R V B proposés : les trois pris en charge (ou déjà fixés dans le profil).
    private var offersGains: Bool {
        let set = profile.wrappedValue.settings.gains != nil
        return [Control.redGain, .greenGain, .blueGain].allSatisfy { offers($0, alreadySet: set) }
    }

    /// Écrans dont on propose les préréglages : celui du profil, ou tous les écrans connus
    /// pour « Écran sélectionné » (à défaut l'écran affiché).
    private var presetSources: [DisplayController] {
        if profile.wrappedValue.displayID != nil { return profileDisplay.map { [$0] } ?? [] }
        let known = model.displays.displays
        if !known.isEmpty { return known }
        return display.map { [$0] } ?? []
    }

    /// Préréglages proposés : ceux de l'écran du profil, ou de tous les écrans pour « Écran sélectionné »
    /// (sinon ceux du Mi Monitor), plus celui du profil s'il n'y est pas.
    private var presetChoices: [ColorPreset] {
        var list: [ColorPreset] = []
        for c in presetSources {
            for preset in c.availablePresets where !list.contains(preset) { list.append(preset) }
        }
        if list.isEmpty { list = DisplayQuirks.miMonitor.defaultPresets }
        if let current = profile.wrappedValue.settings.colorPreset, !list.contains(current) { list.append(current) }
        return list
    }

    /// Nom d'un préréglage : celui que lui donne le premier écran qui le propose, sinon le nom générique.
    private func presetTitle(_ preset: ColorPreset) -> String {
        let owner = presetSources.first { $0.availablePresets.contains(preset) } ?? presetSources.first
        return owner?.title(for: preset) ?? preset.title
    }

    /// Valeurs de l'écran seulement si elles ont été lues (sinon 0 / 50 factices).
    private var readDisplay: DisplayController? { sourceDisplay?.hasReadValues == true ? sourceDisplay : nil }

    private func gainRow(_ title: String, tint: Color, _ key: WritableKeyPath<ProfileSettings.Gains, Int>) -> some View {
        let gains = profile.wrappedValue.settings.gains ?? .init(red: 50, green: 50, blue: 50)
        return LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { Double(gains[keyPath: key]) }, set: { v in
                    var g = profile.wrappedValue.settings.gains ?? gains
                    g[keyPath: key] = Int(v.rounded())
                    profile.wrappedValue.settings.gains = g
                }), in: 0...100)
                .tint(tint)
                Text(SettingsFormat.percent(gains[keyPath: key]))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    /// L'écran n'a pas de mode sRGB : on rappelle comment s'en approcher. Rien si un préréglage
    /// sRGB est proposé.
    private func sRGBNote(for p: Profile) -> String? {
        if presetChoices.contains(.sRGB) { return nil }
        if p.name.localizedCaseInsensitiveContains("sRGB") {
            return "Pas de mode sRGB sur cet écran : ce profil s’en approche (6500 K, luminosité réduite)."
        }
        return "Pas de mode sRGB sur cet écran : 6500 K et une luminosité réduite s’en approchent."
    }
}

/// Curseur 0–100 % avec une case « Ne pas modifier » (valeur nil dans le profil).
struct SettingsOptionalPercentRow: View {
    let title: String
    let keepLabel: String
    @Binding var value: Int?
    /// Valeur de départ quand on décoche (valeur actuelle de l'écran).
    let fallback: Int

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 6) {
                if let v = value {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { Double(v) }, set: { value = Int($0.rounded()) }), in: 0...100)
                        Text(SettingsFormat.percent(v))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(keepLabel, isOn: Binding(get: { value == nil }, set: { value = $0 ? nil : fallback }))
                    .toggleStyle(.checkbox)
            }
        }
    }
}

/// Pastille de choix d'icône : SF Symbol sur un rond de verre interactif, teinté d'accent
/// quand il est choisi.
struct SettingsSymbolChoice: View {
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .glassEffect(isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                             in: .circle)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .help(Profile.symbolNames[symbol] ?? symbol)
        .accessibilityLabel("Icône \(Profile.symbolNames[symbol] ?? symbol)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if DEBUG
#Preview("Profils") {
    SettingsProfilesPane(display: .preview())
        .environment(AppModel.shared)
        .frame(width: 520, height: 700)
}
#endif

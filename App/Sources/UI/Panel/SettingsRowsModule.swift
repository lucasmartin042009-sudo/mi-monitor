// Module des rangées : Couleur (préréglages + gains R/V/B en Utilisateur), Source (liste des
// entrées avec confirmation en place) et l'interrupteur « Suivre le MacBook ».
// Une seule rangée dépliée à la fois pour que le panneau reste court.
// Rangées masquées selon les capacités de l'écran (supportedControls) : Couleur si 0x14,
// gains si préréglage Utilisateur et 0x16/0x18/0x1A, Source si 0x60, « Suivre le MacBook »
// si la luminosité (0x10) est pilotable. Préréglages et entrées viennent de l'écran
// (availablePresets, availableInputs) avec ses propres titres.
// Tuiles de préréglage, sources et confirmation sont en Liquid Glass ; la tuile choisie est
// teintée d'accent système.

import SwiftUI

struct SettingsRowsModule: View {
    let display: DisplayController

    private enum Row { case color, source }
    @State private var expanded: Row?

    var body: some View {
        let supported = display.supportedControls
        let showsColor = supported.contains(.colorPreset) && !display.availablePresets.isEmpty
        let showsSource = supported.contains(.input) && !display.availableInputs.isEmpty
        let showsFollow = supported.contains(.brightness)
        if showsColor || showsSource || showsFollow {
            VStack(spacing: 0) {
                if showsColor {
                    DisclosureRow(symbol: "thermometer.medium", tint: .orange, title: "Couleur",
                                  subtitle: expanded == .color ? "Préréglage de l'écran" : nil,
                                  value: colorValue,
                                  isExpanded: binding(for: .color)) {
                        ColorPresetsSection(display: display)
                    }
                }

                if showsSource {
                    DisclosureRow(symbol: Control.input.symbol, tint: .accentColor, title: "Source",
                                  subtitle: expanded == .source ? "Changement soumis à confirmation" : nil,
                                  value: expanded == .source ? nil : sourceValue,
                                  showsTopSeparator: showsColor,
                                  isExpanded: binding(for: .source)) {
                        SourceSection(display: display)
                    }
                }

                if showsFollow {
                    FollowMacBookRow(display: display, showsTopSeparator: showsColor || showsSource)
                    BlackoutRow(display: display)
                }
            }
            .padding(.vertical, 3)
            .panelModule()
        }
    }

    /// « 6500 K · Neutre » replié, « 6500 K » déplié (les tuiles montrent le reste).
    private var colorValue: String {
        let p = display.colorPreset
        if expanded == .color || p.isUser || p.subtitle.isEmpty { return display.title(for: p) }
        return "\(display.title(for: p)) · \(p.subtitle)"
    }

    /// « USB-C · Ce Mac », « HDMI 1 »…
    private var sourceValue: String {
        let title = display.title(for: display.input)
        return display.isMacInput(display.input) ? "\(title) · Ce Mac" : title
    }

    private func binding(for row: Row) -> Binding<Bool> {
        Binding(get: { expanded == row },
                set: { expanded = $0 ? row : (expanded == row ? nil : expanded) })
    }
}

// MARK: - Couleur

private struct ColorPresetsSection: View {
    let display: DisplayController
    /// Morphoses du verre des tuiles (apparition au dépliage, changement de teinte).
    @Namespace private var glassNamespace

    /// Un gain : réglage, lettre et couleur du curseur.
    private struct Gain: Identifiable {
        let control: Control
        let letter: String
        let color: Color
        var id: Control { control }
    }

    private static let gains = [
        Gain(control: .redGain, letter: "R", color: .red),
        Gain(control: .greenGain, letter: "V", color: .green),
        Gain(control: .blueGain, letter: "B", color: .blue),
    ]

    /// Colonnes des tuiles : une seule ligne jusqu'à quatre préréglages (Mi Monitor),
    /// au-delà deux lignes (au plus quatre tuiles par ligne) pour garder des tuiles lisibles.
    private static func columns(for count: Int) -> [GridItem] {
        let perRow = count <= 4 ? max(count, 1) : min((count + 1) / 2, 4)
        return Array(repeating: GridItem(.flexible(), spacing: 6), count: perRow)
    }

    var body: some View {
        let presets = display.availablePresets
        let gains = Self.gains.filter { display.supportedControls.contains($0.control) }
        VStack(alignment: .leading, spacing: 0) {
            // Conteneur de verre : les tuiles voisines sont rendues ensemble.
            GlassEffectContainer(spacing: 6) {
                LazyVGrid(columns: Self.columns(for: presets.count), spacing: 6) {
                    ForEach(presets) { preset in
                        PresetTile(preset: preset, title: display.title(for: preset), isSelected: display.colorPreset == preset,
                                   isApplying: display.colorPreset == preset && display.applying.contains(.colorPreset)) {
                            withAnimation(.snappy) { display.setColorPreset(preset) }
                        }
                        .glassEffectID(preset, in: glassNamespace)
                    }
                }
            }

            if display.colorPreset.isUser && !gains.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    // Rails de verre des gains, posés sur le verre du module : rendus ensemble.
                    GlassEffectContainer(spacing: 2) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(gains) { gain in
                                GainRow(display: display, control: gain.control, letter: gain.letter, color: gain.color)
                            }
                        }
                    }
                    // Rappel du silence de l'écran après chaque écriture de gain (cf. DisplayQuirks).
                    if gains.contains(where: { display.isSlow($0.control) }) {
                        Text("Écriture lente : au plus une valeur par seconde.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Tuile de préréglage en verre : pastille de couleur (SF Symbol), valeur et qualificatif
/// (« 5000 K / Chaud »).
private struct PresetTile: View {
    let preset: ColorPreset
    /// Nom du préréglage sur cet écran (ex. « Utilisateur » sur le Mi Monitor).
    let title: String
    let isSelected: Bool
    let isApplying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                // Pastille : « circle.fill », cerclée (« circle.inset.filled ») quand elle est choisie.
                Image(systemName: isSelected ? "circle.inset.filled" : "circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(swatch)
                    // Pastille blanche (6500 K) sur verre clair : cerclage « circle » discret
                    // pour qu'elle reste visible en mode clair.
                    .overlay {
                        if preset == .neutral6500K && !isSelected {
                            Image(systemName: "circle")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 3) {
                    if isApplying { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 8, height: 8) }
                    Text(preset.subtitle)
                }
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.86)) : AnyShapeStyle(.secondary))
            }
            .lineLimit(1)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 7)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .glassEffect(isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                         in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(preset.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Teinte de la pastille : couleurs système proches de la température de couleur,
    /// roue chromatique (dégradé angulaire des couleurs système) pour « Utilisateur ».
    private var swatch: AnyShapeStyle {
        if preset.isUser {
            return AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                 center: .center))
        }
        // Températures : chaud en orange, 6500 K (et sRGB / natif) en blanc, froid en cyan.
        guard let kelvin = preset.kelvin else {
            return preset == .sRGB || preset == .native ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.gray.gradient)
        }
        if kelvin < 6500 { return AnyShapeStyle(Color.orange.gradient) }
        return kelvin == 6500 ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.cyan.gradient)
    }
}

/// Curseur de gain coloré (20 pt) avec sa valeur à droite.
private struct GainRow: View {
    let display: DisplayController
    let control: Control
    let letter: String
    let color: Color

    var body: some View {
        let value = display.value(of: control)
        HStack(spacing: 8) {
            ControlCenterSlider(value: value, accessibilityLabel: "Gain \(control.title.lowercased())",
                                badgeText: letter, height: 20, fillColor: color.opacity(0.85),
                                isApplying: display.applying.contains(control)) { newValue in
                display.set(control, percent: newValue)
            }
            Text("\(value)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 24, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Source

private struct SourceSection: View {
    let display: DisplayController
    /// Entrée choisie en attente de confirmation.
    @State private var pending: InputSource?
    /// Morphose de la carte de confirmation (elle se matérialise en verre).
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            options
        }
        // Si l'entrée change ailleurs (profil, OSD de l'écran), la question n'a plus lieu d'être.
        .onChange(of: display.input) { _, newValue in
            if pending == newValue { pending = nil }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(display.availableInputs) { source in
                SourceOption(source: source, display: display,
                             isActive: display.input == source,
                             isPending: pending == source) {
                    withAnimation(.snappy) {
                        pending = (source == display.input) ? nil : source
                    }
                }
            }

            if let pending {
                SourceConfirmation(target: pending, current: display.input, display: display) {
                    withAnimation(.snappy) { self.pending = nil }
                } confirm: {
                    display.switchInput(pending)
                    withAnimation(.snappy) { self.pending = nil }
                }
                .glassEffectID("confirmation", in: glassNamespace)
                .glassEffectTransition(.materialize)
                .padding(.top, 8)
            }
        }
    }
}

private struct SourceOption: View {
    let source: InputSource
    let display: DisplayController
    let isActive: Bool
    let isPending: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconBadge(symbol: isMacInput ? Control.input.symbol : "display",
                          background: isActive ? .accentColor : nil,
                          foreground: isActive ? .white : .primary,
                          size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(display.title(for: source)).font(.system(size: 13))
                    if isMacInput {
                        Text(display.subtitle(for: source).map { "\($0) · Ce Mac" } ?? "Ce Mac")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else if isHovered && !isPending {
                    Text("Demande confirmation")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 38)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(isActive ? "Entrée active" : "Demande une confirmation avant de basculer")
    }

    private var isMacInput: Bool { display.isMacInput(source) }

    /// « USB-C, DisplayPort 2, ce Mac », « HDMI 1 »…
    private var accessibilityTitle: String {
        guard isMacInput else { return display.title(for: source) }
        return ([display.title(for: source)] + [display.subtitle(for: source)].compactMap { $0 } + ["ce Mac"])
            .joined(separator: ", ")
    }

    /// Survol : remplissage système ; entrée en attente : accent système léger.
    private var background: AnyShapeStyle {
        if isPending { return AnyShapeStyle(Color.accentColor.opacity(0.16)) }
        if isHovered && !isActive { return AnyShapeStyle(.fill.tertiary) }
        return AnyShapeStyle(.clear)
    }
}

/// Question posée dans la rangée dépliée, sans alerte (une alerte fermerait le panneau).
private struct SourceConfirmation: View {
    let target: InputSource
    let current: InputSource
    let display: DisplayController
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Basculer sur \(display.title(for: target)) ?")
                    .font(.system(size: 13, weight: .semibold))
            }
            .accessibilityElement(children: .combine)
            Text(explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Annuler", action: cancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Basculer", action: confirm)
                    .buttonStyle(.glassProminent)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelModule(cornerRadius: 12)
    }

    /// Explication selon l'entrée du Mac sur cet écran (macInput).
    private var explanation: String {
        let subject = display.nameWithArticle(capitalized: true)
        if display.isMacInput(target) {
            return "\(subject) affichera de nouveau l'image de ce Mac."
        }
        if display.isMacInput(current), let macInput = display.macInput {
            return "Ce Mac n'aura plus d'image sur \(display.nameWithArticle()). Pour revenir, choisissez l'entrée "
                + "\(display.longTitle(for: macInput)) avec les boutons de l'écran."
        }
        return "\(subject) passera sur l'entrée \(display.title(for: target))."
    }
}

// MARK: - Suivre le MacBook

private struct FollowMacBookRow: View {
    @Environment(AppModel.self) private var model
    let display: DisplayController
    /// Trait de séparation au-dessus (absent si la rangée est seule dans le module).
    var showsTopSeparator = true

    /// Sous-titre fidèle à ce que fait vraiment la synchro.
    private var subtitle: String {
        switch FollowSyncState(model: model, display: display) {
        case .off: "Luminosité indépendante"
        case .following: "Luminosité synchronisée"
        case .paused: "En pause après un réglage manuel"
        case .unavailable: "Luminosité du MacBook indisponible"
        }
    }

    var body: some View {
        let isOn = model.settings.followsMacBook(display.id)
        HStack(spacing: 10) {
            IconBadge(symbol: "laptopcomputer",
                      background: isOn ? .indigo : nil,
                      foreground: isOn ? .white : .primary,
                      size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Suivre le MacBook")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Toggle("Suivre le MacBook", isOn: Binding(
                get: { model.settings.followsMacBook(display.id) },
                set: { newValue in withAnimation(.snappy) { model.settings.setFollowsMacBook(newValue, for: display.id) } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 46)
        .overlay(alignment: .top) {
            if showsTopSeparator {
                Divider()
                    .padding(.leading, 50).padding(.trailing, 12)
            }
        }
    }
}

/// « Mode noir » : écran noir sans l'éteindre (charge USB-C et DDC préservés), cf. BlackoutController.
private struct BlackoutRow: View {
    @Environment(AppModel.self) private var model
    let display: DisplayController

    var body: some View {
        let isOn = model.blackout.isActive(display)
        HStack(spacing: 10) {
            IconBadge(symbol: isOn ? "moon.fill" : "moon",
                      background: isOn ? .black : nil,
                      foreground: isOn ? .white : .primary,
                      size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mode noir")
                    .font(.system(size: 13, weight: .semibold))
                Text(isOn ? "Cliquez sur l'écran noir pour rallumer" : "Écran noir, charge maintenue · \(HotKeyCenter.blackoutCombo.display)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Toggle("Mode noir", isOn: Binding(
                get: { model.blackout.isActive(display) },
                set: { _ in model.blackout.toggle(display) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!display.connection.isUsable && !isOn)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 46)
        .overlay(alignment: .top) {
            Divider().padding(.leading, 50).padding(.trailing, 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Rend l'écran entièrement noir sans l'éteindre ; \(HotKeyCenter.blackoutCombo.display) pour basculer")
    }
}

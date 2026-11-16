// Onglet Général : écran par défaut (s'il y en a plusieurs), ouverture à la connexion,
// touches du clavier, synchro avec le MacBook (par écran), style de l'OSD et mise en veille
// de l'écran sélectionné.

import ServiceManagement
import SwiftUI

struct SettingsGeneralPane: View {
    @Environment(AppModel.self) private var model
    let display: DisplayController?

    /// Reflet de SMAppService (non observable : relu à l'apparition et après chaque changement).
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval
    @State private var loginError: String?
    /// Autorisation Accessibilité, relue chaque seconde tant que l'onglet est visible.
    @State private var isTrusted = MediaKeyMonitor.isTrusted
    @State private var confirmSleep = false

    /// Écrans connus (branchés ou non), dans l'ordre de première détection.
    private var displays: [DisplayController] { model.displays.displays }

    /// Écrans dont on propose le suivi du MacBook : tous les connus ; à défaut (aperçus),
    /// l'écran affiché.
    private var followCandidates: [DisplayController] {
        if !displays.isEmpty { return displays }
        return display.map { [$0] } ?? []
    }

    /// Vrai si au moins un écran suit le MacBook (active le curseur « Écart »).
    private var anyFollows: Bool {
        followCandidates.contains { model.settings.followsMacBook($0.id) }
    }

    /// « Suivre l'écran du MacBook » pour un écran donné (clé followMacBookDisplays).
    private func followMacBook(_ target: DisplayController) -> Binding<Bool> {
        Binding(get: { model.settings.followsMacBook(target.id) },
                set: { on in model.settings.setFollowsMacBook(on, for: target.id) })
    }

    /// Choix de l'« Écran par défaut » : c'est l'écran sélectionné du modèle.
    private var defaultDisplayID: Binding<String> {
        Binding(get: { model.displays.selected?.id ?? "" },
                set: { id in if let c = model.displays.controller(id: id) { model.displays.select(c) } })
    }

    /// Nom de l'écran pour les libellés, avec son état s'il n'est pas branché.
    private func menuTitle(_ c: DisplayController) -> String {
        c.connection == .disconnected ? "\(c.displayName) (débranché)" : c.displayName
    }

    /// Nom de l'écran visé par la mise en veille.
    private var displayTitle: String { display?.displayName ?? "l’écran" }

    /// Mise en veille proposée : toujours tant que l'écran n'a rien lu (comme avant le multi-écran),
    /// sinon seulement s'il annonce l'alimentation (0xD6) ou la prend en charge d'après son modèle.
    private var offersSleep: Bool {
        guard let display, display.hasReadValues else { return true }
        return display.supportedControls.contains(.power)
    }

    /// Pas proposés : 8, 16 (comme macOS) ou 32 crans.
    private static let stepChoices = [8, 16, 32]

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            // MARK: Écran par défaut
            // Avec un seul écran il n'y a rien à choisir : la section n'apparaît qu'à partir de deux.
            if displays.count > 1 {
                Section {
                    Picker(selection: defaultDisplayID) {
                        ForEach(displays) { c in
                            Text(menuTitle(c)).tag(c.id)
                        }
                    } label: {
                        Text("Écran par défaut")
                        Text("Visé par le panneau, les profils sans écran et les actions Raccourcis")
                    }
                }
            }

            // MARK: Ouverture à la connexion
            Section {
                Toggle("Ouvrir à la connexion", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
                if loginNeedsApproval {
                    SettingsWarningRow(text: "À autoriser dans Réglages Système › Général › Ouverture.",
                                       buttonTitle: "Ouvrir…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // MARK: Clavier
            Section("Clavier") {
                Toggle(isOn: $settings.keyboardControl) {
                    Text("Touches de luminosité")
                    Text("Agissent sur l’écran externe où se trouve le pointeur (Accessibilité)")
                }
                Toggle(isOn: $settings.keyboardVolumeControl) {
                    Text("Touches de son et de sourdine")
                    Text("Règlent aussi le haut-parleur de l’écran ; désactivé, elles restent au Mac")
                }
                .disabled(!settings.keyboardControl)
                if settings.keyboardControl && !isTrusted {
                    SettingsWarningRow(text: "Mi Monitor a besoin de l’autorisation Accessibilité pour intercepter les touches.",
                                       buttonTitle: "Autoriser…") {
                        MediaKeyMonitor.requestTrust()
                    }
                }
                Picker("Pas de réglage", selection: $settings.keyboardSteps) {
                    ForEach(Self.stepChoices, id: \.self) { steps in
                        Text("\(steps) crans · \(SettingsFormat.decimal(100.0 / Double(steps)))\u{202F}%").tag(steps)
                    }
                }
                .disabled(!settings.keyboardControl)
            }

            // MARK: Luminosité
            Section {
                if followCandidates.count > 1 {
                    // Plusieurs écrans : un interrupteur par écran.
                    ForEach(followCandidates) { c in
                        Toggle(isOn: followMacBook(c)) {
                            Text(c.displayName)
                            if c.connection == .disconnected {
                                Text("Débranché")
                            }
                        }
                    }
                } else if let only = followCandidates.first {
                    Toggle(isOn: followMacBook(only)) {
                        Text("Suivre l’écran du MacBook")
                        Text("Un réglage manuel suspend la synchro jusqu’à un net changement sur le MacBook (5 points)")
                    }
                } else {
                    Toggle("Suivre l’écran du MacBook", isOn: .constant(false))
                        .disabled(true)
                }
                LabeledContent("Écart") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { Double(settings.followOffset) },
                                              set: { settings.followOffset = Int($0.rounded()) }),
                               in: -50...50, step: 1)
                        Text(SettingsFormat.signedPercent(settings.followOffset))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!anyFollows)
            } header: {
                Text(followCandidates.count > 1 ? "Luminosité · suivre l’écran du MacBook" : "Luminosité")
            } footer: {
                if followCandidates.count > 1 {
                    Text("Un réglage manuel suspend la synchro de l’écran jusqu’à un net changement sur le MacBook (5 points). L’écart vaut pour tous les écrans.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: OSD
            Section {
                // Tuiles de verre regroupées : rendu commun et morphose de la teinte de sélection.
                GlassEffectContainer(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(OSDStyle.allCases) { style in
                            SettingsOSDThumbnail(style: style, isSelected: settings.osdStyle == style) {
                                settings.osdStyle = style
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Affichage à l’écran (OSD)")
            } footer: {
                Text("Avec Canopy, la luminosité et le son s’affichent déjà dans l’encoche : choisissez « Aucun ».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Écran
            Section {
                if offersSleep {
                    LabeledContent {
                        Button("Mettre en veille…", systemImage: "power") { confirmSleep = true }
                            .buttonStyle(.glass)
                            .disabled(!(display?.connection.isUsable ?? false))
                    } label: {
                        Text("Mettre l’écran en veille")
                        Text("Réveil depuis le panneau ou le bouton de l’écran")
                    }
                }
            } header: {
                // Plusieurs écrans : on nomme celui que vise la mise en veille (le sélectionné).
                Text(displays.count > 1 ? "Écran · \(displayTitle)" : "Écran")
            } footer: {
                Text("Son et gains R V B : écriture lente, la dernière valeur part au plus une fois par seconde.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Mettre « \(displayTitle) » en veille ?", isPresented: $confirmSleep) {
            Button("Mettre en veille") {
                guard let display else { return }
                Task { await display.setPower(on: false) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("L’écran s’éteint. Pour le rallumer, utilisez « Réveiller » dans le panneau ou le bouton de l’écran.")
        }
        .task {
            // Ni SMAppService ni l'autorisation Accessibilité ne notifient leurs changements :
            // on les relit régulièrement tant que l'onglet est affiché.
            while !Task.isCancelled {
                let trusted = MediaKeyMonitor.isTrusted
                // Autorisation accordée pendant que l'app tourne : le moniteur créé au lancement
                // n'a pas pu poser son interception ; on le relance pour qu'il la pose maintenant.
                if trusted && !isTrusted && model.settings.keyboardControl {
                    model.mediaKeys.stop()
                    model.mediaKeys.start()
                }
                isTrusted = trusted
                opensAtLogin = LoginItem.isEnabled
                loginNeedsApproval = LoginItem.needsApproval
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginError = nil
        } catch {
            loginError = "Impossible de modifier l’ouverture à la connexion : \(error.localizedDescription)"
        }
        opensAtLogin = LoginItem.isEnabled
        loginNeedsApproval = LoginItem.needsApproval
    }
}

/// Ligne d'avertissement orange avec un bouton d'action.
struct SettingsWarningRow: View {
    let text: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(buttonTitle, action: action)
                .buttonStyle(.glass)
        }
    }
}

/// Vignette de choix du style d'OSD : SF Symbol de la position (capsule en haut, en bas, aucun)
/// sur une tuile Liquid Glass interactive, teintée d'accent quand elle est choisie.
struct SettingsOSDThumbnail: View {
    let style: OSDStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .glassEffect(isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                                 in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(style.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                // Seul « Aucun » porte un sous-titre (la ligne vide garde l'alignement).
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .accessibilityLabel(style == .none ? "\(style.title), \(subtitle)" : style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// L'encoche est laissée à Canopy : « Aucun » est le choix conseillé.
    private var subtitle: String { style == .none ? "Recommandé avec Canopy" : " " }

    /// Pictogramme natif de la position de l'OSD sur l'écran.
    private var symbol: String {
        switch style {
        case .none: "rectangle.slash"
        case .capsuleTop: "inset.filled.topthird.rectangle"
        case .capsuleBottom: "inset.filled.bottomthird.rectangle"
        }
    }
}

#if DEBUG
#Preview("Général") {
    SettingsGeneralPane(display: .preview())
        .environment(AppModel.shared)
        .frame(width: 520, height: 560)
}
#endif

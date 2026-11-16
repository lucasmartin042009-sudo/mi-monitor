// Enregistreur de raccourci clavier pour les profils.
// Capture la prochaine touche via un moniteur d'événements local (fenêtre Réglages au premier plan),
// puis la convertit en KeyCombo : code de touche + modificateurs au format Carbon (ceux qu'attend
// RegisterEventHotKey dans HotKeyCenter) et libellé prêt à afficher (« ⌃⌥1 »).

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct KeyRecorderView: View {
    @Environment(AppModel.self) private var model
    @Binding var combo: KeyCombo?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        // L'indice s'affiche sous la rangée (dans la mise en page, pour ne pas chevaucher la ligne suivante).
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if isRecording {
                    Text("Tapez un raccourci…")
                        .foregroundStyle(Color.accentColor)
                } else if let combo {
                    SettingsKeyCap(text: combo.display)
                    Button {
                        self.combo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Supprimer le raccourci")
                    .accessibilityLabel("Supprimer le raccourci")
                } else {
                    Text("Aucun")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(isRecording ? "Annuler" : "Enregistrer un raccourci") {
                    if isRecording { stop() } else { hint = nil; start() }
                }
                .buttonStyle(.glass)
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    // MARK: - Capture

    private func start() {
        stop()
        hint = nil
        isRecording = true
        // Un raccourci global déjà enregistré (Carbon) passe avant le moniteur local :
        // on les suspend le temps de la saisie, sinon taper ⌃⌥1 appliquerait le profil Nuit.
        model.hotKeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Le moniteur local est appelé sur le fil principal.
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { model.hotKeys.resume() }
        isRecording = false
        hint = nil
    }

    /// Traite une touche ; renvoie vrai si l'événement est consommé.
    private func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = Int(event.keyCode)

        // Échap seul annule ; ⌫ seul efface le raccourci.
        if flags.intersection([.command, .option, .control, .shift]).isEmpty {
            if keyCode == kVK_Escape { stop(); return true }
            if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete { combo = nil; stop(); return true }
        }

        guard let combo = Self.combo(keyCode: keyCode, flags: flags,
                                     characters: event.charactersIgnoringModifiers) else {
            hint = "Ajoutez ⌘, ⌥ ou ⌃ (sauf touches F1 à F20)."
            NSSound.beep()
            return true
        }
        hint = nil
        self.combo = combo
        stop()
        return true
    }

    // MARK: - Conversion (testable)

    /// Construit un KeyCombo, ou nil si la combinaison n'est pas utilisable comme raccourci global
    /// (il faut ⌘, ⌥ ou ⌃, sauf pour les touches de fonction).
    static func combo(keyCode: Int, flags: NSEvent.ModifierFlags, characters: String?) -> KeyCombo? {
        let isFunctionKey = functionKeyNames[keyCode] != nil
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        guard let key = keyName(keyCode: keyCode, characters: characters) else { return nil }

        var carbon: UInt32 = 0
        var label = ""
        // Ordre d'affichage d'Apple : ⌃ ⌥ ⇧ ⌘.
        if flags.contains(.control) { carbon |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); label += "⌘" }
        return KeyCombo(keyCode: UInt32(keyCode), carbonModifiers: carbon, display: label + key)
    }

    /// Nom affiché d'une touche. Les chiffres de la rangée du haut sont nommés par leur chiffre
    /// (sur un clavier AZERTY, ⌃⌥1 plutôt que ⌃⌥&).
    static func keyName(keyCode: Int, characters: String?) -> String? {
        if let name = functionKeyNames[keyCode] ?? specialKeyNames[keyCode] { return name }
        if let digit = digitKeys[keyCode] { return digit }
        guard let chars = characters?.trimmingCharacters(in: .whitespacesAndNewlines), !chars.isEmpty else { return nil }
        return chars.uppercased()
    }

    private static let digitKeys: [Int: String] = [
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Espace",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
}

#if DEBUG
#Preview("Enregistreur de raccourci") {
    @Previewable @State var combo: KeyCombo? = KeyCombo(keyCode: UInt32(kVK_ANSI_1),
                                                         carbonModifiers: UInt32(controlKey | optionKey),
                                                         display: "⌃⌥1")
    KeyRecorderView(combo: $combo)
        .environment(AppModel.shared)
        .padding()
        .frame(width: 360)
}
#endif

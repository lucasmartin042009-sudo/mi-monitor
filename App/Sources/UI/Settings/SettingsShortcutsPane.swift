// Onglet Raccourcis : présente les deux actions App Intents de l'app, avec leurs paramètres
// en jetons bleus comme dans l'app Raccourcis, et ouvre Raccourcis.

import AppKit
import SwiftUI

struct SettingsShortcutsPane: View {
    @Environment(AppModel.self) private var model
    let display: DisplayController?

    /// Exemples affichés dans les jetons : valeurs réelles quand on les connaît.
    private var brightnessExample: String {
        guard let display, display.hasReadValues else { return SettingsFormat.percent(45) }
        return SettingsFormat.percent(display.brightness)
    }
    private var profileExample: String {
        model.profiles.profile(named: "Nuit")?.name ?? model.profiles.profiles.first?.name ?? "Nuit"
    }

    var body: some View {
        Form {
            Section {
                SettingsIntentRow(symbol: "sun.max.fill", tint: Color(.systemBlue),
                                  phrase: "Régler la luminosité du Mi Monitor à", token: brightnessExample)
                SettingsIntentRow(symbol: "square.stack.3d.up.fill", tint: Color(.systemIndigo),
                                  phrase: "Appliquer le profil", token: profileExample)
            } header: {
                Text("Actions disponibles dans Raccourcis et Spotlight")
            } footer: {
                Text("Les jetons bleus sont modifiables dans l’app Raccourcis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Ouvrir Raccourcis", systemImage: "square.2.layers.3d", action: Self.openShortcuts)
                        .buttonStyle(.glass)
                    Spacer()
                }
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
    }

    /// Ouvre l'app Raccourcis (com.apple.shortcuts).
    static func openShortcuts() {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return }
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Une action App Intent : icône, phrase et paramètre en jeton bleu.
struct SettingsIntentRow: View {
    let symbol: String
    let tint: Color
    let phrase: String
    let token: String

    var body: some View {
        HStack(spacing: 10) {
            SettingsIconSquare(symbol: symbol, tint: tint, size: 22)
            Text(phrase)
            Text(token)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Raccourcis") {
    SettingsShortcutsPane(display: .preview())
        .environment(AppModel.shared)
        .frame(width: 520, height: 400)
}
#endif

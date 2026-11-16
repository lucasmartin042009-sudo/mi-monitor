// Onglet À propos : icône réelle de l'app (Liquid Glass, Icon Composer), version, et
// une section par écran connu avec les informations lues par DDC/CI et EDID
// (nom, micrologiciel, MCCS, n° de série, connexion du Mac, codes VCP pris en charge).

import AppKit
import DDCKit
import SwiftUI

struct SettingsAboutPane: View {
    @Environment(AppModel.self) private var model
    /// Écran imposé (aperçus) ; sinon tous les écrans connus du modèle.
    let display: DisplayController?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Écrans décrits : tous ceux que le modèle connaît (branchés ou non), sinon l'écran imposé.
    private var displays: [DisplayController] {
        let known = model.displays.displays
        if !known.isEmpty { return known }
        return display.map { [$0] } ?? []
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Colonne de gauche : icône de l'app telle que macOS la rend, nom et version.
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text("Mi Monitor")
                    .font(.title3.weight(.semibold))
                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150)
            .padding(.top, 44)

            Form {
                if displays.isEmpty {
                    Section("Écran (lu par DDC/CI et EDID)") {
                        Text(model.displays.hasScanned ? "Aucun écran externe" : "Recherche…")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(displays) { c in
                    SettingsAboutDisplaySection(display: c, showsName: displays.count > 1)
                }
                Section {
                } footer: {
                    Text("DDC sur Apple Silicon inspiré de MonitorControl et m1ddc (MIT).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .monospacedDigit()
            .textSelection(.enabled)
        }
    }
}

/// Section « À propos » d'un écran.
struct SettingsAboutDisplaySection: View {
    let display: DisplayController
    /// Plusieurs écrans : le nom de l'écran sert d'en-tête de section.
    let showsName: Bool

    /// Entrée du Mac sur cet écran (« USB-C (DisplayPort 2) » sur le Mi Monitor).
    private var connectionText: String {
        display.macInput.map { display.longTitle(for: $0) } ?? "—"
    }

    /// Les codes viennent-ils de la chaîne de capacités (sinon des lectures réussies) ?
    private var codesFromCapabilities: Bool { !(display.capabilities?.supportedCodes.isEmpty ?? true) }

    /// Codes VCP annoncés dans la chaîne de capacités ; à défaut, ceux dont la lecture a réussi.
    private var codes: [UInt8] {
        if codesFromCapabilities, let caps = display.capabilities { return caps.supportedCodes }
        return Control.allCases.filter { display.readableControls.contains($0) }.map(\.code).sorted()
    }

    /// « 10 12 14 16 … » en hexadécimal.
    private var codesText: String {
        codes.isEmpty ? "—" : codes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Réglages que l'app pilote sur cet écran, dans l'ordre habituel.
    private var controlsText: String {
        let list = Control.allCases.filter { display.supportedControls.contains($0) }.map(\.title)
        return list.isEmpty ? "—" : list.joined(separator: ", ")
    }

    var body: some View {
        Section {
            LabeledContent("Nom", value: display.displayName)
            LabeledContent("État", value: display.connection.label)
            LabeledContent("Micrologiciel", value: display.firmware ?? "—")
            LabeledContent("Version MCCS", value: display.mccsVersion ?? "—")
            LabeledContent("Numéro de série", value: display.identity.alphanumericSerial ?? "—")
            LabeledContent("Connexion", value: connectionText)
            LabeledContent {
                Text(codesText)
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("Codes VCP")
                Text(codesFromCapabilities ? "Annoncés par l’écran" : "Lus avec succès (capacités illisibles)")
            }
            LabeledContent {
                Text(controlsText)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("Réglages pris en charge")
            }
        } header: {
            Text(showsName ? display.displayName : "Écran (lu par DDC/CI et EDID)")
        }
    }
}

#if DEBUG
#Preview("À propos") {
    SettingsAboutPane(display: .preview())
        .environment(AppModel.shared)
        .frame(width: 520, height: 400)
}
#endif

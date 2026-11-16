// Réglages pilotables par DDC et valeurs VCP génériques (préréglages couleur, sources d'entrée).
// Ce que chaque écran accepte vraiment se lit dans ses capacités (DisplayController.supportedControls).

import Foundation
import DDCKit

/// Un réglage continu ou discret écrit par DDC.
nonisolated enum Control: CaseIterable, Hashable, Sendable {
    case brightness, contrast, volume, colorPreset, redGain, greenGain, blueGain, input, power

    var code: UInt8 {
        switch self {
        case .brightness: VCPCode.brightness
        case .contrast: VCPCode.contrast
        case .volume: VCPCode.volume
        case .colorPreset: VCPCode.colorPreset
        case .redGain: VCPCode.redGain
        case .greenGain: VCPCode.greenGain
        case .blueGain: VCPCode.blueGain
        case .input: VCPCode.inputSource
        case .power: VCPCode.powerMode
        }
    }

    var title: String {
        switch self {
        case .brightness: "Luminosité"
        case .contrast: "Contraste"
        case .volume: "Son"
        case .colorPreset: "Couleur"
        case .redGain: "Rouge"
        case .greenGain: "Vert"
        case .blueGain: "Bleu"
        case .input: "Source"
        case .power: "Alimentation"
        }
    }

    /// Nom du SF Symbol associé.
    var symbol: String {
        switch self {
        case .brightness: "sun.max.fill"
        case .contrast: "circle.lefthalf.filled"
        case .volume: "speaker.wave.2.fill"
        case .colorPreset: "thermometer.medium"
        case .redGain, .greenGain, .blueGain: "slider.horizontal.3"
        case .input: "cable.connector"
        case .power: "power"
        }
    }
}

/// Préréglage couleur (valeur du code VCP 0x14). Valeur brute quelconque : chaque écran annonce
/// les siens dans sa chaîne de capacités ; les constantes ci-dessous sont les valeurs MCCS standard.
/// Encodé comme un simple entier (compatible avec les profils enregistrés quand c'était une énumération).
nonisolated struct ColorPreset: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    let rawValue: UInt16

    init(rawValue: UInt16) { self.rawValue = rawValue }

    static let sRGB = ColorPreset(rawValue: 0x01)
    static let native = ColorPreset(rawValue: 0x02)
    static let warm4000K = ColorPreset(rawValue: 0x03)
    static let warm5000K = ColorPreset(rawValue: 0x04)
    static let neutral6500K = ColorPreset(rawValue: 0x05)
    static let cool7500K = ColorPreset(rawValue: 0x06)
    static let cool8200K = ColorPreset(rawValue: 0x07)
    static let cool9300K = ColorPreset(rawValue: 0x08)
    static let cool10000K = ColorPreset(rawValue: 0x09)
    static let cool11500K = ColorPreset(rawValue: 0x0A)
    /// Utilisateur 1 (le seul mode Utilisateur du Mi Monitor).
    static let user = ColorPreset(rawValue: 0x0B)
    static let user2 = ColorPreset(rawValue: 0x0C)
    static let user3 = ColorPreset(rawValue: 0x0D)

    var id: UInt16 { rawValue }

    /// Modes Utilisateur 1 à 3 : les gains R/V/B y sont réglables.
    var isUser: Bool { (0x0B...0x0D).contains(rawValue) }

    /// Température de couleur en kelvins, pour les préréglages qui en ont une.
    var kelvin: Int? {
        switch rawValue {
        case 0x03: 4000
        case 0x04: 5000
        case 0x05: 6500
        case 0x06: 7500
        case 0x07: 8200
        case 0x08: 9300
        case 0x09: 10000
        case 0x0A: 11500
        default: nil
        }
    }

    /// Titre générique (MCCS) ; un écran peut le surcharger (DisplayController.title(for:)).
    var title: String {
        switch rawValue {
        case 0x01: "sRGB"
        case 0x02: "Natif"
        case 0x0B: "Utilisateur 1"
        case 0x0C: "Utilisateur 2"
        case 0x0D: "Utilisateur 3"
        default:
            if let kelvin { "\(kelvin) K" } else { String(format: "Préréglage 0x%02X", rawValue) }
        }
    }

    /// Qualificatif court affiché sous le titre (« Chaud », « Neutre », « Froid »…).
    var subtitle: String {
        if isUser { return "R · V · B" }
        switch rawValue {
        case 0x01: return "Standard"
        case 0x02: return "Écran"
        default:
            guard let kelvin else { return "" }
            return kelvin < 6500 ? "Chaud" : (kelvin == 6500 ? "Neutre" : "Froid")
        }
    }

    // Encodage : un simple entier, comme l'ancienne énumération (profils.json existants).
    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt16.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Source d'entrée (valeur du code VCP 0x60). Même principe que ColorPreset.
nonisolated struct InputSource: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    let rawValue: UInt16

    init(rawValue: UInt16) { self.rawValue = rawValue }

    static let vga1 = InputSource(rawValue: 0x01)
    static let vga2 = InputSource(rawValue: 0x02)
    static let dvi1 = InputSource(rawValue: 0x03)
    static let dvi2 = InputSource(rawValue: 0x04)
    static let displayPort1 = InputSource(rawValue: 0x0F)
    /// L'entrée USB-C du Mi Monitor est câblée en DisplayPort 2 : c'est celle du Mac.
    static let displayPort2 = InputSource(rawValue: 0x10)
    static let hdmi1 = InputSource(rawValue: 0x11)
    static let hdmi2 = InputSource(rawValue: 0x12)
    static let usbC = InputSource(rawValue: 0x1B)

    var id: UInt16 { rawValue }

    /// Titre générique (MCCS) ; un écran peut le surcharger (DisplayQuirks, ex. Mi Monitor 0x10 → « USB-C »).
    var title: String {
        switch rawValue {
        case 0x01: "VGA 1"
        case 0x02: "VGA 2"
        case 0x03: "DVI 1"
        case 0x04: "DVI 2"
        case 0x0F: "DisplayPort 1"
        case 0x10: "DisplayPort 2"
        case 0x11: "HDMI 1"
        case 0x12: "HDMI 2"
        case 0x1B: "USB-C"
        default: String(format: "Entrée 0x%02X", rawValue)
        }
    }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt16.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// État de la liaison DDC avec l'écran.
enum ConnectionState: Equatable, Sendable {
    /// Première lecture en cours.
    case connecting
    case connected
    /// L'écran est vu par macOS mais ne répond pas en DDC/CI.
    case unresponsive(reason: String)
    /// Mis en veille par l'app (0xD6 = 05).
    case asleep
    /// L'écran n'est plus branché ; on garde le contrôleur pour le retrouver.
    case disconnected

    var isUsable: Bool { self == .connected }

    var label: String {
        switch self {
        case .connecting: "Connexion…"
        case .connected: "Connecté"
        case .unresponsive: "DDC/CI ne répond pas"
        case .asleep: "En veille"
        case .disconnected: "Débranché"
        }
    }
}

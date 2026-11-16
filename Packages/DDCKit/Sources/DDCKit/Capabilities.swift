// Analyse de la chaîne de capacités MCCS, par exemple :
// (prot(monitor)type(LCD)model(Mi)cmds(01 02 03 07 0C F3)vcp(10 12 14(05 06 08) 60(0F 11 12) 62)mccs_ver(2.2))

import Foundation

public struct Capabilities: Sendable, Equatable {
    /// Codes VCP annoncés, avec la liste des valeurs permises quand l'écran la donne (ex. 0x60 → sources).
    public var vcp: [UInt8: [UInt16]]
    public var model: String?
    public var type: String?
    public var mccsVersion: String?
    /// Version du micrologiciel (section mpu_ver, ex. « FW: V1.0.10 » → « V1.0.10 »).
    public var firmware: String?
    public var raw: String

    public init(parsing raw: String) {
        self.raw = raw
        self.model = Self.section("model", in: raw)
        self.type = Self.section("type", in: raw)
        self.mccsVersion = Self.section("mccs_ver", in: raw)
        self.firmware = Self.section("mpu_ver", in: raw).map {
            $0.replacingOccurrences(of: "FW:", with: "").trimmingCharacters(in: .whitespaces)
        }
        self.vcp = Self.section("vcp", in: raw).map(Self.parseVCPList) ?? [:]
    }

    public var supportedCodes: [UInt8] { vcp.keys.sorted() }

    /// Contenu entre parenthèses de `name(...)`, en respectant l'imbrication.
    static func section(_ name: String, in s: String) -> String? {
        let chars = Array(s)
        let key = Array(name + "(")
        var i = 0
        while i + key.count <= chars.count {
            // Le nom doit être précédé d'un séparateur pour éviter « vcp » dans « vcpname ».
            let boundary = i == 0 || !chars[i - 1].isLetter
            if boundary, Array(chars[i..<(i + key.count)]) == key {
                var depth = 1
                var j = i + key.count
                let start = j
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 }
                    if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                let end = depth == 0 ? j - 1 : j
                return String(chars[start..<end])
            }
            i += 1
        }
        return nil
    }

    /// « 10 12 14(05 06 08) 60(0F 11 12) » → [0x10: [], 0x12: [], 0x14: [5,6,8], 0x60: [...]]
    /// Tolère les codes collés (« 1012 ») que certains écrans produisent.
    static func parseVCPList(_ s: String) -> [UInt8: [UInt16]] {
        var result: [UInt8: [UInt16]] = [:]
        var lastCode: UInt8?
        var token = ""
        var inValues = false
        var values: [UInt16] = []

        func flushToken() {
            guard !token.isEmpty else { return }
            // Découpe en paires hexadécimales.
            var t = Substring(token)
            while t.count >= 2 {
                let pair = t.prefix(2)
                t = t.dropFirst(2)
                guard let v = UInt8(pair, radix: 16) else { continue }
                if inValues { values.append(UInt16(v)) } else { result[v] = []; lastCode = v }
            }
            token = ""
        }

        for c in s {
            switch c {
            case "(":
                flushToken(); inValues = true; values = []
            case ")":
                flushToken()
                if inValues, let code = lastCode { result[code] = values }
                inValues = false
            case " ", "\t", "\n", "\r":
                flushToken()
            default:
                if c.isHexDigit { token.append(c) } else { flushToken() }
            }
        }
        flushToken()
        return result
    }
}

/// Noms lisibles des codes VCP les plus courants (MCCS 2.2).
public enum VCPCode {
    public static let brightness: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let colorPreset: UInt8 = 0x14
    public static let redGain: UInt8 = 0x16
    public static let greenGain: UInt8 = 0x18
    public static let blueGain: UInt8 = 0x1A
    public static let inputSource: UInt8 = 0x60
    public static let volume: UInt8 = 0x62
    public static let audioMute: UInt8 = 0x8D
    public static let powerMode: UInt8 = 0xD6

    public static func name(_ code: UInt8) -> String {
        switch code {
        case 0x02: "Nouvelle valeur de contrôle"
        case 0x04: "Réinitialisation usine"
        case 0x05: "Réinitialisation luminosité/contraste"
        case 0x08: "Réinitialisation couleur"
        case 0x0B: "Pas de température de couleur"
        case 0x0C: "Température de couleur"
        case 0x10: "Luminosité"
        case 0x12: "Contraste"
        case 0x14: "Préréglage couleur"
        case 0x16: "Gain rouge"
        case 0x18: "Gain vert"
        case 0x1A: "Gain bleu"
        case 0x52: "Code VCP actif"
        case 0x60: "Source d'entrée"
        case 0x62: "Volume"
        case 0x6C: "Niveau de noir rouge"
        case 0x6E: "Niveau de noir vert"
        case 0x70: "Niveau de noir bleu"
        case 0x72: "Gamma"
        case 0x86: "Mise à l'échelle"
        case 0x87: "Netteté"
        case 0x8D: "Sourdine"
        case 0xAC: "Fréquence horizontale"
        case 0xAE: "Fréquence verticale"
        case 0xB0: "Enregistrer / restaurer réglages"
        case 0xB2: "Ordre des sous-pixels"
        case 0xB6: "Technologie d'affichage"
        case 0xC0: "Heures d'utilisation"
        case 0xC6: "Version d'application"
        case 0xC8: "Contrôleur d'affichage"
        case 0xC9: "Version firmware"
        case 0xCA: "OSD"
        case 0xCC: "Langue de l'OSD"
        case 0xD6: "Mode d'alimentation"
        case 0xDC: "Mode d'image"
        case 0xDF: "Version VCP"
        default: "Code fabricant / inconnu"
        }
    }

    /// Noms des sources d'entrée (valeurs du code 0x60).
    public static func inputName(_ value: UInt16) -> String {
        switch value & 0xFF {
        case 0x01: "VGA 1"
        case 0x03: "DVI 1"
        case 0x0F: "DisplayPort 1"
        case 0x10: "DisplayPort 2"
        case 0x11: "HDMI 1"
        case 0x12: "HDMI 2"
        case 0x1B: "USB-C"
        default: String(format: "Entrée 0x%02X", value)
        }
    }

    /// Noms des préréglages couleur (valeurs du code 0x14).
    public static func colorPresetName(_ value: UInt16) -> String {
        switch value & 0xFF {
        case 0x01: "sRGB"
        case 0x02: "Natif"
        case 0x03: "4000 K"
        case 0x04: "5000 K"
        case 0x05: "6500 K"
        case 0x06: "7500 K"
        case 0x08: "9300 K"
        case 0x09: "10000 K"
        case 0x0B: "Utilisateur 1"
        case 0x0C: "Utilisateur 2"
        case 0x0D: "Utilisateur 3"
        default: String(format: "Préréglage 0x%02X", value)
        }
    }
}

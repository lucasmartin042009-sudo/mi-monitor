// Encodage / décodage des trames DDC/CI (norme VESA DDC/CI 1.1 + MCCS).
// Fonctions pures, sans accès matériel : elles sont couvertes par les tests unitaires.

import Foundation

public enum DDCPacket {
    /// Adresse I2C de destination côté écran (0x37 << 1).
    public static let displayAddress: UInt8 = 0x6E
    /// Adresse « source » de l'hôte, envoyée comme premier octet par IOAVServiceWriteI2C.
    public static let hostAddress: UInt8 = 0x51
    /// Adresse virtuelle utilisée pour le calcul de la somme de contrôle des réponses.
    public static let replyChecksumSeed: UInt8 = 0x50

    // Codes d'opération DDC/CI.
    public static let opGetVCP: UInt8 = 0x01
    public static let opGetVCPReply: UInt8 = 0x02
    public static let opSetVCP: UInt8 = 0x03
    public static let opCapabilitiesRequest: UInt8 = 0xF3
    public static let opCapabilitiesReply: UInt8 = 0xE3

    /// XOR de tous les octets, en partant d'une graine.
    public static func checksum(seed: UInt8, _ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    /// Construit la trame à passer à IOAVServiceWriteI2C (l'octet 0x51 est ajouté par le pilote,
    /// il entre donc dans la somme de contrôle sans figurer dans le tampon).
    /// Format : [0x80 | longueur] [charge utile…] [somme de contrôle]
    public static func frame(payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x80 | UInt8(payload.count)] + payload
        out.append(checksum(seed: displayAddress ^ hostAddress, out))
        return out
    }

    public static func getVCPRequest(_ code: UInt8) -> [UInt8] {
        frame(payload: [opGetVCP, code])
    }

    public static func setVCPRequest(_ code: UInt8, value: UInt16) -> [UInt8] {
        frame(payload: [opSetVCP, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    public static func capabilitiesRequest(offset: UInt16) -> [UInt8] {
        frame(payload: [opCapabilitiesRequest, UInt8(offset >> 8), UInt8(offset & 0xFF)])
    }

    // MARK: - Réponses

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case tooShort
        case badChecksum
        case unexpectedOpcode(UInt8)
        case unsupportedCode(UInt8)
        case codeMismatch(expected: UInt8, got: UInt8)

        public var description: String {
            switch self {
            case .tooShort: "réponse trop courte"
            case .badChecksum: "somme de contrôle invalide"
            case .unexpectedOpcode(let o): String(format: "opcode inattendu 0x%02X", o)
            case .unsupportedCode(let c): String(format: "code VCP 0x%02X non supporté par l'écran", c)
            case .codeMismatch(let e, let g): String(format: "code VCP 0x%02X reçu au lieu de 0x%02X", g, e)
            }
        }
    }

    /// Vérifie la somme de contrôle d'une réponse : XOR(0x50, octets[0..<n-1]) == octets[n-1].
    /// La longueur utile est lue dans l'octet 1 pour ignorer le remplissage éventuel.
    public static func validatedReply(_ raw: [UInt8]) throws(DecodeError) -> [UInt8] {
        guard raw.count >= 3 else { throw .tooShort }
        let length = Int(raw[1] & 0x7F)
        let total = 2 + length + 1
        guard raw.count >= total else { throw .tooShort }
        let body = Array(raw[0..<total])
        guard checksum(seed: replyChecksumSeed, body.dropLast()) == body.last else { throw .badChecksum }
        return body
    }

    /// Réponse à « Get VCP » : [0x6E] [0x88] [0x02] [résultat] [code] [type] [maxH] [maxL] [curH] [curL] [chk]
    public static func decodeGetVCPReply(_ raw: [UInt8], expecting code: UInt8) throws(DecodeError) -> VCPValue {
        let r = try validatedReply(raw)
        guard r.count >= 11 else { throw .tooShort }
        guard r[2] == opGetVCPReply else { throw .unexpectedOpcode(r[2]) }
        guard r[3] == 0 else { throw .unsupportedCode(code) }
        guard r[4] == code else { throw .codeMismatch(expected: code, got: r[4]) }
        let max = UInt16(r[6]) << 8 | UInt16(r[7])
        let current = UInt16(r[8]) << 8 | UInt16(r[9])
        return VCPValue(current: current, maximum: max, isMomentary: r[5] == 1)
    }

    /// Réponse à la demande de capacités : [0x6E] [0x80|len] [0xE3] [offH] [offL] [données…] [chk]
    /// Renvoie le décalage et le fragment de texte reçu (vide = fin de la chaîne).
    public static func decodeCapabilitiesReply(_ raw: [UInt8]) throws(DecodeError) -> (offset: UInt16, chunk: [UInt8]) {
        let r = try validatedReply(raw)
        guard r.count >= 6 else { throw .tooShort }
        guard r[2] == opCapabilitiesReply else { throw .unexpectedOpcode(r[2]) }
        let offset = UInt16(r[3]) << 8 | UInt16(r[4])
        return (offset, Array(r[5..<(r.count - 1)]))
    }
}

/// Valeur d'un code VCP lue sur l'écran.
public struct VCPValue: Equatable, Sendable, CustomStringConvertible {
    public var current: UInt16
    public var maximum: UInt16
    /// Type « momentané » (bouton) plutôt que « paramètre ».
    public var isMomentary: Bool

    public init(current: UInt16, maximum: UInt16, isMomentary: Bool = false) {
        self.current = current
        self.maximum = maximum
        self.isMomentary = isMomentary
    }

    public var description: String { "\(current)/\(maximum)" }
}

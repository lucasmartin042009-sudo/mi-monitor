// Écran simulé (Debug uniquement) : permet d'essayer l'interface à deux écrans avant l'arrivée
// du second écran. Activé par la variable d'environnement MIMONITOR_FAKE_DISPLAY=1.
// Les valeurs vivent en mémoire, avec de petites latences ; aucune écriture ne part sur un vrai bus.
// Capacités plausibles d'un AOC Q27G3XMN : pas d'alimentation (0xD6), préréglages sRGB, 6500 K,
// 7500 K, 9300 K et Utilisateur, entrées DisplayPort 1, HDMI 1 et HDMI 2.

#if DEBUG
import DDCKit
import Foundation

actor SimulatedDDC: DDCAccess {
    /// Identifiant stable de l'écran simulé (sélection et ordre mémorisés comme pour un vrai écran).
    nonisolated static let displayID = "simulated-aoc-q27g3xmn"

    /// Chaîne de capacités annoncée.
    nonisolated static let capabilitiesString =
        "(prot(monitor)type(LCD)model(Q27G3XMN)cmds(01 02 03 07 0C F3)"
        + "vcp(10 12 14(01 05 06 08 0B) 16 18 1A 60(0F 11 12) 62)mccs_ver(2.2)mpu_ver(FW: V0.0.1-sim))"

    /// Valeurs courantes par code VCP (maximum 100 pour tous).
    private(set) var values: [UInt8: UInt16] = [
        0x10: 70, 0x12: 50, 0x14: 0x05, 0x16: 50, 0x18: 50, 0x1A: 50, 0x60: 0x11, 0x62: 30,
    ]
    /// Latence simulée d'une lecture / d'une écriture.
    private let latency: Duration

    init(latency: Duration = .milliseconds(40)) {
        self.latency = latency
    }

    func read(_ code: UInt8) async throws -> VCPValue {
        try await Task.sleep(for: latency)
        // Code non annoncé : l'écran répond « non pris en charge », comme un vrai écran.
        guard let value = values[code] else { throw DDCError.decode(.unsupportedCode(code)) }
        return VCPValue(current: value, maximum: 100)
    }

    func write(_ code: UInt8, value: UInt16) async throws {
        try await Task.sleep(for: latency)
        guard values[code] != nil else { throw DDCError.decode(.unsupportedCode(code)) }
        values[code] = value
    }

    func capabilities() async throws -> Capabilities {
        try await Task.sleep(for: latency * 5)
        return Capabilities(parsing: Self.capabilitiesString)
    }

    /// Contrôleur prêt à l'emploi, traité par l'interface comme un écran normal.
    @MainActor
    static func makeController(defaults: UserDefaults = .standard) -> DisplayController {
        DisplayController(id: displayID, name: "AOC Q27G3XMN (simulé)",
                          identity: DisplayIdentity(productName: "AOC Q27G3XMN (simulé)", manufacturer: "AOC",
                                                    alphanumericSerial: displayID),
                          displayID: nil, access: SimulatedDDC(), defaults: defaults, isSimulated: true)
    }
}
#endif

// Exécute les appels DDC bloquants (bus I2C lent) sur une file série dédiée à l'écran,
// pour ne jamais bloquer le fil principal ni le pool de tâches Swift.
//
// Un seul DDCWorker par écran pendant toute la vie de l'app : après un réveil ou un
// rebranchement, on lui confie le nouveau DDCDevice (replace) au lieu d'en créer un second.
// Ainsi toutes les entrées-sorties restent sérialisées sur une seule file, même si une
// ancienne relecture est encore en cours quand un nouveau balayage rattache l'écran.

import Dispatch
import DDCKit

/// Abstraction testable de l'accès DDC (le contrôleur ne voit que ce protocole).
nonisolated protocol DDCAccess: Sendable {
    func read(_ code: UInt8) async throws -> VCPValue
    func write(_ code: UInt8, value: UInt16) async throws
    func capabilities() async throws -> Capabilities
}

actor DDCWorker: DDCAccess {
    private var device: DDCDevice
    private let queue: DispatchSerialQueue

    /// L'acteur s'exécute sur sa propre file série : les appels bloquants n'occupent pas le pool coopératif.
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(device: DDCDevice, label: String) {
        self.device = device
        self.queue = DispatchSerialQueue(label: "ddc.\(label)", qos: .userInitiated)
    }

    /// Remplace le périphérique (service IOAV recréé par macOS) en gardant le rythme imposé
    /// à l'écran (dernière écriture, silence en cours). Exécuté sur la file : jamais pendant un appel.
    func replace(device newDevice: DDCDevice) {
        newDevice.inheritPacing(from: device)
        device = newDevice
    }

    func read(_ code: UInt8) throws -> VCPValue {
        try device.read(code)
    }

    func write(_ code: UInt8, value: UInt16) throws {
        try device.write(code, value: value)
    }

    func capabilities() throws -> Capabilities {
        Capabilities(parsing: try device.capabilitiesString())
    }
}

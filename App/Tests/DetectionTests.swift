// Détection des écrans : reproduit le bug du 16 nov. (écran resté « Débranché » après le démarrage
// de session alors qu'il était branché) et vérifie les nouvelles tentatives automatiques.
import CoreGraphics
import DDCKit
import Foundation
import Testing
@testable import XiaomiDisplay

/// Bus I2C simulé : répond à « Get VCP » pour n'importe quel code, et à la demande de capacités par une chaîne vide.
nonisolated final class AnsweringTransport: I2CTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var lastRequest: [UInt8] = []

    func write(_ bytes: [UInt8]) -> Bool {
        lock.withLock { lastRequest = bytes }
        return true
    }

    func read(count: Int) -> [UInt8]? {
        let request = lock.withLock { lastRequest }
        var reply: [UInt8]
        if request.count >= 3, request[1] == DDCPacket.opGetVCP {
            // [0x6E] [0x88] [0x02] [résultat] [code] [type] [maxH] [maxL] [curH] [curL]
            reply = [0x6E, 0x88, 0x02, 0x00, request[2], 0x00, 0x00, 100, 0x00, 42]
        } else {
            // Capacités : fragment vide = fin de la chaîne.
            reply = [0x6E, 0x83, DDCPacket.opCapabilitiesReply, 0x00, 0x00]
        }
        reply.append(DDCPacket.checksum(seed: DDCPacket.replyChecksumSeed, reply))
        return reply + [UInt8](repeating: 0, count: max(0, count - reply.count))
    }
}

/// Système simulé dont on pilote, balayage après balayage, ce que voient IOKit et CoreGraphics.
nonisolated final class ScriptedSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var _ddcVisible = true
    private var _online = true
    private(set) var scans = 0

    var ddcVisible: Bool {
        get { lock.withLock { _ddcVisible } }
        set { lock.withLock { _ddcVisible = newValue } }
    }
    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }

    static let identity = DisplayIdentity(productName: "Mi Monitor", manufacturer: "XMI", vendorID: 0x61A9,
                                          productID: 0x27A1, alphanumericSerial: "1234560000001")

    var system: DisplaySystem {
        DisplaySystem(
            discover: { [self] in
                lock.withLock { scans += 1 }
                guard ddcVisible else { return [] }
                let device = DDCDevice(transport: AnsweringTransport(), sleep: { _ in })
                return [ExternalDisplay(identity: Self.identity, displayID: 3, device: device)]
            },
            onlineExternals: { [self] in
                online ? [OnlineDisplay(displayID: 3, vendorID: 0x61A9, productID: 0x27A1)] : []
            })
    }
}

@MainActor
@Suite struct DetectionTests {
    func makeManager(_ scripted: ScriptedSystem) -> DisplayManager {
        let manager = DisplayManager(defaults: UserDefaults(suiteName: "tests.detection.\(UUID())")!,
                                     observeSystem: false, system: scripted.system)
        // Tentatives rapides pour le test.
        manager.retryDelays = [.milliseconds(50)]
        return manager
    }

    /// Attend qu'une condition devienne vraie (au plus `timeout`).
    func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Le bug : le service DDC manque un instant alors que l'écran est en ligne.
    /// Avant la correction, l'écran restait « Débranché » ; maintenant il reste connecté.
    @Test func transientDDCGapDoesNotDisconnect() async {
        let scripted = ScriptedSystem()
        let manager = makeManager(scripted)
        await manager.rescanNow()
        let display = manager.displays.first
        #expect(display?.connection == .connected)

        scripted.ddcVisible = false
        await manager.rescanNow()
        #expect(display?.connection == .connected, "un seul balayage manqué ne doit pas débrancher l'écran")

        // Le service revient : les tentatives automatiques le retrouvent sans notification du système.
        scripted.ddcVisible = true
        #expect(await eventually { display?.connection == .connected && scripted.scans >= 3 })
    }

    /// Même si l'écran a fini « Débranché » (trou plus long), il est retrouvé tout seul quand le DDC revient.
    @Test func disconnectedButOnlineDisplayIsRecovered() async {
        let scripted = ScriptedSystem()
        let manager = makeManager(scripted)
        manager.retryDelays = []          // pas de tentative pendant la mise en place
        await manager.rescanNow()
        let display = manager.displays.first

        scripted.ddcVisible = false
        for _ in 0..<DisplayManager.missedScansBeforeDisconnect { await manager.rescanNow() }
        #expect(display?.connection == .disconnected)

        // Le service DDC revient, sans aucune notification : seules les tentatives automatiques peuvent le voir.
        manager.retryDelays = [.milliseconds(50)]
        scripted.ddcVisible = true
        await manager.rescanNow()  // un balayage quelconque relance le cycle de tentatives
        #expect(await eventually { display?.connection == .connected })
    }

    /// Un vrai débranchement (CoreGraphics ne voit plus l'écran) est signalé tout de suite.
    @Test func realUnplugDisconnectsImmediately() async {
        let scripted = ScriptedSystem()
        let manager = makeManager(scripted)
        await manager.rescanNow()
        let display = manager.displays.first

        scripted.ddcVisible = false
        scripted.online = false
        await manager.rescanNow()
        #expect(display?.connection == .disconnected)
    }

    /// Écran en ligne et joignable : aucune tentative en boucle.
    @Test func noRetryWhenEverythingIsFine() async throws {
        let scripted = ScriptedSystem()
        let manager = makeManager(scripted)
        await manager.rescanNow()
        let scansAfterFirst = scripted.scans
        try await Task.sleep(for: .milliseconds(400))
        #expect(scripted.scans == scansAfterFirst)
    }
}

// Tests du contrôleur : regroupement des écritures, sourdine émulée, profils.
import Foundation
import Testing
import DDCKit
@testable import XiaomiDisplay

/// Accès DDC simulé qui enregistre les écritures.
actor FakeDDC: DDCAccess {
    var values: [UInt8: UInt16] = [0x10: 100, 0x12: 75, 0x62: 6, 0x14: 5, 0x16: 50, 0x18: 50, 0x1A: 50, 0x60: 0x10]
    var writes: [(UInt8, UInt16)] = []
    func read(_ code: UInt8) throws -> VCPValue { VCPValue(current: values[code] ?? 0, maximum: 100) }
    func write(_ code: UInt8, value: UInt16) throws { writes.append((code, value)); values[code] = value }
    func capabilities() throws -> Capabilities { Capabilities(parsing: Self.miMonitorCaps) }
    /// Chaîne de capacités réelle du Mi Monitor (docs/etape0-bilan.md).
    static let miMonitorCaps = "(vcp(02 04 05 08 10 12 14(04 05 08 0B) 16 18 1A 60( 11 12 0F 10) 62 "
        + "CC(01 02 03 04 05 06 07 09 0A 0E 0F 14 18 1A 1E) B0 D6(01 05) DF )prot(monitor)type(LCD)"
        + "cmds(01 02 03 07 0C F3)mccs_ver(2.2a)asset_eep(64)mpu_ver(FW: V1.0.10)model(Model: Mi Monitor)mswhql(1))"
    func writeCount(_ code: UInt8) -> Int { writes.filter { $0.0 == code }.count }
    func lastWrite(_ code: UInt8) -> UInt16? { writes.last { $0.0 == code }?.1 }
}

/// Accès DDC dont les lectures marchent mais les écritures échouent.
actor FailingDDC: DDCAccess {
    func read(_ code: UInt8) throws -> VCPValue { VCPValue(current: code == 0x10 ? 37 : 50, maximum: 100) }
    func write(_ code: UInt8, value: UInt16) throws { throw DDCError.writeFailed }
    func capabilities() throws -> Capabilities { Capabilities(parsing: "") }
}

@MainActor
@Suite struct DisplayControllerTests {
    func make() async -> (DisplayController, FakeDDC) {
        let fake = FakeDDC()
        let c = DisplayController(id: "t", name: "Test", identity: DisplayIdentity(productName: "Test"),
                                  displayID: nil, access: fake, defaults: UserDefaults(suiteName: "tests.\(UUID())")!)
        await c.refresh()
        return (c, fake)
    }

    @Test func refreshReadsValues() async {
        let (c, _) = await make()
        #expect(c.connection == .connected)
        #expect(c.brightness == 100 && c.contrast == 75 && c.volume == 6)
        #expect(c.input == .displayPort2 && c.colorPreset == .neutral6500K)
        #expect(c.firmware == "V1.0.10")
    }

    @Test func slowControlCoalescesWrites() async throws {
        let (c, fake) = await make()
        for v in [10, 20, 30, 40, 50] { c.set(.volume, percent: v) }
        try await Task.sleep(for: .milliseconds(1200))
        // Des valeurs envoyées en rafale sont regroupées : au plus 2 écritures, la dernière gagne.
        let count = await fake.writeCount(0x62)
        #expect((1...2).contains(count))
        #expect(await fake.lastWrite(0x62) == 50)
    }

    @Test func emulatedMuteRestoresVolume() async throws {
        let (c, fake) = await make()
        c.toggleMute()
        #expect(c.isMuted && c.volume == 0)
        try await Task.sleep(for: .milliseconds(1000))
        c.toggleMute()
        #expect(!c.isMuted && c.volume == 6)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(await fake.lastWrite(0x62) == 6)
    }

    @Test func activeProfileComparesUserGains() async throws {
        let (c, _) = await make()
        let store = ProfileStore(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("p-\(UUID()).json"))
        let warm = Profile(name: "Photo chaude", symbol: "photo",
                           settings: .init(colorPreset: .user, gains: .init(red: 60, green: 50, blue: 50)))
        let cold = Profile(name: "Photo froide", symbol: "photo",
                           settings: .init(colorPreset: .user, gains: .init(red: 50, green: 50, blue: 60)))
        store.add(warm); store.add(cold)
        c.apply(cold.settings)
        #expect(store.activeProfile(for: c)?.name == "Photo froide")
        c.set(.redGain, percent: 55)
        #expect(store.activeProfile(for: c) == nil)
        #expect(cold.settings.summary == "R 50 · V 50 · B 60")
    }

    @Test func failedWriteRestoresConfirmedValue() async throws {
        let fake = FailingDDC()
        let c = DisplayController(id: "f", name: "Test", identity: DisplayIdentity(productName: "Test"),
                                  displayID: nil, access: fake, defaults: UserDefaults(suiteName: "tests.\(UUID())")!)
        await c.refresh()
        #expect(c.brightness == 37)
        c.set(.brightness, percent: 80)
        try await Task.sleep(for: .milliseconds(200))
        // L'écriture a échoué : l'écran est resté à 37 %, c'est cette valeur qui doit s'afficher.
        if case .unresponsive = c.connection {} else { Issue.record("état attendu : ne répond pas") }
        #expect(c.brightness == 37)
        #expect(c.failedOperation == "Écriture luminosité (0x10)")
    }

    @Test func activeProfileDetection() async {
        let (c, _) = await make()
        let store = ProfileStore(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("p-\(UUID()).json"))
        #expect(store.activeProfile(for: c) == nil)
        let night = store.profile(named: "Nuit")!
        c.apply(night.settings)
        #expect(store.activeProfile(for: c)?.name == "Nuit")
    }
}

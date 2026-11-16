// Tests du modèle multi-écran : capacités, sélection, noms uniques, profils par écran,
// migration de « Suivre le MacBook » et écran simulé.
import Foundation
import Testing
import DDCKit
@testable import XiaomiDisplay

/// Accès DDC simulé à capacités réglables : un code absent de `values` est refusé par l'écran.
actor CapsDDC: DDCAccess {
    var values: [UInt8: UInt16]
    let caps: String?
    var writes: [(UInt8, UInt16)] = []

    init(caps: String?, values: [UInt8: UInt16]) {
        self.caps = caps
        self.values = values
    }

    func read(_ code: UInt8) throws -> VCPValue {
        guard let v = values[code] else { throw DDCError.decode(.unsupportedCode(code)) }
        return VCPValue(current: v, maximum: 100)
    }

    func write(_ code: UInt8, value: UInt16) throws {
        writes.append((code, value))
        values[code] = value
    }

    func capabilities() throws -> Capabilities {
        guard let caps else { throw DDCError.noResponse(lastError: "capacités illisibles") }
        return Capabilities(parsing: caps)
    }

    func writeCount(_ code: UInt8) -> Int { writes.filter { $0.0 == code }.count }
}

@MainActor
@Suite struct MultiDisplayTests {
    static let standardValues: [UInt8: UInt16] = [0x10: 50, 0x12: 50, 0x14: 0x05, 0x16: 50, 0x18: 50, 0x1A: 50,
                                                  0x60: 0x11, 0x62: 20]

    func suite() -> UserDefaults { UserDefaults(suiteName: "tests.multi.\(UUID())")! }

    func make(id: String, name: String = "Écran", serial: String? = nil, manufacturer: String? = nil,
              caps: String?, values: [UInt8: UInt16] = standardValues,
              defaults: UserDefaults? = nil) async -> (DisplayController, CapsDDC) {
        let fake = CapsDDC(caps: caps, values: values)
        let c = DisplayController(id: id, name: name,
                                  identity: DisplayIdentity(productName: name, manufacturer: manufacturer,
                                                            alphanumericSerial: serial ?? id),
                                  displayID: nil, access: fake, defaults: defaults ?? suite())
        await c.refresh()
        return (c, fake)
    }

    // MARK: Capacités

    @Test func capabilitiesDriveSupportedControls() async {
        // 0x62 annoncé mais refusé à la lecture ; 0x16/18/1A lisibles mais non annoncés ; D6 annoncé.
        var values = Self.standardValues
        values[0x62] = nil
        let (c, _) = await make(id: "a", caps: "(vcp(10 12 14(01 05 0B) 60(11 0F) 62 D6(01 05)))", values: values)
        #expect(c.connection == .connected)
        #expect(c.supportedControls == [.brightness, .contrast, .colorPreset, .input, .power])
        #expect(c.availablePresets == [.sRGB, .neutral6500K, .user])
        #expect(c.availableInputs == [.hdmi1, .displayPort1])
    }

    @Test func unreadableCapabilitiesFallBackToReads() async {
        var values = Self.standardValues
        values[0x62] = nil
        let (c, _) = await make(id: "b", caps: nil, values: values)
        #expect(c.capabilities == nil)
        #expect(c.supportedControls == [.brightness, .contrast, .colorPreset, .redGain, .greenGain, .blueGain, .input])
        // Écran inconnu : seuls le préréglage et l'entrée courants sont proposés.
        #expect(c.availablePresets == [.neutral6500K])
        #expect(c.availableInputs == [.hdmi1])
        // Mi Monitor : ses quatre préréglages et entrées connus.
        let (mi, _) = await make(id: "mi", name: "Mi Monitor", manufacturer: "XMI", caps: nil)
        #expect(mi.availablePresets == [.warm5000K, .neutral6500K, .cool9300K, .user])
        #expect(mi.availableInputs == [.hdmi1, .hdmi2, .displayPort1, .displayPort2])
        #expect(mi.title(for: InputSource.displayPort2) == "USB-C")
        #expect(mi.longTitle(for: .displayPort2) == "USB-C (DisplayPort 2)")
        #expect(mi.title(for: ColorPreset.user) == "Utilisateur")
        #expect(mi.isMacInput(.displayPort2))
    }

    /// Non-régression : le Mi Monitor, avec sa vraie chaîne de capacités, garde exactement
    /// les réglages, tuiles, entrées, silences et double écriture d'avant le multi-écran.
    @Test func miMonitorKeepsItsBehaviour() async {
        let (mi, _) = await make(id: "1234560000001", name: "Mi Monitor", manufacturer: "XMI",
                                 caps: FakeDDC.miMonitorCaps,
                                 values: Self.standardValues.merging([0x60: 0x10]) { $1 })
        #expect(mi.quirks.isKnown && mi.quirks.name == "Mi Monitor")
        #expect(mi.supportedControls == Set(Control.allCases))
        #expect(mi.availablePresets == [.warm5000K, .neutral6500K, .cool9300K, .user])
        #expect(mi.availableInputs == [.hdmi1, .hdmi2, .displayPort1, .displayPort2])
        #expect(mi.macInput == .displayPort2 && mi.isMacInput(mi.input))
        #expect(mi.longTitle(for: mi.input) == "USB-C (DisplayPort 2)")
        // Réglages lents et intervalles d'écriture inchangés.
        for control in Control.allCases {
            let slow = [Control.volume, .redGain, .greenGain, .blueGain].contains(control)
            #expect(mi.isSlow(control) == slow)
            #expect(mi.minimumWriteInterval(for: control) == (slow ? .milliseconds(900) : .milliseconds(60)))
        }
        // Temporisation DDC : double écriture et silences mesurés.
        let t = DisplayQuirks.timing(for: DisplayIdentity(productName: "Mi Monitor", manufacturer: "XMI"))
        #expect(t.writeCycles == 2 && t.attempts == DDCTiming().attempts)
        #expect(t.quietAfterWrite == [0x62: 0.9, 0x16: 0.9, 0x18: 0.9, 0x1A: 0.9, 0x14: 0.6, 0x60: 2.0])
        // Capacités illisibles : la mise en veille reste proposée sur le Mi Monitor (comme avant).
        let (noCaps, _) = await make(id: "mi2", name: "Mi Monitor", manufacturer: "XMI", caps: nil)
        #expect(noCaps.supportedControls.contains(.power))
        let (unknown, _) = await make(id: "u2", caps: nil)
        #expect(!unknown.supportedControls.contains(.power))
    }

    @Test func genericValuesAndSlowControls() async {
        #expect(ColorPreset(rawValue: 0x05).title == "6500 K")
        #expect(ColorPreset(rawValue: 0x0C).isUser && !ColorPreset.cool9300K.isUser)
        #expect(ColorPreset(rawValue: 0x42).title == "Préréglage 0x42")
        #expect(InputSource(rawValue: 0x10).title == "DisplayPort 2")
        #expect(InputSource(rawValue: 0x33).title == "Entrée 0x33")
        let (c, _) = await make(id: "s", caps: nil)
        // Écran inconnu : son et gains lents par prudence.
        #expect(c.isSlow(.volume) && c.isSlow(.redGain) && !c.isSlow(.brightness))
        #expect(c.minimumWriteInterval(for: .volume) == .milliseconds(900))
    }

    @Test func macInputIsLearnedAndRemembered() async {
        let defaults = suite()
        let (c, _) = await make(id: "m", caps: nil, defaults: defaults)
        #expect(c.macInput == .hdmi1)
        // Relancement : l'entrée mémorisée reste, même si l'écran est passé sur une autre entrée.
        var values = Self.standardValues
        values[0x60] = 0x12
        let (again, _) = await make(id: "m", caps: nil, values: values, defaults: defaults)
        #expect(again.input == .hdmi2 && again.macInput == .hdmi1)
    }

    // MARK: Sélection, ordre et noms

    @Test func selectionPersistsAndFallsBack() async {
        let defaults = suite()
        let manager = DisplayManager(defaults: defaults, observeSystem: false)
        let (a, _) = await make(id: "A", caps: nil)
        let (b, _) = await make(id: "B", caps: nil)
        manager.register(a); manager.register(b)
        #expect(manager.selected === a)
        manager.select(b)
        #expect(manager.selected === b)

        // Nouveau lancement : la sélection et l'ordre de première détection sont retrouvés.
        let again = DisplayManager(defaults: defaults, observeSystem: false)
        let (b2, _) = await make(id: "B", caps: nil)
        let (a2, _) = await make(id: "A", caps: nil)
        again.register(b2); again.register(a2)
        #expect(again.displays.map(\.id) == ["A", "B"])
        #expect(again.selectedID == "B" && again.selected === b2)
        // Écran sélectionné débranché : repli sur le premier connecté.
        b2.markDisconnected()
        #expect(again.selected === a2)
        a2.markDisconnected()
        #expect(again.selected === a2)
    }

    @Test func duplicateNamesGetSerialSuffix() async {
        let manager = DisplayManager(defaults: suite(), observeSystem: false)
        let (a, _) = await make(id: "1", name: "Mi Monitor", serial: "1234560000001", caps: nil)
        let (b, _) = await make(id: "2", name: "Mi Monitor", serial: "1234560009999", caps: nil)
        let (c, _) = await make(id: "3", name: "Q27G3XMN", serial: "ABC", caps: nil)
        manager.register(a)
        #expect(a.displayName == "Mi Monitor")
        manager.register(b); manager.register(c)
        #expect(a.displayName == "Mi Monitor · 0001")
        #expect(b.displayName == "Mi Monitor · 9999")
        #expect(c.displayName == "Q27G3XMN")
    }

    // MARK: Profils

    @Test func legacyProfilesDecodeWithoutDisplayID() throws {
        let json = """
        [{"id":"7D1C4D9E-3C55-4E43-9D8A-0E6C2B7A1F10","name":"Nuit","symbol":"moon.fill",
          "settings":{"colorPreset":4,"brightness":15}},
         {"id":"2B0B8E5A-0C2D-4C5E-8F7A-1A2B3C4D5E6F","name":"Photo","symbol":"photo",
          "settings":{"colorPreset":11,"gains":{"red":60,"green":50,"blue":50}},
          "hotKey":{"keyCode":18,"carbonModifiers":6144,"display":"⌃⌥1"}}]
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("legacy-\(UUID()).json")
        try Data(json.utf8).write(to: url)
        let store = ProfileStore(url: url)
        #expect(store.profiles.count == 2)
        #expect(store.profiles.allSatisfy { $0.displayID == nil })
        #expect(store.profiles[0].settings.colorPreset == .warm5000K)
        #expect(store.profiles[1].settings.colorPreset == .user && store.profiles[1].hotKey?.display == "⌃⌥1")
        // Le préréglage reste encodé comme un simple entier.
        let encoded = String(decoding: try JSONEncoder().encode(store.profiles[0].settings), as: UTF8.self)
        #expect(encoded.contains("\"colorPreset\":4"))
    }

    @Test func activeProfileOnlyConsidersOwnAndGlobalProfiles() async {
        let (c, _) = await make(id: "own", caps: nil)
        let store = ProfileStore(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("p-\(UUID()).json"))
        store.profiles.forEach { store.remove(id: $0.id) }
        store.add(Profile(name: "Autre", symbol: "photo", settings: .init(brightness: 50), displayID: "other"))
        #expect(store.activeProfile(for: c) == nil)
        store.add(Profile(name: "Le mien", symbol: "photo", settings: .init(brightness: 50), displayID: "own"))
        #expect(store.activeProfile(for: c)?.name == "Le mien")
        #expect(store.profiles(for: c).map(\.name) == ["Le mien"])
    }

    @Test func unsupportedPresetIsIgnored() async throws {
        let (c, fake) = await make(id: "u", caps: "(vcp(10 12 14(05 0B) 60(11)))")
        c.apply(ProfileSettings(colorPreset: .warm5000K, brightness: 30))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fake.writeCount(0x14) == 0)
        #expect(await fake.values[0x10] == 30)
        #expect(c.colorPreset == .neutral6500K)
    }

    @Test func appModelAppliesToProfileDisplayOrSelected() async throws {
        let defaults = suite()
        let manager = DisplayManager(defaults: defaults, observeSystem: false)
        let (a, fakeA) = await make(id: "A", caps: nil)
        let (b, fakeB) = await make(id: "B", caps: nil)
        manager.register(a); manager.register(b)
        let model = AppModel(displays: manager, settings: AppSettings(defaults: defaults),
                             profiles: ProfileStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
                                .appendingPathComponent("p-\(UUID()).json")))
        let forB = Profile(name: "B", symbol: "photo", settings: .init(brightness: 40), displayID: "B")
        #expect(model.target(for: forB) === b)
        #expect(model.apply(forB))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fakeB.values[0x10] == 40)
        #expect(await fakeA.writeCount(0x10) == 0)
        // Écran du profil débranché : l'écran sélectionné (A) le reçoit.
        b.markDisconnected()
        let global = Profile(name: "G", symbol: "photo", settings: .init(brightness: 20))
        #expect(model.target(for: forB) === a && model.target(for: global) === a)
        #expect(model.apply(forB))
        a.markDisconnected()
        #expect(!model.apply(global))
    }

    /// Écran du profil branché mais en veille : il reste la cible (rien n'est appliqué),
    /// le profil ne part pas sur l'écran sélectionné.
    @Test func profileDisplayAsleepIsNotReplacedBySelected() async throws {
        let defaults = suite()
        let manager = DisplayManager(defaults: defaults, observeSystem: false)
        let (a, fakeA) = await make(id: "A", caps: nil)
        let (b, _) = await make(id: "B", caps: nil)
        manager.register(a); manager.register(b)
        manager.select(a)
        let model = AppModel(displays: manager, settings: AppSettings(defaults: defaults),
                             profiles: ProfileStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
                                .appendingPathComponent("p-\(UUID()).json")))
        #expect(await b.setPower(on: false))
        let forB = Profile(name: "B", symbol: "photo", settings: .init(brightness: 40), displayID: "B")
        #expect(model.target(for: forB) === b)
        #expect(!model.apply(forB))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fakeA.writeCount(0x10) == 0)
    }

    /// Un réglage absent des capacités (pas de haut-parleur) n'est pas écrit par un profil.
    @Test func profileSkipsUnsupportedControls() async throws {
        var values = Self.standardValues
        values[0x62] = nil
        let (c, fake) = await make(id: "s", caps: "(vcp(10 12 14(05 0B) 60(11)))", values: values)
        #expect(!c.supportedControls.contains(.volume))
        c.apply(ProfileSettings(brightness: 25, volume: 30))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fake.writeCount(0x62) == 0)
        #expect(await fake.values[0x10] == 25)
    }

    // MARK: Préférences

    @Test func followMacBookMigratesToSelectedDisplay() {
        let defaults = suite()
        defaults.set(true, forKey: "followMacBook")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.followMacBookDisplays.isEmpty && settings.hasPendingFollowMacBookMigration)
        #expect(defaults.object(forKey: "followMacBook") == nil)
        settings.completeFollowMacBookMigration(selectedID: nil)
        #expect(settings.hasPendingFollowMacBookMigration)
        settings.completeFollowMacBookMigration(selectedID: "mi")
        #expect(settings.followMacBookDisplays == ["mi"] && !settings.hasPendingFollowMacBookMigration)
        #expect(AppSettings(defaults: defaults).followsMacBook("mi"))

        // Ancien réglage coupé : rien à migrer.
        let off = suite()
        off.set(false, forKey: "followMacBook")
        let offSettings = AppSettings(defaults: off)
        #expect(!offSettings.hasPendingFollowMacBookMigration && offSettings.followMacBookDisplays.isEmpty)
    }

    // MARK: Écran simulé

    @Test func simulatedDisplayBehavesLikeARealOne() async throws {
        let c = SimulatedDDC.makeController(defaults: suite())
        await c.refresh()
        #expect(c.connection == .connected && c.isSimulated)
        #expect(c.displayName == "AOC Q27G3XMN (simulé)")
        #expect(c.supportedControls == [.brightness, .contrast, .volume, .colorPreset, .redGain, .greenGain,
                                        .blueGain, .input])
        #expect(c.availablePresets == [.sRGB, .neutral6500K, .cool7500K, .cool9300K, .user])
        #expect(c.availableInputs == [.displayPort1, .hdmi1, .hdmi2])
        #expect(c.macInput == .hdmi1 && c.brightness == 70)
        c.set(.brightness, percent: 33)
        try await Task.sleep(for: .milliseconds(200))
        await c.refresh()
        #expect(c.brightness == 33)
        // Seul écran : il est la cible par défaut.
        let manager = DisplayManager(defaults: suite(), observeSystem: false)
        manager.register(c)
        #expect(manager.selected === c)
    }

    /// L'écran simulé, enregistré avant le premier balayage, passe après les vrais écrans
    /// et n'entre pas dans l'ordre mémorisé.
    @Test func simulatedDisplayComesAfterRealOnes() async {
        let defaults = suite()
        let manager = DisplayManager(defaults: defaults, observeSystem: false)
        let fake = SimulatedDDC.makeController(defaults: suite())
        await fake.refresh()
        manager.register(fake)
        let (mi, _) = await make(id: "mi", name: "Mi Monitor", manufacturer: "XMI", caps: nil)
        manager.register(mi)
        #expect(manager.displays.map(\.id) == ["mi", SimulatedDDC.displayID])
        #expect(manager.selected === mi)
        #expect(defaults.stringArray(forKey: "displayOrder") == ["mi"])
    }
}

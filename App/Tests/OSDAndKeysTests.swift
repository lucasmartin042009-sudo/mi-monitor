// Tests du module clavier et OSD : décodage des touches multimédia, actions, jauge, placement.
import CoreGraphics
import Foundation
import Testing
@testable import XiaomiDisplay

@MainActor
@Suite struct OSDAndKeysTests {
    /// Fabrique un data1 comme le fait IOHIDSystem : touche << 16 | état << 8 | répétition.
    func data1(_ key: Int, state: Int, repeat r: Bool = false) -> Int {
        (key << 16) | (state << 8) | (r ? 1 : 0)
    }

    @Test func decodesBrightnessUpPress() {
        #expect(AuxKeyEvent.decode(data1: data1(2, state: 0xA)) == AuxKeyEvent(key: .brightnessUp, phase: .down, isRepeat: false))
    }

    @Test func decodesReleaseAndRepeat() {
        #expect(AuxKeyEvent.decode(data1: data1(3, state: 0xB)) == AuxKeyEvent(key: .brightnessDown, phase: .up, isRepeat: false))
        #expect(AuxKeyEvent.decode(data1: data1(0, state: 0xA, repeat: true)) == AuxKeyEvent(key: .soundUp, phase: .down, isRepeat: true))
        #expect(AuxKeyEvent.decode(data1: data1(1, state: 0xA))?.key == .soundDown)
        #expect(AuxKeyEvent.decode(data1: data1(7, state: 0xA))?.key == .mute)
    }

    @Test func ignoresOtherKeysAndStates() {
        // NX_KEYTYPE_PLAY (16), clavier rétroéclairé (21), état inconnu.
        #expect(AuxKeyEvent.decode(data1: data1(16, state: 0xA)) == nil)
        #expect(AuxKeyEvent.decode(data1: data1(21, state: 0xA)) == nil)
        #expect(AuxKeyEvent.decode(data1: data1(2, state: 0x0)) == nil)
    }

    @Test func keyDownBrightnessCodes() {
        #expect(AuxKeyEvent.Key.fromKeyDown(keyCode: 144) == .brightnessUp)
        #expect(AuxKeyEvent.Key.fromKeyDown(keyCode: 145) == .brightnessDown)
        #expect(AuxKeyEvent.Key.fromKeyDown(keyCode: 0) == nil)
    }

    @Test func actions() {
        #expect(KeyAction.action(for: .brightnessUp, stepSize: 6, fine: false) == .step(.brightness, 6))
        #expect(KeyAction.action(for: .soundDown, stepSize: 6, fine: false) == .step(.volume, -6))
        #expect(KeyAction.action(for: .brightnessDown, stepSize: 6, fine: true) == .step(.brightness, -2))
        #expect(KeyAction.action(for: .soundUp, stepSize: 2, fine: true) == .step(.volume, 1))
        #expect(KeyAction.action(for: .mute, stepSize: 6, fine: false) == .toggleMute)
    }

    @Test func notchGrid() {
        // 16 crans : 16 appuis vont exactement de 0 à 100 % (pas de 6,25 %).
        var v = 0
        for _ in 0..<16 { v = KeyAction.notchTarget(current: v, steps: 16, up: true) }
        #expect(v == 100)
        #expect(KeyAction.notchTarget(current: 100, steps: 16, up: true) == 100)
        #expect(KeyAction.notchTarget(current: 0, steps: 16, up: false) == 0)
        // Valeur hors grille (curseur à 37 %) : ramenée au cran le plus proche (6 → 37,5 %) puis ±1 cran.
        #expect(KeyAction.notchTarget(current: 37, steps: 16, up: true) == 44)
        #expect(KeyAction.notchTarget(current: 37, steps: 16, up: false) == 31)
        #expect(AuxKeyEvent.Key.soundUp.isSound && AuxKeyEvent.Key.mute.isSound && !AuxKeyEvent.Key.brightnessUp.isSound)
    }

    @Test func gaugeMatchesMockup() {
        // Maquette : 45 % → 7 crans, 15 % → 2, 12 % → 2, sourdine → 0 et « — ».
        #expect(OSDContent.filledNotches(value: 45, steps: 16) == 7)
        #expect(OSDContent.filledNotches(value: 15, steps: 16) == 2)
        #expect(OSDContent.filledNotches(value: 12, steps: 16) == 2)
        #expect(OSDContent.filledNotches(value: 100, steps: 16) == 16)
        let muted = OSDContent(control: .volume, value: 0, isMuted: true, applying: false, steps: 16)
        #expect(muted.title == "Sourdine" && muted.filled == 0 && muted.valueText == "—")
        // « Application… » seulement pour les réglages lents.
        #expect(OSDContent(control: .volume, value: 12, isMuted: false, applying: true, steps: 16).applying)
        #expect(!OSDContent(control: .brightness, value: 45, isMuted: false, applying: true, steps: 16).applying)
        #expect(OSDContent(control: .brightness, value: 15, isMuted: false, applying: false, steps: 16).symbol == "sun.min.fill")
    }

    @Test func placement() {
        let screen = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let visible = CGRect(x: 1512, y: 0, width: 2560, height: 1410) // barre des menus de 30 pt
        let top = OSDController.contentFrame(style: .capsuleTop, screenFrame: screen, visibleFrame: visible)
        #expect(top.midX == screen.midX)
        let expectedTop: CGFloat = 1440 - 30 - 10
        #expect(top.maxY == expectedTop)
        let bottom = OSDController.contentFrame(style: .capsuleBottom, screenFrame: screen, visibleFrame: visible)
        #expect(bottom.minY == 120)
        #expect(bottom.size == OSDCapsule.size && bottom.midX == screen.midX)
    }

    /// « Aucun » par défaut ; l'ancien style centré "system" retombe sur « Aucun ».
    @Test func osdStyleDefaultAndMigration() throws {
        let fresh = try #require(UserDefaults(suiteName: "osd-\(UUID().uuidString)"))
        #expect(AppSettings(defaults: fresh).osdStyle == .none)
        let legacy = try #require(UserDefaults(suiteName: "osd-\(UUID().uuidString)"))
        legacy.set("system", forKey: "osdStyle")
        #expect(AppSettings(defaults: legacy).osdStyle == .none)
        let top = try #require(UserDefaults(suiteName: "osd-\(UUID().uuidString)"))
        top.set("capsuleTop", forKey: "osdStyle")
        #expect(AppSettings(defaults: top).osdStyle == .capsuleTop)
        #expect(!OSDStyle.allCases.map(\.rawValue).contains("system"))
    }

    @Test func brightnessDeduplicatedAcrossPaths() {
        let last = (key: AuxKeyEvent.Key.brightnessUp, viaAux: true, time: 10.0)
        // Même touche par l'autre chemin, aussitôt : doublon.
        #expect(MediaKeyMonitor.isDuplicate(key: .brightnessUp, viaAux: false, at: 10.005, last: last))
        // Même chemin (répétition) ou touche différente ou trop tard : pas un doublon.
        #expect(!MediaKeyMonitor.isDuplicate(key: .brightnessUp, viaAux: true, at: 10.005, last: last))
        #expect(!MediaKeyMonitor.isDuplicate(key: .brightnessDown, viaAux: false, at: 10.005, last: last))
        #expect(!MediaKeyMonitor.isDuplicate(key: .brightnessUp, viaAux: false, at: 10.2, last: last))
        #expect(!MediaKeyMonitor.isDuplicate(key: .brightnessUp, viaAux: false, at: 10.0, last: nil))
    }
}

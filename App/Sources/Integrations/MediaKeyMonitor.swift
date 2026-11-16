// Touches luminosité (et, sur option, son / sourdine) du clavier redirigées vers l'écran externe
// piloté qui se trouve sous le pointeur (comme macOS le fait pour l'écran intégré).
// Les touches son restent à macOS par défaut (réglage keyboardVolumeControl) : le son passe
// d'ordinaire par le Mac, pas par le haut-parleur de l'écran. Même avec l'option, elles ne sont
// prises que si l'écran visé annonce un volume pilotable (code VCP 0x62).
//
// Mécanique : un CGEventTap de session (headInsert, defaultTap) reçoit
//  • les événements NX_SYSDEFINED (type 14), sous-type 8 = NX_SUBTYPE_AUX_CONTROL_BUTTONS,
//    dont data1 code la touche (bits 16–31), l'état (bits 8–15 : 0xA appui, 0xB relâche)
//    et la répétition (bit 0) ;
//  • les keyDown / keyUp 144 / 145, chemin pris par certains claviers pour la luminosité
//    (dédoublonnés si la même frappe arrive aussi en type 14).
// L'événement est avalé (nil) quand l'app l'a traité, sinon il continue vers macOS.
// Le tap exige l'autorisation Accessibilité ; sans elle, on réessaie toutes les 3 s.

import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Décodage (pur, testé)

/// Touche multimédia décodée.
struct AuxKeyEvent: Equatable {
    /// Codes NX_KEYTYPE_* utiles ici.
    enum Key: Int, Equatable {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7

        /// Certains claviers envoient la luminosité en keyDown (codes 144 et 145).
        static func fromKeyDown(keyCode: Int64) -> Key? {
            switch keyCode {
            case 144: .brightnessUp
            case 145: .brightnessDown
            default: nil
            }
        }
    }

    enum Phase: Equatable { case down, up }

    var key: Key
    var phase: Phase
    var isRepeat: Bool

    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS.
    static let auxControlSubtype: Int16 = 8
    /// NX_SYSDEFINED.
    static let systemDefinedType: UInt32 = 14

    /// Décode data1 d'un événement NX_SYSDEFINED / sous-type 8 ; nil si touche ou état inconnus.
    static func decode(data1: Int) -> AuxKeyEvent? {
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard let key = Key(rawValue: keyCode) else { return nil }
        let phase: Phase
        switch state {
        case 0xA: phase = .down
        case 0xB: phase = .up
        default: return nil
        }
        return AuxKeyEvent(key: key, phase: phase, isRepeat: flags & 0x1 != 0)
    }
}

/// Action à mener pour une touche.
enum KeyAction: Equatable {
    case step(Control, Int)
    case toggleMute

    /// `fine` (⌥⇧ enfoncées) : quart de cran, comme macOS.
    static func action(for key: AuxKeyEvent.Key, stepSize: Int, fine: Bool) -> KeyAction {
        let step = fine ? max(1, Int((Double(stepSize) / 4).rounded())) : max(1, stepSize)
        switch key {
        case .brightnessUp: return .step(.brightness, step)
        case .brightnessDown: return .step(.brightness, -step)
        case .soundUp: return .step(.volume, step)
        case .soundDown: return .step(.volume, -step)
        case .mute: return .toggleMute
        }
    }

    /// Valeur visée par un appui « cran entier » : la valeur courante est ramenée au cran le plus
    /// proche, puis on avance d'un cran. Avec 16 crans, 16 appuis vont bien de 0 à 100 %
    /// (un pas entier arrondi à 6 % en demandait 17).
    static func notchTarget(current: Int, steps: Int, up: Bool) -> Int {
        let n = Double(max(1, steps))
        let notch = (Double(current) / 100 * n).rounded() + (up ? 1 : -1)
        return Int((min(n, max(0, notch)) / n * 100).rounded())
    }
}

extension AuxKeyEvent.Key {
    /// Touches son et sourdine (laissées à macOS sauf si l'option est activée).
    var isSound: Bool { self == .soundUp || self == .soundDown || self == .mute }
}

// MARK: - Moniteur

final class MediaKeyMonitor {
    private unowned let model: AppModel
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    /// Dernière touche luminosité traitée, avec son chemin (aux = type 14, sinon keyDown 144/145)
    /// et son heure : certains claviers envoient les deux pour une même frappe, il ne faut agir qu'une fois.
    private var lastBrightness: (key: AuxKeyEvent.Key, viaAux: Bool, time: TimeInterval)?
    /// Fenêtre de dédoublonnage entre les deux chemins (une répétition clavier est bien plus lente).
    nonisolated static let duplicateWindow: TimeInterval = 0.03

    init(model: AppModel) { self.model = model }

    /// Autorisation Accessibilité nécessaire pour intercepter les touches.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ouvre la demande système (Réglages › Confidentialité › Accessibilité).
    static func requestTrust() {
        // Clé kAXTrustedCheckOptionPrompt écrite en clair (la constante C n'est pas Sendable).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Vrai quand le tap est installé et actif.
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        guard tap == nil else { return }
        if !installTap() {
            // Pas encore autorisé : on réessaie sans bloquer jusqu'à obtenir l'accès.
            guard retryTimer == nil else { return }
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.installTap() {
                        self.retryTimer?.invalidate()
                        self.retryTimer = nil
                    }
                }
            }
            // Modes communs : le réessai continue même pendant le suivi d'un menu ou du panneau.
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
    }

    /// Crée le tap et l'ajoute à la run loop principale. Faux sans autorisation.
    private func installTap() -> Bool {
        guard tap == nil else { return true }
        guard Self.isTrusted else { return false }
        let mask: CGEventMask = (1 << CGEventMask(AuxKeyEvent.systemDefinedType))
            | (1 << CGEventMask(CGEventType.keyDown.rawValue))
            | (1 << CGEventMask(CGEventType.keyUp.rawValue))
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: mediaKeyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
        return true
    }

    /// Traite un événement du tap ; renvoie vrai s'il faut l'avaler.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS coupe le tap s'il a été trop lent ou sur saisie sécurisée : on le relance.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard model.settings.keyboardControl else { return false }

        let decoded: AuxKeyEvent
        let viaAux: Bool
        if type == .keyDown || type == .keyUp {
            guard let key = AuxKeyEvent.Key.fromKeyDown(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
            else { return false }
            // La relâche 144/145 est suivie aussi, pour ne pas laisser passer une moitié de frappe.
            decoded = AuxKeyEvent(key: key, phase: type == .keyDown ? .down : .up,
                                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            viaAux = false
        } else if type.rawValue == AuxKeyEvent.systemDefinedType {
            guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
                  ns.subtype.rawValue == AuxKeyEvent.auxControlSubtype,
                  let d = AuxKeyEvent.decode(data1: ns.data1)
            else { return false }
            decoded = d
            viaAux = true
        } else {
            return false
        }

        // Touches son : laissées à macOS (haut-parleurs du Mac) sauf si l'option est activée.
        // Appui et relâche passent tous deux, la frappe reste entière pour macOS.
        if decoded.key.isSound && !model.settings.keyboardVolumeControl { return false }

        // Seulement quand le pointeur est sur un écran externe piloté et joignable.
        guard let display = model.displays.controllerUnderMouse() else { return false }
        // Écran sans haut-parleur pilotable (pas de 0x62) : les touches son restent à macOS, frappe entière.
        if decoded.key.isSound && !display.supportedControls.contains(.volume) { return false }
        // La relâche est avalée aussi, pour que macOS ne voie pas une moitié de frappe.
        guard decoded.phase == .down else { return true }
        // La sourdine ne se répète pas quand on garde la touche enfoncée.
        if decoded.key == .mute && decoded.isRepeat { return true }

        // Même frappe de luminosité reçue par les deux chemins : on n'agit qu'une fois.
        if decoded.key == .brightnessUp || decoded.key == .brightnessDown {
            let now = ProcessInfo.processInfo.systemUptime
            if Self.isDuplicate(key: decoded.key, viaAux: viaAux, at: now, last: lastBrightness) { return true }
            lastBrightness = (decoded.key, viaAux, now)
        }

        let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
        switch KeyAction.action(for: decoded.key, stepSize: model.settings.keyboardStepSize, fine: fine) {
        case .step(let control, let delta):
            var change = delta
            if !fine {
                // Pas normal : sur la grille exacte des crans (6,25 % pour 16 crans).
                let current = display.value(of: control)
                change = KeyAction.notchTarget(current: current, steps: model.settings.keyboardSteps,
                                               up: delta > 0) - current
            }
            // Déjà en butée (0 ou 100 %) : rien à écrire, l'OSD s'affiche quand même.
            if change != 0 { display.step(control, by: change) }
            model.osd.show(control, on: display)
        case .toggleMute:
            display.toggleMute()
            model.osd.show(.volume, on: display)
        }
        return true
    }

    /// Vrai si la touche a déjà été traitée par l'autre chemin il y a moins de `duplicateWindow` (pur, testé).
    nonisolated static func isDuplicate(key: AuxKeyEvent.Key, viaAux: Bool, at time: TimeInterval,
                                        last: (key: AuxKeyEvent.Key, viaAux: Bool, time: TimeInterval)?) -> Bool {
        guard let last else { return false }
        return last.key == key && last.viaAux != viaAux && time - last.time < duplicateWindow
    }
}

/// Rappel C du tap : sans contexte capturé, le moniteur est retrouvé via userInfo.
/// Le tap est sur la run loop principale, d'où MainActor.assumeIsolated.
nonisolated private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                             userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    nonisolated(unsafe) let e = event
    let swallow = MainActor.assumeIsolated { monitor.handle(type: type, event: e) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

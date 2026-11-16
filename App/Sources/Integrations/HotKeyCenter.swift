// Raccourcis globaux des profils (« ⌃⌥1 »…) via l'API Carbon RegisterEventHotKey :
// pas besoin de l'autorisation Accessibilité. Un seul gestionnaire d'événements est installé
// sur la cible de l'application ; chaque raccourci porte un identifiant relié à un profil.
// La liste suit automatiquement les changements de ProfileStore (Observation).
// Les raccourcis refusés par le système sont publiés (failedProfileIDs) pour l'interface,
// et l'enregistreur de raccourci les suspend le temps de la saisie (suspend / resume).

import Carbon.HIToolbox
import Foundation
import Observation

@Observable
final class HotKeyCenter {
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var refs: [EventHotKeyRef] = []
    /// Identifiant Carbon → profil.
    @ObservationIgnored private var bindings: [UInt32: UUID] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var nextID: UInt32 = 1
    /// Vrai quand un suivi des profils est armé : chaque appel externe à reload() ne doit pas
    /// en empiler un nouveau (sinon chaque modification déclencherait N rechargements).
    @ObservationIgnored private var isTrackingProfiles = false
    /// Raccourcis désactivés pendant l'enregistrement d'une nouvelle combinaison.
    @ObservationIgnored private var isSuspended = false

    /// Profils dont le raccourci a été refusé par le système (déjà pris par macOS ou une autre app).
    private(set) var failedProfileIDs: Set<UUID> = []

    /// Signature 'MiMo' des raccourcis de l'app.
    static let signature: OSType = 0x4D69_4D6F

    init(model: AppModel) { self.model = model }

    /// (Ré)enregistre les raccourcis globaux des profils.
    func reload() {
        installHandlerIfNeeded()
        unregisterAll()

        // Lecture suivie (une seule à la fois) : toute modification des profils relance reload().
        let profiles: [Profile]
        if isTrackingProfiles {
            profiles = model.profiles.profiles
        } else {
            isTrackingProfiles = true
            profiles = withObservationTracking {
                model.profiles.profiles
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isTrackingProfiles = false
                    self.reload()
                }
            }
        }

        // Pendant l'enregistrement d'un raccourci, rien n'est enregistré : la combinaison tapée
        // doit arriver à l'enregistreur, pas appliquer le profil qui l'utilise déjà.
        guard !isSuspended else { return }

        var failed = Set<UUID>()
        defer { if failed != failedProfileIDs { failedProfileIDs = failed } }
        for profile in profiles {
            guard let combo = profile.hotKey else { continue }
            let id = nextID
            nextID &+= 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                bindings[id] = profile.id
            } else {
                // Typiquement eventHotKeyExistsErr : combinaison déjà prise (autre app ou autre profil).
                NSLog("Mi Monitor : raccourci \(combo.display) du profil « \(profile.name) » refusé (\(status))")
                failed.insert(profile.id)
            }
        }
    }

    /// Désactive tous les raccourcis (enregistreur de raccourci actif).
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
    }

    /// Réenregistre les raccourcis après une suspension.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        reload()
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        bindings.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { NSLog("Mi Monitor : gestionnaire de raccourcis non installé (\(status))") }
    }

    /// Raccourci pressé : applique le profil puis montre l'OSD luminosité. Vrai si traité.
    fileprivate func fire(signature: OSType, id: UInt32) -> Bool {
        guard signature == Self.signature, let profileID = bindings[id],
              let profile = model.profiles.profile(id: profileID) else { return false }
        // Écran du profil s'il est connecté, sinon l'écran sélectionné.
        if let display = model.target(for: profile), model.apply(profile, to: display) {
            model.osd.show(.brightness, on: display)
        }
        return true
    }
}

/// Rappel C de Carbon (distribué sur le fil principal par la run loop de l'app).
nonisolated private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                            _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKey = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    guard status == noErr else { return status }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let signature = hotKey.signature, id = hotKey.id
    let handled = MainActor.assumeIsolated { center.fire(signature: signature, id: id) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}

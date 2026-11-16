// Préférences de l'app (UserDefaults), observables par SwiftUI.

import Foundation
import Observation
import ServiceManagement

enum OSDStyle: String, CaseIterable, Identifiable, Codable {
    /// Pas d'OSD maison (par défaut) : recommandé avec une app qui l'affiche dans l'encoche (Canopy).
    case none
    /// Capsule de verre sous la barre des menus.
    case capsuleTop
    /// Capsule de verre en bas de l'écran.
    case capsuleBottom
    // L'ancien carré centré « Façon système » a été retiré : une préférence "system"
    // enregistrée ne se décode plus et retombe sur .none (voir AppSettings.init).

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Aucun"
        case .capsuleTop: "Capsule en haut"
        case .capsuleBottom: "Capsule en bas"
        }
    }
}

@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// Les touches luminosité du clavier agissent sur l'écran externe quand le pointeur s'y trouve.
    var keyboardControl: Bool { didSet { defaults.set(keyboardControl, forKey: "keyboardControl") } }
    /// Les touches son / sourdine agissent aussi sur le haut-parleur de l'écran.
    /// Désactivé par défaut : le son passe d'ordinaire par le Mac, ses touches doivent lui rester.
    var keyboardVolumeControl: Bool { didSet { defaults.set(keyboardVolumeControl, forKey: "keyboardVolumeControl") } }
    /// Nombre de crans de 0 à 100 % (16 comme macOS).
    var keyboardSteps: Int { didSet { defaults.set(keyboardSteps, forKey: "keyboardSteps") } }
    /// Écrans (identifiants) dont la luminosité suit celle de l'écran du MacBook.
    var followMacBookDisplays: Set<String> {
        didSet { defaults.set(followMacBookDisplays.sorted(), forKey: "followMacBookDisplays") }
    }
    /// Écart ajouté à la luminosité du MacBook (−50…+50 points).
    var followOffset: Int { didSet { defaults.set(followOffset, forKey: "followOffset") } }
    var osdStyle: OSDStyle { didSet { defaults.set(osdStyle.rawValue, forKey: "osdStyle") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["keyboardControl": true, "keyboardVolumeControl": false, "keyboardSteps": 16,
                                     "followOffset": 0, "osdStyle": OSDStyle.none.rawValue])
        keyboardControl = defaults.bool(forKey: "keyboardControl")
        keyboardVolumeControl = defaults.bool(forKey: "keyboardVolumeControl")
        keyboardSteps = defaults.integer(forKey: "keyboardSteps")
        followMacBookDisplays = Set(defaults.stringArray(forKey: "followMacBookDisplays") ?? [])
        // Ancien réglage global (un seul écran) : vrai → l'écran sélectionné le suivra, dès qu'il sera
        // connu (cf. completeFollowMacBookMigration). L'ancienne clé est retirée tout de suite.
        if let legacy = defaults.object(forKey: "followMacBook") as? Bool {
            if legacy && defaults.stringArray(forKey: "followMacBookDisplays") == nil {
                defaults.set(true, forKey: Self.pendingFollowKey)
            }
            defaults.removeObject(forKey: "followMacBook")
        }
        followOffset = defaults.integer(forKey: "followOffset")
        // Valeur inconnue (ancien style "system" retiré) : on retombe sur « Aucun » et on efface
        // la préférence périmée pour qu'elle ne soit plus relue.
        if let stored = OSDStyle(rawValue: defaults.string(forKey: "osdStyle") ?? "") {
            osdStyle = stored
        } else {
            osdStyle = .none
            defaults.removeObject(forKey: "osdStyle")
        }
    }

    private static let pendingFollowKey = "followMacBookPendingMigration"

    /// Vrai si l'ancien « Suivre le MacBook » était actif et attend l'écran sélectionné.
    var hasPendingFollowMacBookMigration: Bool { defaults.bool(forKey: Self.pendingFollowKey) }

    /// Termine la migration de l'ancien booléen : l'écran sélectionné suit le MacBook.
    func completeFollowMacBookMigration(selectedID: String?) {
        guard let selectedID, hasPendingFollowMacBookMigration else { return }
        followMacBookDisplays.insert(selectedID)
        defaults.removeObject(forKey: Self.pendingFollowKey)
    }

    /// Vrai si la luminosité de cet écran suit celle du MacBook.
    func followsMacBook(_ displayID: String?) -> Bool {
        displayID.map(followMacBookDisplays.contains) ?? false
    }

    /// Active ou coupe le suivi du MacBook pour un écran.
    func setFollowsMacBook(_ on: Bool, for displayID: String) {
        if on { followMacBookDisplays.insert(displayID) } else { followMacBookDisplays.remove(displayID) }
    }

    /// Taille d'un cran clavier en points de pourcentage, arrondie (sert au pas fin ⌥⇧ ;
    /// le pas normal suit la grille exacte des crans, cf. KeyAction.notchTarget).
    var keyboardStepSize: Int { max(1, Int((100.0 / Double(max(1, keyboardSteps))).rounded())) }
}

/// Lancement à l'ouverture de session via SMAppService (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// L'utilisateur doit parfois approuver dans Réglages Système › Général › Ouverture.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

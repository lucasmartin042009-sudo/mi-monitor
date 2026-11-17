// Point central partagé par l'interface, les raccourcis clavier et les App Intents.

import Foundation
import Observation

@Observable
final class AppModel {
    static let shared = AppModel()

    let displays: DisplayManager
    let settings: AppSettings
    let profiles: ProfileStore

    @ObservationIgnored private(set) lazy var osd = OSDController(model: self)
    @ObservationIgnored private(set) lazy var mediaKeys = MediaKeyMonitor(model: self)
    @ObservationIgnored private(set) lazy var hotKeys = HotKeyCenter(model: self)
    @ObservationIgnored private(set) lazy var brightnessSync = BrightnessSync(model: self)
    /// « Mode noir » : écran noir sans l'éteindre (la veille DDC coupe la charge USB-C du Mac).
    @ObservationIgnored private(set) lazy var blackout = BlackoutController(model: self)

    private var started = false

    /// Les tests injectent des préférences et un fichier de profils isolés.
    init(displays: DisplayManager = DisplayManager(), settings: AppSettings = AppSettings(),
         profiles: ProfileStore = ProfileStore()) {
        self.displays = displays
        self.settings = settings
        self.profiles = profiles
    }

    /// Démarre la détection des écrans et les intégrations (appelé une fois au lancement).
    func start() {
        guard !started else { return }
        started = true
        // Migration de l'ancien « Suivre le MacBook » (booléen) vers l'écran sélectionné,
        // jamais vers l'écran simulé (Debug) : on attend alors qu'un vrai écran soit détecté.
        displays.onScanned = { [weak self] in
            guard let self else { return }
            let target = self.displays.selected.flatMap { $0.isSimulated ? nil : $0.id }
            self.settings.completeFollowMacBookMigration(selectedID: target)
        }
        displays.start()
        mediaKeys.start()
        hotKeys.reload()
        brightnessSync.start()
        // Noms des profils proposés à Siri / Spotlight (« Applique Nuit dans Mi Monitor »).
        MiMonitorShortcuts.updateAppShortcutParameters()
        askAccessibilityOnce()
    }

    /// Les touches clavier sont actives par défaut mais exigent l'autorisation Accessibilité :
    /// on la demande une seule fois au premier lancement, ensuite seul l'onglet Général la propose.
    private func askAccessibilityOnce() {
        let key = "didAskAccessibility"
        guard settings.keyboardControl, !MediaKeyMonitor.isTrusted, !BrightnessSync.isRunningTests,
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        MediaKeyMonitor.requestTrust()
    }

    /// Écran visé par un profil : le sien s'il est branché, sinon l'écran sélectionné.
    /// Un écran du profil branché mais momentanément inutilisable (connexion en cours, en veille,
    /// sans réponse DDC) reste la cible : le profil n'est alors pas appliqué, plutôt que de partir
    /// sur un autre écran dont il ne décrit pas les réglages.
    func target(for profile: Profile) -> DisplayController? {
        if let id = profile.displayID, let own = displays.controller(id: id), own.connection != .disconnected { return own }
        return displays.selected
    }

    /// Applique un profil à l'écran donné, ou à défaut à celui qu'il vise (cf. target(for:)).
    /// Un préréglage que l'écran n'annonce pas est ignoré. Renvoie faux si aucun écran utilisable.
    @discardableResult
    func apply(_ profile: Profile, to display: DisplayController? = nil) -> Bool {
        guard let target = display ?? target(for: profile), target.connection.isUsable else { return false }
        target.apply(profile.settings)
        return true
    }
}

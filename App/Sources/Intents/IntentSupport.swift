// Outils communs aux actions Raccourcis : démarrage de l'app si l'action l'a lancée,
// attente de l'écran visé et erreurs lisibles en français.
//
// Les actions s'exécutent dans le processus de l'app (pas d'extension) : si Mi Monitor tourne
// déjà, elles agissent sur le même AppModel.shared que le panneau ; sinon macOS lance l'app
// en arrière-plan (openAppWhenRun = false) et on démarre la détection nous-mêmes.
//
// Deux façons de viser un écran :
//  • « souple » (profils) : l'écran demandé s'il est branché, sinon l'écran sélectionné ;
//  • « stricte » (paramètre « Écran » choisi dans Raccourcis) : cet écran-là, ou une erreur
//    claire s'il n'est pas branché — on n'agit jamais en douce sur un autre écran.

import AppIntents
import Foundation

/// Erreurs affichées par Raccourcis.
enum MiMonitorIntentError: Error, CustomLocalizedStringResourceConvertible {
    /// Aucun écran externe pilotable détecté.
    case noDisplay
    /// L'écran choisi n'est pas branché (nom, s'il est connu).
    case displayNotConnected(String?)
    /// L'écran est en veille (nom).
    case asleep(String)
    /// L'écran ne répond pas au DDC/CI (nom, état lisible).
    case notResponding(String, String)
    /// L'écran ne propose pas ce réglage par DDC/CI (nom, réglage).
    case unsupported(String, String)
    case profileNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noDisplay:
            "Aucun écran externe pilotable n'est détecté. Vérifiez qu'il est branché et allumé."
        case .displayNotConnected(let name?):
            "L'écran « \(name) » n'est pas branché. Branchez-le ou choisissez un autre écran."
        case .displayNotConnected(nil):
            "L'écran choisi n'est pas branché. Branchez-le ou choisissez un autre écran."
        case .asleep(let name):
            "L'écran « \(name) » est en veille. Rallumez-le depuis le panneau de Mi Monitor ou avec son bouton."
        case .notResponding(let name, let state):
            "L'écran « \(name) » ne répond pas (\(state)). Vérifiez que DDC/CI est activé dans le menu de l'écran."
        case .unsupported(let name, let control):
            "L'écran « \(name) » ne permet pas de régler « \(control) » par DDC/CI."
        case .profileNotFound:
            "Ce profil n'existe plus dans Mi Monitor."
        }
    }
}

enum IntentSupport {
    /// Délai maximal d'attente de la connexion après un lancement par Raccourcis.
    static let connectionTimeout: Duration = .seconds(5)
    /// Délai maximal d'attente de la fin des écritures (les gains R/V/B sont lents : ~0,9 s chacun).
    static let writeTimeout: Duration = .seconds(5)
    /// Délai maximal d'attente de la première détection avant de proposer la liste des écrans.
    static let scanTimeout: Duration = .seconds(3)

    /// Démarre l'app si besoin et renvoie l'écran visé une fois connecté : celui d'identifiant
    /// `preferredID` s'il est branché, sinon l'écran sélectionné (visée souple).
    static func connectedDisplay(preferredID: String? = nil) async throws -> DisplayController {
        try await waitForDisplay(id: preferredID, strict: false, name: nil)
    }

    /// Écran choisi dans Raccourcis (visée stricte), ou l'écran sélectionné si aucun n'est choisi.
    static func connectedDisplay(for entity: DisplayEntity?) async throws -> DisplayController {
        guard let entity else { return try await connectedDisplay() }
        return try await waitForDisplay(id: entity.id, strict: true, name: entity.isKnown ? entity.name : nil)
    }

    /// Vérifie que l'écran propose ce réglage (capacités lues), sinon erreur claire.
    static func requireSupport(_ control: Control, on display: DisplayController) throws {
        guard display.supportedControls.contains(control) else {
            throw MiMonitorIntentError.unsupported(display.displayName, control.title.lowercased())
        }
    }

    /// Démarre l'app si besoin et attend la première détection des écrans (bornée), pour que
    /// la liste proposée par Raccourcis ne soit pas vide juste après un lancement.
    static func waitForScan() async {
        let model = AppModel.shared
        model.start() // sans effet si l'app tournait déjà
        let clock = ContinuousClock()
        let deadline = clock.now + scanTimeout
        while !model.displays.hasScanned && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Attente commune : `strict` interdit le repli sur l'écran sélectionné quand `id` est donné.
    private static func waitForDisplay(id: String?, strict: Bool, name: String?) async throws -> DisplayController {
        let model = AppModel.shared
        model.start() // sans effet si l'app tournait déjà
        let clock = ContinuousClock()
        let deadline = clock.now + connectionTimeout
        // Après une panne passagère (bus pris par une autre app), une relecture suffit souvent.
        var retriedUnresponsive = false
        // Visée souple : l'écran demandé tant qu'il est branché (même en cours de connexion,
        // juste après un lancement par Raccourcis) ; l'écran sélectionné seulement s'il est débranché
        // ou, une fois la détection finie, inconnu. Sinon un profil partirait sur un autre écran
        // pendant que le sien termine sa première lecture.
        func target() -> DisplayController? {
            guard let id else { return model.displays.selected }
            if let own = model.displays.controller(id: id) {
                if strict || own.connection != .disconnected { return own }
                return model.displays.selected
            }
            if strict || !model.displays.hasScanned { return nil }
            return model.displays.selected
        }
        // Écran introuvable : l'écran choisi (visée stricte) ou n'importe lequel (visée souple).
        func missing() -> MiMonitorIntentError {
            strict && id != nil ? .displayNotConnected(name) : .noDisplay
        }
        while clock.now < deadline {
            if let display = target(), display.connection.isUsable { return display }
            // Après la première détection, les états définitifs échouent tout de suite (inutile d'attendre 5 s).
            if model.displays.hasScanned {
                guard let display = target() else { throw missing() }
                switch display.connection {
                case .unresponsive where !retriedUnresponsive:
                    retriedUnresponsive = true
                    await display.refresh()
                    continue
                case .unresponsive, .asleep, .disconnected: throw error(for: display)
                case .connecting, .connected: break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let display = target() else { throw missing() }
        throw error(for: display)
    }

    /// Erreur lisible correspondant à l'état de connexion (inutilisable) d'un écran.
    static func error(for display: DisplayController) -> MiMonitorIntentError {
        switch display.connection {
        case .asleep: .asleep(display.displayName)
        case .disconnected: .displayNotConnected(display.displayName)
        default: .notResponding(display.displayName, display.connection.label)
        }
    }

    /// Attend que les écritures DDC en file soient parties, puis vérifie que l'écran a suivi.
    static func waitForWrites(on display: DisplayController) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + writeTimeout
        while !display.applying.isEmpty && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard display.connection.isUsable else { throw error(for: display) }
    }
}

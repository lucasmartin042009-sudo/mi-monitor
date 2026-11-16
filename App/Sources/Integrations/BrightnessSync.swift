// « Suivre la luminosité du MacBook » : la luminosité de chaque écran choisi
// (settings.followMacBookDisplays) recopie celle de l'écran intégré, décalée de
// settings.followOffset points et bornée à 0–100. L'état (pause après un réglage manuel)
// est tenu écran par écran.
//
// Fonctionnement :
//  • interrogation légère toutes les 0,5 s (macOS ne publie pas de notification de changement
//    de luminosité), uniquement quand l'option est active ET que l'écran est connecté ;
//    le reste du temps la boucle dort et se réveille par Observation (withObservationTracking) ;
//  • on n'écrit que si la cible diffère d'au moins 1 point de la luminosité actuelle ;
//    le cœur regroupe/limite ensuite les écritures DDC (60 ms) ;
//  • réglage manuel : si la luminosité d'un écran n'est plus celle que la synchro a écrite
//    (curseur, touches, profil, Raccourcis…), la synchro se met en pause jusqu'à un net
//    changement de luminosité du MacBook (au moins resumeThreshold points) ou de l'écart réglé.
//    Un seuil est nécessaire : la luminosité automatique du MacBook bouge d'un point toutes les
//    quelques secondes et défaisait aussitôt un profil « Nuit » ou un réglage au curseur. On n'utilise pas onUserChange,
//    qui n'admet qu'un seul abonné et sert déjà à d'autres modules ;
//  • les écritures de la synchro ne déclenchent PAS onUserChange (désactivé le temps de l'appel) :
//    ce n'est pas un geste de l'utilisateur, l'OSD ne doit pas s'afficher à chaque pas automatique ;
//  • jamais lancée sous les tests (l'app sert d'hôte aux tests : pas d'écriture sur le vrai écran).

import Foundation
import Observation

@Observable
final class BrightnessSync {
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// Écrans (identifiants) en pause après un réglage manuel.
    private(set) var suspendedDisplays: Set<String> = []
    /// Dernière luminosité lue sur le MacBook, en points (nil si inconnue).
    private(set) var macBookPercent: Int?

    /// Valeur écrite par la synchro lors du dernier passage, par écran (pour repérer un réglage manuel).
    @ObservationIgnored private var lastWritten: [String: Int] = [:]
    /// Luminosité MacBook et écart au moment de la pause, par écran.
    @ObservationIgnored private var suspendedAt: [String: (mac: Int, offset: Int)] = [:]

    /// Vrai si la synchro de cet écran est en pause après un réglage manuel.
    func isSuspended(_ displayID: String) -> Bool { suspendedDisplays.contains(displayID) }

    /// Période d'interrogation de la luminosité intégrée.
    static let pollInterval: Duration = .milliseconds(500)
    /// Écart minimal de luminosité du MacBook (en points) pour reprendre après une pause.
    static let resumeThreshold = 5

    init(model: AppModel) { self.model = model }

    /// Luminosité de l'écran intégré (0…1), nil si inconnue (capot fermé, Mac de bureau…).
    static var builtInBrightness: Double? { BuiltInBrightness.read() }

    func start() {
        guard loop == nil, !Self.isRunningTests else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isActive {
                    self.tick()
                    try? await Task.sleep(for: Self.pollInterval)
                } else {
                    self.reset()
                    await self.waitUntilActivityMayChange()
                }
            }
        }
    }

    // MARK: - Mécanique

    /// Vrai quand l'app est lancée comme hôte des tests (xcodebuild test).
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    }

    /// Écrans qui suivent le MacBook et sont prêts à recevoir des écritures.
    private var followedDisplays: [DisplayController] {
        model.displays.displays.filter { model.settings.followsMacBook($0.id) && $0.connection.isUsable }
    }

    /// Au moins un écran à synchroniser.
    private var isActive: Bool { !followedDisplays.isEmpty }

    /// Oublie l'état de suivi (option coupée, écrans débranchés ou endormis).
    private func reset() {
        lastWritten.removeAll()
        suspendedAt.removeAll()
        if !suspendedDisplays.isEmpty { suspendedDisplays.removeAll() }
        if macBookPercent != nil { macBookPercent = nil }
    }

    /// Suspend la boucle jusqu'à ce que l'option ou l'état de l'écran change.
    private func waitUntilActivityMayChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                // Lectures suivies : option, liste des écrans et leur connexion.
                _ = self.isActive
            } onChange: {
                // Appelé une seule fois, avant la modification : la boucle relira l'état après.
                continuation.resume()
            }
        }
    }

    /// Un passage de la synchro.
    private func tick() {
        let displays = followedDisplays
        // Les écrans qui ne suivent plus (option coupée, débranchés) oublient leur état.
        let ids = Set(displays.map(\.id))
        lastWritten = lastWritten.filter { ids.contains($0.key) }
        suspendedAt = suspendedAt.filter { ids.contains($0.key) }
        if !suspendedDisplays.isSubset(of: ids) { suspendedDisplays.formIntersection(ids) }
        guard let builtIn = Self.builtInBrightness else {
            // Capot fermé ou lecture impossible : on garde l'état et on réessaie au prochain passage.
            if macBookPercent != nil { macBookPercent = nil }
            return
        }
        let mac = Int((builtIn * 100).rounded())
        let offset = model.settings.followOffset
        // Affectation conditionnelle : évite de réveiller les vues observatrices deux fois par seconde.
        if macBookPercent != mac { macBookPercent = mac }
        for display in displays { follow(display, mac: mac, offset: offset) }
    }

    /// Recopie la luminosité du MacBook sur un écran (sauf pendant une pause après un réglage manuel).
    private func follow(_ display: DisplayController, mac: Int, offset: Int) {
        let id = display.id
        // Réglage manuel détecté : la valeur affichée n'est plus celle que la synchro a posée.
        if let written = lastWritten[id], display.brightness != written, suspendedAt[id] == nil {
            suspendedAt[id] = (mac, offset)
            suspendedDisplays.insert(id)
        }
        if let pause = suspendedAt[id] {
            // Reprise sur un vrai geste : luminosité du MacBook nettement changée, ou nouvel écart.
            guard abs(mac - pause.mac) >= Self.resumeThreshold || offset != pause.offset else { return }
            suspendedAt[id] = nil
            suspendedDisplays.remove(id)
        }

        let target = min(100, max(0, mac + offset))
        if abs(target - display.brightness) >= 1 {
            // onUserChange est réservé aux gestes de l'utilisateur (OSD…) : on le coupe le temps
            // de l'écriture automatique, puis on le remet tel quel.
            let handler = display.onUserChange
            display.onUserChange = nil
            display.set(.brightness, percent: target)
            display.onUserChange = handler
        }
        lastWritten[id] = display.brightness
    }
}

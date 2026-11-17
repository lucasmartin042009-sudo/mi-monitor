// Suit les écrans externes : détection au lancement, rebranchement, réveil de veille.
// Un contrôleur est conservé par écran (identifié par son n° de série) pour garder son état.
// Les écrans sont rangés dans l'ordre de leur première détection (mémorisé), et un écran
// « sélectionné » (mémorisé lui aussi) sert de cible par défaut au panneau, aux profils sans
// écran et aux actions Raccourcis.

import AppKit
import CoreGraphics
import DDCKit
import Observation
import os

/// Écran externe en ligne selon CoreGraphics (indépendant du DDC).
nonisolated struct OnlineDisplay: Sendable, Equatable {
    var displayID: CGDirectDisplayID
    var vendorID: UInt32
    var productID: UInt32

    /// Vrai si cet écran correspond à l'identité EDID d'un contrôleur.
    func matches(_ identity: DisplayIdentity) -> Bool {
        identity.vendorID == vendorID && identity.productID == productID
    }

    /// Écrans externes en ligne d'après CoreGraphics.
    static func current() -> [OnlineDisplay] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.map {
            OnlineDisplay(displayID: $0, vendorID: CGDisplayVendorNumber($0), productID: CGDisplayModelNumber($0))
        }
    }
}

/// Accès au système remplaçable sous les tests : découverte DDC (IOKit) et écrans en ligne (CoreGraphics).
nonisolated struct DisplaySystem: Sendable {
    var discover: @Sendable () -> [ExternalDisplay] = { DisplayDiscovery.externalDisplays() }
    var onlineExternals: @Sendable () -> [OnlineDisplay] = { OnlineDisplay.current() }
}

@Observable
final class DisplayManager {
    private(set) var displays: [DisplayController] = []
    /// Dernière détection terminée (évite d'afficher « aucun écran » avant la première).
    private(set) var hasScanned = false

    /// Identifiant de l'écran choisi par l'utilisateur (mémorisé d'un lancement à l'autre).
    private(set) var selectedID: String? {
        didSet { defaults.set(selectedID, forKey: Self.selectedKey) }
    }

    /// Écran visé par défaut : le sélectionné s'il est présent, sinon le premier connecté,
    /// sinon le premier encore branché (en veille, ne répond pas…), sinon le premier connu.
    var selected: DisplayController? {
        if let selectedID, let c = controller(id: selectedID), c.connection != .disconnected { return c }
        return displays.first { $0.connection.isUsable }
            ?? displays.first { $0.connection != .disconnected }
            ?? displays.first
    }

    /// Appelé à la fin de chaque balayage (migration des préférences qui dépendent de l'écran sélectionné).
    @ObservationIgnored var onScanned: (() -> Void)?

    private let defaults: UserDefaults
    /// Ordre de première détection des écrans (identifiants), mémorisé.
    @ObservationIgnored private var order: [String]
    private static let selectedKey = "selectedDisplayID"
    private static let orderKey = "displayOrder"

    private var rescanTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    // MARK: Nouvelles tentatives
    //
    // Cause du bug du 16 nov. : au démarrage de session, macOS reconfigure les écrans et le service DDC
    // (DCPAVServiceProxy) du Mi Monitor peut manquer un instant. Un seul balayage tombé dans ce trou
    // le marquait « Débranché », et plus rien ne relançait la détection : l'écran restait perdu des heures.
    // Désormais : un écran que CoreGraphics voit encore en ligne n'est déclaré débranché qu'après plusieurs
    // balayages manqués, et tant qu'un écran en ligne n'est pas joignable, on rebalaye avec un délai croissant.

    @ObservationIgnored private let system: DisplaySystem
    /// Balayages consécutifs où un écran connu, encore en ligne, n'a pas été trouvé par la détection DDC.
    @ObservationIgnored private var missedScans: [String: Int] = [:]
    /// Rang dans `retryDelays` de la prochaine tentative automatique.
    @ObservationIgnored private var retryStep = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Délais des tentatives automatiques ; le dernier se répète tant que le problème dure.
    @ObservationIgnored var retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(30), .seconds(60)]
    /// Nombre de balayages manqués avant de déclarer « Débranché » un écran que macOS voit encore.
    static let missedScansBeforeDisconnect = 3

    private let log = Logger(subsystem: "MiMonitor", category: "detection")

    /// - Parameters:
    ///   - observeSystem: faux sous les tests (pas d'abonnement aux notifications du système).
    ///   - system: découverte DDC et écrans en ligne (remplacés sous les tests).
    init(defaults: UserDefaults = .standard, observeSystem: Bool = true, system: DisplaySystem = DisplaySystem()) {
        self.defaults = defaults
        self.system = system
        self.selectedID = defaults.string(forKey: Self.selectedKey)
        self.order = defaults.stringArray(forKey: Self.orderKey) ?? []
        guard observeSystem else { return }
        let ws = NSWorkspace.shared.notificationCenter
        // Réveil du Mac ou des écrans : le bus DDC met quelques secondes à revenir.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRescan(after: .seconds(3)) }
            })
        }
        // Branchement / débranchement / changement de résolution.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRescan(after: .seconds(2)) }
        })
    }

    /// Premier balayage au lancement.
    func start() {
        #if DEBUG
        // Écran simulé pour essayer l'interface à deux écrans sans le second écran.
        if ProcessInfo.processInfo.environment["MIMONITOR_FAKE_DISPLAY"] == "1", controller(id: SimulatedDDC.displayID) == nil {
            let fake = SimulatedDDC.makeController()
            register(fake)
            Task { await fake.refresh() }
        }
        #endif
        scheduleRescan(after: .zero)
    }

    /// Choisit l'écran visé par défaut (mémorisé).
    func select(_ display: DisplayController) {
        guard selectedID != display.id else { return }
        selectedID = display.id
    }

    /// Ajoute un contrôleur à la liste, à sa place dans l'ordre de première détection,
    /// et recalcule les noms affichés.
    /// L'écran simulé n'entre pas dans l'ordre mémorisé et passe toujours après les vrais écrans :
    /// sinon, enregistré avant le premier balayage, il deviendrait le premier écran (et la cible
    /// par défaut du panneau) et le resterait dans les préférences.
    func register(_ controller: DisplayController) {
        guard self.controller(id: controller.id) == nil else { return }
        if !controller.isSimulated && !order.contains(controller.id) {
            order.append(controller.id)
            defaults.set(order, forKey: Self.orderKey)
        }
        displays.append(controller)
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // Tri stable : à rang égal (écrans non mémorisés, dont l'écran simulé), l'ordre d'ajout est conservé.
        displays = displays.enumerated().sorted { a, b in
            let (ra, rb) = (a.element.isSimulated ? .max : rank[a.element.id] ?? .max,
                            b.element.isSimulated ? .max : rank[b.element.id] ?? .max)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        updateDisplayNames()
    }

    /// Donne à chaque écran un nom unique (cf. uniqueNames).
    private func updateDisplayNames() {
        let names = Self.uniqueNames(displays.map {
            (name: $0.identity.productName ?? $0.name, serial: $0.identity.alphanumericSerial ?? $0.id)
        })
        for (c, name) in zip(displays, names) where c.displayName != name { c.displayName = name }
    }

    /// Noms lisibles uniques : le nom EDID, suffixé des 4 derniers caractères du n° de série
    /// quand plusieurs écrans portent le même nom (« Mi Monitor · 0001 »).
    nonisolated static func uniqueNames(_ entries: [(name: String, serial: String)]) -> [String] {
        var counts: [String: Int] = [:]
        for e in entries { counts[e.name, default: 0] += 1 }
        return entries.map { e in
            guard counts[e.name, default: 0] > 1, !e.serial.isEmpty else { return e.name }
            return "\(e.name) · \(e.serial.suffix(4))"
        }
    }

    /// Regroupe les notifications en rafale en un seul balayage.
    /// Un balayage commencé n'est pas interruptible (sa relecture dure plusieurs secondes) :
    /// le suivant attend sa fin, pour que deux balayages ne parlent jamais en même temps à l'écran.
    func scheduleRescan(after delay: Duration) {
        let previous = rescanTask
        previous?.cancel()
        rescanTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.rescan()
        }
    }

    /// Balaye tout de suite et attend la fin (boutons Réessayer, Réveiller).
    func rescanNow() async {
        scheduleRescan(after: .zero)
        await rescanTask?.value
    }

    func controller(id: String) -> DisplayController? { displays.first { $0.id == id } }

    /// Contrôleur de l'écran sous le pointeur de la souris, s'il est externe et piloté.
    func controllerUnderMouse() -> DisplayController? {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return displays.first { $0.displayID == number.uint32Value && $0.connection.isUsable }
    }

    /// NSScreen correspondant à un contrôleur (pour placer l'OSD).
    func screen(for controller: DisplayController) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == controller.displayID
        }
    }

    private func rescan() async {
        // La découverte touche au registre IOKit : rapide, mais faite hors du fil principal.
        let system = self.system
        let found = await Task.detached(priority: .userInitiated) { system.discover() }.value
        let online = system.onlineExternals()
        log.info("Balayage : \(found.count, privacy: .public) écran(s) DDC, \(online.count, privacy: .public) écran(s) externe(s) en ligne")
        var seen = Set<String>()
        for display in found {
            // Un balayage plus récent est programmé : il fera ce travail avec des données plus fraîches.
            guard !Task.isCancelled else { return }
            let id = DisplayController.stableID(of: display)
            seen.insert(id)
            missedScans[id] = nil
            if let existing = controller(id: id) {
                await existing.reattach(to: display)
            } else {
                let c = DisplayController(display: display)
                register(c)
                await c.refresh()
            }
        }
        // Un écran mis en veille par l'app coupe souvent son signal et disparaît de la liste :
        // il reste « En veille » (avec son bouton Réveiller) au lieu de passer « Débranché ».
        // L'écran simulé n'est jamais vu par la détection : il reste tel quel.
        for c in displays where !seen.contains(c.id) && !c.isSimulated
            && c.connection != .disconnected && c.connection != .asleep {
            let stillOnline = online.contains { $0.matches(c.identity) }
            let missed = (missedScans[c.id] ?? 0) + 1
            missedScans[c.id] = missed
            if stillOnline && missed < Self.missedScansBeforeDisconnect {
                // macOS voit toujours l'écran : service DDC momentanément absent, on retentera.
                log.notice("\(c.displayName, privacy: .public) absent de la détection DDC mais en ligne (\(missed, privacy: .public)/\(Self.missedScansBeforeDisconnect, privacy: .public))")
                continue
            }
            log.notice("\(c.displayName, privacy: .public) marqué débranché (en ligne : \(stillOnline, privacy: .public))")
            c.markDisconnected()
        }
        hasScanned = true
        onScanned?()
        scheduleRetryIfNeeded(found: seen, online: online)
    }

    /// Vrai si un écran en ligne n'est pas joignable : à rebalayer plus tard.
    private func needsRetry(found: Set<String>, online: [OnlineDisplay]) -> Bool {
        // Un écran externe en ligne qu'aucun contrôleur utilisable ne pilote.
        let unmatched = online.contains { o in
            !displays.contains { !$0.isSimulated && $0.connection.isUsable && o.matches($0.identity) }
        }
        // Un écran connu qui ne répond pas, ou absent de la détection alors que macOS le voit.
        let stuck = displays.contains { c in
            guard !c.isSimulated, c.connection != .asleep else { return false }
            let isOnline = online.contains { $0.matches(c.identity) }
            switch c.connection {
            case .unresponsive: return true
            case .disconnected, .connecting: return isOnline
            default: return isOnline && !found.contains(c.id)
            }
        }
        return unmatched || stuck
    }

    private func scheduleRetryIfNeeded(found: Set<String>, online: [OnlineDisplay]) {
        retryTask?.cancel()
        guard needsRetry(found: found, online: online), !retryDelays.isEmpty else {
            retryStep = 0
            return
        }
        let delay = retryDelays[min(retryStep, retryDelays.count - 1)]
        retryStep += 1
        log.info("Nouvelle détection dans \(String(describing: delay), privacy: .public)")
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.scheduleRescan(after: .zero)
        }
    }
}

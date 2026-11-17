// Modèle observable d'un écran externe : valeurs affichées, état de connexion,
// et file d'écriture DDC regroupée par réglage (la dernière valeur gagne).
//
// Règles issues des mesures de l'étape 0 :
//  • l'interface est mise à jour immédiatement, l'écriture DDC suit ;
//  • réglages rapides (luminosité, contraste, préréglage, source) : au plus une écriture / 60 ms ;
//  • réglages lents (son, gains R/V/B, cf. DisplayQuirks) : au plus une écriture / 900 ms, sinon l'écran les ignore ;
//  • ce que l'écran sait faire se lit dans sa chaîne de capacités (supportedControls, availablePresets…).
//  • la sourdine n'existe pas en DDC sur cet écran (0x8D refusé) : elle est émulée (son à 0 puis restauration).

import CoreGraphics
import DDCKit
import Foundation
import Observation

@Observable
final class DisplayController: Identifiable {
    // MARK: Identité

    /// Identifiant stable (n° de série EDID, sinon nom) pour retrouver l'écran après un rebranchement.
    let id: String
    private(set) var name: String
    private(set) var identity: DisplayIdentity
    private(set) var displayID: CGDirectDisplayID?
    /// Nom lisible et unique parmi les écrans connus : nom EDID, suffixé de la fin du n° de série
    /// si deux écrans portent le même nom. Attribué par DisplayManager (qui connaît les autres écrans).
    var displayName: String
    /// Particularités connues du modèle (titres d'entrées, réglages lents, silences…).
    private(set) var quirks: DisplayQuirks.Profile
    /// Écran simulé (Debug, MIMONITOR_FAKE_DISPLAY=1) : jamais marqué débranché par un balayage.
    let isSimulated: Bool

    // MARK: État

    private(set) var connection: ConnectionState = .connecting
    /// Réglages dont une écriture est en cours ou en attente (pour l'état « Application… »).
    private(set) var applying: Set<Control> = []

    // MARK: Valeurs (0–100 pour les curseurs)

    private(set) var brightness: Int = 0
    private(set) var contrast: Int = 0
    private(set) var volume: Int = 0
    private(set) var colorPreset: ColorPreset = .neutral6500K
    private(set) var redGain: Int = 50
    private(set) var greenGain: Int = 50
    private(set) var blueGain: Int = 50
    private(set) var input: InputSource = .displayPort2
    /// Sourdine émulée.
    private(set) var isMuted: Bool = false
    /// Dernières valeurs connues valides (affichées grisées en cas d'erreur).
    private(set) var hasReadValues = false
    /// Opération qui a fait passer l'écran en « ne répond pas » (ligne de diagnostic du panneau),
    /// ex. « Lecture luminosité (0x10) » ou « Écriture son (0x62) ».
    private(set) var failedOperation: String?

    /// Informations lues sur l'écran pour l'onglet À propos.
    private(set) var firmware: String?
    private(set) var mccsVersion: String?
    /// Chaîne de capacités (0xF3), lue une fois à la première connexion réussie puis gardée.
    private(set) var capabilities: Capabilities?
    /// Réglages dont au moins une lecture a réussi (un code annoncé mais refusé reste masqué).
    private(set) var readableControls: Set<Control> = []

    // MARK: Mécanique

    private var access: DDCAccess?
    /// File DDC unique de l'écran, gardée même débranché : au rattachement on lui confie le
    /// nouveau périphérique (deux files ne doivent jamais parler en même temps au même écran).
    private var worker: DDCWorker?
    /// Augmente à chaque rattachement / débranchement : une relecture ou une écriture commencée
    /// avec un accès plus ancien ne doit plus toucher à l'état de connexion.
    private var accessGeneration = 0
    private var pending: [Control: UInt16] = [:]
    /// Tâche d'écriture par réglage, avec un identifiant pour qu'une tâche annulée n'efface pas sa remplaçante.
    private var writers: [Control: (id: Int, task: Task<Void, Never>)] = [:]
    private var nextWriterID = 0
    private var maxima: [Control: UInt16] = [:]
    /// Dernière valeur brute confirmée par l'écran (lue, ou écrite sans erreur), par réglage :
    /// restaurée à l'affichage si une écriture échoue.
    private var confirmed: [Control: UInt16] = [:]
    /// Relectures automatiques après une panne DDC passagère (bus pris par une autre app…).
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    /// Délais des relectures automatiques successives (au-delà : bouton Réessayer).
    static let recoveryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]
    private let defaults: UserDefaults

    /// Appelé après chaque changement de valeur venant de l'utilisateur (OSD, profils actifs, synchro).
    var onUserChange: ((Control, Int) -> Void)?

    /// - Parameter quirks: particularités du modèle ; par défaut, déduites de l'identité EDID.
    init(id: String, name: String, identity: DisplayIdentity, displayID: CGDirectDisplayID?,
         access: DDCAccess?, defaults: UserDefaults = .standard,
         quirks: DisplayQuirks.Profile? = nil, isSimulated: Bool = false) {
        self.id = id
        self.name = name
        self.displayName = identity.productName ?? name
        self.identity = identity
        self.displayID = displayID
        self.quirks = quirks ?? DisplayQuirks.profile(for: identity)
        self.isSimulated = isSimulated
        self.access = access
        self.worker = access as? DDCWorker
        self.defaults = defaults
        // La sourdine émulée survit à un redémarrage de l'app.
        self.isMuted = defaults.bool(forKey: mutedKey)
        self.learnedMacInput = (defaults.object(forKey: macInputKey) as? Int).map { InputSource(rawValue: UInt16($0)) }
    }

    convenience init(display: ExternalDisplay) {
        let id = Self.stableID(of: display)
        self.init(id: id, name: display.name, identity: display.identity, displayID: display.displayID,
                  access: DDCWorker(device: Self.configured(display), label: id))
    }

    /// Identifiant stable d'un écran détecté : n° de série EDID, sinon UUID EDID, sinon nom.
    nonisolated static func stableID(of display: ExternalDisplay) -> String {
        display.identity.alphanumericSerial ?? display.identity.edidUUID ?? display.name
    }

    /// Applique au périphérique DDC les particularités connues du modèle (DisplayQuirks).
    private static func configured(_ display: ExternalDisplay) -> DDCDevice {
        display.device.timing = DisplayQuirks.timing(for: display.identity)
        return display.device
    }

    private var mutedKey: String { "muted.\(id)" }
    private var volumeBeforeMuteKey: String { "volumeBeforeMute.\(id)" }
    private var macInputKey: String { "macInput.\(id)" }

    // MARK: - Capacités

    /// Réglages réellement pilotables : codes annoncés dans les capacités ∩ lectures réussies.
    /// Capacités illisibles : repli sur les réglages dont la lecture a réussi, plus ceux que le modèle
    /// est connu pour accepter sans relecture (Mi Monitor : alimentation, comme avant le multi-écran).
    /// L'alimentation (0xD6) n'est jamais relue : elle compte dès qu'elle est annoncée.
    var supportedControls: Set<Control> {
        guard let vcp = capabilities?.vcp, !vcp.isEmpty else {
            return hasReadValues ? readableControls.union(quirks.unreadControls) : readableControls
        }
        return Set(Control.allCases.filter { control in
            vcp[control.code] != nil && (control == .power || readableControls.contains(control))
        })
    }

    /// Préréglages proposés : valeurs de 0x14 annoncées dans les capacités ; sinon ceux connus du modèle
    /// (Mi Monitor) ; sinon le préréglage courant seul, s'il a été lu.
    var availablePresets: [ColorPreset] {
        if let values = capabilities?.vcp[Control.colorPreset.code], !values.isEmpty {
            return Self.unique(values.map { ColorPreset(rawValue: $0 & 0xFF) })
        }
        if !quirks.defaultPresets.isEmpty { return quirks.defaultPresets }
        return readableControls.contains(.colorPreset) ? [colorPreset] : []
    }

    /// Entrées proposées : valeurs de 0x60 annoncées ; sinon celles connues du modèle ; sinon l'entrée courante.
    var availableInputs: [InputSource] {
        if let values = capabilities?.vcp[Control.input.code], !values.isEmpty {
            return Self.unique(values.map { InputSource(rawValue: $0 & 0xFF) })
        }
        if !quirks.defaultInputs.isEmpty { return quirks.defaultInputs }
        return readableControls.contains(.input) ? [input] : []
    }

    /// Retire les doublons en gardant l'ordre annoncé par l'écran.
    private static func unique<T: Hashable>(_ list: [T]) -> [T] {
        var seen = Set<T>()
        return list.filter { seen.insert($0).inserted }
    }

    /// Entrée apprise à la première connexion réussie (mémorisée par écran).
    private var learnedMacInput: InputSource?

    /// Entrée du Mac : connue du modèle (DisplayQuirks), sinon l'entrée active lue à la première
    /// connexion réussie (l'écran affichait alors le Mac) ; nil tant qu'aucune lecture n'a réussi.
    var macInput: InputSource? { quirks.macInput ?? learnedMacInput }

    /// Vrai si cette entrée est celle du Mac.
    func isMacInput(_ source: InputSource) -> Bool { macInput == source }

    /// Nom d'une entrée sur cet écran (ex. Mi Monitor : 0x10 → « USB-C »).
    func title(for source: InputSource) -> String { quirks.inputTitles[source]?.title ?? source.title }

    /// Sous-titre éventuel d'une entrée (ex. Mi Monitor : « DisplayPort 2 » sous « USB-C »).
    func subtitle(for source: InputSource) -> String? { quirks.inputTitles[source]?.subtitle }

    /// « USB-C (DisplayPort 2) », « HDMI 1 »…
    func longTitle(for source: InputSource) -> String {
        if let subtitle = subtitle(for: source) { "\(title(for: source)) (\(subtitle))" } else { title(for: source) }
    }

    /// Nom d'un préréglage sur cet écran (ex. Mi Monitor : 0x0B → « Utilisateur »).
    func title(for preset: ColorPreset) -> String { quirks.presetTitles[preset] ?? preset.title }

    /// Réglage « lent » sur cet écran (silence après écriture, cf. DisplayQuirks).
    func isSlow(_ control: Control) -> Bool { quirks.slowControls.contains(control) }

    /// Intervalle minimal entre deux écritures du même réglage.
    func minimumWriteInterval(for control: Control) -> Duration {
        isSlow(control) ? .milliseconds(900) : .milliseconds(60)
    }

    // MARK: - Connexion

    /// Rattache l'écran retrouvé après un rebranchement ou un réveil, puis relit tout.
    /// Écran mis en veille par l'app : on met seulement l'accès à jour, sans relire
    /// (il ne répondrait pas) ni quitter l'état « En veille », pour garder le bouton Réveiller.
    func reattach(to display: ExternalDisplay) async {
        identity = display.identity
        displayID = display.displayID
        name = display.name
        quirks = DisplayQuirks.profile(for: display.identity)
        let device = Self.configured(display)
        if let worker {
            await worker.replace(device: device)
        } else {
            worker = DDCWorker(device: device, label: id)
        }
        access = worker
        accessGeneration += 1
        guard connection != .asleep else { return }
        // Écran retrouvé après avoir été déclaré débranché : on repasse en « Connexion… » AVANT de relire.
        // Sinon refresh() jette chaque résultat (isStillCurrent refuse l'état .disconnected) et l'écran
        // ne pouvait jamais revenir, même après « Réessayer » ou un rebranchement (bug du 16 nov.).
        if connection == .disconnected { connection = .connecting }
        await refresh()
    }

    func markDisconnected() {
        cancelWriters()
        cancelRecovery()
        access = nil
        accessGeneration += 1
        displayID = nil
        connection = .disconnected
    }

    /// Date de la dernière relecture complète réussie.
    private var lastRefresh = Date.distantPast

    /// Relit les valeurs si la dernière lecture date de plus de `age` secondes (ouverture du panneau).
    func refreshIfStale(age: TimeInterval = 10) {
        guard connection.isUsable, Date().timeIntervalSince(lastRefresh) > age, applying.isEmpty else { return }
        Task { await refresh() }
    }

    /// Relit toutes les valeurs. En cas d'échec, l'écran passe en « ne répond pas »
    /// mais les dernières valeurs connues restent affichées.
    func refresh() async {
        guard let access else { connection = .disconnected; return }
        let generation = accessGeneration
        // Relecture demandée par le réveil : en cas d'échec, l'écran reste « En veille ».
        let wasAsleep = connection == .asleep
        if !hasReadValues && !wasAsleep { connection = .connecting }
        /// Faux si l'écran a été rattaché, débranché ou mis en veille pendant la relecture :
        /// le résultat de cette relecture ne doit alors plus changer l'état de connexion.
        func isStillCurrent() -> Bool {
            generation == accessGeneration && connection != .disconnected && (wasAsleep || connection != .asleep)
        }
        do {
            let b = try await access.read(Control.brightness.code)
            guard isStillCurrent() else { return }
            store(b, for: .brightness)
            // Les autres lectures sont « au mieux » : un échec isolé ne doit pas tout bloquer.
            // Le bus peut être occupé un instant (autre app DDC, écriture en cours) :
            // les réglages ratés sont relus une fois après une courte pause.
            var missing: [Control] = []
            // Capacités connues : inutile d'interroger un code que l'écran n'annonce pas.
            let announced = capabilities.map { Set($0.vcp.keys) }.flatMap { $0.isEmpty ? nil : $0 }
            let others = [Control.contrast, .volume, .colorPreset, .redGain, .greenGain, .blueGain, .input]
            for control in others where announced?.contains(control.code) ?? true {
                if let v = try? await access.read(control.code) { store(v, for: control) } else { missing.append(control) }
            }
            if !missing.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
                for control in missing {
                    if let v = try? await access.read(control.code) { store(v, for: control) }
                }
            }
            // Capacités : lues une fois (~750 ms), gardées ensuite même après un rebranchement.
            if capabilities == nil, let caps = try? await access.capabilities() {
                capabilities = caps
                firmware = caps.firmware
                mccsVersion = caps.mccsVersion
            }
            guard isStillCurrent() else { return }
            // Première connexion réussie : l'entrée active est celle du Mac (il s'affiche sur l'écran).
            if learnedMacInput == nil, readableControls.contains(.input) {
                learnedMacInput = input
                defaults.set(Int(input.rawValue), forKey: macInputKey)
            }
            hasReadValues = true
            lastRefresh = Date()
            failedOperation = nil
            recoveryAttempts = 0
            connection = .connected
        } catch {
            guard isStillCurrent(), !wasAsleep else { return }
            failedOperation = "Lecture luminosité (0x10)"
            connection = .unresponsive(reason: String(describing: error))
            scheduleRecovery()
        }
    }

    /// Relit la luminosité sur l'écran (action Raccourcis « Obtenir la luminosité ») :
    /// elle a pu changer avec les boutons de l'écran depuis la dernière relecture.
    /// Valeur en cache si la lecture échoue ou si une écriture de luminosité est en cours.
    func readBrightness() async -> Int {
        guard connection.isUsable, !applying.contains(.brightness), let access,
              let v = try? await access.read(Control.brightness.code) else { return brightness }
        store(v, for: .brightness)
        return brightness
    }

    /// Programme une relecture automatique après une panne DDC (délais croissants, nombre borné).
    private func scheduleRecovery() {
        guard recoveryTask == nil, recoveryAttempts < Self.recoveryDelays.count else { return }
        let delay = Self.recoveryDelays[recoveryAttempts]
        recoveryAttempts += 1
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.recoveryTask = nil
            guard case .unresponsive = self.connection else { return }
            // En cas de nouvel échec, refresh() reprogramme la tentative suivante.
            await self.refresh()
        }
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempts = 0
    }

    /// Range une valeur lue, sauf si l'utilisateur est en train de régler ce réglage.
    private func store(_ v: VCPValue, for control: Control) {
        maxima[control] = v.maximum
        confirmed[control] = v.current
        readableControls.insert(control)
        guard !applying.contains(control) else { return }
        switch control {
        case .brightness: brightness = percent(v, control)
        case .contrast: contrast = percent(v, control)
        case .volume:
            volume = percent(v, control)
            // Si le son a été remonté ailleurs (OSD de l'écran), la sourdine n'a plus de sens.
            if isMuted && volume > 0 { setMutedFlag(false) }
        case .redGain: redGain = percent(v, control)
        case .greenGain: greenGain = percent(v, control)
        case .blueGain: blueGain = percent(v, control)
        case .colorPreset: colorPreset = ColorPreset(rawValue: v.current & 0xFF)
        case .input: input = InputSource(rawValue: v.current & 0xFF)
        case .power: break
        }
    }


    // MARK: - Commandes utilisateur

    /// Règle un curseur (0–100). L'interface change tout de suite, l'écriture DDC suit.
    func set(_ control: Control, percent value: Int) {
        let v = min(100, max(0, value))
        switch control {
        case .brightness: brightness = v
        case .contrast: contrast = v
        case .volume:
            volume = v
            if isMuted && v > 0 { setMutedFlag(false) }
        case .redGain: redGain = v
        case .greenGain: greenGain = v
        case .blueGain: blueGain = v
        case .colorPreset, .input, .power:
            assertionFailure("utiliser setColorPreset / switchInput / setPower")
            return
        }
        enqueue(control, raw: raw(fromPercent: v, control))
        onUserChange?(control, v)
    }

    /// Pas relatif (touches du clavier) ; renvoie la nouvelle valeur.
    @discardableResult
    func step(_ control: Control, by delta: Int) -> Int {
        let current = value(of: control)
        if control == .volume && isMuted && delta > 0 {
            // Comme macOS : monter le son depuis la sourdine repart de la valeur mémorisée.
            toggleMute()
            return volume
        }
        set(control, percent: current + delta)
        return value(of: control)
    }

    func value(of control: Control) -> Int {
        switch control {
        case .brightness: brightness
        case .contrast: contrast
        case .volume: volume
        case .redGain: redGain
        case .greenGain: greenGain
        case .blueGain: blueGain
        case .colorPreset: Int(colorPreset.rawValue)
        case .input: Int(input.rawValue)
        case .power: connection == .asleep ? 0 : 1
        }
    }

    func setColorPreset(_ preset: ColorPreset) {
        colorPreset = preset
        enqueue(.colorPreset, raw: preset.rawValue)
        onUserChange?(.colorPreset, Int(preset.rawValue))
    }

    /// Change de source. Si on quitte l'entrée du Mac, l'image disparaît : l'interface doit confirmer avant.
    func switchInput(_ source: InputSource) {
        input = source
        enqueue(.input, raw: source.rawValue)
    }

    /// Sourdine émulée : mémorise le son puis le met à 0 ; au second appel, restaure.
    func toggleMute() {
        if isMuted {
            let restored = defaults.object(forKey: volumeBeforeMuteKey) as? Int ?? 30
            setMutedFlag(false)
            volume = max(1, restored)
            enqueue(.volume, raw: raw(fromPercent: volume, .volume))
        } else {
            // Ne jamais mémoriser 0 : on garderait un « son coupé » au rétablissement.
            if volume > 0 { defaults.set(volume, forKey: volumeBeforeMuteKey) }
            setMutedFlag(true)
            volume = 0
            enqueue(.volume, raw: 0)
        }
        onUserChange?(.volume, volume)
    }

    /// Mise en veille (0xD6 = 05) ou réveil (01). Le réveil par DDC dépend de l'écran : à vérifier en usage.
    /// Un réveil sans réponse laisse l'écran « En veille » (le bouton Réveiller reste proposé).
    /// Renvoie vrai si l'opération a abouti.
    @discardableResult
    func setPower(on: Bool) async -> Bool {
        guard let access else { return false }
        do {
            try await access.write(Control.power.code, value: on ? 0x01 : 0x05)
            if on {
                try? await Task.sleep(for: .seconds(2))
                await refresh()
                return connection.isUsable
            } else {
                cancelWriters()
                cancelRecovery()
                connection = .asleep
                return true
            }
        } catch {
            if on { return false }
            failedOperation = "Mise en veille (0xD6)"
            connection = .unresponsive(reason: String(describing: error))
            return false
        }
    }

    /// Applique plusieurs valeurs d'un coup (profil, raccourci).
    /// Un préréglage que l'écran n'annonce pas est ignoré (on n'écrit pas une valeur qu'il refuserait),
    /// et les gains R/V/B ne sont écrits que si l'écran est bien dans le mode Utilisateur du profil.
    /// De même, un réglage que l'écran ne prend pas en charge (profil global appliqué à un écran sans
    /// haut-parleur, par exemple) n'est pas écrit — sauf tant que rien n'a été lu, faute de savoir.
    func apply(_ settings: ProfileSettings) {
        func accepts(_ control: Control) -> Bool { !hasReadValues || supportedControls.contains(control) }
        if let p = settings.colorPreset, availablePresets.contains(p) { setColorPreset(p) }
        if let b = settings.brightness, accepts(.brightness) { set(.brightness, percent: b) }
        if let c = settings.contrast, accepts(.contrast) { set(.contrast, percent: c) }
        if let v = settings.volume, accepts(.volume) { set(.volume, percent: v) }
        if let p = settings.colorPreset, p.isUser, colorPreset == p, let g = settings.gains {
            if accepts(.redGain) { set(.redGain, percent: g.red) }
            if accepts(.greenGain) { set(.greenGain, percent: g.green) }
            if accepts(.blueGain) { set(.blueGain, percent: g.blue) }
        }
    }

    /// Instantané des valeurs courantes (création d'un profil depuis les réglages actuels).
    var currentSettings: ProfileSettings {
        ProfileSettings(colorPreset: colorPreset, brightness: brightness, contrast: contrast, volume: nil,
                        gains: colorPreset.isUser ? .init(red: redGain, green: greenGain, blue: blueGain) : nil)
    }

    // MARK: - File d'écriture

    private func enqueue(_ control: Control, raw: UInt16) {
        pending[control] = raw
        applying.insert(control)
        guard writers[control] == nil else { return }
        nextWriterID += 1
        let writerID = nextWriterID
        // La tâche démarre après cette affectation (même acteur) : l'entrée existe avant son premier tour.
        writers[control] = (writerID, Task { [weak self] in await self?.drain(control, writerID: writerID) })
    }

    /// Écrit la dernière valeur en attente, patiente l'intervalle du réglage, recommence s'il y en a une nouvelle.
    private func drain(_ control: Control, writerID: Int) async {
        defer {
            // Une tâche annulée (débranchement) ne doit pas effacer la tâche qui l'a remplacée.
            if writers[control]?.id == writerID {
                writers[control] = nil
                if pending[control] == nil { applying.remove(control) }
            }
        }
        while !Task.isCancelled, let value = pending.removeValue(forKey: control) {
            guard let access, connection.isUsable || connection == .connecting else { pending.removeAll(); return }
            let generation = accessGeneration
            do {
                try await access.write(control.code, value: value)
            } catch {
                // Écran débranché, endormi ou rattaché entre-temps : cet échec ne dit plus rien de son état.
                guard !Task.isCancelled, generation == accessGeneration,
                      connection != .disconnected, connection != .asleep else { return }
                failedOperation = "Écriture \(control.title.lowercased()) (0x\(String(control.code, radix: 16, uppercase: true)))"
                // Les valeurs jamais arrivées à l'écran ne doivent pas s'afficher comme « dernières » connues.
                restoreConfirmedValues(for: Set(pending.keys).union([control]))
                connection = .unresponsive(reason: String(describing: error))
                scheduleRecovery()
                return
            }
            guard !Task.isCancelled else { return }
            confirmed[control] = value
            try? await Task.sleep(for: minimumWriteInterval(for: control))
        }
    }

    /// Abandonne les écritures en attente et réaffiche la dernière valeur confirmée de ces réglages.
    private func restoreConfirmedValues(for controls: Set<Control>) {
        pending.removeAll()
        for control in controls {
            applying.remove(control)
            if let raw = confirmed[control] {
                store(VCPValue(current: raw, maximum: maxima[control] ?? 100), for: control)
            }
        }
    }

    private func cancelWriters() {
        writers.values.forEach { $0.task.cancel() }
        writers.removeAll()
        pending.removeAll()
        applying.removeAll()
    }

    // MARK: - Conversions

    private func setMutedFlag(_ muted: Bool) {
        isMuted = muted
        defaults.set(muted, forKey: mutedKey)
    }

    private func percent(_ v: VCPValue, _ control: Control) -> Int {
        let max = v.maximum == 0 ? 100 : Int(v.maximum)
        return Int((Double(v.current) / Double(max) * 100).rounded())
    }

    private func raw(fromPercent p: Int, _ control: Control) -> UInt16 {
        let max = Double(maxima[control] ?? 100)
        return UInt16((Double(p) / 100 * max).rounded())
    }
}

#if DEBUG
extension DisplayController {
    /// Contrôleur factice pour les aperçus SwiftUI et les tests.
    static func preview(connection: ConnectionState = .connected) -> DisplayController {
        let c = DisplayController(id: "preview", name: "Mi Monitor",
                                  identity: DisplayIdentity(productName: "Mi Monitor", manufacturer: "XMI"),
                                  displayID: nil, access: nil, defaults: UserDefaults(suiteName: "preview")!)
        c.brightness = 45; c.contrast = 70; c.volume = 6; c.hasReadValues = true
        c.connection = connection
        c.firmware = "V1.0.10"; c.mccsVersion = "2.2"
        c.readableControls = [.brightness, .contrast, .volume, .colorPreset, .redGain, .greenGain, .blueGain, .input]
        return c
    }
}
#endif

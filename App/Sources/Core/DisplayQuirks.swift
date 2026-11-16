// Particularités DDC propres à chaque modèle d'écran, mesurées avec ddctool.
// Pour un nouvel écran (ex. AOC) : mesurer avec `ddctool caps / probe / sweep / seq`, puis ajouter
// un profil ici (double écriture ? silences ? nom de l'entrée du Mac ?).
// Un écran inconnu reçoit le profil « prudent » : mêmes silences que le Mi Monitor, rien de supposé
// sur ses entrées ni ses préréglages (ils sont lus dans ses capacités).

import DDCKit
import Foundation

nonisolated enum DisplayQuirks {
    /// Titre (et sous-titre éventuel) d'une entrée, propre à un modèle.
    struct InputTitle: Sendable, Equatable {
        var title: String
        var subtitle: String?
    }

    /// Ce que l'on sait d'un modèle d'écran.
    struct Profile: Sendable {
        /// Nom du profil (diagnostic), ex. « Mi Monitor » ou « Écran inconnu ».
        var name: String
        /// Vrai si le modèle a été mesuré (faux : réglages prudents par défaut).
        var isKnown: Bool
        /// Temporisation DDC (double écriture, silences après écriture).
        var timing: DDCTiming
        /// Réglages « lents » : l'écran est muet après leur écriture et ignore ce qu'il reçoit pendant ce temps.
        /// L'app espace alors leurs écritures (900 ms au lieu de 60 ms).
        var slowControls: Set<Control>
        /// Noms d'entrées propres au modèle (ex. Mi Monitor : 0x10 → « USB-C », sous-titre « DisplayPort 2 »).
        var inputTitles: [InputSource: InputTitle]
        /// Noms de préréglages propres au modèle (ex. Mi Monitor : 0x0B → « Utilisateur », il n'en a qu'un).
        var presetTitles: [ColorPreset: String]
        /// Préréglages proposés si la chaîne de capacités est illisible.
        var defaultPresets: [ColorPreset]
        /// Entrées proposées si la chaîne de capacités est illisible.
        var defaultInputs: [InputSource]
        /// Entrée du Mac connue d'avance (sinon apprise à la première connexion).
        var macInput: InputSource?
        /// Réglages jamais relus mais connus du modèle (alimentation 0xD6) : comptés dans
        /// supportedControls même si la chaîne de capacités n'a pas pu être lue.
        var unreadControls: Set<Control> = []
    }

    /// Réglages lents d'un écran inconnu : son et gains, par prudence (comme le Mi Monitor).
    static let prudentSlowControls: Set<Control> = [.volume, .redGain, .greenGain, .blueGain]

    /// Silences prudents : ceux mesurés sur le Mi Monitor (cf. miMonitor).
    private static let prudentQuiet: [UInt8: TimeInterval] = [
        VCPCode.volume: 0.9, VCPCode.redGain: 0.9, VCPCode.greenGain: 0.9, VCPCode.blueGain: 0.9,
        VCPCode.colorPreset: 0.6, VCPCode.inputSource: 2.0,
    ]

    /// Mi Monitor (firmware V1.0.10), mesures du 16 nov. 2026 :
    ///  • requête ignorée si envoyée une seule fois → double écriture (défaut de DDCTiming) ;
    ///  • après son / gains R V B : ~820 ms de silence ;
    ///  • après un changement de préréglage couleur : 200–500 ms de silence
    ///    (une luminosité envoyée 200 ms après est perdue, à 500 ms elle passe) ;
    ///  • changement de source : l'écran resynchronise l'image, on lui laisse 2 s.
    static let miMonitor: Profile = {
        var t = DDCTiming()
        t.quietAfterWrite = prudentQuiet
        return Profile(
            name: "Mi Monitor", isKnown: true, timing: t,
            slowControls: prudentSlowControls,
            inputTitles: [.displayPort2: InputTitle(title: "USB-C", subtitle: "DisplayPort 2")],
            presetTitles: [.user: "Utilisateur"],
            defaultPresets: [.warm5000K, .neutral6500K, .cool9300K, .user],
            defaultInputs: [.hdmi1, .hdmi2, .displayPort1, .displayPort2],
            macInput: .displayPort2, unreadControls: [.power])
    }()

    /// Écran jamais mesuré : silences et réglages lents prudents, rien d'autre de supposé.
    static let unknown: Profile = {
        var t = DDCTiming()
        t.quietAfterWrite = prudentQuiet
        return Profile(name: "Écran inconnu", isKnown: false, timing: t, slowControls: prudentSlowControls,
                       inputTitles: [:], presetTitles: [:], defaultPresets: [], defaultInputs: [], macInput: nil)
    }()

    /// Profil du modèle identifié par son EDID.
    static func profile(for identity: DisplayIdentity) -> Profile {
        if identity.manufacturer == "XMI" && identity.productName == "Mi Monitor" { return miMonitor }
        return unknown
    }

    /// Réglages de temporisation DDC adaptés à l'écran identifié.
    static func timing(for identity: DisplayIdentity) -> DDCTiming {
        profile(for: identity).timing
    }
}

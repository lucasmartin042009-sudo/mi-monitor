// Profils enregistrables (« Montage photo sRGB », « Nuit », « Jeu »…) appliqués en un clic.
// Stockés en JSON dans ~/Library/Application Support/Mi Monitor/profiles.json.

import Foundation
import Observation

/// Valeurs appliquées par un profil. nil = ne pas toucher à ce réglage.
struct ProfileSettings: Codable, Equatable, Sendable {
    struct Gains: Codable, Equatable, Sendable {
        var red: Int, green: Int, blue: Int
    }

    var colorPreset: ColorPreset?
    var brightness: Int?
    var contrast: Int?
    var volume: Int?
    /// Uniquement utile en préréglage Utilisateur.
    var gains: Gains?

    /// Résumé court, ex. « 6500 K · lum. 45 % · contraste 70 ».
    var summary: String {
        var parts: [String] = []
        if let colorPreset {
            // Préréglage Utilisateur : les gains distinguent deux profils (« R 60 · V 50 · B 42 »).
            if colorPreset.isUser, let gains {
                parts.append("R \(gains.red) · V \(gains.green) · B \(gains.blue)")
            } else {
                parts.append(colorPreset.isUser ? "R V B" : colorPreset.title)
            }
        }
        if let brightness { parts.append("lum. \(brightness) %") }
        if let contrast { parts.append("contraste \(contrast)") }
        if let volume { parts.append("son \(volume) %") }
        return parts.joined(separator: " · ")
    }
}

/// Combinaison de touches globale (codes Carbon : keyCode + modificateurs Carbon).
struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// Libellé prêt à afficher, ex. « ⌃⌥1 ».
    var display: String
}

struct Profile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// Nom du SF Symbol.
    var symbol: String
    var settings: ProfileSettings
    var hotKey: KeyCombo?
    /// Écran visé (identifiant de DisplayController) ; nil = « écran sélectionné ».
    /// Absent des profils enregistrés avant le multi-écran : ils restent donc globaux.
    var displayID: String? = nil

    /// Symboles proposés dans l'éditeur.
    static let symbolChoices = ["camera.aperture", "photo", "moon.fill", "gamecontroller.fill",
                                "sun.max.fill", "display", "film", "book.fill"]

    /// Noms français des symboles, pour VoiceOver et les infobulles.
    static let symbolNames: [String: String] = [
        "camera.aperture": "Appareil photo", "photo": "Photo", "moon.fill": "Lune",
        "gamecontroller.fill": "Manette", "sun.max.fill": "Soleil", "display": "Écran",
        "film": "Film", "book.fill": "Livre",
    ]
}

@Observable
final class ProfileStore {
    private(set) var profiles: [Profile] = []
    private let url: URL

    init(url: URL = ProfileStore.defaultURL) {
        self.url = url
        load()
    }

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mi Monitor", isDirectory: true)
        return dir.appendingPathComponent("profiles.json")
    }

    /// Profils proposés au premier lancement. L'écran n'a pas de mode sRGB :
    /// « Montage photo sRGB » s'en approche avec 6500 K et une luminosité réduite.
    static let defaults: [Profile] = [
        Profile(name: "Montage photo sRGB", symbol: "camera.aperture",
                settings: .init(colorPreset: .neutral6500K, brightness: 45, contrast: 70)),
        Profile(name: "Nuit", symbol: "moon.fill",
                settings: .init(colorPreset: .warm5000K, brightness: 15)),
        Profile(name: "Jeu", symbol: "gamecontroller.fill",
                settings: .init(brightness: 100, contrast: 80)),
    ]

    func profile(id: UUID) -> Profile? { profiles.first { $0.id == id } }
    func profile(named name: String) -> Profile? {
        profiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// Profils proposés pour un écran : les siens et les profils globaux (sans écran).
    func profiles(for display: DisplayController) -> [Profile] {
        profiles.filter { $0.displayID == nil || $0.displayID == display.id }
    }

    /// Profil (de cet écran ou global) dont toutes les valeurs définies correspondent à l'état de l'écran.
    func activeProfile(for display: DisplayController) -> Profile? {
        profiles(for: display).first { p in
            let s = p.settings
            if let c = s.colorPreset, c != display.colorPreset { return false }
            if let b = s.brightness, b != display.brightness { return false }
            if let c = s.contrast, c != display.contrast { return false }
            if let v = s.volume, v != display.volume { return false }
            // En préréglage Utilisateur, les gains R V B font partie du profil.
            if s.colorPreset?.isUser == true, let g = s.gains,
               (g.red, g.green, g.blue) != (display.redGain, display.greenGain, display.blueGain) { return false }
            return s.colorPreset != nil || s.brightness != nil || s.contrast != nil || s.volume != nil
        }
    }

    func add(_ profile: Profile) { profiles.append(profile); save() }

    func update(_ profile: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        save()
    }

    func remove(id: UUID) { profiles.removeAll { $0.id == id }; save() }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        profiles.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    private func load() {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = list
        } else {
            profiles = Self.defaults
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(profiles).write(to: url, options: .atomic)
            // Les phrases Siri / Spotlight citent les noms des profils : on les tient à jour.
            MiMonitorShortcuts.updateAppShortcutParameters()
        } catch {
            NSLog("Mi Monitor : enregistrement des profils impossible : \(error)")
        }
    }
}

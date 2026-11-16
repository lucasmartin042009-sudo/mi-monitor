// Profils exposés à Raccourcis : entité « Profil » et action « Appliquer un profil ».

import AppIntents
import Foundation

/// Un profil de Mi Monitor vu par Raccourcis (copie légère : identifiant, nom, symbole).
struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Profil"
    static let defaultQuery = ProfileQuery()

    let id: UUID
    let name: String
    let symbol: String
    let summary: String

    @MainActor
    init(_ profile: Profile) {
        id = profile.id
        name = profile.name
        symbol = profile.symbol
        // Profil lié à un écran : son nom précède le résumé (deux profils de même nom, un par
        // écran, restent ainsi distincts dans Raccourcis).
        let screen = profile.displayID.map { AppModel.shared.displays.controller(id: $0)?.displayName ?? "Écran inconnu" }
        summary = [screen, profile.settings.summary.isEmpty ? nil : profile.settings.summary]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: summary.isEmpty ? nil : "\(summary)",
                              image: .init(systemName: symbol))
    }
}

/// Recherche des profils dans le magasin de l'app (AppModel.shared.profiles).
struct ProfileQuery: EntityStringQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
        let store = AppModel.shared.profiles
        return identifiers.compactMap { store.profile(id: $0) }.map(ProfileEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ProfileEntity] {
        AppModel.shared.profiles.profiles.map(ProfileEntity.init)
    }

    /// Recherche par nom, insensible à la casse et aux accents (« nuit » trouve « Nuit »).
    @MainActor
    func entities(matching string: String) async throws -> [ProfileEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = AppModel.shared.profiles.profiles
        guard !query.isEmpty else { return all.map(ProfileEntity.init) }
        return all.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.map(ProfileEntity.init)
    }
}

/// « Appliquer le profil … »
struct ApplyProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Appliquer un profil"
    static let description = IntentDescription(
        "Applique un profil enregistré de Mi Monitor (couleur, luminosité, contraste…) sur son écran, ou sur l'écran sélectionné si le profil n'en vise aucun ou si le sien n'est pas branché.")
    static let openAppWhenRun = false

    @Parameter(title: "Profil")
    var profile: ProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Appliquer le profil \(\.$profile)")
    }

    init() {}

    init(profile: ProfileEntity) { self.profile = profile }

    @MainActor
    func perform() async throws -> some IntentResult {
        // On relit le profil dans le magasin (il a pu être modifié ou supprimé depuis la création
        // du raccourci), avant d'attendre l'écran : l'erreur « profil introuvable » est immédiate.
        guard let stored = AppModel.shared.profiles.profile(id: profile.id) else {
            throw MiMonitorIntentError.profileNotFound
        }
        // Écran du profil s'il est connecté, sinon l'écran sélectionné.
        let display = try await IntentSupport.connectedDisplay(preferredID: stored.displayID)
        AppModel.shared.apply(stored, to: display)
        try await IntentSupport.waitForWrites(on: display)
        return .result()
    }
}

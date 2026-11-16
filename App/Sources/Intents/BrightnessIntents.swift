// Actions Raccourcis sur la luminosité d'un écran externe.
// Paramètre « Écran » facultatif : sans lui, l'action vise l'écran sélectionné dans Mi Monitor ;
// avec lui, cet écran-là uniquement (erreur claire s'il n'est pas branché ou s'il ne propose pas
// la luminosité par DDC/CI).
// Pas d'action « Changer de source » : quitter l'entrée du Mac ferait perdre son image.

import AppIntents

/// « Régler la luminosité de … à … % »
struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Régler la luminosité"
    static let description = IntentDescription(
        "Règle la luminosité d'un écran externe (0 à 100 %). Sans écran choisi : l'écran sélectionné dans Mi Monitor.")
    static let openAppWhenRun = false

    @Parameter(title: "Écran", description: "Écran à régler ; par défaut, l'écran sélectionné dans Mi Monitor.")
    var display: DisplayEntity?

    @Parameter(title: "Luminosité (%)", inclusiveRange: (0, 100))
    var level: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Régler la luminosité de \(\.$display) à \(\.$level) %")
    }

    init() {}

    init(level: Int, display: DisplayEntity? = nil) {
        self.level = level
        self.display = display
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let target = try await IntentSupport.connectedDisplay(for: display)
        try IntentSupport.requireSupport(.brightness, on: target)
        target.set(.brightness, percent: level)
        try await IntentSupport.waitForWrites(on: target)
        return .result()
    }
}

/// « Obtenir la luminosité de … » : renvoie un nombre (0–100) utilisable dans un raccourci.
struct GetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Obtenir la luminosité"
    static let description = IntentDescription(
        "Renvoie la luminosité actuelle d'un écran externe, en pourcentage. Sans écran choisi : l'écran sélectionné dans Mi Monitor.")
    static let openAppWhenRun = false

    @Parameter(title: "Écran", description: "Écran à lire ; par défaut, l'écran sélectionné dans Mi Monitor.")
    var display: DisplayEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Obtenir la luminosité de \(\.$display)")
    }

    init() {}

    init(display: DisplayEntity?) { self.display = display }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let target = try await IntentSupport.connectedDisplay(for: display)
        try IntentSupport.requireSupport(.brightness, on: target)
        // Relue sur l'écran : elle a pu changer avec ses boutons depuis la dernière relecture.
        return .result(value: await target.readBrightness())
    }
}

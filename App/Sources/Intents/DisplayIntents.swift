// Écrans exposés à Raccourcis : entité « Écran », pour le paramètre facultatif des actions
// de luminosité. L'identifiant est celui du contrôleur (n° de série EDID…), stable d'un
// branchement à l'autre ; le nom est le nom affiché par l'app (displayName).

import AppIntents
import Foundation

/// Un écran externe de Mi Monitor vu par Raccourcis (copie légère : identifiant et nom).
struct DisplayEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Écran"
    static let defaultQuery = DisplayQuery()

    let id: String
    let name: String
    /// Faux pour un écran enregistré dans un raccourci mais absent depuis le lancement de l'app :
    /// son nom n'est alors plus connu.
    let isKnown: Bool

    @MainActor
    init(_ display: DisplayController) {
        id = display.id
        name = display.displayName
        isKnown = true
    }

    /// Écran inconnu de l'app en ce moment (débranché avant son lancement).
    init(unknownID id: String) {
        self.id = id
        name = "Écran non branché"
        isKnown = false
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "display"))
    }
}

/// Recherche des écrans dans le gestionnaire de l'app (AppModel.shared.displays).
struct DisplayQuery: EntityQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [String]) async throws -> [DisplayEntity] {
        await IntentSupport.waitForScan()
        let manager = AppModel.shared.displays
        // Un écran absent reste résolu (sous un nom d'attente) : l'action dira clairement
        // qu'il n'est pas branché au lieu de perdre le paramètre.
        return identifiers.map { id in
            manager.controller(id: id).map(DisplayEntity.init) ?? DisplayEntity(unknownID: id)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [DisplayEntity] {
        await IntentSupport.waitForScan()
        return AppModel.shared.displays.displays.map(DisplayEntity.init)
    }
}

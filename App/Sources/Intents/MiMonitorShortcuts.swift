// Raccourcis d'app proposés d'office dans l'app Raccourcis et à Siri / Spotlight.
// Chaque phrase doit contenir le nom de l'app (\(.applicationName)).
// Les paramètres Int ne peuvent pas figurer dans une phrase : Raccourcis demande la valeur.
// Le profil (AppEntity) le peut : « Applique Nuit dans Mi Monitor ». La liste des noms est
// rafraîchie par updateAppShortcutParameters() au lancement et à chaque enregistrement des profils.

import AppIntents

struct MiMonitorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ApplyProfileIntent(),
            phrases: [
                "Applique le profil \(\.$profile) dans \(.applicationName)",
                "Applique \(\.$profile) dans \(.applicationName)",
                "\(\.$profile) sur \(.applicationName)",
                "Applique un profil dans \(.applicationName)",
                "Applique un profil \(.applicationName)",
                "Change de profil dans \(.applicationName)",
            ],
            shortTitle: "Appliquer un profil",
            systemImageName: "person.crop.rectangle.stack"
        )
        AppShortcut(
            intent: SetBrightnessIntent(),
            phrases: [
                "Règle la luminosité dans \(.applicationName)",
                "Règle la luminosité du \(.applicationName)",
            ],
            shortTitle: "Régler la luminosité",
            systemImageName: "sun.max.fill"
        )
        AppShortcut(
            intent: GetBrightnessIntent(),
            phrases: [
                "Quelle est la luminosité du \(.applicationName)",
                "Obtiens la luminosité dans \(.applicationName)",
            ],
            shortTitle: "Obtenir la luminosité",
            systemImageName: "sun.min"
        )
    }
}

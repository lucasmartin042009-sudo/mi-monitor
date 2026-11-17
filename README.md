# Mi Monitor

App macOS de barre des menus pour piloter ses écrans externes en DDC/CI depuis un Mac Apple Silicon, avec un panneau
inspiré du Centre de contrôle (Liquid Glass, macOS 26+). Non sandboxée : les API IOKit privées l'interdisent, elle n'est
donc pas distribuable sur l'App Store.

> **Compatibilité.** L'app lit les capacités de chaque écran (commande DDC 0xF3) et n'affiche que ce qu'il annonce :
> elle devrait fonctionner avec la plupart des écrans DDC/CI. Elle n'a été **testée et réglée en vrai que sur le
> Xiaomi Mi Monitor 4K** (firmware V1.0.10, en USB-C/DisplayPort). Un autre écran reçoit des temporisations prudentes ;
> ses éventuelles particularités se mesurent avec `ddctool` puis s'ajoutent dans `DisplayQuirks.swift`.
> Plusieurs écrans externes sont gérés (sélecteur dans le panneau).

## Ce que l'app fait

- **Panneau de barre des menus** : profils en un clic, luminosité, contraste et son, sourdine (simulée : l'écran n'a pas de
  commande de sourdine), préréglages couleur (5000 K, 6500 K, 9300 K, Utilisateur avec gains R V B), source d'entrée avec
  confirmation, interrupteur « Suivre le MacBook ».
- **Touches du clavier** : luminosité et son agissent sur l'écran externe quand le pointeur s'y trouve, avec un OSD en
  capsule de verre facultatif (« Aucun » par défaut : avec Canopy, l'encoche l'affiche déjà). Nécessite l'autorisation
  Accessibilité.
- **Mode noir** (⌃⌥⌘N ou bouton du panneau) : écran entièrement noir et rétroéclairage au minimum, **sans
  éteindre l'écran** — la charge USB-C du Mac et le DDC continuent. Un clic sur l'écran noir le rallume.
- **Profils** enregistrables (globaux ou liés à un écran), avec raccourci clavier global facultatif.
- **Synchronisation** de la luminosité avec l'écran du MacBook, écran par écran (avec écart réglable).
- **Raccourcis (App Intents)** : « Régler la luminosité », « Obtenir la luminosité » (écran au choix), « Appliquer un profil ».
- **Ouverture à la connexion** (SMAppService).
- **Erreurs** : écran débranché, DDC qui ne répond pas, veille ; rebranchement et réveil détectés automatiquement.

Ce que le Mi Monitor sait faire (et ne pas faire) est mesuré dans [docs/etape0-bilan.md](docs/etape0-bilan.md) ;
la conception multi-écran est dans [docs/multi-ecran.md](docs/multi-ecran.md).

### Testé en vrai (Mi Monitor, MacBook Pro M3 Pro, macOS 27)

Curseurs luminosité / contraste / son, profils, sourdine simulée, confirmation de changement de source, touches de
luminosité du clavier (pointeur sur l'écran externe ou sur le MacBook), synchro avec le MacBook (pause après réglage
manuel, reprise), raccourcis clavier des profils, actions Raccourcis, inscription à l'ouverture de session.
Testé aussi : mode noir (charge maintenue à 65 W). Veille DDC (0xD6) testée et **bloquée** pour le Mi Monitor :
elle coupe la charge USB-C du Mac et l'écran ne se réveille plus qu'avec son bouton. Non testé : second écran réel.

## Prérequis

- Mac Apple Silicon, macOS 26 ou plus récent.
- Xcode 26 ou plus récent, et [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- DDC/CI activé dans le menu de l'écran.
- Un compte développeur Apple configuré dans Xcode (signature « Apple Development » ; un compte gratuit suffit).

### Signature : `Config/Local.xcconfig`

L'identifiant de l'app et l'équipe de signature ne sont pas dans le dépôt. Copier l'exemple et le remplir :

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
# puis éditer APP_BUNDLE_ID et DEVELOPMENT_TEAM
```

`Config/Local.xcconfig` est ignoré par git.

## Construire et installer

```bash
xcodegen generate
xcodebuild -project XiaomiDisplay.xcodeproj -scheme XiaomiDisplay -configuration Release -derivedDataPath build/dd build
cp -R "build/dd/Build/Products/Release/Mi Monitor.app" ~/Applications/
open ~/Applications/"Mi Monitor.app"
```

Ou ouvrir `XiaomiDisplay.xcodeproj` dans Xcode (après `xcodegen generate`) et lancer le schéma **XiaomiDisplay**.

Après le premier lancement :

1. **Touches du clavier** : Réglages de Mi Monitor › Général › « Autoriser… », puis cocher Mi Monitor dans
   Réglages Système › Confidentialité et sécurité › Accessibilité. Chaque nouvelle signature de l'app peut demander de
   recocher la case.
2. **Raccourcis** : les actions apparaissent dans l'app Raccourcis une fois l'app lancée au moins une fois depuis
   `~/Applications` ou `/Applications`.
3. **Conflit possible** : quitter MonitorControl (ou désactiver ses touches) — deux apps sur le même bus DDC se gênent.

## Tests

```bash
cd Packages/DDCKit && swift test          # trames DDC, capacités, réessais, silences de l'écran
xcodebuild -project XiaomiDisplay.xcodeproj -scheme XiaomiDisplay -derivedDataPath build/dd test   # contrôleur, profils, touches
```

## Outil de diagnostic `ddctool`

```bash
cd Packages/DDCKit
swift run ddctool list              # écrans externes et association IOAVService ↔ écran
swift run ddctool caps              # chaîne de capacités (0xF3) et codes VCP annoncés
swift run ddctool probe             # lit les codes usuels
swift run ddctool get 10            # lit la luminosité
swift run ddctool set 10 60         # écrit puis relit (mesure aussi le silence de l'écran)
swift run ddctool sweep 62 7,8,9 80 # simule un curseur
swift run ddctool seq 14=4,10=15 60 # écritures enchaînées sur plusieurs codes (comme un profil)
```

## Architecture

```
Packages/DDCKit/           couche DDC/CI indépendante de l'UI (testable)
  DDCPacket.swift          trames et sommes de contrôle
  DDCDevice.swift          délais, double écriture, réessais, silences de l'écran
  DisplayDiscovery.swift   IOAVService (API privée Apple Silicon) ↔ écran (EDID)
  Capabilities.swift       analyse de la chaîne de capacités MCCS
  ddctool/                 outil en ligne de commande
App/Sources/
  Core/                    DisplayController (état + file d'écriture), DisplayManager (branchements, veille),
                           DisplayQuirks (particularités par modèle), profils, préférences
  UI/Panel, UI/Components  panneau de la barre des menus
  UI/Settings              fenêtre Réglages (Général, Profils, Raccourcis, À propos)
  Integrations/            touches clavier (event tap), OSD, raccourcis globaux, synchro MacBook
  Intents/                 App Intents pour Raccourcis
Config/                    signature (Signing.xcconfig + Local.xcconfig personnel, non suivi)
docs/                      bilan DDC du Mi Monitor, conception multi-écran, maquette validée
```

Points clés de la couche DDC sur ce Mi Monitor (mesurés) :

- chaque requête doit être **envoyée deux fois**, sinon l'écran renvoie un message nul ;
- après une écriture du **son ou des gains R V B**, l'écran ignore toute commande pendant ~820 ms ; après un
  **préréglage couleur**, 200 à 500 ms. L'app regroupe donc les écritures (la dernière valeur gagne) et attend la fin
  de ces silences avant la commande suivante.

Pour ajouter un autre écran : mesurer avec `ddctool`, puis ajouter ses particularités dans
`App/Sources/Core/DisplayQuirks.swift`.

## Licence

MIT — voir [LICENSE](LICENSE).

## Crédits

Accès DDC sur Apple Silicon inspiré de [MonitorControl](https://github.com/MonitorControl/MonitorControl) et
[m1ddc](https://github.com/waydabber/m1ddc) (licence MIT) ; le code ici est réécrit, pas copié.

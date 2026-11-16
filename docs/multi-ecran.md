# Passage en multi-écran — conception (16 nov. 2026)

Objectif : piloter le Mi Monitor **et** un second écran (AOC 4K mini LED en HDMI, attendu prochainement),
sans rien supposer de ce second écran avant de l'avoir mesuré. Le MacBook Pro M3 Pro accepte 2 écrans externes.

## Principes

1. **L'interface suit les capacités lues sur chaque écran** (chaîne 0xF3), jamais une liste codée en dur.
   Un réglage absent des capacités n'est pas affiché ; un réglage annoncé mais qui échoue à la lecture est masqué
   aussi (certains écrans annoncent des codes qu'ils refusent).
2. **Les particularités mesurées vivent dans `DisplayQuirks`** (double écriture, silences, nom de l'entrée du Mac…).
   Un écran inconnu reçoit des réglages prudents par défaut.
3. **Un écran « sélectionné »**, mémorisé par identifiant (n° de série EDID), remplace « le premier détecté ».
   Il sert de cible par défaut aux profils sans écran, aux actions Raccourcis sans écran et au panneau.
4. **Les touches du clavier** visent déjà l'écran sous le pointeur (inchangé).
5. **Un écran simulé** (`MIMONITOR_FAKE_DISPLAY=1`, Debug uniquement) permet de tester l'interface à deux écrans
   avant l'arrivée de l'AOC.

## Modèle

### Valeurs VCP génériques

- `ColorPreset` et `InputSource` deviennent des **structs** `RawRepresentable<UInt16>` (Hashable, Codable, Identifiable)
  avec des constantes statiques pour les valeurs MCCS standard et un titre lisible tiré d'une table :
  - préréglages 0x14 : 0x01 sRGB, 0x02 Natif, 0x03 4000 K, 0x04 5000 K, 0x05 6500 K, 0x06 7500 K, 0x07 8200 K,
    0x08 9300 K, 0x09 10000 K, 0x0A 11500 K, 0x0B Utilisateur 1, 0x0C Utilisateur 2, 0x0D Utilisateur 3 ;
    toute autre valeur : « Préréglage 0xNN » ;
  - sources 0x60 : 0x01 VGA 1, 0x02 VGA 2, 0x03 DVI 1, 0x04 DVI 2, 0x0F DisplayPort 1, 0x10 DisplayPort 2,
    0x11 HDMI 1, 0x12 HDMI 2, 0x1B USB-C ; autre : « Entrée 0xNN ».
  - Les constantes existantes restent disponibles sous leurs noms actuels (`.warm5000K`, `.neutral6500K`,
    `.cool9300K`, `.user`, `.hdmi1`, `.hdmi2`, `.displayPort1`, `.displayPort2`) pour limiter les changements.
  - `isUser` (0x0B–0x0D) remplace les comparaisons `== .user`.
- Le nom d'une entrée peut être surchargé par écran via `DisplayQuirks` (Mi Monitor : 0x10 → « USB-C »,
  sous-titre « DisplayPort 2 »).

### `DisplayController` (par écran)

Nouveaux membres :
- `capabilities: Capabilities?` (lu une fois à la connexion, gardé ensuite) ;
- `supportedControls: Set<Control>` — calculé : codes annoncés ∩ lectures réussies ; si la chaîne de capacités est
  illisible, repli sur les codes dont la lecture a réussi ;
- `availablePresets: [ColorPreset]` (valeurs de 0x14 dans les capacités, sinon les 4 du Mi Monitor si c'est lui,
  sinon la valeur courante seule) ; `availableInputs: [InputSource]` (idem avec 0x60) ;
- `macInput: InputSource?` — l'entrée active lue à la première connexion réussie (c'est celle du Mac, puisque
  l'écran affiche le Mac) ; mémorisée par écran dans UserDefaults ;
- `displayName` — nom unique lisible : nom EDID, suffixé de la fin du n° de série si deux écrans ont le même nom ;
- `quirks: DisplayQuirks.Profile` (titres d'entrées, réglages lents, silences).
- `Control.isSlow` devient une propriété du contrôleur : `isSlow(_ control:)` lue dans les quirks
  (Mi Monitor : son et gains ; écran inconnu : son et gains aussi, par prudence).

### `DisplayManager`

- `displays` triés de façon stable (ordre de première détection mémorisé) ;
- `selectedID: String?` persistant, `selected: DisplayController?` (sélectionné s'il est présent, sinon le premier
  connecté, sinon le premier) ; `select(_:)` ;
- `primary` est **retiré** : remplacer partout par `selected` (ou par l'écran visé explicitement) ;
- écran simulé : en Debug, si la variable d'environnement `MIMONITOR_FAKE_DISPLAY=1` est présente, ajouter un
  contrôleur « AOC Q27G3XMN (simulé) » branché sur un `SimulatedDDC` (acteur, valeurs en mémoire, petites latences,
  capacités MCCS plausibles : 0x10 0x12 0x14(01 05 06 08 0B) 0x16 0x18 0x1A 0x60(0F 11 12) 0x62, pas de 0xD6)
  — l'interface doit le traiter comme un écran normal.

### Profils

- `Profile.displayID: String?` — nil = « écran sélectionné » ; sinon l'écran visé. Rétrocompatible au décodage
  (champ absent = nil). Les profils existants restent donc globaux.
- `ProfileStore.activeProfile(for:)` ne considère que les profils de cet écran ou globaux.
- `AppModel.apply(_:to:)` : cible = écran du profil s'il est connecté, sinon l'écran sélectionné ; renvoie un Bool.
- Un préréglage absent des capacités de l'écran visé est ignoré (pas d'écriture d'une valeur refusée).

### Synchro MacBook

- `AppSettings.followMacBook` devient un ensemble d'identifiants d'écrans (`followMacBookDisplays: Set<String>`) ;
  migration : l'ancien booléen vrai → l'écran sélectionné ; `followOffset` reste global.

## Interface

- **Panneau** : si plus d'un écran, une rangée de sélection en haut (boutons en verre, un par écran : SF Symbol
  `display`, nom court, pastille d'état) ; le reste du panneau montre l'écran sélectionné. Avec un seul écran,
  rien ne change. Modules et rangées masqués selon `supportedControls` (Couleur si 0x14, gains si Utilisateur et
  0x16/18/1A, Son si 0x62, Source si 0x60…). Les profils listés sont ceux de l'écran + globaux.
- **Réglages** :
  - Général : « Écran par défaut » (sélectionné) ; « Suivre le MacBook » par écran ;
  - Profils : sélecteur « Écran » dans l'éditeur (« Écran sélectionné » ou un écran précis) ; préréglages et
    réglages proposés selon les capacités de l'écran choisi ;
  - À propos : une section par écran (nom, firmware, MCCS, série, connexion, codes VCP pris en charge).
- **Raccourcis** : `DisplayEntity` (AppEntity sur les écrans connus) ; paramètre « écran » facultatif dans
  « Régler la luminosité » et « Obtenir la luminosité » (défaut : écran sélectionné) ; « Appliquer le profil »
  suit l'écran du profil.

## Pour l'AOC, le jour où il arrive

```bash
cd Packages/DDCKit
swift run ddctool list && swift run ddctool caps 1 && swift run ddctool probe 1
swift run ddctool set 10 60 1     # puis remettre la valeur
swift run ddctool sweep 62 7,8,9 80 1 ; swift run ddctool seq 14=5,10=50 60 1
```
Puis ajouter son profil dans `DisplayQuirks` (double écriture ? silences ? nom de l'entrée du Mac ?).
Si le DDC ne répond pas en HDMI : essayer un câble USB-C → DisplayPort.

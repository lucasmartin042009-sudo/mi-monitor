# Étape 0 — Bilan DDC/CI du Mi Monitor (16 nov. 2026)

Matériel : MacBook Pro M3 Pro, macOS 27.2.1. Écran « Mi Monitor » (EDID XMI 61A9:27A1, n° de série masqué,
firmware V1.0.10, MCCS 2.2a), 3840×2160 @ 60 Hz, entrée active 0x10 = DisplayPort 2 (USB-C en mode DP).

Outil : `Packages/DDCKit` → `swift run ddctool list|caps|probe|get|set|sweep|raw`.

## Découvertes techniques

- **Double écriture obligatoire** : une requête isolée reçoit un message nul `6E 80 BE`.
  Envoyée deux fois (10 ms d'écart), l'écran répond. → `DDCTiming.writeCycles = 2`.
- **Silence après certaines écritures** : après Set VCP sur volume (0x62) et gains RVB (0x16/0x18/0x1A),
  l'écran ne répond plus pendant ~820 ms **et ignore les écritures reçues pendant ce temps**.
  Luminosité, contraste et préréglage n'ont pas ce silence (rafale de 6 écritures à 80 ms : valeur finale exacte).
  → l'UI devra regrouper les écritures par code (dernière valeur gagnante) avec un intervalle ≥ 900 ms
  pour les codes « lents ».
- Lecture d'un code : ~75 ms. Chaîne de capacités : ~750 ms (271 caractères).
- MonitorControl tourne aussi sur ce Mac et utilise le même bus : risque de collisions si les deux pilotent l'écran.

## Chaîne de capacités

```
(vcp(02 04 05 08 10 12 14(04 05 08 0B) 16 18 1A 60( 11 12 0F 10) 62 CC(01 02 03 04 05 06 07 09 0A 0E 0F 14 18 1A 1E)
B0 D6(01 05) DF )prot(monitor)type(LCD)cmds(01 02 03 07 0C F3)mccs_ver(2.2a)asset_eep(64)mpu_ver(FW: V1.0.10)
model(Model: Mi Monitor)mswhql(1))
```

## Bilan par fonction

| Code | Fonction | Annoncé | Lecture (valeur/max) | Écriture prouvée |
|------|----------|---------|----------------------|------------------|
| 0x10 | Luminosité | oui | 100/100 | ✅ 100→60→30→100, relu à chaque fois ; 10/10 en rafale |
| 0x12 | Contraste | oui | 75/100 | ✅ 75→70→75 relu |
| 0x14 | Préréglage couleur | oui (04 05 08 0B) | 5/12 (6500 K) | ✅ 5→4→5 relu |
| 0x16/0x18/0x1A | Gains R/V/B | oui | 50/100 chacun | ✅ rouge 50→45→50 relu (silence ~820 ms) |
| 0x60 | Source d'entrée | oui (11 12 0F 10) | 16 = DP 2 | ⏸ non testé (couperait l'image du Mac) |
| 0x62 | Volume | oui | 6/100 | ✅ 6→10→6 relu (silence ~820 ms) |
| 0x8D | Sourdine | non | refusé par l'écran | ❌ → sourdine à émuler (volume 0 + mémoire) |
| 0xD6 | Alimentation | oui (01 05) | 1 = allumé | ⏸ non testé (éteindrait l'écran) |
| 0x72 / 0x87 | Gamma / Netteté | non | refusé | ❌ |
| 0x0C, 0xDC, 0xCA, 0xCC | Temp. couleur, mode image, OSD, langue | 0xCC seul | répondent | non prévu dans l'UI |

Valeurs de préréglage annoncées : 0x04 = 5000 K, 0x05 = 6500 K, 0x08 = 9300 K, 0x0B = Utilisateur 1.
Sources annoncées : 0x11 HDMI 1, 0x12 HDMI 2, 0x0F DP 1, 0x10 DP 2 (USB-C).

#!/bin/zsh
# Capture PNG d'une planche de maquette HTML avec Chrome sans interface.
# usage : scripts/capture-maquette.sh <fichier.html> <sortie.png> [largeur] [hauteur]
set -e
in="$1"; out="$2"; w="${3:-1800}"; h="${4:-1400}"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size="$w,$h" --virtual-time-budget=1500 \
  --user-data-dir="$(mktemp -d)" --screenshot="$out" "file://$(cd "$(dirname "$in")" && pwd)/$(basename "$in")" 2>/dev/null
echo "$out"

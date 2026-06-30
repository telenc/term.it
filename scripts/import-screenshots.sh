#!/bin/bash
# Range les captures du Bureau dans assets/ et convertit la vidéo de démo en GIF.
#
# Prérequis : avoir pris 4 captures d'écran DANS L'ORDRE
#   1) accueil  2) terminal  3) sftp  4) réglages
# et (optionnel) un enregistrement .mov pour la démo.
#
# Usage : ./scripts/import-screenshots.sh
set -e
cd "$(dirname "$0")/.."
DESK="$HOME/Desktop"
mkdir -p assets

# 4 PNG les plus récents du Bureau, triés du plus ancien au plus récent.
# (compatible bash 3.2 de macOS : pas de mapfile)
shots=()
while IFS= read -r line; do
    [ -n "$line" ] && shots+=("$line")
done < <(ls -t "$DESK"/*.png 2>/dev/null | head -4 | tail -r)
names=(launcher terminal sftp settings)

if [ "${#shots[@]}" -lt 4 ]; then
    echo "⚠️  Trouvé ${#shots[@]} capture(s) sur le Bureau, il en faut 4."
else
    for i in 0 1 2 3; do
        cp "${shots[$i]}" "assets/${names[$i]}.png"
        echo "✅ assets/${names[$i]}.png  ← $(basename "${shots[$i]}")"
    done
fi

# Vidéo de démo la plus récente → GIF.
mov="$(ls -t "$DESK"/*.mov 2>/dev/null | head -1)"
if [ -n "$mov" ]; then
    echo "🎬 Conversion de $(basename "$mov") en GIF…"
    ffmpeg -y -i "$mov" -vf "fps=12,scale=900:-1:flags=lanczos" -loop 0 assets/demo.gif >/dev/null 2>&1
    echo "✅ assets/demo.gif"
fi

echo "Terminé. Vérifie les images dans assets/."

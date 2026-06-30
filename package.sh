#!/bin/bash
# Construit FreeTermius et l'empaquette dans un bundle .app macOS.
set -e
cd "$(dirname "$0")"

# Force l'Xcode stable : le compilateur Metal de la beta échoue sur le SDK 27.
if [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

CONFIG="${1:-release}"
echo "▶ Compilation ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/FreeTermius.app"

echo "▶ Création du bundle $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_PATH/FreeTermius" "$APP/Contents/MacOS/FreeTermius"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Copie les bundles de ressources SPM (plats, sans code) dans Resources/.
# Bundle.module les retrouve via le resourceURL de l'app.
for b in "$BIN_PATH"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/" || true
done

# Signature avec une identité STABLE si disponible (sinon ad-hoc).
# Une identité stable garde l'autorisation « Toujours autoriser » du trousseau
# entre les rebuilds ; l'ad-hoc redemande à chaque fois.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')"
fi
if [ -n "$SIGN_ID" ]; then
    echo "▶ Signature avec : $SIGN_ID"
    codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP"
else
    echo "▶ Signature ad-hoc (aucune identité trouvée)…"
    codesign --force --deep --sign - "$APP"
fi

echo "✅ Terminé : $APP"
echo "   Lance avec : open $APP"

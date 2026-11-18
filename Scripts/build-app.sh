#!/usr/bin/env bash
# Baut „reichi Sync“ ohne Xcode-Projekt direkt mit SwiftPM und setzt ein
# startfähiges .app-Bundle zusammen (ad hoc signiert).
#
#   Scripts/build-app.sh [release|debug] [Zielordner]
#
# Voraussetzungen: macOS 14+, Xcode 15+ Command Line Tools (swift, codesign,
# iconutil, plutil). Für Distribution siehe docs/SIGNING.md.
set -euo pipefail

CONFIG="${1:-release}"
OUT_DIR="${2:-dist}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="reichi Sync"
BUNDLE_ID="de.reichi.sync"
EXECUTABLE="ReichiSync"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Dieses Skript muss auf macOS ausgeführt werden (App-Bundle, codesign, iconutil)." >&2
  exit 1
fi

cd "$ROOT"
echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$EXECUTABLE" --arch arm64 --arch x86_64 2>/dev/null \
  || swift build -c "$CONFIG" --product "$EXECUTABLE"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
# Bei Universal-Builds liegt das Ergebnis in .build/apple/Products/<Config>
if [[ -d ".build/apple/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}" ]]; then
  BIN_DIR=".build/apple/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
fi

APP="$OUT_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
# SwiftPM-Ressourcenbundle (Lokalisierung) mitnehmen, falls vorhanden
for bundle in "$BIN_DIR"/ReichiSync_ReichiSync.bundle "$BIN_DIR"/ReichiSyncCore_ReichiSyncCore.bundle; do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Info.plist mit aufgelösten Variablen
sed -e "s/\$(EXECUTABLE_NAME)/$EXECUTABLE/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    "Sources/ReichiSyncApp/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# App-Icon aus dem Asset-Katalog als .icns
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cp Sources/ReichiSyncApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc-Signatur mit Entitlements (Sandbox + Netzwerk + Benutzer-Dateien)
echo "▶ codesign (ad hoc)"
codesign --force --deep --options runtime \
  --entitlements "Sources/ReichiSyncApp/ReichiSync.entitlements" \
  --sign "${CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --verbose=2 "$APP"

echo "✔ Fertig: $APP"
echo "  Starten mit: open \"$APP\""

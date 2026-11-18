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
MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-1}"

case "$CONFIG" in
  release|debug) ;;
  *)
    echo "Ungültige Konfiguration: $CONFIG (erlaubt: release, debug)" >&2
    exit 2
    ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Dieses Skript muss auf macOS ausgeführt werden (App-Bundle, codesign, iconutil)." >&2
  exit 1
fi

cd "$ROOT"
echo "▶ swift build -c $CONFIG (arm64 + x86_64)"
swift build -c "$CONFIG" --product "$EXECUTABLE" --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"
SOURCE_BINARY="$BIN_DIR/$EXECUTABLE"
if [[ ! -x "$SOURCE_BINARY" ]]; then
  echo "Build erfolgreich gemeldet, aber Binary fehlt: $SOURCE_BINARY" >&2
  exit 1
fi
ARCHS="$(lipo -archs "$SOURCE_BINARY")"
for required in arm64 x86_64; do
  if [[ " $ARCHS " != *" $required "* ]]; then
    echo "Binary ist nicht universal (gefunden: $ARCHS; fehlt: $required)." >&2
    exit 1
  fi
done

APP="$OUT_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$SOURCE_BINARY" "$APP/Contents/MacOS/$EXECUTABLE"
# SwiftPM-Ressourcenbundle (Lokalisierung) mitnehmen, falls vorhanden
for bundle in "$BIN_DIR"/ReichiSync_ReichiSync.bundle "$BIN_DIR"/ReichiSyncCore_ReichiSyncCore.bundle; do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Info.plist mit aufgelösten Variablen
sed -e "s/\$(EXECUTABLE_NAME)/$EXECUTABLE/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e "s/\$(MARKETING_VERSION)/$MARKETING_VERSION/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$CURRENT_PROJECT_VERSION/g" \
    "Sources/ReichiSyncApp/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# App-Icon aus dem Asset-Katalog als .icns
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
cp Sources/ReichiSyncApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc-Signatur mit Entitlements (Sandbox + Netzwerk + Benutzer-Dateien)
echo "▶ codesign (${CODESIGN_IDENTITY:-ad hoc})"
codesign --force --deep --options runtime \
  --entitlements "Sources/ReichiSyncApp/ReichiSync.entitlements" \
  --sign "${CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --verbose=2 "$APP"

echo "✔ Fertig: $APP"
echo "  Starten mit: open \"$APP\""

# reichi Sync auf einem Mac bauen

## Voraussetzungen

- macOS 14 Sonoma oder neuer
- Xcode 15 oder neuer aus dem App Store
- Xcode Command Line Tools
- Git
- optional: Homebrew und XcodeGen

Nach der Xcode-Installation einmal ausführen:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -version
swift --version
```

## Quellcode und Tests

```bash
git clone https://github.com/reichiClaw/RC-Webdav-Sync.git
cd RC-Webdav-Sync
git checkout main

swift build --target ReichiSyncCore \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
```

Die Tests benötigen Python 3 für den lokalen WebDAV-/Cloudreve-Testserver.
macOS bringt in aktuellen Xcode-Umgebungen nicht immer ein `python3` mit; falls
der Befehl fehlt:

```bash
brew install python
```

## Variante A: startfähiges App-Bundle per Skript

```bash
Scripts/build-app.sh release dist
open "dist/reichi Sync.app"
```

Das Skript baut ein Universal Binary für Apple Silicon (`arm64`) und Intel
(`x86_64`), erstellt `dist/reichi Sync.app`, übernimmt Ressourcen und Icon und
signiert lokal ad hoc. Prüfen:

```bash
lipo -archs "dist/reichi Sync.app/Contents/MacOS/ReichiSync"
codesign --verify --deep --strict --verbose=2 "dist/reichi Sync.app"
```

Erwartet werden beide Architekturen: `arm64 x86_64`. Ein ad-hoc-signiertes
Bundle ist für den eigenen Mac geeignet, aber nicht für die Weitergabe an
andere Macs. Nach einem Signaturwechsel kann macOS den gespeicherten
Ordnerzugriff verwerfen; dann den Sync-Ordner in den Einstellungen erneut
auswählen.

Für einen schnelleren Entwicklungsbuild:

```bash
Scripts/build-app.sh debug dist-debug
open "dist-debug/reichi Sync.app"
```

## Variante B: Xcode

```bash
brew install xcodegen
xcodegen generate
open ReichiSync.xcodeproj
```

In Xcode:

1. Scheme **ReichiSync** wählen.
2. Unter **Signing & Capabilities** das eigene Development Team wählen.
3. Mit `⌘B` bauen, mit `⌘R` starten und mit `⌘U` testen.

Eine reine Kompilierprüfung ohne Entwicklerzertifikat ist auch im Terminal
möglich:

```bash
xcodebuild \
  -project ReichiSync.xcodeproj \
  -scheme ReichiSync \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

## Signierte Weitergabe

Mit einem installierten Developer-ID-Zertifikat:

```bash
CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  Scripts/build-app.sh release dist
```

Danach muss die App für eine verlässliche Verteilung notariell beglaubigt und
das Ticket angeheftet werden. Die vollständigen Befehle stehen in
[`SIGNING.md`](SIGNING.md).

## App-Icon neu erzeugen

Der Build verwendet die bereits eingecheckten PNG-Größen im Asset-Katalog.
Das Icon-Skript bevorzugt eine skalierbare Quelle unter `Design/logo.svg`:

```bash
python3 -m pip install --user pillow cairosvg
python3 Scripts/generate-icon.py
```

Im aktuellen Repository ist `Design/logo.svg` noch nicht vorhanden, sondern
nur `Design/logo.png`. Eine SVG-Quelldatei sollte deshalb als
`Design/logo.svg` eingecheckt werden; eine Rückkonvertierung des PNG wäre nicht
verlustfrei.

## Häufige Fehler

- **`xcrun: error: invalid active developer path`**  
  `xcode-select` wie oben auf die vollständige Xcode-Installation setzen.
- **Signing verlangt ein Team**  
  Für lokale Skript-Builds ist kein Team nötig. In Xcode ein Team auswählen
  oder für eine reine Prüfung `CODE_SIGNING_ALLOWED=NO` verwenden.
- **App kann den Ordner nach einem Neubau nicht öffnen**  
  Den Ordner in den App-Einstellungen erneut auswählen.
- **Tests werden übersprungen oder der Testserver startet nicht**  
  `python3 --version` prüfen und `python3 -m py_compile
  Scripts/dev-webdav-server.py` ausführen.
- **Build auf Linux erfolgreich, App-Build dennoch fehlerhaft**  
  Linux kompiliert nur `ReichiSyncCore`; SwiftUI, AppKit, FSEvents, Keychain
  und das vollständige App-Bundle müssen auf macOS/Xcode geprüft werden.

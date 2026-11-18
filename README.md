# reichi Sync

Native macOS-App (macOS 14+, Apple Silicon und Intel), die einen lokalen Ordner
bidirektional mit **Cloudreve** (Standardserver `https://reichi.cloud`) oder einem
beliebigen WebDAV-Server (Nextcloud, ownCloud, Apache mod_dav, Synology …)
synchronisiert. Die App läuft als Menüleisten-Programm; das Hauptfenster zeigt
Übersicht, Aktivität, Konflikte, Freigaben und Einstellungen.

Mit Cloudreve kommen hinzu: **Chunked und fortsetzbare Uploads** über die
Cloudreve-Upload-API (Abbrüche werden an der letzten bestätigten Stelle
fortgesetzt), automatische Bereitstellung eines WebDAV-Kontos pro Gerät und
**Freigabelinks** (mit Passwort, Ablauf, Download-Limit) direkt aus der App.

Oberste Regeln der Implementierung:

- **Datenerhalt vor Fortschritt.** Konflikte werden nicht automatisch zugunsten
  einer Seite entschieden; beide erkannten Versionen bleiben erhalten
  (Konfliktkopie mit Gerätename und Zeitstempel). Kann ein Server eine Mutation
  nicht atomar gegen parallele Änderungen schützen, bleibt sie ausstehend.
- **Löschungen nur, wenn sie eindeutig sind.** Eine Löschung wird nur
  übertragen, wenn der Eintrag im gemeinsamen Stand (Baseline) bekannt war, die
  Bestandsaufnahme der anderen Seite vollständig war und sich die Datei dort
  seither nicht geändert hat. Netzwerkfehler, Authentifizierungsfehler oder
  unvollständige Listings führen nie zu Löschungen. Große Löschmengen werden
  zurückgehalten und müssen bestätigt werden.
- **Zugangsdaten nur im Schlüsselbund.** Keine Passwörter in Datenbank, Protokoll
  oder bei Umleitungen auf fremde Hosts.

---

## Inhalt

1. [Architekturüberblick](#architekturüberblick)
2. [Stand der Verifikation (was wurde getestet)](#stand-der-verifikation)
3. [Bauen und starten](#bauen-und-starten)
4. [Benutzung](#benutzung)
5. [Getroffene Entscheidungen](#getroffene-entscheidungen)
6. [Projektstruktur](#projektstruktur)
7. [Weitere Dokumente](#weitere-dokumente)

---

## Architekturüberblick

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ReichiSync (macOS-App, SwiftUI + AppKit)                                 │
│  ReichiSyncApp.swift   MenuBarExtra · Window("main") · Settings · Delegate│
│  AppModel              @MainActor-Fassade: Status, Listen, Aktionen       │
│  Views/                Übersicht · Aktivität · Konflikte · Einstellungen  │
│                        · Einrichtungsassistent · Menüleisten-Popover      │
│  Services/             KeychainStore · BookmarkStore (Security-Scoped)    │
│                        FolderWatcher (FSEvents) · ConnectivityMonitor     │
│                        (NWPathMonitor) · SleepWakeObserver · LoginItem    │
│                        (SMAppService) · NotificationService · AppPaths    │
├──────────────────────────────────────────────────────────────────────────┤
│ ReichiSyncCore (Swift Package, plattformunabhängig, auf Linux getestet)  │
│                                                                          │
│   SyncEngine (actor) ── orchestriert einen Durchgang:                    │
│     1 Root prüfen → 2 Server-Probe → 3 LocalScanner → 4 RemoteEnumerator  │
│     → 5 SyncPlanner (reine Funktion) → 6 DeletionGuard → 7 Ausführung     │
│     → Baseline nur nach bestätigtem Erfolg                                │
│                                                                          │
│   SyncPlanner    Drei-Wege-Vergleich Baseline/Lokal/Server, Entscheidungs-│
│                  tabelle, Rename-Erkennung (Hash), Ordner-Löschlogik      │
│   LocalScanner   NFC-Normalisierung, Hash-Cache (Größe+mtime), Settle-Zeit│
│   RemoteEnumerator  PROPFIND Depth 1 (parallel) oder RFC 6578 sync-coll.  │
│   WebDAVClient   URLSession, 207-Parser (namespace-aware), ETag/If-Match, │
│                  Redirect-/Auth-Härtung, Streaming-Up/Download            │
│   SyncStore (actor) SQLite (WAL): accounts, mappings, entries (Baseline),  │
│                  local_index, remote_index, conflicts, transfers, queue,  │
│                  pending_deletions                                        │
│   Util           RelativePath (Pfadsicherheit), ExclusionRules, SHA-256,  │
│                  SyncLogger (Redaktion von Secrets), RetryPolicy          │
└──────────────────────────────────────────────────────────────────────────┘
```

**Ablauf eines Durchgangs** (`SyncEngine.performSync`):

1. Existiert der lokale Stammordner? Sonst Zustand *Pausiert – Ordner fehlt*
   (keine Löschungen, kein Abgleich).
2. `PROPFIND Depth: 0` auf die Wurzel als echte Erreichbarkeitsprüfung.
   Netzwerkfehler → *Offline* mit exponentiellem Backoff (5 s … 5 min);
   401/403 → *Anmeldung erforderlich* (pausiert, keine Wiederholung).
3. Lokale Bestandsaufnahme (iterativ, Symlinks übersprungen, Ausschlüsse,
   Case-Kollisionen markiert, gerade geschriebene Dateien zurückgestellt,
   Hashes aus Cache oder neu berechnet).
4. Server-Bestandsaufnahme: `sync-collection` mit gespeichertem Token, sonst
   vollständige `PROPFIND Depth: 1`-Traversierung (bis zu 4 Ordner parallel).
   Teilfehler markieren Teilbäume als unvollständig – dort werden keine
   Löschungen abgeleitet.
5. Planung (reine Funktion `SyncPlanner.plan`): pro Pfad Zustand lokal/remote
   gegenüber der Baseline → Aktion nach Entscheidungstabelle (siehe
   `docs/ARCHITECTURE.md`).
6. Löschschutz: ≥ 25 Einträge oder > 20 % des Bestands oder „lokal komplett
   leer, Server nicht“ → Löschungen werden als `pending_deletions` gespeichert,
   der Rest wird ausgeführt, die UI fragt nach.
7. Ausführung in Phasen: Ordner anlegen → Umbenennungen (MOVE) → Transfers
   (begrenzt parallel) → Löschungen (tiefste zuerst) → Buchführung. Jede
   Aktion prüft unmittelbar vorher erneut die Vorbedingungen (Hash lokal,
   ETag/`If-Match` serverseitig). Baseline-Einträge werden nur nach
   bestätigtem Erfolg geschrieben.

---

## Stand der Verifikation

Diese Umgebung ist **Linux (Ubuntu 24.04, Swift 6.0.3)** ohne macOS/Xcode.
Deshalb gilt:

| Bereich | Status |
|---|---|
| `ReichiSyncCore` (Engine, Planner, WebDAV-Client, Parser, SQLite-Store, Scanner, Cloudreve-Client, Chunk-Upload) | **Gebaut und getestet auf Linux**: `swift build`, `swift test` → **134 Tests, 0 Fehler** |
| Integrationstests gegen WebDAV-Testumgebung | **Ausgeführt**: Fake-Server-Actor (alle 13 Sync-Szenarien aus der Anforderung) **und** echter HTTP-Server (`Scripts/dev-webdav-server.py`) inkl. 401-Behandlung, If-Match/If-None-Match, kompletter Engine-Lauf über HTTP |
| Cloudreve-Integration | **Gegen Emulation getestet** (`dev-webdav-server.py --cloudreve`, gebaut nach Cloudreve-v4-Quellcode und API-Dokumentation): Login/2FA/Token-Refresh, WebDAV-Konten, Chunk-Upload, **Wiederaufnahme ohne erneutes Senden bestätigter Chunks**, abgelaufene Sitzung, lokale Änderung während des Uploads, Versionsprüfung (`previous`), Freigaben, Engine-Schwelle. **Eine echte Cloudreve-Instanz existiert noch nicht** – der erste Lauf gegen reichi.cloud muss die Annahmen in `docs/WEBDAV.md` (Abschnitt Cloudreve) bestätigen. |
| `ReichiSync` (SwiftUI/AppKit-App, Menüleiste, Services) | **Geschrieben, auf Linux nur syntaktisch geprüft (`swiftc -parse`)**. Typprüfung, Build und manueller Test müssen auf einem Mac erfolgen (Schritte unten). |
| `project.yml` (XcodeGen), `Scripts/build-app.sh`, Entitlements, Info.plist, Icon | Erstellt; App-Icon-PNGs generiert und geprüft. Nicht auf macOS ausgeführt. |
| Szenario 14 (Fenster schließen → App läuft in Menüleiste weiter) | Implementiert in `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` + `LSUIElement`; nur auf macOS prüfbar. |

### Exakte Verifikationsschritte auf einem Mac (macOS 14+, Xcode 15+)

Eine ausführliche Anleitung einschließlich Xcode, universellem App-Bundle,
Signierung und Fehlerdiagnose steht in [`docs/MAC_BUILD.md`](docs/MAC_BUILD.md).

```bash
git clone <repo> && cd reichi-sync

# 1) Core bauen und alle Tests ausführen (Unit + Integration, ~5 s)
swift build
swift test

# 2) App ohne Xcode-Projekt als startfähiges Bundle bauen (ad hoc signiert)
Scripts/build-app.sh release dist
open "dist/reichi Sync.app"

# 3) Alternativ: Xcode-Projekt erzeugen und in Xcode bauen/debuggen
brew install xcodegen
xcodegen generate
open ReichiSync.xcodeproj      # Schema „ReichiSync“, ⌘R; Tests mit ⌘U

# 4) Lokalen WebDAV-Testserver starten (Python 3, keine Abhängigkeiten)
python3 Scripts/dev-webdav-server.py --root /tmp/dav --prefix /dav --port 8080 --user test --password test
# In der App (Modus „Anderer WebDAV-Server“): http://127.0.0.1:8080/dav/

# 5) Cloudreve-Emulation starten (API unter /api/v4, WebDAV unter /dav, Chunks à 1 MB)
python3 Scripts/dev-webdav-server.py --cloudreve --chunk-size 1048576 --root /tmp/cr --port 8080 \
    --user test@example.org --password test          # optional: --twofa 123456
# In der App (Modus „reichi.cloud / Cloudreve“): Server http://127.0.0.1:8080, E-Mail test@example.org
```

Manuelle Prüfpunkte in der App (Erwartung in Klammern):

1. Einrichtungsassistent durchlaufen, Verbindung testen (Server-Software und
   Sync-Fähigkeiten werden angezeigt), Ordner wählen, fertigstellen (erster
   Abgleich startet, Menüleistensymbol wechselt zu „syncing“ und dann zu
   „synced“ ✓).
2. Hauptfenster schließen → Symbol bleibt in der Menüleiste, Klick öffnet
   Popover mit Status/letztem Abgleich/Ausstehend/Aktionen; „Einstellungen …“
   öffnet das Fenster erneut.
3. Datei lokal anlegen → nach ≤ 3 s Upload sichtbar in „Aktivität“; Datei auf
   dem Server anlegen → spätestens nach dem Abfrageintervall (60 s) lokal.
4. Datei auf beiden Seiten verschieden ändern → Konflikt im Bereich
   „Konflikte“ mit beiden Versionen, Konfliktkopie im Ordner, Menüleiste
   zeigt Warnsymbol; die drei Optionen prüfen.
5. Server stoppen → „Server nicht erreichbar“, lokale Änderungen sammeln sich
   in der Warteschlange; Server starten → automatische Fortsetzung.
6. Über 25 Dateien lokal löschen → Übersicht zeigt Bestätigungskarte mit
   Vorschau; „verwerfen“ lädt die Dateien erneut herunter.
7. Falsches Passwort in den Einstellungen → „Anmeldung erforderlich“, keine
   Löschungen, Benachrichtigung (falls erlaubt).
8. „Bei der Anmeldung starten“ umschalten → Zustand entspricht
   *Systemeinstellungen › Allgemein › Anmeldeobjekte*.
9. „Beenden“ aus dem Menü → App wartet auf laufende Aktion, speichert Zustand,
   beendet sich; Neustart zeigt vorherige Listen und offene Konflikte.
10. **Cloudreve**: Einrichtung mit E-Mail/Passwort (ggf. 2FA-Code), Server-Ordner
    wählen → WebDAV-Konto „reichi Sync (<Mac>)“ erscheint in Cloudreve unter
    *Verbinden & Zugriff*. Datei > 8 MB in den Ordner legen → „Aktivität“ zeigt
    Upload mit Fortschritt; während des Uploads WLAN trennen → Fehler, nach
    Wiederverbindung setzt der nächste Durchgang ab dem letzten Chunk fort
    (Protokoll: „Upload von … wird fortgesetzt (Chunk n/m)“).
11. **Freigaben**: Bereich „Freigaben“ → „+“ → Datei wählen, optional Passwort/
    Ablauf/Limit → Link wird angezeigt und kopiert; Kontextmenü in „Aktivität“
    („Link teilen …“) und Menüleiste („Link teilen …“) führen zum gleichen Dialog.

---

## Bauen und starten

### Voraussetzungen

- macOS 14 Sonoma oder neuer, Xcode 15+ (bzw. Command Line Tools mit Swift 5.9+)
- optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) für ein `.xcodeproj`
- für die Core-Tests auf Linux: Swift 5.9+/6.x, `libsqlite3-dev`

### Variante A – SwiftPM + Build-Skript (kein Xcode-Projekt nötig)

```bash
Scripts/build-app.sh release dist     # oder: debug
open "dist/reichi Sync.app"
```

Das Skript baut das Produkt `ReichiSync`, legt das Bundle an, erzeugt
`AppIcon.icns` aus dem Asset-Katalog und signiert **ad hoc** mit den
Entitlements (Sandbox, Netzwerk-Client, benutzergewählte Dateien, Bookmarks).
Mit `CODESIGN_IDENTITY="Developer ID Application: …"` kann eine echte
Identität verwendet werden (siehe `docs/SIGNING.md`).

### Variante B – Xcode

```bash
brew install xcodegen
xcodegen generate
open ReichiSync.xcodeproj
```

Das Projekt bindet das lokale Package (`ReichiSyncCore`) ein, verwendet
`Sources/ReichiSyncApp/Info.plist` und die Entitlements. Team-ID in Xcode unter
*Signing & Capabilities* wählen (oder `DEVELOPMENT_TEAM` in `project.yml`).

### Tests

```bash
swift test                              # alles
swift test --filter SyncPlannerTests    # nur Planner-Entscheidungen
swift test --filter SyncEngineIntegrationTests
swift test --filter WebDAVClientHTTPTests   # echter HTTP-Server (Python 3 nötig)
```

---

## Benutzung

1. **Einrichtung**: Beim ersten Start erscheint der Assistent. Standard ist
   **reichi.cloud / Cloudreve**: Server (vorbelegt `https://reichi.cloud`),
   E-Mail und Passwort, ggf. 2FA-Code, Server-Ordner (neu anlegen oder
   vorhandenes WebDAV-Konto), lokaler Ordner. reichi Sync legt über die
   Cloudreve-API ein eigenes WebDAV-Konto für dieses Gerät an; das
   Cloudreve-Passwort wird **nicht** gespeichert, im Schlüsselbund liegen nur
   die Sitzungs-Tokens und das WebDAV-Passwort. Alternativ „Anderer
   WebDAV-Server“ (URL, Benutzer/Passwort, Verbindungstest). Der Ordnerzugriff
   wird als Security-Scoped Bookmark gespeichert.
2. **Menüleiste**: Symbol je Zustand
   – ✓ synchronisiert, ⟳ läuft, Wi-Fi-durchgestrichen offline, ‖ pausiert,
   ⚠ Konflikte, ! Aufmerksamkeit (Fehler/Anmeldung/Bestätigung).
   Popover: Status, letzter Abgleich, Ausstehend, Fortschritt, „Jetzt
   synchronisieren“, Pause/Fortsetzen, Ordner im Finder, Aktivität, Konflikte,
   Einstellungen, Beenden.
3. **Hauptfenster**: Übersicht (Status, Kennzahlen, Verbindung, Diagnose),
   Aktivität (Transfers mit Filter, Fehlerdetails, Wiederholen), Konflikte
   (beide Versionen, „Beide behalten / Lokale Version verwenden /
   Serverversion verwenden“), Freigaben (nur Cloudreve: Links erstellen,
   kopieren, löschen), Einstellungen (Verbindung, Ordner, Intervall,
   Ausschlüsse, Login-Item, Benachrichtigungen, Dock-Symbol und erneute
   Cloudreve-Anmeldung).
4. **Wiederherstellung gelöschter Dateien**: Lokale Löschungen durch die App
   landen im macOS-Papierkorb. Falls das nicht möglich ist, im
   Wiederherstellungsbereich `~/Library/Containers/de.reichi.sync/Data/Library/Application Support/reichi Sync/Wiederherstellung/<Zeitstempel>/…`
   (Pfad in der Diagnose). Serverseitig hängt eine Wiederherstellung vom
   Server ab (Nextcloud/ownCloud haben einen Papierkorb; Standard-WebDAV
   nicht – die App verspricht das nicht).
5. **Daten der App** (außerhalb des Sync-Ordners): Datenbank `sync.sqlite`,
   Protokoll `Logs/reichi-sync.log` und Wiederherstellungsbereich liegen im
   App-Container unter `Application Support/reichi Sync/`. Im Sync-Ordner
   selbst wird nur ein versteckter Temp-Ordner `.reichi-sync-tmp` für
   Downloads verwendet (wird nie hochgeladen).

---

## Getroffene Entscheidungen

Punkte, die die Anforderung offen ließ, wurden so entschieden:

| Thema | Entscheidung |
|---|---|
| Konfliktdarstellung im Dateisystem | Serverversion behält den Originalnamen; lokale Version wird zu `Name (Konfliktkopie von <Gerät> JJJJ-MM-TT HH-mm-ss).ext` und wird im Folgedurchgang hochgeladen, damit beide Versionen auf beiden Seiten liegen. |
| „Lokale Version verwenden“ | Konfliktkopie ersetzt die Datei unter dem Originalnamen (nach erneuter Hash-Prüfung), die bisherige Serverversion wandert lokal in den Papierkorb; der nächste Abgleich lädt die neue Version hoch und löscht die Konfliktkopie auf dem Server. |
| Erster Abgleich mit Dateien auf beiden Seiten | Gleicher Hash → nur Baseline; unterschiedlich → Konflikt (`initialMergeDiffers`), keine Seite gewinnt. |
| Löschschutz-Schwellen | ≥ 25 Einträge **oder** > 20 % der Baseline **oder** lokal leer bei nicht-leerer Baseline; in den Einstellungen anpassbar (Anzahl). |
| Verwerfen zurückgehaltener Löschungen | Baseline der betroffenen Pfade wird entfernt → die überlebende Seite gilt als „neu“ und wird wieder übertragen. |
| Umbenennung | Erkennung über eindeutigen Hash (lokal gelöscht + lokal neu mit gleichem Hash, Server unverändert) → `MOVE`; Fallback Upload + Löschung. |
| Bundles (`.app`, `.photoslibrary` …) | Werden als normale Ordner synchronisiert (WebDAV kennt keine Bundles). |
| xattrs / Resource Forks / Finder-Tags | Werden nicht übertragen (WebDAV hat kein Pendant); `._*`-Dateien sind ausgeschlossen. |
| Symlinks | Werden übersprungen und in „Aktivität“ als zurückgestellt gemeldet. |
| Case-Kollisionen (Server hat `A.txt` und `a.txt`) | Beide Pfade werden ausgelassen, Meldung mit Aktion „Im Finder zeigen“; kein Datenverlust. |
| Dateien in Bearbeitung | mtime jünger als 2 s → zurückgestellt bis zum nächsten Durchgang. |
| Authentifizierung | HTTP Basic über HTTPS (Nextcloud-App-Passwörter empfohlen). Digest/NTLM/OAuth nicht implementiert (siehe `docs/WEBDAV.md`). |
| Unverschlüsseltes HTTP | Nur `localhost`/`127.0.0.1` standardmäßig; sonst explizite Freigabe in den Einstellungen (ATS erlaubt zusätzlich nur lokale Netze). |
| Abfrageintervall | 60 s Standard, 30 s bis 15 min wählbar; zusätzlich Trigger bei Start, Aufwachen, Netzwerkrückkehr, FSEvents, manuell. |
| Dock-Symbol | Standardmäßig reines Menüleisten-Programm (`LSUIElement`), optional Dock-Symbol in den Einstellungen. |
| Speicherplatz | Downloads werden vor dem Start gegen freien Platz (+200 MB Reserve) geprüft; bei Platzmangel Pause mit Hinweis. |
| Cloudreve-Anbindung | Hybrid: Listing, Download und Ordneranlage über WebDAV (`/dav/`); Uploads über die versionierte REST-Upload-API (`/api/v4`). Da Cloudreve DAV-Vorbedingungen ignoriert, bleiben Server-Löschungen und -Umbenennungen sicherheitshalber ausstehend. Bei abgelaufener API-Sitzung funktionieren Lesen und Herunterladen weiter; Schreibvorgänge warten auf eine erneute Anmeldung. |
| Cloudreve-Upload-Sitzungen | Cloudreve bestimmt die Chunk-Größe seiner sicheren REST-Sitzung. Zustand pro Datei in `upload_sessions` (Sitzung, bestätigte Chunks, Größe/mtime/Hash); Fortsetzung nur bei unveränderter Datei und > 2 min Restlaufzeit, sonst Neustart. Signierte URLs und Upload-Credentials werden nicht persistiert. |
| Cloudreve `If-Match` | Cloudreve wertet `If-Match`/`If-None-Match` bei DAV-PUT, DELETE und MOVE nicht atomar aus. Der Cloudreve-Hinweis setzt deshalb auch bei fehlgeschlagenem Ping `honorsIfMatch = false`. Uploads nutzen `previous` beziehungsweise den atomaren Existenzschutz der REST-API; DELETE/MOVE werden ohne gleichwertige Servervorbedingung nicht automatisch ausgeführt. |
| Freigaben | Nur Einträge innerhalb des Sync-Ordners; Passwort alphanumerisch ≤ 32 Zeichen (Cloudreve-Vorgabe), Ablauf 1 h–30 d, Download-Limit; Link inkl. Passwort-Teil `…/s/<id>/<pw>` wird kopiert. Lokaler Cache der Freigaben in `shares`. |
| App-Icon | Vorlage auf heller macOS-Kachel mit Verlauf/Schatten (`Scripts/generate-icon.py`). Liegt `Design/logo.svg` vor, wird das Logo **pro Icon-Größe verlustfrei aus dem SVG gerendert** (`pip3 install cairosvg` oder `brew install librsvg`); sonst dient `Design/logo.png` (256 px) als Raster-Vorlage. Im Repo liegt bisher nur das PNG – die SVG-Datei einfach als `Design/logo.svg` ablegen und das Skript erneut ausführen. |

---

## Projektstruktur

```
Package.swift                  SwiftPM: CSQLite, ReichiSyncCore, Tests, ReichiSync (nur macOS)
project.yml                    XcodeGen-Beschreibung für ReichiSync.xcodeproj
Sources/CSQLite/               Modulemap für die System-SQLite
Sources/ReichiSyncCore/
  Models/                      Baseline, Local/Remote-Items, Transfers, Konflikte, Account
  Util/                        RelativePath, ExclusionRules, SHA256, SyncLogger
  Persistence/                 SQLiteDatabase, SyncStore (actor)
  WebDAV/                      WebDAVClient, MultiStatusParser, Modelle/Fehler
  Cloudreve/                   CloudreveAPIClient (Login, Tokens, DAV-Konten, Upload-API, Freigaben), ResumableUpload
  Local/                       LocalFileSystem, LocalScanner
  Sync/                        SyncPlanner, SyncEngine, RemoteEnumerator, RetryPolicy, SyncStatus
Sources/ReichiSyncApp/         macOS-App (SwiftUI/AppKit), Services, Views, Ressourcen
Tests/ReichiSyncCoreTests/     Unit-, Integrations- und HTTP-Tests, Fixtures, FakeWebDAVServer
Scripts/dev-webdav-server.py   WebDAV-Testserver (Python 3, stdlib); --cloudreve emuliert die Cloudreve-API
Design/                        Icon-Vorlage (logo.png) und 1024-px-Master
Scripts/build-app.sh           .app-Bundle aus SwiftPM-Build
Scripts/generate-icon.py       App-Icon-PNGs erzeugen (SVG-Vorlage bevorzugt, PNG als Rückfall)
docs/ARCHITECTURE.md           Entscheidungstabelle, Zustände, Datenmodell
docs/WEBDAV.md                 Unterstützte WebDAV-Funktionen und Grenzen
docs/MAC_BUILD.md              Schritt-für-Schritt-Bauanleitung für macOS
docs/SIGNING.md                Signierung, Notarisierung, Sandbox
```

---

## Weitere Dokumente

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) – Drei-Wege-Entscheidungstabelle, Zustandsmodell, Datenbankschema, Sicherheitsmaßnahmen
- [`docs/WEBDAV.md`](docs/WEBDAV.md) – unterstützte WebDAV-Funktionen, getestete Server, bekannte Grenzen, **Cloudreve-Abschnitt** (Upload-API, Annahmen, Grenzen)
- [`docs/MAC_BUILD.md`](docs/MAC_BUILD.md) – vollständige Anleitung für Tests, App-Bundle, Xcode und Signierung auf macOS
- [`docs/SIGNING.md`](docs/SIGNING.md) – Signierung, Notarisierung, Hinweise zur Sandbox

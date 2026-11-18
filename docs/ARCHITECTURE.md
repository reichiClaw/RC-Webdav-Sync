# Architektur von reichi Sync

Ergänzt den Überblick im [README](../README.md) um Details zu Abgleichlogik,
Zuständen, Datenmodell und Sicherheitsmaßnahmen.

## 1. Schichten und Nebenläufigkeit

| Schicht | Typ | Isolation |
|---|---|---|
| `AppModel` | `@MainActor final class: ObservableObject` | Main Actor – alle UI-Zustände |
| `SyncEngine` | `actor` | eigener Actor; genau ein Durchgang zur Zeit, weitere Anfragen werden zusammengefasst (`rerunRequested`) |
| `SyncStore` | `actor` über `SQLiteDatabase` | serialisiert alle DB-Zugriffe; WAL-Modus |
| `WebDAVClient` | `final class, Sendable` | zustandslos bis auf URLSession; alle Aufrufe `async` |
| `CloudreveAPIClient` | `final class, @unchecked Sendable` | hält Token-Paar hinter `NSLock`; genau ein Refresh zur Zeit; 401 → einmaliger Refresh + Wiederholung |
| `CloudreveUploadTransport` | `final class` (`ResumableUploadTransport`) | wird von der Engine für Uploads ≥ Schwelle aufgerufen; persistiert den Chunk-Fortschritt im `SyncStore` |
| `LocalScanner`, `SyncPlanner` | `struct`, reine Funktionen | laufen in `Task.detached` bzw. im Engine-Actor |
| `FolderWatcher`, `ConnectivityMonitor` | Klassen mit eigener Dispatch-Queue | melden nur „es gibt Änderungen“ an die Engine |

Die Engine veröffentlicht `SyncStatus`-Schnappschüsse über einen Handler
(gedrosselt auf ~4/s während Transfers) und `SyncEvent`s für
Benachrichtigungen. Die UI liest Listen (Transfers, Konflikte, Warteschlange,
zurückgehaltene Löschungen) bei Bedarf aus der Engine.

## 2. Drei-Wege-Abgleich

Für jeden Pfad (NFC-normalisiert, relativ zur Wurzel) werden drei Zustände
betrachtet: **Baseline** (letzter gemeinsam bestätigter Stand), **Lokal**,
**Server**. Daraus ergibt sich je Seite ein `SideState`:

| SideState | Bedeutung |
|---|---|
| `absent` | weder jetzt noch in der Baseline vorhanden |
| `new` | jetzt vorhanden, nicht in der Baseline |
| `unchanged` | vorhanden, Hash (lokal) bzw. ETag/Validator (Server) wie in der Baseline |
| `changed` | vorhanden, aber abweichend von der Baseline |
| `deleted` | in der Baseline, jetzt nicht mehr vorhanden |
| `unknown` | nicht beurteilbar (Teilbaum des Server-Listings unvollständig) |

Entscheidungstabelle (`SyncPlanner.plan`):

| Lokal | Server | Aktion |
|---|---|---|
| `unknown` / – | – / `unknown` | nichts (keine Ableitung aus unvollständigen Daten) |
| `absent` | `absent` | Baseline-Eintrag entfernen, falls vorhanden |
| `deleted` | `deleted` | Baseline-Eintrag entfernen |
| `new` | `absent`/`deleted` | **Upload** (Ordner: MKCOL) |
| `absent`/`deleted` | `new` | **Download** (Ordner: lokal anlegen) |
| `new` | `new` | Ordner+Ordner → Baseline; Datei+Datei gleicher Hash → Baseline; sonst **verifyConflict** (`initialMergeDiffers`); Datei↔Ordner → **kindMismatch** |
| `unchanged` | `unchanged` | nichts |
| `changed` | `unchanged` | **Upload** mit `If-Match` |
| `unchanged` | `changed` | **Download** (lokale Datei muss beim Einsetzen noch unverändert sein) |
| `changed` | `changed` | **verifyConflict**: Inhalt per Hash vergleichen; gleich → Baseline; sonst lokale Version → Konfliktkopie, Serverversion unter Originalname, Konflikt melden |
| `deleted` | `unchanged` | **deleteRemote** (nur mit Baseline, vollständigem Listing, `If-Match`/Stat-Prüfung) |
| `unchanged` | `deleted` | **deleteLocal** (Hash-Prüfung, dann Papierkorb) |
| `deleted` | `changed` | **keepRemoteAfterLocalDelete**: Server-Version herunterladen, Konflikt melden |
| `changed` | `deleted` | **keepLocalAfterRemoteDelete**: lokale Version hochladen, Konflikt melden |
| übrige Kombinationen (Baseline vorhanden ↔ fehlt) | | konservativ überspringen und melden |

Weitere Regeln:

- **Ordnerlöschung mit Überlebenden**: Soll ein Ordner gelöscht werden, dessen
  Unterbaum auf der anderen Seite geänderte oder neue Einträge enthält, wird
  der Ordner stattdessen erhalten (ggf. wieder angelegt) und nur die
  unveränderten Kinder werden gelöscht.
- **Rename-Erkennung**: `deleted` lokal + `new` lokal mit identischem,
  eindeutigem Hash, Server unverändert, Zielpfad serverseitig frei → `MOVE`
  statt Download/Upload. Fehlschlag → Upload + Löschung.
- **Eingefrorene Pfade**: offene Konflikte, gerade geschriebene Dateien,
  Case-Kollisionen und Pfade unter unvollständigen Server-Teilbäumen werden
  im Durchgang nicht angefasst.
- **Bestätigte Löschungen** (`allowedDeletions`) begrenzen Löschaktionen nach
  einer Nachfrage auf exakt die bestätigte Menge.

### Ausführungsreihenfolge

1. Ordner anlegen (Eltern vor Kindern)
2. Umbenennungen (sequenziell)
3. Transfers (parallel, Standard 3; Uploads/Downloads/Konfliktprüfung)
4. Löschungen (tiefste Pfade zuerst, Ordner nach Inhalt)
5. Buchführung (Baseline aktualisieren/entfernen)

Jede Aktion prüft direkt vor der Ausführung erneut die Vorbedingungen. Ein
Upload etwa liest Größe/mtime, hasht, sendet mit `If-Match` (starke ETags)
oder prüft vorher per `PROPFIND`, und vergleicht nach dem Upload erneut
Größe/mtime der lokalen Datei. Weicht etwas ab → Aktion wird zurückgestellt
(`deferred`) und im Folgedurchgang neu geplant.

### Baseline-Aktualisierung

Ein Baseline-Eintrag (`entries`) enthält Pfad, Art, lokalen Hash, Größe,
mtime, Server-Validator (ETag oder `mtime:…;size:…`), Stärke des Validators,
Servergröße und -datum. Er wird **nur** geschrieben, wenn Lokal und Server
nachweislich denselben Inhalt haben (Upload bestätigt, Download eingesetzt,
Hash-Gleichheit festgestellt). `lastSuccessfulSync` wird nur gesetzt, wenn
beide Bestandsaufnahmen vollständig waren und keine Aktion fehlschlug.

## 3. Löschschutz (`DeletionGuard`)

Bestätigung erforderlich, wenn eine der Bedingungen gilt:

- Anzahl betroffener Einträge (inkl. Kinder gelöschter Ordner) ≥ Schwelle (Standard 25)
- Anteil an der Baseline > 20 %
- lokaler Ordner ist leer, Baseline aber nicht (klassisch: Ordner
  umbenannt/ausgehängt)

Zurückgehaltene Löschungen landen in `pending_deletions`, überleben Neustarts
und werden in der Übersicht mit Vorschau gezeigt. „Ausführen“ erlaubt sie für
genau einen Durchgang; „Verwerfen“ entfernt die Baseline der betroffenen Pfade,
sodass die noch vorhandene Seite beim nächsten Durchgang als neu übertragen
wird.

Zusätzlich gilt unabhängig vom Guard: fehlender lokaler Stammordner → Pause;
verlorene Datenbank → leere Baseline → keine Löschungen (alles wird als neu
zusammengeführt); unvollständige Server-Listings → betroffene Teilbäume
`unknown`.

## 4. Zustände (`SyncHealth`)

| Zustand | Bedingung | Menüleiste |
|---|---|---|
| `setupRequired` | keine Verbindung konfiguriert | Zahnrad |
| `syncing` | Durchgang läuft | Kreispfeile (pulsierend) |
| `paused` | Benutzer, Ordner fehlt, Speicher voll, Anmeldung | Pause / Schloss-Hinweis |
| `offline` | Probe fehlgeschlagen; Backoff aktiv | Wi-Fi durchgestrichen |
| `conflicts` | ≥ 1 offener Konflikt | Warndreieck |
| `attention` | fehlgeschlagene Aktionen, zurückgehaltene Löschungen, Case-Kollisionen, unvollständiges Listing | Ausrufezeichen |
| `synced` | nichts ausstehend, keine Konflikte, keine Fehler, letzter Durchgang vollständig | Haken |

„Synchronisiert“ wird also nur angezeigt, wenn tatsächlich nichts offen ist.

## 5. Datenbankschema (SQLite, `user_version = 4`)

| Tabelle | Inhalt |
|---|---|
| `meta` | Schlüssel/Wert (z. B. Geräte-ID) |
| `accounts` | Verbindungen (JSON-kodierte `AccountConfiguration`, ohne Passwort) |
| `mappings` | Zuordnung Server-URL + lokaler Pfad → Baseline-Satz; `sync_token`, `last_successful_sync`, `remote_index_complete` |
| `entries` | Baseline pro Mapping und Pfad |
| `local_index` | Hash-Cache (Pfad → Größe, mtime, Geräte-/Inode-/ctime-Fingerabdruck, SHA-256) |
| `remote_index` | zuletzt bekannter Serverbestand (für `sync-collection`) |
| `conflicts` | offene/erledigte Konflikte inkl. Konfliktkopie-Pfad |
| `transfers` | Aktivitätsprotokoll (Zustand, Bytes, Fehler, Empfehlung) |
| `queue` | geplante, noch nicht ausgeführte Aktionen (für Offline-Anzeige) |
| `pending_deletions` | zurückgehaltene Löschungen |
| `upload_sessions` | Zustand unterbrochener Chunk-Uploads pro Mapping und Pfad; kurzlebige Zugangsdaten und signierte Upload-URLs werden nicht persistiert |
| `shares` | Bereinigter lokaler Cache der Cloudreve-Freigaben; private Passwörter werden weder separat noch als URL-Pfadsegment gespeichert |

Der Mapping-Schlüssel (`mapping-v3`) bindet den gemeinsamen Stand an
Server-URL, Benutzer, Cloudreve-DAV-Konto/-Wurzel, lokalen Pfad samt
Geräte-/Inode-Identität und Ausschlussregeln. Ändert sich einer dieser Werte,
entsteht ein leerer, sicher zusammenzuführender Stand; eine fremde oder alte
Baseline wird nicht wiederverwendet. Schema 4 entfernt außerdem potenziell
geheime Altwerte mit `secure_delete`, WAL-Checkpoint und `VACUUM`.

## 6. Dateisystem-Details

- Schlüsselpfade sind NFC-normalisiert; für echte Dateisystem-/Serverzugriffe
  wird der ursprüngliche `rawPath` verwendet.
- `RelativePath.localURL(root:relativePath:)` verweigert `..`, absolute
  Pfade, leere Segmente und prüft, dass das Ergebnis unterhalb der Wurzel
  bleibt. Server-`href`s werden dekodiert, gegen den Basis-Pfad geprüft und
  durch dieselbe Validierung geführt.
- Downloads gehen in `.reichi-sync-tmp/` im Sync-Ordner (ausgeschlossen),
  werden gehasht und erst nach einer Hash-/Dateiidentitätsprüfung eingesetzt.
  Auf macOS tauscht `renameatx_np(..., RENAME_SWAP)` Ziel und Arbeitsdatei
  atomar; die tatsächlich verdrängte Version wird danach erneut geprüft und
  bei jeder Abweichung erhalten beziehungsweise zurückgetauscht.
- Lokale Dateilöschungen verschieben die konkrete Datei zuerst atomar in
  Quarantäne, prüfen dort Identität und Hash und geben nur die bestätigte
  Version an Papierkorb beziehungsweise Wiederherstellungsbereich weiter.
  Ordner werden ausschließlich mit einer nichtrekursiven „nur wenn leer“-
  Operation entfernt.
- Case-insensitive APFS: Kollisionen auf dem Server werden erkannt und
  ausgelassen.
- Symlinks werden nicht verfolgt; Bundles sind Ordner; xattrs werden nicht
  übertragen.

## 7. Sicherheit

- Passwort nur im Schlüsselbund (`kSecClassGenericPassword`, Service
  `de.reichi.sync`), nie in SQLite oder Protokollen. `SyncLogger` redigiert
  registrierte Secrets, `Authorization: Basic …` und URL-Userinfo.
- HTTPS mit regulärer Systemzertifikatsprüfung (`performDefaultHandling`),
  kein Pinning, keine Ausnahmen. HTTP nur für Loopback oder nach expliziter
  Freigabe (ATS erlaubt zusätzlich nur lokale Netze).
- Umleitungen: nur gleiche Scheme+Host und nur für lesende Methoden
  (GET/HEAD/OPTIONS/PROPFIND); sonst Abbruch mit `redirectRefused`. Dadurch
  gelangen Zugangsdaten nie an fremde Hosts.
- 401/403 → Pause „Anmeldung erforderlich“, keine Löschungen, keine Retries.
- App Sandbox mit `files.user-selected.read-write` + Security-Scoped Bookmarks
  für den Sync-Ordner; Datenbank/Logs/Wiederherstellung im Container.
- Cookies/Cache deaktiviert; ephemerale `URLSession`.
- Cloudreve: Das Konto-Passwort wird nach der Anmeldung verworfen. Im
  Schlüsselbund liegen nur die JWT-Tokens (Eintrag `<account>.cloudreve`,
  JSON) und das Passwort des von der App angelegten WebDAV-Kontos. Tokens
  werden im `SyncLogger` als Secrets registriert. API-Aufrufe gehen nur an
  den konfigurierten Site-Host; Umleitungen werden abgelehnt.
- Chunk-Upload: Vor jedem Chunk wird geprüft, dass die lokale Datei
  (Größe/mtime) unverändert ist; sonst wird die Sitzung serverseitig
  gelöscht. Server-URIs werden aus validierten relativen Pfaden erzeugt
  (`CloudreveURI.fileURI` → `RelativePath.segments`), nie umgekehrt.

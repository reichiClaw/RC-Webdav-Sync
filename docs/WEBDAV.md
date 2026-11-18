# WebDAV-Unterstützung in reichi Sync

## Unterstützte Funktionen

| Funktion | Verwendung | Hinweise |
|---|---|---|
| `OPTIONS` | Capability-Erkennung (`DAV:`-Header, `Server`) | Klassen 1/2/3 werden erkannt; keine zwingende Voraussetzung |
| `PROPFIND Depth: 0` | Erreichbarkeitsprobe, Einzelabfrage (`stat`), `sync-token` abrufen | Ersetzt einfache Ping-Prüfungen |
| `PROPFIND Depth: 1` | Rekursive Bestandsaufnahme (bis zu 4 Ordner parallel) | `Depth: infinity` wird bewusst nicht verwendet (häufig deaktiviert) |
| `207 Multi-Status` | Namespace-bewusster Parser (`XMLParser`, `shouldProcessNamespaces`) | Nur `propstat` mit 2xx-Status werden ausgewertet; fremde Namespaces (`oc:`, `nc:`) werden als `{ns}name` durchgereicht |
| `REPORT sync-collection` (RFC 6578) | Inkrementelle Änderungsabfrage, falls `DAV:sync-collection` in `supported-report-set` | Ungültiges Token (403 `valid-sync-token`, 410) → vollständiges Listing; Token werden vor der ersten Vollaufnahme geholt und nur mit vollständigem `remote_index` genutzt |
| `GET` (Download-Task) | Streaming in temporäre Datei, ETag aus `ETag`/`OC-ETag` | Fortschritt über `URLSessionTaskDelegate` |
| `PUT` (Upload-Task aus Datei) | Streaming, `Content-Length`, `X-OC-Mtime` | `If-Match: <etag>` bei starken ETags, `If-None-Match: *` für neue Dateien |
| `MKCOL` | Ordner anlegen | 405 (existiert bereits) wird toleriert |
| `DELETE` | Dateilöschung nur mit starkem ETag und nachgewiesen atomarem `If-Match` | Rekursive Collection-Löschungen bleiben gesperrt; eine Vorprüfung allein wäre wegen des Race-Fensters kein Schutz |
| `MOVE` | Umbenennungen (`Destination`, `Overwrite: F`, `If-Match`) nur bei nachgewiesen atomaren Vorbedingungen | Fallback Upload + geschützte Löschung; bleibt ein Teilschritt offen, bleibt die Gesamtaktion ausstehend |
| `412 Precondition Failed` | Kennzeichen für Änderung seit der Bestandsaufnahme → Aktion zurückstellen, neu planen | Nie als Fehler „durchgedrückt“ |
| `423 Locked`, `507 Insufficient Storage`, `409 Conflict` | Werden gemeldet, Aktion wird zurückgestellt/fehlgeschlagen markiert | Kein Lock-Management (Klasse 2 wird nicht genutzt) |
| ETags | Opaque behandelt; schwache ETags (`W/`) werden erkannt und nicht für `If-Match` verwendet | Ohne ETags: Ersatzvalidator `mtime:<HTTP-Date>;size:<n>` |
| URL-Kodierung | Jedes Pfadsegment einzeln `percent-encoded`; `href`s dekodiert und gegen den Basis-Pfad validiert | Leerzeichen, Umlaute, Emoji, `#`, `?`, `+`, `%` getestet |
| Authentifizierung | HTTP Basic (vorab gesendet) über HTTPS | Siehe Grenzen |

## Getestete Server

| Server | Art des Tests | Ergebnis |
|---|---|---|
| `FakeWebDAVServer` (In-Memory-Actor) | Integrationstests für Sync-, Race-, Lösch- und Recovery-Szenarien (42 Tests) | bestanden auf Linux |
| `Scripts/dev-webdav-server.py` (Python-stdlib, Klasse 1, starke ETags, Basic Auth) | echte HTTP-Tests: Capabilities, 401, If-Match/If-None-Match-Zyklus, kompletter Engine-Lauf | bestanden auf Linux |
| Nextcloud / ownCloud | **nicht in dieser Umgebung getestet**; 207-Parser mit Nextcloud-Fixture (`Tests/…/Fixtures/nextcloud-propfind.xml`) geprüft; `OC-ETag`, `X-OC-Mtime`, `oc:`-Props, sync-collection-Format berücksichtigt | Verifikation auf einem Mac gegen eine echte Instanz empfohlen |
| Apache `mod_dav`, Synology, Nginx DAV | nicht getestet; nur Klasse-1-Funktionen vorausgesetzt | sollten funktionieren, da keine Erweiterungen verlangt werden |
| Cloudreve v4 (Emulation `dev-webdav-server.py --cloudreve`) | Erkennung, Login/2FA/Refresh, WebDAV-Konten, Upload inkl. Wiederaufnahme/Ablauf/Versionsprüfung, Freigaben, Engine-Integration (18 Tests) | bestanden auf Linux; **echte Instanz existiert noch nicht** – siehe Abschnitt Cloudreve |

## Bekannte Grenzen

- **Nur HTTP Basic Auth.** Digest, NTLM, Kerberos, OAuth/App-Login-Flows
  (z. B. Nextcloud Login Flow v2) sind nicht implementiert. Bei Nextcloud
  bitte ein App-Passwort verwenden. Ein Digest/NTLM-Challenge führt zu
  „Anmeldung erforderlich“.
- **Keine Chunked-/Resumable-Uploads.** Große Dateien werden in einem `PUT`
  gestreamt. Bei Verbindungsabbruch wird der Serverzustand per `PROPFIND`
  verifiziert und ggf. erneut hochgeladen; es gibt keine Fortsetzung ab
  Offset. Nextclouds Chunking-API wird nicht genutzt.
- **Keine Locks (Klasse 2).** `LOCK/UNLOCK` werden nicht gesendet; `423`
  wird nur gemeldet.
- **Kein `Depth: infinity`.** Große Bäume erfordern einen `PROPFIND` pro
  Ordner (parallelisiert); `sync-collection` beschleunigt Folgeabfragen, wenn
  der Server es anbietet.
- **Server-Papierkorb wird nicht zugesichert.** `DELETE` ist auf Standard-
  WebDAV endgültig. Nextcloud/ownCloud bieten einen Papierkorb; die App
  verlässt sich nicht darauf und schützt stattdessen über Baseline-Regeln,
  Nachfrage bei großen Löschmengen und lokalen Papierkorb.
- **Keine Übertragung von Metadaten** außer Modifikationsdatum (`X-OC-Mtime`,
  nur von ownCloud/Nextcloud ausgewertet). xattrs, Resource Forks,
  Finder-Tags, POSIX-Rechte, Symlinks und Bundle-Flags gehen nicht über
  WebDAV.
- **Bundles** (`.app`, `.photoslibrary`, `.rtfd`) werden als Ordner
  synchronisiert; eine teilweise Übertragung kann ein Bundle vorübergehend
  inkonsistent machen.
- **Groß-/Kleinschreibung.** Case-insensitive APFS gegen case-sensitive
  Server: existieren serverseitig zwei Namen, die sich nur in der
  Schreibweise unterscheiden, werden beide ausgelassen und gemeldet.
- **Serverseitige Umbenennungen** werden als Löschen + Neu erkannt
  (Download der neuen Datei, Löschung der alten mit allen Sicherheitsregeln);
  eine Server-Move-Erkennung über `oc:fileid` ist nicht implementiert.
- **Unverschlüsseltes HTTP** ist nur für Loopback und – nach Freigabe – für
  lokale Netze möglich (App Transport Security). Für beliebige HTTP-Hosts
  müsste `NSAllowsArbitraryLoads` gesetzt werden, was bewusst nicht geschieht.
- **Zertifikate**: ausschließlich Systemvertrauen; selbstsignierte
  Zertifikate müssen im macOS-Schlüsselbund als vertrauenswürdig hinterlegt
  sein.

## Nextcloud-Besonderheiten, die berücksichtigt sind

- WebDAV-Basis `remote.php/dav/files/<user>/…`; `href`s enthalten den
  vollständigen Pfad und werden relativ zur Basis aufgelöst.
- `OC-ETag`/`ETag` auf `PUT`-Antworten, `oc:fileid`, `oc:permissions`,
  `oc:size` werden geparst (als `{http://owncloud.org/ns}…`-Properties).
- `X-OC-Mtime` setzt das Modifikationsdatum serverseitig.
- `sync-collection` liefert `sync-token` als `http://sabre.io/ns/sync/<n>`;
  gelöschte Einträge kommen als `404`-Responses.

## Cloudreve (Standardserver reichi.cloud)

reichi Sync behandelt Cloudreve als WebDAV-Server mit Zusatzfunktionen. Die
Implementierung folgt dem Quellcode von Cloudreve v4 (`pkg/webdav`,
`service/explorer`, `pkg/serializer/error.go`) und der API-Dokumentation
(`docs.cloudreve.org`), da zum Zeitpunkt der Entwicklung keine Instanz zum
Testen verfügbar war. Alle Punkte mit **Annahme** sollten beim ersten Lauf
gegen `https://reichi.cloud` bestätigt werden.

### Was läuft über WebDAV, was über die REST-API

| Aufgabe | Weg |
|---|---|
| Listing (PROPFIND), Download (GET), MKCOL | WebDAV `https://<site>/dav/…` mit dem von reichi Sync angelegten WebDAV-Konto (Benutzername = E-Mail, generiertes Passwort) |
| Anmeldung, Token-Erneuerung | `POST /api/v4/session/token`, `…/2fa`, `…/refresh` (JWT-Paar, Access ≈ 1 h, Refresh ≈ 180 d) |
| WebDAV-Konten lesen/anlegen, Server-Ordner anlegen | `GET/PUT /api/v4/devices/dav`, `POST /api/v4/file/create` |
| Neue und geänderte Uploads | `PUT /api/v4/file/upload` (Sitzung mit Existenz-/`previous`-Schutz) + `POST /api/v4/file/upload/{session}/{index}`; oberhalb der Schwelle fortsetzbar |
| Löschen und Verschieben | Bleiben ausstehend, solange Cloudreve keine gleichwertige atomare Versionsvorbedingung bereitstellt |
| Freigaben | `PUT/GET /api/v4/share`, `DELETE /api/v4/share/{id}` |

### Erkennung

`GET <site>/api/v4/site/ping` antwortet mit `{"code":0,"data":"<version>"}`.
Dann gilt `serverKind = .cloudreve` und `honorsIfMatch = false`.

### `If-Match` wird ignoriert

Cloudreve wertet `If-Match`/`If-None-Match` bei `PUT`, `DELETE` und `MOVE`
nicht atomar aus. Eine getrennte `PROPFIND`-Prüfung würde ein Race-Fenster
lassen und gilt daher ausdrücklich nicht als Schreibschutz. Die Engine
verwendet für Uploads die REST-Sitzung: `previous` (Entity-ID des bekannten
ETags) schützt Ersetzungen, der Existenzmodus schützt Neuanlagen. Stimmt die
Version nicht, wird Code `40076 Stale version` wie HTTP 412 neu geplant.
DAV-DELETE und MOVE werden blockiert, bis eine serverseitig atomare
Alternative existiert.

### Chunked und fortsetzbare Uploads

1. `PUT /api/v4/file/upload` mit `{uri, size, last_modified, entity_type:
   "version" (beim Überschreiben), previous}` → `session_id`, `chunk_size`
   (0 = alles in einer Anfrage), `expires`, `storage_policy{type, relay}`.
2. Chunks werden sequenziell als `application/octet-stream` an
   `POST /api/v4/file/upload/{session}/{index}` gesendet; `Content-Length` muss
   `chunk_size` entsprechen (letzter Chunk kürzer). Cloudreve schreibt jeden
   Chunk am Offset `index × chunk_size`; ein wiederholter Index ist idempotent.
   Nach dem letzten Chunk ist die Datei fertig (kein eigener Abschluss-Aufruf).
3. Nach jedem bestätigten Chunk speichert reichi Sync den Zustand
   (`upload_sessions`: Sitzung, Chunks, Größe, mtime, Hash, Ablauf). Bricht die
   Übertragung ab, setzt der nächste Durchgang **am ersten unbestätigten Chunk**
   fort – sofern die Datei unverändert ist und die Sitzung noch > 2 min gültig
   ist. Sonst wird die Sitzung verworfen (`DELETE /api/v4/file/upload`) und neu
   begonnen. `40011` (Sitzung abgelaufen), `40012`/`40013` (Chunk-Fehler) führen
   zu genau einem Neustart.
4. Ändert sich die lokale Datei zwischen zwei Chunks, wird die Sitzung
   gelöscht und die Datei im nächsten Durchgang neu bewertet (kein
   Mischzustand auf dem Server).
5. Nach Abschluss wird die neue Version per `PROPFIND` gelesen (ETag =
   Entity-ID) und in die Baseline übernommen.

**Unterstützte Speicherrichtlinien:** unverschlüsseltes `local` sowie jede
unverschlüsselte Richtlinie mit `relay = true` (Chunks gehen an Cloudreve
selbst). Direkte Fremdspeicher-Uploads und Policies mit aktivierter
Client-Verschlüsselung werden fail-closed abgelehnt; ein ungeschützter
WebDAV-PUT-Rückfall findet nicht statt.

### Annahmen, die gegen eine echte Instanz zu bestätigen sind

- ETag der WebDAV-Antworten ist `"<hashid(entity)>"` und ändert sich mit jeder
  neuen Version (laut Quellcode).
- `GET /api/v4/devices/dav` liefert `password` im Klartext für bestehende
  Konten (laut API-Beschreibung); sonst muss der Assistent immer ein neues
  Konto anlegen.
- `PUT /api/v4/share` liefert als `data` die vollständige Link-URL
  (`<site>/s/<id>[/<passwort>]`).
- Fehlercodes entsprechen `pkg/serializer/error.go` (40004, 40011, 40012,
  40013, 40016, 40020, 40022, 40044, 40051, 40076, 40077, 40080).
- WebDAV-Konten mit Wurzel `cloudreve://my/<Ordner>` bilden den Ordner auf
  `/dav/` ab (relativer Root).

### Grenzen

- Kein paralleler Chunk-Versand (`chunk_concurrency` wird ignoriert;
  sequenziell ist für die Wiederaufnahme am einfachsten und robust).
- Keine Ordner-Freigaben mit eigenem Berechtigungsmodell; es werden nur
  Cloudreve-Share-Links erzeugt.
- Läuft das Refresh-Token ab (≈ 180 Tage ohne Nutzung) oder wird es serverseitig
  widerrufen, bleiben Listing und Download per WebDAV möglich. Uploads,
  Freigaben und Kontoverwaltung benötigen eine erneute Anmeldung; unsichere
  WebDAV-Schreibzugriffe werden nicht als Rückfall verwendet.

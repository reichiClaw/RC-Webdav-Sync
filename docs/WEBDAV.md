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
| `DELETE` | Löschen mit `If-Match` (starke ETags) oder vorheriger `PROPFIND`-Prüfung | Ordner werden vor dem Löschen erneut gelistet und mit der Baseline verglichen |
| `MOVE` | Umbenennungen (`Destination`, `Overwrite: F`, `If-Match`) | Fallback Upload + Löschung |
| `412 Precondition Failed` | Kennzeichen für Änderung seit der Bestandsaufnahme → Aktion zurückstellen, neu planen | Nie als Fehler „durchgedrückt“ |
| `423 Locked`, `507 Insufficient Storage`, `409 Conflict` | Werden gemeldet, Aktion wird zurückgestellt/fehlgeschlagen markiert | Kein Lock-Management (Klasse 2 wird nicht genutzt) |
| ETags | Opaque behandelt; schwache ETags (`W/`) werden erkannt und nicht für `If-Match` verwendet | Ohne ETags: Ersatzvalidator `mtime:<HTTP-Date>;size:<n>` |
| URL-Kodierung | Jedes Pfadsegment einzeln `percent-encoded`; `href`s dekodiert und gegen den Basis-Pfad validiert | Leerzeichen, Umlaute, Emoji, `#`, `?`, `+`, `%` getestet |
| Authentifizierung | HTTP Basic (vorab gesendet) über HTTPS | Siehe Grenzen |

## Getestete Server

| Server | Art des Tests | Ergebnis |
|---|---|---|
| `FakeWebDAVServer` (In-Memory-Actor) | Integrationstests für alle Sync-Szenarien (26 Tests) | bestanden auf Linux |
| `Scripts/dev-webdav-server.py` (Python-stdlib, Klasse 1, starke ETags, Basic Auth) | echte HTTP-Tests: Capabilities, 401, If-Match/If-None-Match-Zyklus, kompletter Engine-Lauf | bestanden auf Linux |
| Nextcloud / ownCloud | **nicht in dieser Umgebung getestet**; 207-Parser mit Nextcloud-Fixture (`Tests/…/Fixtures/nextcloud-propfind.xml`) geprüft; `OC-ETag`, `X-OC-Mtime`, `oc:`-Props, sync-collection-Format berücksichtigt | Verifikation auf einem Mac gegen eine echte Instanz empfohlen |
| Apache `mod_dav`, Synology, Nginx DAV | nicht getestet; nur Klasse-1-Funktionen vorausgesetzt | sollten funktionieren, da keine Erweiterungen verlangt werden |

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

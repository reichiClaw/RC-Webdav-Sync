# Signierung, Notarisierung und Sandbox

## Entitlements

`Sources/ReichiSyncApp/ReichiSync.entitlements`:

| Entitlement | Zweck |
|---|---|
| `com.apple.security.app-sandbox` | App Sandbox (Pflicht für App Store, empfohlen auch außerhalb) |
| `com.apple.security.network.client` | Ausgehende Verbindungen zum WebDAV-Server |
| `com.apple.security.files.user-selected.read-write` | Zugriff auf den vom Benutzer gewählten Sync-Ordner |
| `com.apple.security.files.bookmarks.app-scope` | Security-Scoped Bookmarks, damit der Zugriff Neustarts überlebt |

Keychain-Zugriff benötigt in der Sandbox kein zusätzliches Entitlement, solange
die App ihre eigenen Einträge verwendet (Service `de.reichi.sync`). Für
Login-Items (`SMAppService.mainApp`) ist kein Entitlement nötig; das System
zeigt den Eintrag unter *Systemeinstellungen › Allgemein › Anmeldeobjekte*.

## Lokale Entwicklung

- `Scripts/build-app.sh` signiert **ad hoc** (`--sign -`). Sandbox und
  Entitlements sind damit aktiv. Hinweis: Security-Scoped Bookmarks sind an
  die Signaturidentität gebunden; nach einem Neubau mit anderer Ad-hoc-
  Signatur kann das Bookmark ungültig werden – dann den Ordner in den
  Einstellungen erneut auswählen. Mit einem echten Development-Zertifikat
  tritt das nicht auf.
- In Xcode: *Signing & Capabilities* → Team wählen, „Automatically manage
  signing“. Die Capabilities werden aus der Entitlements-Datei übernommen.

## Distribution außerhalb des App Store (Developer ID)

```bash
# 1) Universal-Build + Bundle mit echter Identität
CODESIGN_IDENTITY="Developer ID Application: Max Mustermann (TEAMID)" \
  Scripts/build-app.sh release dist

# 2) Hardened Runtime ist im Skript aktiv (--options runtime). Prüfen:
codesign -dv --verbose=4 "dist/reichi Sync.app"
spctl --assess --type execute --verbose "dist/reichi Sync.app"   # vor Notarisierung: "rejected" ist normal

# 3) Archiv für den Notary Service
ditto -c -k --keepParent "dist/reichi Sync.app" dist/reichi-sync.zip

# 4) Notarisieren (einmalig: xcrun notarytool store-credentials "notary" --apple-id … --team-id … --password <app-spezifisches Passwort>)
xcrun notarytool submit dist/reichi-sync.zip --keychain-profile "notary" --wait

# 5) Ticket anheften und prüfen
xcrun stapler staple "dist/reichi Sync.app"
spctl --assess --type execute --verbose "dist/reichi Sync.app"   # jetzt: accepted, source=Notarized Developer ID
```

Alternativ in Xcode: *Product › Archive* → *Distribute App* → *Developer ID*
→ *Upload* (Notarisierung automatisch) → *Export*.

Für ein DMG: `hdiutil create -volname "reichi Sync" -srcfolder dist/"reichi Sync.app" -ov -format UDZO dist/reichi-sync.dmg`,
anschließend das DMG signieren (`codesign --sign "Developer ID Application: …" dist/reichi-sync.dmg`), notarisieren und stapeln.

## Mac App Store

- Signatur mit „Apple Distribution“, Provisioning-Profil mit App-ID
  `de.reichi.sync`.
- Sandbox ist aktiv; alle Dateizugriffe laufen über den gewählten Ordner
  (Bookmark) und den App-Container.
- `LSUIElement = true` ist für Menüleisten-Apps zulässig; in den Einstellungen
  kann das Dock-Symbol eingeschaltet werden (`NSApp.setActivationPolicy`).
- Keine privaten APIs; FSEvents, `SMAppService`, `UNUserNotificationCenter`,
  `NWPathMonitor` sind öffentliche Frameworks.

## Versionen

`CFBundleShortVersionString` (1.0.0) und `CFBundleVersion` (1) stehen in
`Sources/ReichiSyncApp/Info.plist` bzw. `project.yml`
(`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`).

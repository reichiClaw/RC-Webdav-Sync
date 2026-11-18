import Foundation

/// Verwaltet Security-Scoped Bookmarks für den dauerhaften Zugriff auf den vom
/// Benutzer gewählten lokalen Ordner (App Sandbox).
struct BookmarkStore {
    enum BookmarkError: Error, LocalizedError {
        case missing
        case cannotAccess

        var errorDescription: String? {
            switch self {
            case .missing: return "Für den lokalen Ordner liegt keine Zugriffsberechtigung vor. Bitte den Ordner in den Einstellungen erneut auswählen."
            case .cannotAccess: return "Der Zugriff auf den lokalen Ordner wurde vom System verweigert."
            }
        }
    }

    private let defaults = UserDefaults.standard

    private func key(_ accountID: String) -> String { "bookmark." + accountID }

    func makeData(folder: URL) throws -> Data {
        try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func save(data: Data, accountID: String) {
        defaults.set(data, forKey: key(accountID))
    }

    func save(folder: URL, accountID: String) throws {
        save(data: try makeData(folder: folder), accountID: accountID)
    }

    func data(accountID: String) -> Data? {
        defaults.data(forKey: key(accountID))
    }

    func remove(accountID: String) {
        defaults.removeObject(forKey: key(accountID))
    }

    /// Löst das Bookmark auf und beginnt den Zugriff. Der Aufrufer muss
    /// `stopAccessingSecurityScopedResource()` aufrufen, wenn der Zugriff endet.
    func resolveAndStartAccessing(accountID: String, fallbackPath: String?) throws -> URL {
        guard let data = defaults.data(forKey: key(accountID)) else {
            if let fallbackPath, FileManager.default.isWritableFile(atPath: fallbackPath) {
                // Ohne Sandbox (z. B. Entwicklungs-Build) reicht der Pfad.
                return URL(fileURLWithPath: fallbackPath, isDirectory: true)
            }
            throw BookmarkError.missing
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw BookmarkError.cannotAccess }
        if stale {
            do {
                try save(folder: url, accountID: accountID)
            } catch {
                url.stopAccessingSecurityScopedResource()
                throw error
            }
        }
        return url
    }
}

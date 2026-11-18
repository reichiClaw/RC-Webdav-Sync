import Foundation

/// Fehler bei der Prüfung von Pfaden.
public enum PathError: Error, Equatable, Sendable {
    case emptySegment
    case relativeTraversal
    case invalidCharacter
    case outsideRoot
    case tooLong
}

/// Hilfsfunktionen für sichere relative Pfade.
///
/// Alle Schlüsselpfade der Synchronisierung sind NFC-normalisiert, verwenden
/// „/“ als Trenner und haben weder führenden noch abschließenden Schrägstrich.
public enum RelativePath {
    /// Zerlegt einen Pfad in Segmente und prüft jedes Segment.
    public static func segments(of path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        for (index, part) in parts.enumerated() {
            if part.isEmpty {
                // Führende/abschließende Schrägstriche werden toleriert, leere Zwischensegmente nicht.
                if index == 0 || index == parts.count - 1 { continue }
                throw PathError.emptySegment
            }
            if part == "." || part == ".." { throw PathError.relativeTraversal }
            if part.unicodeScalars.contains(where: { $0.value == 0 }) { throw PathError.invalidCharacter }
            if part.utf8.count > 255 { throw PathError.tooLong }
            result.append(part)
        }
        return result
    }

    /// Normalisiert einen Pfad für den Vergleich (NFC, ohne Randschrägstriche).
    public static func normalize(_ path: String) throws -> String {
        try segments(of: path).map { $0.precomposedStringWithCanonicalMapping }.joined(separator: "/")
    }

    /// Schlüssel für die Erkennung von Kollisionen bei Groß-/Kleinschreibung
    /// (APFS/HFS+ sind standardmäßig nicht case-sensitiv).
    public static func caseInsensitiveKey(_ normalizedPath: String) -> String {
        normalizedPath
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    public static func parent(of path: String) -> String? {
        guard let idx = path.lastIndex(of: "/") else { return path.isEmpty ? nil : "" }
        return String(path[path.startIndex..<idx])
    }

    public static func name(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: idx)...])
    }

    public static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    /// Alle Vorfahren eines Pfades (ohne den Pfad selbst), von der Wurzel aus.
    public static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = ""
        let segs = path.split(separator: "/")
        for seg in segs.dropLast() {
            current = join(current, String(seg))
            result.append(current)
        }
        return result
    }

    public static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        if ancestor.isEmpty { return !path.isEmpty }
        return path.hasPrefix(ancestor + "/")
    }

    /// Bildet eine lokale URL unterhalb des Stammordners und stellt sicher, dass
    /// sie innerhalb des Stammordners bleibt.
    public static func localURL(root: URL, relativePath: String) throws -> URL {
        let segs = try segments(of: relativePath)
        var url = root
        for seg in segs { url.appendPathComponent(seg) }
        let rootPath = root.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate == rootPath || candidate.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw PathError.outsideRoot
        }
        return url
    }

    /// Erzeugt einen Konfliktkopie-Namen, z. B.
    /// `Bericht (Konfliktkopie von MacBook 2026-11-18 11-14-05).pdf`.
    public static func conflictCopyName(for name: String, deviceName: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let stamp = formatter.string(from: date)
        let safeDevice = deviceName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let device = truncateUTF8(safeDevice.isEmpty ? "Gerät" : safeDevice, maxBytes: 40)
        let originalExtension = (name as NSString).pathExtension
        let ext = truncateUTF8(originalExtension, maxBytes: 32)
        let originalBase = originalExtension.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = " (Konfliktkopie von \(device) \(stamp))"
        let extensionPart = ext.isEmpty ? "" : "." + ext
        let baseBudget = max(1, 255 - suffix.utf8.count - extensionPart.utf8.count)
        var base = truncateUTF8(originalBase, maxBytes: baseBudget)
        if base.isEmpty { base = truncateUTF8("Datei", maxBytes: baseBudget) }
        return base + suffix + extensionPart
    }

    static func truncateUTF8(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0, value.utf8.count > maxBytes else { return maxBytes > 0 ? value : "" }
        var result = ""
        var used = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard used + bytes <= maxBytes else { break }
            result.append(character)
            used += bytes
        }
        return result
    }
}

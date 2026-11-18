import Foundation

/// Ausschlussregeln für Dateien und Ordner.
///
/// Muster werden auf den Dateinamen angewendet; beginnt ein Muster mit „/“,
/// wird es gegen den relativen Pfad ab der Wurzel geprüft. Unterstützt werden
/// `*` (beliebige Zeichen außer „/“), `?` (ein Zeichen) und `**` (beliebige
/// Pfadteile).
public struct ExclusionRules: Sendable, Hashable {
    /// Präfix für eigene temporäre Dateien und Ordner. Diese werden immer ausgeschlossen.
    public static let internalPrefix = ".reichi-sync"

    /// Standardausschlüsse: Finder-Metadaten, AppleDouble-Dateien, Office-Sperrdateien.
    public static let defaultPatterns: [String] = [
        ".DS_Store",
        "._*",
        ".Trashes",
        ".Spotlight-V100",
        ".fseventsd",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        ".VolumeIcon.icns",
        "Icon\r",
        "Thumbs.db",
        "desktop.ini",
        "~$*",
        ".~lock.*#",
        "*.crdownload",
        "*.download",
        "*.part",
        ".reichi-sync*",
    ]

    public var patterns: [String]

    public init(patterns: [String] = ExclusionRules.defaultPatterns) {
        self.patterns = patterns
    }

    public init(userPatterns: [String]) {
        var all = ExclusionRules.defaultPatterns
        for p in userPatterns where !p.trimmingCharacters(in: .whitespaces).isEmpty && !all.contains(p) {
            all.append(p.trimmingCharacters(in: .whitespaces))
        }
        self.patterns = all
    }

    /// Prüft, ob ein relativer Pfad ausgeschlossen ist (inklusive aller Elternordner).
    public func isExcluded(relativePath: String) -> Bool {
        let name = RelativePath.name(of: relativePath)
        if name.hasPrefix(Self.internalPrefix) { return true }
        for segment in relativePath.split(separator: "/") where segment.hasPrefix(Self.internalPrefix) {
            return true
        }
        for pattern in patterns {
            if pattern.hasPrefix("/") {
                let anchored = String(pattern.dropFirst())
                if Self.match(pattern: anchored, text: relativePath) { return true }
                // Auch alle Elternpfade prüfen, damit ausgeschlossene Ordner ihre Inhalte mitnehmen.
                for ancestor in RelativePath.ancestors(of: relativePath) where Self.match(pattern: anchored, text: ancestor) {
                    return true
                }
            } else if pattern.contains("/") {
                // Muster mit Pfadanteil: gegen den Pfad und alle Teilpfade ab einem Ordner prüfen.
                let segments = relativePath.split(separator: "/").map(String.init)
                for start in 0..<segments.count {
                    let suffix = segments[start...].joined(separator: "/")
                    if Self.match(pattern: pattern, text: suffix) { return true }
                }
            } else {
                for segment in relativePath.split(separator: "/") where Self.match(pattern: pattern, text: String(segment)) {
                    return true
                }
            }
        }
        return false
    }

    /// Einfacher Glob-Vergleich. `*` entspricht beliebigen Zeichen außer „/“,
    /// `**` beliebigen Zeichen inklusive „/“, `?` genau einem Zeichen.
    public static func match(pattern: String, text: String) -> Bool {
        let p = Array(pattern.unicodeScalars)
        let t = Array(text.unicodeScalars)
        return matchGlob(p, 0, t, 0)
    }

    private static func matchGlob(_ p: [Unicode.Scalar], _ pi: Int, _ t: [Unicode.Scalar], _ ti: Int) -> Bool {
        var pi = pi
        var ti = ti
        while pi < p.count {
            let c = p[pi]
            if c == "*" {
                let doubleStar = pi + 1 < p.count && p[pi + 1] == "*"
                var next = pi + 1
                if doubleStar { next += 1 }
                if next == p.count {
                    if doubleStar { return true }
                    return !t[ti...].contains("/")
                }
                var k = ti
                while k <= t.count {
                    if matchGlob(p, next, t, k) { return true }
                    if k < t.count && !doubleStar && t[k] == "/" { return false }
                    k += 1
                }
                return false
            } else if c == "?" {
                if ti >= t.count || t[ti] == "/" { return false }
                pi += 1
                ti += 1
            } else {
                if ti >= t.count { return false }
                if c != t[ti] && !(c.properties.lowercaseMapping == t[ti].properties.lowercaseMapping) { return false }
                pi += 1
                ti += 1
            }
        }
        return ti == t.count
    }
}

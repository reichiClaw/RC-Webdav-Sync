import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Metadaten, die Foundation nicht auf allen unterstützten Plattformen stabil
/// bereitstellt. `lstat` folgt absichtlich keinen symbolischen Links.
enum POSIXFileMetadata {
    struct Values: Sendable, Equatable {
        let fileID: String
        let changeTime: TimeInterval
        /// Verlustfreier Cache-Schlüssel aus Gerät, Inode und ctime inklusive
        /// Nanosekunden. Ein `Double` allein kann bei großen Epoch-Werten
        /// benachbarte Zeitpunkte zusammenfassen.
        let cacheToken: String
        let isSymbolicLink: Bool
    }

    struct Timestamp: Sendable, Equatable {
        var seconds: Int64
        var nanoseconds: Int64
    }

    /// Unterschiede unter einer Millisekunde entstehen durch die Umwandlung
    /// zwischen APFS-Nanosekunden, `Date` und dem mikrosekundengenauen
    /// `utimes`, das `FileManager.setAttributes` auf dem Mac verwendet.
    /// Eine echte Bearbeitung setzt die Änderungszeit neu.
    static let modificationTimeTolerance: TimeInterval = 0.001

    static func sameModificationTime(_ lhs: TimeInterval, _ rhs: TimeInterval) -> Bool {
        lhs == rhs || abs(lhs - rhs) < modificationTimeTolerance
    }

    static func read(atPath path: String) throws -> Values? {
        var information = stat()
        guard lstat(path, &information) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXFileMetadataError(
                path: path,
                code: errno,
                message: String(cString: strerror(errno))
            )
        }

        #if canImport(Darwin)
        let seconds = information.st_ctimespec.tv_sec
        let nanoseconds = information.st_ctimespec.tv_nsec
        #else
        let seconds = information.st_ctim.tv_sec
        let nanoseconds = information.st_ctim.tv_nsec
        #endif

        // POSIX-Dateitypmaske und Kennung für symbolische Links.
        let typeMask = mode_t(0o170000)
        let symbolicLink = mode_t(0o120000)
        return Values(
            fileID: "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))",
            changeTime: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000,
            cacheToken: "\(UInt64(information.st_dev)):\(UInt64(information.st_ino)):\(seconds):\(nanoseconds)",
            isSymbolicLink: information.st_mode & typeMask == symbolicLink
        )
    }

    static func modificationTime(atPath path: String) throws -> Timestamp? {
        var information = stat()
        guard lstat(path, &information) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXFileMetadataError(
                path: path,
                code: errno,
                message: String(cString: strerror(errno))
            )
        }
        let (seconds, nanoseconds) = modificationComponents(of: information)
        return Timestamp(seconds: Int64(seconds), nanoseconds: Int64(nanoseconds))
    }

    /// Übernimmt eine Änderungszeit mit Nanosekunden. `FileManager.setAttributes`
    /// rundet auf dem Mac über `utimes` auf Mikrosekunden und lässt die Kopie
    /// dadurch wie eine andere Dateiversion aussehen.
    static func setModificationTime(atPath path: String, _ timestamp: Timestamp) throws {
        var times = [timespec(), timespec()]
        times[0].tv_nsec = omitNanoseconds
        times[1].tv_sec = time_t(timestamp.seconds)
        times[1].tv_nsec = Int(timestamp.nanoseconds)
        let result = path.withCString { cPath in
            times.withUnsafeBufferPointer { buffer in
                utimensat(AT_FDCWD, cPath, buffer.baseAddress, AT_SYMLINK_NOFOLLOW)
            }
        }
        guard result == 0 else {
            throw POSIXFileMetadataError(
                path: path,
                code: errno,
                message: String(cString: strerror(errno))
            )
        }
    }

    private static func modificationComponents(of information: stat) -> (seconds: time_t, nanoseconds: Int) {
        #if canImport(Darwin)
        return (information.st_mtimespec.tv_sec, information.st_mtimespec.tv_nsec)
        #else
        return (information.st_mtim.tv_sec, Int(information.st_mtim.tv_nsec))
        #endif
    }

    /// `UTIME_OMIT` ist auf Darwin `-2` und auf Linux `(1 << 30) - 2`.
    private static var omitNanoseconds: Int {
        #if canImport(Darwin)
        return -2
        #else
        return (1 << 30) - 2
        #endif
    }
}

struct POSIXFileMetadataError: LocalizedError {
    let path: String
    let code: Int32
    let message: String

    var errorDescription: String? {
        "Dateimetadaten für „\(path)“ konnten nicht gelesen werden (\(code)): \(message)"
    }
}

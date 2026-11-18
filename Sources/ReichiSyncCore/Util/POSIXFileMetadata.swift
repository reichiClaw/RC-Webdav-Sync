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
}

struct POSIXFileMetadataError: LocalizedError {
    let path: String
    let code: Int32
    let message: String

    var errorDescription: String? {
        "Dateimetadaten für „\(path)“ konnten nicht gelesen werden (\(code)): \(message)"
    }
}

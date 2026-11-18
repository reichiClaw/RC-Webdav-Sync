import Foundation

/// Ergebnis einer Upload-Vorbereitung durch die Engine: eindeutig bestimmte lokale Version.
public struct UploadRequestInfo: Sendable {
    /// Relativer Schlüsselpfad (NFC).
    public var path: String
    /// Pfad für das lokale Dateisystem.
    public var rawPath: String
    public var fileURL: URL
    public var size: Int64
    public var modified: Double
    public var hash: String
    /// Validator (ETag) der Serverversion, die ersetzt werden soll; `nil` bei neuer Datei.
    public var replacingValidator: String?

    public init(path: String, rawPath: String, fileURL: URL, size: Int64, modified: Double, hash: String, replacingValidator: String?) {
        self.path = path
        self.rawPath = rawPath
        self.fileURL = fileURL
        self.size = size
        self.modified = modified
        self.hash = hash
        self.replacingValidator = replacingValidator
    }
}

/// Alternative Upload-Strecke (z. B. Cloudreve-Chunk-API). Die Engine verwendet sie für Dateien
/// oberhalb der konfigurierten Schwelle; alles andere läuft per WebDAV `PUT`.
public protocol ResumableUploadTransport: Sendable {
    /// `true`, wenn die Strecke einsatzbereit ist (z. B. API-Anmeldung vorhanden).
    func isAvailable() async -> Bool
    /// Lädt die Datei hoch. Wirft `WebDAVError.preconditionFailed`, wenn sich die Serverversion
    /// geändert hat, `LocalFileError.changedSinceScan`, wenn sich die lokale Datei während des
    /// Uploads geändert hat, und `WebDAVError.network`, wenn der Upload später fortgesetzt werden kann.
    func upload(_ info: UploadRequestInfo, progress: TransferProgress?) async throws -> UploadResult
}

/// Persistierter Zustand eines unterbrochenen Chunk-Uploads.
public struct ResumableUploadState: Codable, Sendable, Hashable {
    public var path: String
    public var uri: String
    public var sessionID: String
    public var chunkSize: Int64
    public var totalChunks: Int
    /// Anzahl der bestätigten Chunks (0…totalChunks); Chunks werden sequenziell gesendet.
    public var uploadedChunks: Int
    public var size: Int64
    public var modified: Double
    public var hash: String
    public var expires: Date
    public var policyType: String
    public var policyRelay: Bool
    public var uploadURLs: [String]
    public var credential: String?
    public var createdAt: Date

    public init(path: String, uri: String, session: CloudreveUploadSession, info: UploadRequestInfo) {
        self.path = path
        self.uri = uri
        self.sessionID = session.sessionID
        self.chunkSize = session.chunkSize
        self.totalChunks = ResumableUploadState.chunkCount(size: info.size, chunkSize: session.chunkSize)
        self.uploadedChunks = 0
        self.size = info.size
        self.modified = info.modified
        self.hash = info.hash
        self.expires = session.expires
        self.policyType = session.policy.type
        self.policyRelay = session.policy.relay
        self.uploadURLs = session.uploadURLs
        self.credential = session.credential
        self.createdAt = Date()
    }

    public static func chunkCount(size: Int64, chunkSize: Int64) -> Int {
        if chunkSize <= 0 || size == 0 { return 1 }
        return Int((size + chunkSize - 1) / chunkSize)
    }

    /// Passt der gespeicherte Zustand zur aktuellen lokalen Version und ist die Sitzung noch gültig?
    public func matches(_ info: UploadRequestInfo, uri: String, now: Date = Date()) -> Bool {
        path == info.path && self.uri == uri && size == info.size && modified == info.modified && hash == info.hash
            && expires.timeIntervalSince(now) > 120
    }

    var session: CloudreveUploadSession {
        CloudreveUploadSession(sessionID: sessionID, chunkSize: chunkSize, expires: expires, uploadURLs: uploadURLs, credential: credential,
                               policy: CloudreveStoragePolicy(id: "", name: "", type: policyType, relay: policyRelay, chunkConcurrency: 1, maxSize: 0), uri: uri)
    }
}

/// Chunk-Upload über die Cloudreve-REST-API mit Wiederaufnahme nach Abbrüchen.
///
/// Ablauf: Upload-Sitzung anlegen (mit `previous` = bekannter ETag als Versionsprüfung) →
/// Chunks sequenziell am Offset senden (Zustand nach jedem Chunk persistieren) → nach dem letzten
/// Chunk schließt Cloudreve den Upload automatisch ab → ETag der neuen Version per WebDAV-PROPFIND
/// lesen. Bricht die Verbindung ab, wird beim nächsten Versuch ab dem ersten fehlenden Chunk
/// fortgesetzt, sofern Datei (Größe, mtime, Hash) und Sitzung unverändert sind.
public final class CloudreveUploadTransport: ResumableUploadTransport, @unchecked Sendable {
    private let api: CloudreveAPIClient
    private let dav: WebDAVClientProtocol
    private let store: SyncStore
    private let mappingID: String
    private let rootURI: String
    private let logger: SyncLogger
    /// Für Tests: feste Chunk-Größe erzwingen, falls der Server `0` (kein Chunking) meldet.
    public var fallbackChunkSize: Int64 = 0

    public init(api: CloudreveAPIClient, dav: WebDAVClientProtocol, store: SyncStore, mappingID: String, rootURI: String, logger: SyncLogger = .shared) {
        self.api = api
        self.dav = dav
        self.store = store
        self.mappingID = mappingID
        self.rootURI = rootURI
        self.logger = logger
    }

    public func isAvailable() async -> Bool {
        api.isSignedIn
    }

    public func upload(_ info: UploadRequestInfo, progress: TransferProgress?) async throws -> UploadResult {
        let uri = try CloudreveURI.fileURI(root: rootURI, relativePath: info.rawPath)
        var state: ResumableUploadState
        if let saved = try? await store.uploadState(path: info.path, mappingID: mappingID), saved.matches(info, uri: uri) {
            state = saved
            logger.info("cloudreve", "Upload von \(info.path) wird fortgesetzt (Chunk \(saved.uploadedChunks + 1)/\(saved.totalChunks))")
        } else {
            if let stale = try? await store.uploadState(path: info.path, mappingID: mappingID) {
                await api.deleteUploadSession(id: stale.sessionID, uri: stale.uri)
                try? await store.removeUploadState(path: info.path, mappingID: mappingID)
            }
            state = try await createSession(info, uri: uri)
        }
        do {
            return try await sendChunks(&state, info: info, uri: uri, progress: progress)
        } catch let error as CloudreveError {
            switch error {
            case .uploadSessionExpired, .invalidChunk:
                // Sitzung unbrauchbar: einmal komplett neu beginnen.
                logger.notice("cloudreve", "Upload-Sitzung für \(info.path) ungültig (\(error)); Neustart")
                try? await store.removeUploadState(path: info.path, mappingID: mappingID)
                await api.deleteUploadSession(id: state.sessionID, uri: uri)
                var fresh = try await createSession(info, uri: uri)
                do {
                    return try await sendChunks(&fresh, info: info, uri: uri, progress: progress)
                } catch let again as CloudreveError {
                    throw again.asWebDAVError
                }
            default:
                throw error.asWebDAVError
            }
        }
    }

    private func createSession(_ info: UploadRequestInfo, uri: String) async throws -> ResumableUploadState {
        let previous = info.replacingValidator.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).replacingOccurrences(of: "W/", with: "") }
        let session: CloudreveUploadSession
        do {
            session = try await api.createUploadSession(uri: uri, size: info.size, lastModified: Date(timeIntervalSince1970: info.modified),
                                                        overwrite: info.replacingValidator != nil, previousEntityID: previous)
        } catch let error as CloudreveError {
            throw error.asWebDAVError
        }
        guard session.usesLocalChunkAPI || session.usesRemoteChunkAPI else {
            await api.deleteUploadSession(id: session.sessionID, uri: uri)
            throw CloudreveError.unsupportedStoragePolicy(session.policy.type)
        }
        var adjusted = session
        if adjusted.chunkSize <= 0 && fallbackChunkSize > 0 { adjusted.chunkSize = fallbackChunkSize }
        var state = ResumableUploadState(path: info.path, uri: uri, session: adjusted, info: info)
        state.uploadedChunks = 0
        try await store.saveUploadState(state, mappingID: mappingID)
        logger.info("cloudreve", "Upload-Sitzung für \(info.path): \(state.totalChunks) Chunk(s) à \(state.chunkSize) Bytes, Richtlinie \(session.policy.type)")
        return state
    }

    private func sendChunks(_ state: inout ResumableUploadState, info: UploadRequestInfo, uri: String, progress: TransferProgress?) async throws -> UploadResult {
        let handle = try FileHandle(forReadingFrom: info.fileURL)
        defer { try? handle.close() }
        let session = state.session
        let chunkSize = state.chunkSize > 0 ? state.chunkSize : max(info.size, 1)
        while state.uploadedChunks < state.totalChunks {
            try Task.checkCancellation()
            // Lokale Datei darf sich zwischen den Chunks nicht ändern.
            let attrs = try FileManager.default.attributesOfItem(atPath: info.fileURL.path)
            let currentSize = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let currentModified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            if currentSize != info.size || currentModified != info.modified {
                logger.notice("cloudreve", "\(info.path) wurde während des Uploads geändert – Sitzung verworfen")
                try? await store.removeUploadState(path: info.path, mappingID: mappingID)
                await api.deleteUploadSession(id: state.sessionID, uri: uri)
                throw LocalFileError.changedSinceScan(info.path)
            }
            let index = state.uploadedChunks
            let offset = Int64(index) * chunkSize
            let length = Int(min(chunkSize, info.size - offset))
            try handle.seek(toOffset: UInt64(offset))
            let data = length > 0 ? (try handle.read(upToCount: length) ?? Data()) : Data()
            guard data.count == length else { throw WebDAVError.network("Datei konnte nicht vollständig gelesen werden") }
            let base = offset
            let total = info.size
            let chunkProgress: TransferProgress? = progress.map { handler in
                { @Sendable sent, _ in handler(min(total, base + sent), total) }
            }
            try await api.uploadChunk(data, index: index, session: session, progress: chunkProgress)
            state.uploadedChunks = index + 1
            try await store.saveUploadState(state, mappingID: mappingID)
            progress?(min(total, offset + Int64(length)), total)
        }
        try? await store.removeUploadState(path: info.path, mappingID: mappingID)
        // Neue Version abfragen (ETag = Entity-ID).
        let stat = try await dav.stat(info.rawPath)
        if let stat, stat.size != info.size {
            logger.warning("cloudreve", "Größe nach Upload weicht ab (\(stat.size) ≠ \(info.size)) für \(info.path)")
            throw WebDAVError.invalidResponse("Server meldet nach dem Upload eine abweichende Dateigröße")
        }
        return UploadResult(etag: stat?.validator, status: 201)
    }
}

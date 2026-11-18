import Foundation
@testable import ReichiSyncCore

/// In-Memory-WebDAV-Server für Integrationstests der Engine.
///
/// Implementiert das `WebDAVClientProtocol` direkt (ohne HTTP) und erlaubt das
/// gezielte Einspielen von Fehlern: fehlgeschlagene Auflistungen, abgebrochene
/// Übertragungen, konkurrierende Änderungen zwischen Bestandsaufnahme und Upload.
actor FakeWebDAVServer: WebDAVClientProtocol {
    struct File {
        var data: Data
        var etag: String
        var modified: Date
    }

    private(set) var files: [String: File] = [:]
    private(set) var directories: Set<String> = [""]
    private var etagCounter = 0
    private var changeCounter = 0
    private var changeLog: [(seq: Int, path: String, deleted: Bool)] = []

    // Fehlerinjektion
    var failListingPrefixes: Set<String> = []
    var offline = false
    var authFails = false
    var dropConnectionOnUploadButStore = false
    var dropConnectionOnDownload = false
    var beforeUpload: (@Sendable (String) async -> Void)?
    var supportsSync = false
    var weakETags = false
    var requestLog: [String] = []

    init() {}

    // MARK: Hilfen für Tests

    func putFile(_ path: String, _ content: String, modified: Date = Date()) {
        for ancestor in RelativePath.ancestors(of: path) { directories.insert(ancestor) }
        files[path] = File(data: Data(content.utf8), etag: nextETag(), modified: modified)
        record(path, deleted: false)
    }

    func mkdir(_ path: String) {
        for ancestor in RelativePath.ancestors(of: path) { directories.insert(ancestor) }
        directories.insert(path)
        record(path, deleted: false)
    }

    func remove(_ path: String) {
        files[path] = nil
        directories.remove(path)
        for key in files.keys where RelativePath.isDescendant(key, of: path) { files[key] = nil }
        for key in directories where RelativePath.isDescendant(key, of: path) { directories.remove(key) }
        record(path, deleted: true)
    }

    func content(_ path: String) -> String? {
        files[path].map { String(decoding: $0.data, as: UTF8.self) }
    }

    func exists(_ path: String) -> Bool { files[path] != nil || directories.contains(path) }

    func setFailListing(_ prefixes: Set<String>) { failListingPrefixes = prefixes }
    func setOffline(_ value: Bool) { offline = value }
    func setAuthFails(_ value: Bool) { authFails = value }
    func setDropConnectionOnUploadButStore(_ value: Bool) { dropConnectionOnUploadButStore = value }
    func setDropConnectionOnDownload(_ value: Bool) { dropConnectionOnDownload = value }
    func setBeforeUpload(_ hook: (@Sendable (String) async -> Void)?) { beforeUpload = hook }
    func setSupportsSync(_ value: Bool) { supportsSync = value }
    func setWeakETags(_ value: Bool) { weakETags = value }
    func log() -> [String] { requestLog }
    func clearLog() { requestLog = [] }

    private func nextETag() -> String {
        etagCounter += 1
        return weakETags ? "W/\"e\(etagCounter)\"" : "\"e\(etagCounter)\""
    }

    private func record(_ path: String, deleted: Bool) {
        changeCounter += 1
        changeLog.append((changeCounter, path, deleted))
    }

    private func checkConnection() throws {
        if offline { throw WebDAVError.network("Simulierter Verbindungsabbruch") }
        if authFails { throw WebDAVError.authenticationRequired(status: 401) }
    }

    private func item(_ path: String) -> RemoteItem? {
        if let f = files[path] {
            return RemoteItem(path: path, rawPath: path, kind: .file, size: Int64(f.data.count), modified: f.modified.timeIntervalSince1970,
                              validator: f.etag, validatorIsStrong: !f.etag.hasPrefix("W/"), contentType: nil)
        }
        if directories.contains(path) {
            return RemoteItem(path: path, rawPath: path, kind: .directory, size: 0, modified: nil, validator: "\"dir\"", validatorIsStrong: false)
        }
        return nil
    }

    // MARK: WebDAVClientProtocol

    func detectCapabilities() async throws -> WebDAVCapabilities {
        try checkConnection()
        return WebDAVCapabilities(davClasses: ["1", "3"], supportsSyncCollection: supportsSync, providesETags: true, strongETags: !weakETags, serverSoftware: "FakeDAV")
    }

    func probe() async throws -> RemoteItem {
        try checkConnection()
        requestLog.append("PROBE")
        return RemoteItem(path: "", rawPath: "", kind: .directory)
    }

    func list(directory rawPath: String) async throws -> [RemoteItem] {
        try checkConnection()
        requestLog.append("LIST \(rawPath)")
        let key = (try? RelativePath.normalize(rawPath)) ?? rawPath
        if failListingPrefixes.contains(key) { throw WebDAVError.unexpectedStatus(500, "Simulierter Serverfehler") }
        guard directories.contains(key) else { throw WebDAVError.notFound }
        var result: [RemoteItem] = []
        for path in files.keys where RelativePath.parent(of: path) == key { result.append(item(path)!) }
        for path in directories where !path.isEmpty && RelativePath.parent(of: path) == key { result.append(item(path)!) }
        return result
    }

    func stat(_ rawPath: String) async throws -> RemoteItem? {
        try checkConnection()
        requestLog.append("STAT \(rawPath)")
        return item((try? RelativePath.normalize(rawPath)) ?? rawPath)
    }

    func syncCollection(token: String?) async throws -> SyncCollectionResult {
        try checkConnection()
        requestLog.append("SYNC \(token ?? "nil")")
        guard supportsSync else { throw WebDAVError.unexpectedStatus(403, "REPORT nicht unterstützt") }
        var since = 0
        if let token {
            guard token.hasPrefix("fake-sync-"), let n = Int(token.dropFirst("fake-sync-".count)) else { throw WebDAVError.invalidSyncToken }
            since = n
        }
        var changes: [SyncCollectionChange] = []
        var seenPaths: Set<String> = []
        for entry in changeLog.reversed() where entry.seq > since {
            if seenPaths.contains(entry.path) { continue }
            seenPaths.insert(entry.path)
            if let current = item(entry.path) {
                changes.append(SyncCollectionChange(item: current, path: entry.path, deleted: false))
            } else {
                changes.append(SyncCollectionChange(item: nil, path: entry.path, deleted: true))
            }
        }
        if token == nil {
            for path in files.keys where !seenPaths.contains(path) { changes.append(SyncCollectionChange(item: item(path), path: path, deleted: false)) }
            for path in directories where !path.isEmpty && !seenPaths.contains(path) { changes.append(SyncCollectionChange(item: item(path), path: path, deleted: false)) }
        }
        return SyncCollectionResult(changes: changes, newToken: "fake-sync-\(changeCounter)")
    }

    func currentSyncToken() async throws -> String? {
        try checkConnection()
        return supportsSync ? "fake-sync-\(changeCounter)" : nil
    }

    func download(_ rawPath: String, to destination: URL, progress: TransferProgress?) async throws -> DownloadResult {
        try checkConnection()
        requestLog.append("GET \(rawPath)")
        let key = (try? RelativePath.normalize(rawPath)) ?? rawPath
        guard let f = files[key] else { throw WebDAVError.notFound }
        if dropConnectionOnDownload { throw WebDAVError.network("Simulierter Abbruch beim Download") }
        try f.data.write(to: destination)
        progress?(Int64(f.data.count), Int64(f.data.count))
        return DownloadResult(etag: f.etag, lastModified: f.modified, contentLength: Int64(f.data.count))
    }

    func upload(file: URL, to rawPath: String, ifMatch: String?, ifNoneMatchAll: Bool, progress: TransferProgress?) async throws -> UploadResult {
        try checkConnection()
        requestLog.append("PUT \(rawPath) ifMatch=\(ifMatch ?? "-") ifNoneMatch=\(ifNoneMatchAll)")
        let key = (try? RelativePath.normalize(rawPath)) ?? rawPath
        if let hook = beforeUpload { await hook(key) }
        guard let parent = RelativePath.parent(of: key), directories.contains(parent) else { throw WebDAVError.conflict(status: 409, "Elternordner fehlt") }
        if ifNoneMatchAll, files[key] != nil { throw WebDAVError.preconditionFailed }
        if let ifMatch {
            guard let existing = files[key], existing.etag == ifMatch else { throw WebDAVError.preconditionFailed }
        }
        let data = try Data(contentsOf: file)
        let newFile = File(data: data, etag: nextETag(), modified: Date())
        files[key] = newFile
        record(key, deleted: false)
        if dropConnectionOnUploadButStore {
            dropConnectionOnUploadButStore = false
            throw WebDAVError.network("Simulierter Abbruch nach dem Speichern")
        }
        progress?(Int64(data.count), Int64(data.count))
        return UploadResult(etag: newFile.etag, status: 201)
    }

    func makeDirectory(_ rawPath: String) async throws {
        try checkConnection()
        requestLog.append("MKCOL \(rawPath)")
        let key = (try? RelativePath.normalize(rawPath)) ?? rawPath
        if directories.contains(key) || files[key] != nil { throw WebDAVError.conflict(status: 405, "existiert") }
        guard let parent = RelativePath.parent(of: key), directories.contains(parent) else { throw WebDAVError.conflict(status: 409, "Elternordner fehlt") }
        directories.insert(key)
        record(key, deleted: false)
    }

    func delete(_ rawPath: String, ifMatch: String?) async throws {
        try checkConnection()
        requestLog.append("DELETE \(rawPath) ifMatch=\(ifMatch ?? "-")")
        let key = (try? RelativePath.normalize(rawPath)) ?? rawPath
        if let ifMatch, let f = files[key], f.etag != ifMatch { throw WebDAVError.preconditionFailed }
        guard exists(key) else { throw WebDAVError.notFound }
        remove(key)
    }

    func move(from rawPath: String, to destinationRawPath: String, overwrite: Bool, ifMatch: String?) async throws {
        try checkConnection()
        requestLog.append("MOVE \(rawPath) -> \(destinationRawPath)")
        let from = (try? RelativePath.normalize(rawPath)) ?? rawPath
        let to = (try? RelativePath.normalize(destinationRawPath)) ?? destinationRawPath
        guard let f = files[from] else { throw WebDAVError.notFound }
        if let ifMatch, f.etag != ifMatch { throw WebDAVError.preconditionFailed }
        if !overwrite, exists(to) { throw WebDAVError.preconditionFailed }
        guard let parent = RelativePath.parent(of: to), directories.contains(parent) else { throw WebDAVError.conflict(status: 409, "Elternordner fehlt") }
        files[to] = File(data: f.data, etag: nextETag(), modified: f.modified)
        files[from] = nil
        record(from, deleted: true)
        record(to, deleted: false)
    }
}

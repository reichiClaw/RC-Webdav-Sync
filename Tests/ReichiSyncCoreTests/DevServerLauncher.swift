import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// Startet `Scripts/dev-webdav-server.py` für HTTP-Integrationstests und beendet ihn wieder.
final class DevServerLauncher {
    let serverRoot: URL
    private(set) var port: Int = 0
    private var process: Process?

    var davURL: URL { URL(string: "http://127.0.0.1:\(port)/dav/")! }
    var siteURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    init() throws {
        serverRoot = FileManager.default.temporaryDirectory.appendingPathComponent("reichi-dav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: serverRoot, withIntermediateDirectories: true)
    }

    /// Startet den Server; wirft `XCTSkip`, wenn Python oder das Skript fehlen.
    func start(user: String = "anna", password: String = "geheim", extraArguments: [String] = []) throws {
        let script = Self.repoRoot().appendingPathComponent("Scripts/dev-webdav-server.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw XCTSkip("Testserver-Skript nicht gefunden") }
        let python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { throw XCTSkip("python3 nicht verfügbar") }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        var arguments = [script.path, "--root", serverRoot.path, "--port", "0", "--user", user, "--password", password] + extraArguments
        let readinessURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reichi-devserver-ready-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: readinessURL.path, contents: nil),
              let readinessHandle = FileHandle(forWritingAtPath: readinessURL.path) else {
            throw NSError(
                domain: "de.reichi.sync.tests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Temporäre Readiness-Datei konnte nicht angelegt werden"]
            )
        }
        defer {
            try? readinessHandle.close()
            try? FileManager.default.removeItem(at: readinessURL)
        }
        proc.standardOutput = readinessHandle
        // REICHI_DEVSERVER_LOG=/pfad/datei.log protokolliert die Serveranfragen (Fehlersuche).
        if let logPath = ProcessInfo.processInfo.environment["REICHI_DEVSERVER_LOG"] {
            if !FileManager.default.fileExists(atPath: logPath) { _ = FileManager.default.createFile(atPath: logPath, contents: nil) }
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                proc.standardError = handle
            }
        } else {
            arguments.append("--quiet")
            proc.standardError = FileHandle.nullDevice
        }
        proc.arguments = arguments
        try proc.run()
        process = proc

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let buffer = (try? Data(contentsOf: readinessURL)) ?? Data()
            if let text = String(data: buffer, encoding: .utf8), let line = text.split(separator: "\n").first(where: { $0.hasPrefix("READY ") }),
               let p = Int(line.dropFirst("READY ".count).trimmingCharacters(in: .whitespaces)) {
                port = p
                return
            }
            if !proc.isRunning { break }
            usleep(50_000)
        }
        stop()
        throw NSError(
            domain: "de.reichi.sync.tests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Testserver konnte nicht innerhalb von 10 Sekunden gestartet werden"]
        )
    }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        try? FileManager.default.removeItem(at: serverRoot)
    }

    // MARK: - Test-Hooks der Cloudreve-Emulation

    @discardableResult
    func hook(_ name: String, json: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: siteURL.appendingPathComponent("__test/\(name)"))
        request.httpMethod = json == nil ? "GET" : "POST"
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    /// Pfade aller bisher protokollierten API-Anfragen (`METHOD /pfad`).
    func requestLog() async throws -> [String] {
        let data = try await hook("log")
        let entries = try JSONSerialization.jsonObject(with: data) as? [[String: String]] ?? []
        return entries.map { "\($0["method"] ?? "?") \($0["path"] ?? "?")" }
    }
}

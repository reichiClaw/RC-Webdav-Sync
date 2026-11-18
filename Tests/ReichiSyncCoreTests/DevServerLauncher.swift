import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import XCTest

/// Startet `Scripts/dev-webdav-server.py` für HTTP-Integrationstests und beendet ihn wieder.
final class DevServerLauncher {
    let serverRoot: URL
    private(set) var port: Int = 0
    #if os(Linux)
    private var processID: pid_t?
    #else
    private var process: Process?
    #endif

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

        #if os(Linux)
        // Foundation.Process verwendet unter swift-corelibs-foundation eine
        // Dispatch-Source, deren Beenden sporadisch synchron auf ihre eigene
        // Queue wartet. POSIX spawn/waitpid vermeidet diesen Laufzeitfehler.
        var errorHandle: FileHandle?
        let standardErrorFD: Int32
        if let logPath = ProcessInfo.processInfo.environment["REICHI_DEVSERVER_LOG"] {
            if !FileManager.default.fileExists(atPath: logPath) {
                _ = FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: logPath) else {
                throw NSError(
                    domain: "de.reichi.sync.tests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Testserver-Protokoll konnte nicht geöffnet werden"]
                )
            }
            handle.seekToEndOfFile()
            errorHandle = handle
            standardErrorFD = handle.fileDescriptor
        } else {
            arguments.append("--quiet")
            standardErrorFD = open("/dev/null", O_WRONLY)
            guard standardErrorFD >= 0 else {
                throw NSError(
                    domain: "de.reichi.sync.tests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Null-Ausgabe für den Testserver konnte nicht geöffnet werden"]
                )
            }
        }
        defer {
            if let errorHandle {
                try? errorHandle.close()
            } else {
                _ = close(standardErrorFD)
            }
        }
        processID = try Self.spawn(
            executable: python,
            arguments: arguments,
            standardOutputFD: readinessHandle.fileDescriptor,
            standardErrorFD: standardErrorFD
        )
        #else
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
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
        #endif

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let buffer = (try? Data(contentsOf: readinessURL)) ?? Data()
            if let text = String(data: buffer, encoding: .utf8), let line = text.split(separator: "\n").first(where: { $0.hasPrefix("READY ") }),
               let p = Int(line.dropFirst("READY ".count).trimmingCharacters(in: .whitespaces)) {
                port = p
                return
            }
            #if os(Linux)
            if !linuxProcessIsRunning() { break }
            #else
            if !proc.isRunning { break }
            #endif
            usleep(50_000)
        }
        stop()
        throw NSError(
            domain: "de.reichi.sync.tests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Testserver konnte nicht innerhalb von 10 Sekunden gestartet werden"]
        )
    }

    #if os(Linux)
    private static func spawn(
        executable: String,
        arguments: [String],
        standardOutputFD: Int32,
        standardErrorFD: Int32
    ) throws -> pid_t {
        var actions = posix_spawn_file_actions_t()
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else { throw spawnError(code) }
        defer { posix_spawn_file_actions_destroy(&actions) }

        code = posix_spawn_file_actions_adddup2(&actions, standardOutputFD, STDOUT_FILENO)
        guard code == 0 else { throw spawnError(code) }
        code = posix_spawn_file_actions_adddup2(&actions, standardErrorFD, STDERR_FILENO)
        guard code == 0 else { throw spawnError(code) }
        if standardOutputFD != STDOUT_FILENO {
            code = posix_spawn_file_actions_addclose(&actions, standardOutputFD)
            guard code == 0 else { throw spawnError(code) }
        }
        if standardErrorFD != STDERR_FILENO, standardErrorFD != standardOutputFD {
            code = posix_spawn_file_actions_addclose(&actions, standardErrorFD)
            guard code == 0 else { throw spawnError(code) }
        }

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        guard !argv.contains(where: { $0 == nil }) else {
            for case let value? in argv { free(value) }
            throw spawnError(ENOMEM)
        }
        argv.append(nil)
        defer {
            for case let value? in argv { free(value) }
        }

        var pid: pid_t = 0
        code = executable.withCString { executablePath in
            argv.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(&pid, executablePath, &actions, nil, buffer.baseAddress!, environ)
            }
        }
        guard code == 0 else { throw spawnError(code) }
        return pid
    }

    private static func spawnError(_ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
        )
    }

    private func linuxProcessIsRunning() -> Bool {
        guard let processID else { return false }
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        if result == 0 { return true }
        if result == -1, errno == EINTR { return true }
        self.processID = nil
        return false
    }
    #endif

    func stop() {
        #if os(Linux)
        if let processID {
            _ = kill(processID, SIGTERM)
            let deadline = Date().addingTimeInterval(2)
            var reaped = false
            while Date() < deadline {
                var status: Int32 = 0
                let result = waitpid(processID, &status, WNOHANG)
                if result == processID || (result == -1 && errno == ECHILD) {
                    reaped = true
                    break
                }
                if result == -1, errno != EINTR { break }
                usleep(20_000)
            }
            if !reaped {
                _ = kill(processID, SIGKILL)
                var status: Int32 = 0
                while waitpid(processID, &status, 0) == -1, errno == EINTR {}
            }
            self.processID = nil
        }
        #else
        if let process {
            let pid = process.processIdentifier
            if pid > 0 {
                _ = kill(pid, SIGTERM)
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    if kill(pid, 0) == -1, errno == ESRCH { break }
                    usleep(20_000)
                }
                if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
            }
        }
        process = nil
        #endif
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

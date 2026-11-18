import Foundation
import CSQLite

/// Fehler der Datenbankschicht.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite-Fehler \(code): \(message)" }
}

/// Ein Wert, der an eine SQL-Anweisung gebunden werden kann.
public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ v: Int64?) { self = v.map { .integer($0) } ?? .null }
    public init(_ v: Int?) { self = v.map { .integer(Int64($0)) } ?? .null }
    public init(_ v: Double?) { self = v.map { .real($0) } ?? .null }
    public init(_ v: String?) { self = v.map { .text($0) } ?? .null }
    public init(_ v: Bool) { self = .integer(v ? 1 : 0) }
    public init(_ v: Date?) { self = v.map { .real($0.timeIntervalSince1970) } ?? .null }
}

/// Eine Ergebniszeile.
public struct SQLRow: Sendable {
    public let columns: [String: SQLValue]

    public func int64(_ name: String) -> Int64? {
        if case .integer(let v)? = columns[name] { return v }
        if case .real(let v)? = columns[name] { return Int64(v) }
        return nil
    }

    public func int(_ name: String) -> Int? { int64(name).map(Int.init) }
    public func bool(_ name: String) -> Bool { (int64(name) ?? 0) != 0 }

    public func double(_ name: String) -> Double? {
        if case .real(let v)? = columns[name] { return v }
        if case .integer(let v)? = columns[name] { return Double(v) }
        return nil
    }

    public func string(_ name: String) -> String? {
        if case .text(let v)? = columns[name] { return v }
        return nil
    }

    public func date(_ name: String) -> Date? { double(name).map { Date(timeIntervalSince1970: $0) } }
}

/// Dünne, synchrone Hülle um SQLite. Wird ausschließlich innerhalb des
/// `SyncStore`-Actors verwendet und ist daher nicht selbst threadsicher.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Datenbank konnte nicht geöffnet werden"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: rc, message: msg)
        }
        handle = db
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
        // Gelöschte JSON-Datensätze dürfen keine früher gespeicherten
        // Zugangsdaten in frei gewordenen Datenbankseiten hinterlassen.
        try execute("PRAGMA secure_delete = ON")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        _ = try query(sql, params)
    }

    @discardableResult
    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "Datenbank geschlossen") }
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)) + " — SQL: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let bindResult: Int32
            switch p {
            case .null:
                bindResult = sqlite3_bind_null(stmt, idx)
            case .integer(let v):
                bindResult = sqlite3_bind_int64(stmt, idx, v)
            case .real(let v):
                bindResult = sqlite3_bind_double(stmt, idx, v)
            case .text(let v):
                bindResult = sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v):
                bindResult = v.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(v.count), transient)
                }
            }
            guard bindResult == SQLITE_OK else {
                throw SQLiteError(
                    code: bindResult,
                    message: String(cString: sqlite3_errmsg(handle)) + " — Parameter \(idx), SQL: \(sql)"
                )
            }
        }
        var rows: [SQLRow] = []
        let columnCount = Int(sqlite3_column_count(stmt))
        var names: [String] = []
        for c in 0..<columnCount { names.append(String(cString: sqlite3_column_name(stmt, Int32(c)))) }
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var cols: [String: SQLValue] = [:]
                for c in 0..<columnCount {
                    let ci = Int32(c)
                    switch sqlite3_column_type(stmt, ci) {
                    case SQLITE_INTEGER: cols[names[c]] = .integer(sqlite3_column_int64(stmt, ci))
                    case SQLITE_FLOAT: cols[names[c]] = .real(sqlite3_column_double(stmt, ci))
                    case SQLITE_TEXT:
                        if let text = sqlite3_column_text(stmt, ci) { cols[names[c]] = .text(String(cString: text)) } else { cols[names[c]] = .null }
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(stmt, ci))
                        if let bytes = sqlite3_column_blob(stmt, ci) { cols[names[c]] = .blob(Data(bytes: bytes, count: count)) } else { cols[names[c]] = .blob(Data()) }
                    default: cols[names[c]] = .null
                    }
                }
                rows.append(SQLRow(columns: cols))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)) + " — SQL: \(sql)")
            }
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func userVersion() throws -> Int {
        try query("PRAGMA user_version").first?.int("user_version") ?? 0
    }

    public func setUserVersion(_ version: Int) throws {
        guard version >= 0 else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "Ungültige Schema-Version \(version)")
        }
        try execute("PRAGMA user_version = \(version)")
    }
}

import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Lightweight SQLite wrapper for reading iOS backup databases.
final class SQLiteReader {

    private var db: OpaquePointer?
    let path: String

    enum SQLiteError: Error, LocalizedError {
        case openFailed(String)
        case queryFailed(String)
        case prepareFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "SQLite open failed: \(msg)"
            case .queryFailed(let msg): return "SQLite query failed: \(msg)"
            case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
            }
        }
    }

    init(path: String) throws {
        self.path = path

        // Fail fast if the file is missing: sqlite3_open_v2 with READONLY opens
        // lazily, so a missing file would surface as a confusing prepare error later.
        guard FileManager.default.fileExists(atPath: path) else {
            throw SQLiteError.openFailed("file not found: \(path)")
        }

        // Open read-only + immutable via URI so SQLite never tries to create
        // -wal / -shm sidecars next to the database. Backup directories can be
        // TCC-protected or read-only and WAL creation would otherwise fail the
        // first prepare with 'unable to open database file'.
        var dbPointer: OpaquePointer?
        let encoded = path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:\(encoded)?mode=ro&immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2(uri, &dbPointer, flags, nil)
        guard rc == SQLITE_OK, let opened = dbPointer else {
            let msg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(dbPointer)
            throw SQLiteError.openFailed(msg)
        }
        self.db = opened
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    /// Execute a query and return rows as dictionaries.
    func query(_ sql: String, params: [String] = []) throws -> [[String: Any?]] {
        guard let db = db else { throw SQLiteError.openFailed("Database not open") }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let statement = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(statement) }

        // Bind parameters
        for (index, param) in params.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), (param as NSString).utf8String, -1, nil)
        }

        var rows: [[String: Any?]] = []
        let columnCount = sqlite3_column_count(statement)

        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any?] = [:]
            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, i))
                let type = sqlite3_column_type(statement, i)

                switch type {
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT:
                    if let cStr = sqlite3_column_text(statement, i) {
                        row[name] = String(cString: cStr)
                    } else {
                        row[name] = nil
                    }
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(statement, i)
                    if let blob = sqlite3_column_blob(statement, i) {
                        row[name] = Data(bytes: blob, count: Int(bytes))
                    } else {
                        row[name] = nil
                    }
                case SQLITE_NULL:
                    row[name] = nil
                default:
                    row[name] = nil
                }
            }
            rows.append(row)
        }

        return rows
    }

    /// Get a single scalar value from a query.
    func scalar<T>(_ sql: String) throws -> T? {
        let rows = try query(sql)
        guard let firstRow = rows.first, let firstValue = firstRow.values.first else {
            return nil
        }
        return firstValue as? T
    }

    /// Get table names in the database.
    func tableNames() throws -> [String] {
        let rows = try query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        return rows.compactMap { $0["name"] as? String }
    }

    /// Get column info for a table.
    func columns(for table: String) throws -> [(name: String, type: String)] {
        let rows = try query("PRAGMA table_info(\(table))")
        return rows.compactMap { row in
            guard let name = row["name"] as? String,
                  let type = row["type"] as? String else { return nil }
            return (name: name, type: type)
        }
    }

    /// Get row count for a table.
    func rowCount(for table: String) throws -> Int {
        let count: Int? = try scalar("SELECT COUNT(*) FROM \(table)")
        return count ?? 0
    }
}

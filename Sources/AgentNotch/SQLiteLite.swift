import Foundation
import SQLite3

/// Minimal read-only SQLite reader. Opens read-write so it can attach to the
/// WAL of a database another process holds open, then hard-locks itself with
/// `query_only` so it can never write.
final class SQLiteLite {
    private var db: OpaquePointer?
    private let path: String
    private var openedAt: Date = .distantPast

    init(path: String) { self.path = path }
    deinit { close() }

    var isOpen: Bool { db != nil }

    @discardableResult
    func open() -> Bool {
        if db != nil { return true }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        // Don't hammer a missing/locked file.
        guard Date().timeIntervalSince(openedAt) > 5 else { return false }
        openedAt = Date()
        var handle: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            sqlite3_close(handle)
            handle = nil
            flags = SQLITE_OPEN_READONLY
            if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
                sqlite3_close(handle)
                return false
            }
        }
        db = handle
        exec("PRAGMA query_only = 1;")
        exec("PRAGMA busy_timeout = 200;")
        return true
    }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Runs a query and hands each row to the caller as `[column: value]`.
    func query(_ sql: String) -> [[String: String]] {
        guard open(), let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // Database swapped underneath us (e.g. after a vacuum) — reopen next tick.
            close()
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: String]] = []
        let columns = Int(sqlite3_column_count(stmt))
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<columns {
                guard let cName = sqlite3_column_name(stmt, Int32(i)) else { continue }
                let name = String(cString: cName)
                if let text = sqlite3_column_text(stmt, Int32(i)) {
                    row[name] = String(cString: text)
                }
            }
            rows.append(row)
        }
        return rows
    }
}

extension Dictionary where Key == String, Value == String {
    func i(_ k: String) -> Int { Int(self[k] ?? "") ?? 0 }
    func d(_ k: String) -> Double { Double(self[k] ?? "") ?? 0 }
    func s(_ k: String) -> String? { self[k] }
    func json(_ k: String) -> [String: Any]? {
        guard let raw = self[k], let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

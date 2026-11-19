import CSQLiteMemory
import Foundation
import SQLite3

/// An isolated in-memory allocator regression, before AppKit and production
/// startup. It never opens user databases or creates application services.
enum SQLiteMemoryProbe {
    static func runIfRequested() -> Int32? {
        guard CommandLine.arguments.contains("--verify-sqlite-memory") else { return nil }
        guard tb_sqlite_memory_is_installed() == 1, sqlite3_initialize() == SQLITE_OK else {
            print("FAIL SQLite allocator was not installed before initialization")
            return 1
        }
        let baseline = tb_sqlite_memory_live_bytes()
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var failures = 0
            func fail() { lock.lock(); failures += 1; lock.unlock() }
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<3 {
                var database: OpaquePointer?
                guard sqlite3_open_v2(":memory:", &database,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                      let database else {
                    if let database { sqlite3_close_v2(database) }
                    results.fail(); continue
                }
                defer { sqlite3_close_v2(database) }
                var sql = "BEGIN;"
                for index in 0..<256 {
                    sql += "CREATE TABLE t\(index)(id INTEGER PRIMARY KEY,value BLOB);"
                    sql += "CREATE INDEX i\(index) ON t\(index)(value);"
                }
                sql += "INSERT INTO t0(value) VALUES(zeroblob(2097152));COMMIT;"
                guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                    results.fail(); continue
                }
                guard sqlite3_exec(database, "BEGIN;DELETE FROM t0;ROLLBACK;", nil, nil, nil) == SQLITE_OK else {
                    results.fail(); continue
                }
                var statement: OpaquePointer?
                let status = sqlite3_prepare_v2(database, "SELECT length(value) FROM t0", -1, &statement, nil)
                if status != SQLITE_OK || sqlite3_step(statement) != SQLITE_ROW
                    || sqlite3_column_int(statement, 0) != 2_097_152 { results.fail() }
                sqlite3_finalize(statement)
                _ = tb_sqlite_memory_reclaim()
            }
        }
        _ = tb_sqlite_memory_reclaim()
        let remaining = tb_sqlite_memory_live_bytes()
        guard results.failures == 0, remaining <= baseline + 131_072 else {
            print("FAIL SQLite memory: failures=\(results.failures), baseline=\(baseline), remaining=\(remaining)")
            return 1
        }
        print("PASS SQLite isolated memory: baseline=\(baseline), remaining=\(remaining)")
        return 0
    }
}

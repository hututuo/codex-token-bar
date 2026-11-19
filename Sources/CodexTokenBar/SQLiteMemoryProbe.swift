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
        // Keep an unrelated connection alive throughout. Its small allocations
        // must not pin the zones used by concurrent, short-lived large schemas.
        var sentinel: OpaquePointer?
        guard sqlite3_open(":memory:", &sentinel) == SQLITE_OK, let sentinel else { return 1 }
        defer { sqlite3_close_v2(sentinel) }
        guard sqlite3_exec(sentinel, "CREATE TABLE keep_alive(value)", nil, nil, nil) == SQLITE_OK else { return 1 }
        let baseline = tb_sqlite_memory_live_bytes()
        let baselineZones = tb_sqlite_memory_zone_count()
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var failures = 0
            func fail() { lock.lock(); failures += 1; lock.unlock() }
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<3 {
                let memoryScope = tb_sqlite_memory_begin_scope()
                defer { tb_sqlite_memory_end_scope(memoryScope) }
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
        guard results.failures == 0, remaining <= baseline + 131_072,
              tb_sqlite_memory_zone_count() == baselineZones else {
            print("FAIL SQLite memory: failures=\(results.failures), baseline=\(baseline), remaining=\(remaining)")
            return 1
        }
        // A retained pointer remains usable after its scope ends. Reallocation
        // and release on another thread must use its original allocator.
        let scope = tb_sqlite_memory_begin_scope()
        guard let pointer = sqlite3_malloc(1024) else { return 1 }
        memset(pointer, 42, 1024)
        tb_sqlite_memory_end_scope(scope)
        let address = UInt(bitPattern: pointer)
        let completion = DispatchGroup()
        completion.enter()
        DispatchQueue.global().async {
            defer { completion.leave() }
            let original = UnsafeMutableRawPointer(bitPattern: address)!
            if let resized = sqlite3_realloc(original, 4096) {
                if resized.load(as: UInt8.self) != 42 { results.fail() }
                sqlite3_free(resized)
            } else { sqlite3_free(original); results.fail() }
        }
        guard completion.wait(timeout: .now() + 10) == .success else { return 1 }
        guard results.failures == 0, tb_sqlite_memory_zone_count() == baselineZones else { return 1 }
        print("PASS SQLite isolated memory: baseline=\(baseline), remaining=\(remaining)")
        return 0
    }
}

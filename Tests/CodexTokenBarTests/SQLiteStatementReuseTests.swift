import Foundation
import SQLite3
import XCTest
@testable import CodexTokenBar

final class SQLiteStatementReuseTests: XCTestCase {
    private func connection(_ body: (SQLiteDatabaseConnection) throws -> Void) throws {
        let work = try SQLiteTemporaryDatabase()
        try body(work.connection)
    }

    private func statements(_ db: SQLiteDatabaseConnection) -> Int {
        var count = 0
        var cursor = sqlite3_next_stmt(db.rawDatabase, nil)
        while let current = cursor { count += 1; cursor = sqlite3_next_stmt(db.rawDatabase, current) }
        return count
    }

    func testReuseKeepsLiveValuesAndTypedBindingsWithoutRetainingCursors() throws {
        try connection { db in
            try db.execute("CREATE TABLE facts(id INTEGER PRIMARY KEY,amount INTEGER,payload BLOB)")
            try db.withReusedStatements {
                for n in 0..<20 {
                    try db.execute("INSERT INTO facts VALUES(?,?,?)", bindings: [.int(n), .int64(Int64.min + Int64(n)), .blob(Data([0, UInt8(n), 255]))])
                    XCTAssertEqual(try db.readRows("SELECT amount FROM facts WHERE id=?", bindings: [.int(n)]) { $0.int64(0) }, [Int64.min + Int64(n)])
                    XCTAssertEqual(try db.readRows("SELECT payload FROM facts WHERE id=?", bindings: [.int(n)]) { $0.data(0) }, [Data([0, UInt8(n), 255])])
                    XCTAssertEqual(statements(db), 3)
                }
                try db.execute("UPDATE facts SET amount=NULL WHERE id=?", bindings: [.int(0)])
                XCTAssertEqual(try db.readRows("SELECT amount FROM facts WHERE id=?", bindings: [.int(0)]) { $0.int64(0) }, [nil])
                XCTAssertEqual(try db.readRows("SELECT ?", bindings: [.int64(Int64.max)]) { $0.int64(0) }, [Int64.max])
                XCTAssertEqual(try db.readRows("SELECT ?") { $0.int64(0) }, [nil],
                    "An omitted parameter must not inherit the previous event's binding")
            }
            XCTAssertEqual(statements(db), 0)
        }
    }

    func testNestedSameSQLAndThrownMappingDoNotResetTheActiveOuterCursor() throws {
        struct ExpectedFailure: Error {}
        try connection { db in
            try db.execute("CREATE TABLE facts(id INTEGER PRIMARY KEY); INSERT INTO facts VALUES(1),(2),(3)")
            let sql = "SELECT id FROM facts ORDER BY id"
            try db.withReusedStatements {
                let outer = try db.readRows(sql) { row in
                    let inner = try db.withReusedStatements { try db.readRows(sql) { $0.int(0) } }
                    XCTAssertEqual(inner, [1, 2, 3])
                    return row.int(0)
                }
                XCTAssertEqual(outer, [1, 2, 3])
                XCTAssertEqual(statements(db), 1)
                XCTAssertThrowsError(try db.readRows(sql) { _ -> Int in throw ExpectedFailure() })
                XCTAssertEqual(try db.readRows(sql) { $0.int(0) }, [1, 2, 3])
            }
            XCTAssertEqual(statements(db), 0)
        }
    }

    func testSchemaChangeAndRollbackRetainSQLiteSemanticsAndFreeStatementsOnThrow() throws {
        struct ExpectedFailure: Error {}
        try connection { db in
            try db.execute("CREATE TABLE facts(id INTEGER PRIMARY KEY)")
            XCTAssertThrowsError(try db.withReusedStatements {
                try db.transaction { tx in
                    try tx.execute("INSERT INTO facts VALUES(?)", bindings: [.int(7)])
                    XCTAssertEqual(try tx.readRows("SELECT * FROM facts") { $0.int(0) }, [7])
                    try tx.execute("ALTER TABLE facts ADD COLUMN label TEXT DEFAULT 'new'")
                    XCTAssertEqual(try tx.readRows("SELECT * FROM facts") { $0.text(1) }, ["new"])
                    throw ExpectedFailure()
                }
            })
            XCTAssertEqual(statements(db), 0)
            XCTAssertEqual(try db.readRows("SELECT COUNT(*) FROM facts") { $0.int(0) }, [0])
            XCTAssertEqual(try db.readRows("PRAGMA table_info(facts)") { $0.text(1) }, ["id"])
        }
    }

    func testScopeHasFiniteStatementCapacityAndReleasesAllOnExit() throws {
        try connection { db in
            try db.withReusedStatements {
                for n in 0..<200 {
                    XCTAssertEqual(try db.readRows("SELECT \(n)") { $0.int(0) }, [n])
                    XCTAssertLessThanOrEqual(statements(db), 64)
                }
            }
            XCTAssertEqual(statements(db), 0)
        }
    }

    func testCompiledStatementCannotOutliveNamespaceAuthorization() throws {
        try connection { db in
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("statement-owner-not-opened")
            let store = BusinessSQLiteStore(containerURL: base.appendingPathComponent("codex-ledger.sqlite"),
                logicalURL: base.appendingPathComponent("index.sqlite"), module: "exact.swift", sourceIdentity: "fixture")
            try db.execute("CREATE TABLE \"\(store.prefix)facts\"(value INTEGER); INSERT INTO \"\(store.prefix)facts\" VALUES(17)")
            let binding = SQLiteStoreBinding(store: store, names: ["facts"])
            db.businessBinding = binding
            try db.withReusedStatements {
                XCTAssertEqual(try db.readRows("SELECT value FROM facts") { $0.int(0) }, [17])
                XCTAssertEqual(statements(db), 1)
                binding.namespace.objectNames.remove("facts")
                XCTAssertThrowsError(try db.readRows("SELECT value FROM facts") { $0.int(0) })
                XCTAssertThrowsError(try db.readRows("SELECT * FROM main.tb_stores") { $0.int(0) })
            }
            XCTAssertEqual(statements(db), 0)
        }
    }

    func testPrepareErrorsKeepTheReadRecoveryOperationContractInsideAndOutsideReuse() throws {
        try connection { db in
            func check() {
                XCTAssertThrowsError(try db.readRows("SELECT value FROM absent_table") { $0.int(0) }) { error in
                    XCTAssertEqual((error as? SQLiteDatabaseError)?.operation, "Prepare SQLite query")
                    XCTAssertEqual((error as? SQLiteDatabaseError)?.primaryCode, SQLITE_ERROR)
                }
                XCTAssertThrowsError(try db.execute("INSERT INTO absent_table VALUES(?)", bindings: [.int(1)])) { error in
                    XCTAssertEqual((error as? SQLiteDatabaseError)?.operation, "Prepare SQLite statement")
                    XCTAssertEqual((error as? SQLiteDatabaseError)?.primaryCode, SQLITE_ERROR)
                }
            }
            check()
            db.withReusedStatements(check)
            XCTAssertEqual(statements(db), 0)
        }
    }
}

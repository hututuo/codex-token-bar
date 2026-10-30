import Foundation
import XCTest
@testable import CodexTokenBar

final class SQLiteOperationConnectionTests: XCTestCase {
    private func database() throws -> (URL, SQLiteDatabaseDriver) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-operation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db.sqlite")
        return (url, SQLiteDatabaseDriver(url: url))
    }

    func testOperationReusesConnectionAndClosesItAtScopeEndIncludingThrows() throws {
        let (_, driver) = try database()
        enum Stop: Error { case now }
        try driver.withOperationConnection {
            try driver.execute("CREATE TEMP TABLE operation_probe(value INTEGER); INSERT INTO operation_probe VALUES(42)")
            try driver.withOperationConnection {
                XCTAssertEqual(try driver.readRows("SELECT value FROM operation_probe") { $0.int(0)! }, [42])
            }
        }
        XCTAssertThrowsError(try driver.readRows("SELECT value FROM operation_probe") { $0.int(0)! })
        XCTAssertThrowsError(try driver.withOperationConnection {
            try driver.execute("CREATE TEMP TABLE operation_throw(value INTEGER)")
            throw Stop.now
        })
        XCTAssertThrowsError(try driver.readRows("SELECT * FROM operation_throw") { $0.int(0) })
    }

    func testTransactionsStillCommitAndRollbackIndependentlyInsideOperation() throws {
        let (_, driver) = try database()
        enum Stop: Error { case now }
        try driver.withOperationConnection {
            try driver.execute("CREATE TABLE proof(value INTEGER)")
            XCTAssertThrowsError(try driver.transaction { connection in
                try connection.execute("INSERT INTO proof VALUES(1)")
                throw Stop.now
            })
            XCTAssertEqual(try driver.readRows("SELECT COUNT(*) FROM proof") { $0.int(0)! }, [0])
            try driver.transaction { try $0.execute("INSERT INTO proof VALUES(42)") }
            let independent = SQLiteDatabaseDriver(url: driver.url, readOnly: true, createsFileIfMissing: false)
            XCTAssertEqual(try independent.readRows("SELECT value FROM proof") { $0.int(0)! }, [42],
                "The operation scope must not delay commits until the connection closes")
        }
        XCTAssertEqual(try driver.readRows("SELECT value FROM proof") { $0.int(0)! }, [42])
    }

    func testOperationRejectsReplacedFileRatherThanReadingRetiredConnection() throws {
        let (url, driver) = try database()
        try driver.execute("CREATE TABLE proof(value INTEGER); INSERT INTO proof VALUES(1)")
        try driver.withOperationConnection {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("retired"))
            try SQLiteDatabaseDriver(url: url).execute("CREATE TABLE proof(value INTEGER); INSERT INTO proof VALUES(2)")
            XCTAssertThrowsError(try driver.readRows("SELECT value FROM proof") { $0.int(0) })
        }
        XCTAssertEqual(try driver.readRows("SELECT value FROM proof") { $0.int(0)! }, [2])
    }

    func testAnotherThreadNeverInheritsOperationConnection() throws {
        let (_, driver) = try database()
        let result = LockedConnectionProbe()
        let completed = DispatchSemaphore(value: 0)
        try driver.withOperationConnection {
            try driver.execute("CREATE TEMP TABLE operation_probe(value INTEGER)")
            Thread {
                do {
                    result.record(try driver.readRows("SELECT COUNT(*) FROM sqlite_temp_master WHERE name='operation_probe'") { $0.int(0)! }.first == 0)
                } catch { result.record(false) }
                completed.signal()
            }.start()
            XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
            XCTAssertTrue(result.value)
            XCTAssertEqual(try driver.readRows("SELECT COUNT(*) FROM sqlite_temp_master WHERE name='operation_probe'") { $0.int(0)! }, [1])
        }
    }
}

private final class LockedConnectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func record(_ value: Bool) { lock.lock(); defer { lock.unlock() }; stored = value }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

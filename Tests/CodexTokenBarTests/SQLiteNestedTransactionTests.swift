import SQLite3
import XCTest
@testable import CodexTokenBar

final class SQLiteNestedTransactionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testSuccessfulNestedTransactionRollsBackWithFailingOuterTransaction() throws {
        let database = SQLiteDatabaseDriver(url: try makeDatabaseURL())
        try createTable(in: database)

        XCTAssertThrowsError(try database.transaction { outer in
            try outer.execute("INSERT INTO entries(value) VALUES ('outer');")
            try outer.transaction { inner in
                try inner.execute("INSERT INTO entries(value) VALUES ('inner');")
            }
            throw ExpectedTransactionFailure()
        })

        XCTAssertEqual(try values(in: database), [])
    }

    func testCaughtNestedFailureRollsBackOnlyInnerSavepoint() throws {
        let database = SQLiteDatabaseDriver(url: try makeDatabaseURL())
        try createTable(in: database)

        try database.transaction { outer in
            try outer.execute("INSERT INTO entries(value) VALUES ('before');")
            do {
                try outer.transaction { inner in
                    try inner.execute("INSERT INTO entries(value) VALUES ('inner');")
                    throw ExpectedTransactionFailure()
                }
                XCTFail("the nested transaction should propagate its body error")
            } catch is ExpectedTransactionFailure {
                // The outer transaction remains usable after the savepoint rollback.
            }
            try outer.execute("INSERT INTO entries(value) VALUES ('after');")
        }

        XCTAssertEqual(try values(in: database), ["before", "after"])
    }

    func testNestedReadTransactionDoesNotCommitOuterTransaction() throws {
        let database = SQLiteDatabaseDriver(url: try makeDatabaseURL())
        try createTable(in: database)

        XCTAssertThrowsError(try database.transaction { outer in
            try outer.execute("INSERT INTO entries(value) VALUES ('uncommitted');")
            let visibleInsideRead = try outer.readTransaction { nestedReader in
                try nestedReader.readRows("SELECT value FROM entries ORDER BY rowid;") {
                    $0.text(0) ?? ""
                }
            }
            XCTAssertEqual(visibleInsideRead, ["uncommitted"])
            throw ExpectedTransactionFailure()
        })

        XCTAssertEqual(try values(in: database), [])
    }

    func testSeparateConnectionSeesOldValueUntilOuterCommit() throws {
        let url = try makeDatabaseURL()
        let writer = SQLiteDatabaseDriver(url: url, enableWAL: true)
        let reader = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
        try createTable(in: writer)
        try writer.execute("INSERT INTO entries(value) VALUES ('old');")

        try writer.transaction { outer in
            try outer.execute("UPDATE entries SET value = 'new';")
            XCTAssertEqual(try values(in: reader), ["old"])
        }

        XCTAssertEqual(try values(in: reader), ["new"])
    }

    private func createTable(in database: SQLiteDatabaseDriver) throws {
        try database.execute("CREATE TABLE entries (value TEXT NOT NULL);")
    }

    private func values(in database: SQLiteDatabaseDriver) throws -> [String] {
        try database.readRows("SELECT value FROM entries ORDER BY rowid;") {
            $0.text(0) ?? ""
        }
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteNestedTransactionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("test.sqlite")
    }
}

private struct ExpectedTransactionFailure: Error {}

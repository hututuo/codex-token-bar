import SQLite3
import XCTest
@testable import CodexTokenBar

final class SQLiteDatabaseDriverTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testReadRowsAndBindingsRoundTripValues() throws {
        let driver = SQLiteDatabaseDriver(url: try makeDatabaseURL(), enableWAL: true)
        try driver.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, title TEXT NOT NULL, score REAL NOT NULL);")
        try driver.execute(
            "INSERT INTO events (title, score) VALUES (?, ?), (?, ?);",
            bindings: [.text("alpha"), .double(1.5), .text("beta"), .double(2.25)]
        )

        let rows = try driver.readRows(
            "SELECT id, title, score FROM events WHERE score > ? ORDER BY id;",
            bindings: [.double(1.0)]
        ) { statement in
            (
                id: statement.int(0),
                title: statement.text(1),
                score: statement.double(2)
            )
        }

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, 1)
        XCTAssertEqual(rows[0].title, "alpha")
        XCTAssertEqual(rows[0].score ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(rows[1].id, 2)
        XCTAssertEqual(rows[1].title, "beta")
        XCTAssertEqual(rows[1].score ?? 0, 2.25, accuracy: 0.001)
    }

    func testExecuteChangedRowsReturnsChangedCount() throws {
        let driver = SQLiteDatabaseDriver(url: try makeDatabaseURL())
        try driver.execute("CREATE TABLE counters (id INTEGER PRIMARY KEY, value INTEGER NOT NULL);")
        try driver.execute("INSERT INTO counters (value) VALUES (1), (2), (3);")

        let changed = try driver.executeChangedRows(
            "UPDATE counters SET value = value + 10 WHERE value >= ?;",
            bindings: [.int(2)]
        )
        let values = try driver.readRows("SELECT value FROM counters ORDER BY id;") { $0.int(0) ?? 0 }

        XCTAssertEqual(changed, 2)
        XCTAssertEqual(values, [1, 12, 13])
    }

    func testForEachRowStreamsRowsAndPropagatesBodyErrors() throws {
        enum TestError: Error {
            case stop
        }

        let driver = SQLiteDatabaseDriver(url: try makeDatabaseURL())
        try driver.execute("CREATE TABLE values_table (value INTEGER NOT NULL);")
        try driver.execute(
            """
            WITH RECURSIVE sequence(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 1_000
            )
            INSERT INTO values_table (value)
            SELECT value FROM sequence;
            """
        )

        var count = 0
        var sum = 0
        try driver.forEachRow("SELECT value FROM values_table ORDER BY value;") { statement in
            count += 1
            sum += statement.int(0) ?? 0
        }

        XCTAssertEqual(count, 1_000)
        XCTAssertEqual(sum, 500_500)

        var visited: [Int] = []
        XCTAssertThrowsError(
            try driver.forEachRow("SELECT value FROM values_table ORDER BY value;") { statement in
                let value = statement.int(0) ?? 0
                visited.append(value)
                if value == 3 {
                    throw TestError.stop
                }
            }
        )
        XCTAssertEqual(visited, [1, 2, 3])
    }

    func testPreparedStatementCanBeReusedAfterFailedStepWithinTransaction() throws {
        let driver = SQLiteDatabaseDriver(url: try makeDatabaseURL())
        try driver.execute("CREATE TABLE items (name TEXT NOT NULL UNIQUE, value INTEGER NOT NULL);")

        try driver.transaction { connection in
            let insert = try connection.prepare("INSERT INTO items (name, value) VALUES (?, ?);")
            XCTAssertEqual(try insert.execute([.text("alpha"), .int(1)]), 1)
            XCTAssertThrowsError(try insert.execute([.text("alpha"), .int(2)]))
            XCTAssertEqual(try insert.execute([.text("beta"), .int(3)]), 1)
        }

        let rows = try driver.readRows("SELECT name, value FROM items ORDER BY name;") {
            ($0.text(0) ?? "", $0.int(1) ?? 0)
        }
        XCTAssertEqual(rows.map(\.0), ["alpha", "beta"])
        XCTAssertEqual(rows.map(\.1), [1, 3])
    }

    func testPreparedStatementWritesRollBackWithTransaction() throws {
        enum TestError: Error {
            case rollback
        }

        let driver = SQLiteDatabaseDriver(url: try makeDatabaseURL())
        try driver.execute("CREATE TABLE items (name TEXT NOT NULL);")

        XCTAssertThrowsError(
            try driver.transaction { connection in
                let insert = try connection.prepare("INSERT INTO items (name) VALUES (?);")
                XCTAssertEqual(try insert.execute([.text("one")]), 1)
                XCTAssertEqual(try insert.execute([.text("two")]), 1)
                throw TestError.rollback
            }
        )

        let count = try driver.readRows("SELECT count(*) FROM items;") { $0.int(0) ?? -1 }.first
        XCTAssertEqual(count, 0)

        try driver.transaction { connection in
            let insert = try connection.prepare("INSERT INTO items (name) VALUES (?);")
            XCTAssertEqual(try insert.execute([.text("committed")]), 1)
        }
        let names = try driver.readRows("SELECT name FROM items;") { $0.text(0) ?? "" }
        XCTAssertEqual(names, ["committed"])
    }

    func testTransactionRollsBackOnError() throws {
        enum TestError: Error {
            case rollback
        }

        let driver = SQLiteDatabaseDriver(url: try makeDatabaseURL())
        try driver.execute("CREATE TABLE items (name TEXT NOT NULL);")

        XCTAssertThrowsError(
            try driver.transaction { connection in
                try connection.execute("INSERT INTO items (name) VALUES (?);", bindings: [.text("temporary")])
                throw TestError.rollback
            }
        )

        let count = try driver.readRows("SELECT count(*) FROM items;") { $0.int(0) ?? -1 }.first
        XCTAssertEqual(count, 0)
    }

    func testPersistentReaderKeepsReadOnlyHandleReusable() throws {
        let url = try makeDatabaseURL()
        let writer = SQLiteDatabaseDriver(url: url)
        try writer.execute("CREATE TABLE logs (id INTEGER PRIMARY KEY, body TEXT NOT NULL);")
        try writer.execute("INSERT INTO logs (body) VALUES ('one');")

        let reader = SQLitePersistentDatabaseReader(url: url, busyTimeoutMilliseconds: 100)
        let firstRead = try reader.readRows("SELECT body FROM logs ORDER BY id;") { $0.text(0) ?? "" }
        XCTAssertEqual(firstRead, ["one"])

        try writer.execute("INSERT INTO logs (body) VALUES ('two');")
        let secondRead = try reader.readRows("SELECT body FROM logs ORDER BY id;") { $0.text(0) ?? "" }
        XCTAssertEqual(secondRead, ["one", "two"])
    }

    func testReadRecoveryReopensAfterTransientExtendedIOError() throws {
        var attempts = 0
        var observedDelays: [TimeInterval] = []

        let value: String = try SQLiteReadRecovery.run(
            retryDelays: [0.01, 0.02],
            sleep: { observedDelays.append($0) }
        ) {
            attempts += 1
            if attempts == 1 {
                throw SQLiteDatabaseError(
                    operation: "Step SQLite query",
                    code: SQLITE_IOERR | (1 << 8),
                    message: "disk I/O error",
                    path: "/tmp/state_5.sqlite"
                )
            }
            if attempts == 2 {
                throw SQLiteDatabaseError(
                    operation: "Step SQLite query",
                    code: SQLITE_BUSY,
                    message: "database is busy",
                    path: "/tmp/state_5.sqlite"
                )
            }
            return "recovered"
        }

        XCTAssertEqual(value, "recovered")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(observedDelays, [0.01, 0.02])
    }

    func testReadRecoveryDoesNotRetryPermanentSQLiteFailure() {
        var attempts = 0

        XCTAssertThrowsError(
            try SQLiteReadRecovery.run(
                retryDelays: [0.01, 0.02],
                sleep: { _ in XCTFail("永久错误不得进入等待重试") }
            ) { () -> String in
                attempts += 1
                throw SQLiteDatabaseError(
                    operation: "Step SQLite query",
                    code: SQLITE_CORRUPT,
                    message: "database disk image is malformed",
                    path: "/tmp/state_5.sqlite"
                )
            }
        ) { error in
            XCTAssertEqual((error as? SQLiteDatabaseError)?.code, SQLITE_CORRUPT)
        }
        XCTAssertEqual(attempts, 1)
    }

    func testReadRecoveryStopsAfterConfiguredRetryCount() {
        var attempts = 0

        XCTAssertThrowsError(
            try SQLiteReadRecovery.run(
                retryDelays: [0.01, 0.02],
                sleep: { _ in }
            ) { () -> String in
                attempts += 1
                throw SQLiteDatabaseError(
                    operation: "Step SQLite query",
                    code: SQLITE_IOERR,
                    message: "disk I/O error",
                    path: "/tmp/state_5.sqlite"
                )
            }
        ) { error in
            XCTAssertEqual((error as? SQLiteDatabaseError)?.primaryCode, SQLITE_IOERR)
        }
        XCTAssertEqual(attempts, 3)
    }

    func testNoCreateWriteConnectionRefusesToCreateAMissingDatabase() throws {
        let url = try makeDatabaseURL()
        let driver = SQLiteDatabaseDriver(url: url, createsFileIfMissing: false)

        XCTAssertThrowsError(
            try driver.executeChangedRows("UPDATE threads SET cwd = 'x';")
        ) { error in
            guard let databaseError = error as? SQLiteDatabaseError else {
                return XCTFail("应抛 SQLiteDatabaseError，实际：\(error)")
            }
            XCTAssertEqual(databaseError.code, SQLITE_CANTOPEN)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "no-create 打开不得留下空的 decoy 数据库"
        )
    }

    func testNoCreateWriteConnectionStillWritesToAnExistingDatabase() throws {
        let url = try makeDatabaseURL()
        let creator = SQLiteDatabaseDriver(url: url)
        try creator.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT);")
        try creator.execute("INSERT INTO threads (id, cwd) VALUES ('a', '/old');")

        let driver = SQLiteDatabaseDriver(url: url, createsFileIfMissing: false)
        let changed = try driver.executeChangedRows(
            "UPDATE threads SET cwd = ?1 WHERE id = 'a';",
            bindings: [.text("/new")]
        )

        XCTAssertEqual(changed, 1)
        let values = try driver.readRows("SELECT cwd FROM threads WHERE id = 'a';") { $0.text(0) ?? "" }
        XCTAssertEqual(values, ["/new"])
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTokenBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("test.sqlite")
    }
}

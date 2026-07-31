import SQLite3
import Darwin
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

    func testReadOnlyDriverAcceptsStablePinnedHardLink() throws {
        let url = try makeDatabaseURL()
        let writer = SQLiteDatabaseDriver(url: url)
        try writer.execute("CREATE TABLE items (value TEXT NOT NULL);")
        try writer.execute("INSERT INTO items (value) VALUES ('healthy');")
        let alias = url.deletingLastPathComponent().appendingPathComponent("state-backup.sqlite")
        XCTAssertEqual(Darwin.link(url.path, alias.path), 0)

        let reader = SQLiteDatabaseDriver(
            url: url,
            readOnly: true,
            createsFileIfMissing: false,
            consistency: .externallyOwnedWAL
        )
        let values = try reader.readRows("SELECT value FROM items;") { $0.text(0) ?? "" }
        XCTAssertEqual(values, ["healthy"])
        XCTAssertEqual(Darwin.unlink(alias.path), 0)
    }

    func testExternalWALConsistencyRejectsWriteConnectionBeforeBodyRuns() throws {
        let url = try makeDatabaseURL()
        let setup = SQLiteDatabaseDriver(url: url)
        try setup.execute("CREATE TABLE items (value TEXT NOT NULL);")
        try setup.execute("INSERT INTO items (value) VALUES ('unchanged');")

        let invalidWriter = SQLiteDatabaseDriver(
            url: url,
            readOnly: false,
            createsFileIfMissing: false,
            consistency: .externallyOwnedWAL
        )
        var bodyRan = false
        XCTAssertThrowsError(
            try invalidWriter.withConnection { connection in
                bodyRan = true
                try connection.execute("UPDATE items SET value = 'changed';")
            }
        ) { error in
            let databaseError = error as? SQLiteDatabaseError
            XCTAssertEqual(databaseError?.primaryCode, SQLITE_MISUSE)
            XCTAssertTrue(databaseError?.message.contains("read-only") == true)
        }
        XCTAssertFalse(bodyRan)
        XCTAssertEqual(
            try setup.readRows("SELECT value FROM items;") { $0.text(0) ?? "" },
            ["unchanged"]
        )
    }

    func testExternalWALReadDiscardsResultWhenMainFileIsReplacedInFlight() throws {
        let url = try makeDatabaseURL()
        let writer = SQLiteDatabaseDriver(url: url)
        try writer.execute("CREATE TABLE items (value TEXT NOT NULL);")
        try writer.execute("INSERT INTO items (value) VALUES ('old');")

        let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.sqlite")
        let replacementWriter = SQLiteDatabaseDriver(url: replacement)
        try replacementWriter.execute("CREATE TABLE items (value TEXT NOT NULL);")
        try replacementWriter.execute("INSERT INTO items (value) VALUES ('new');")

        let reader = SQLiteDatabaseDriver(
            url: url,
            readOnly: true,
            createsFileIfMissing: false,
            consistency: .externallyOwnedWAL
        )
        let pinned = url.deletingLastPathComponent().appendingPathComponent("pinned-state.sqlite")
        XCTAssertEqual(Darwin.link(url.path, pinned.path), 0)
        XCTAssertEqual(
            try reader.readRows("SELECT value FROM items;") { $0.text(0) ?? "" },
            ["old"],
            "a stable pinned alias must not block the sibling runtime"
        )
        XCTAssertThrowsError(
            try reader.withConnection { connection in
                let stale = try connection.readRows("SELECT value FROM items;") {
                    $0.text(0) ?? ""
                }
                XCTAssertEqual(stale, ["old"])
                try FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: replacement, to: url)
                return stale
            }
        ) { error in
            let databaseError = error as? SQLiteDatabaseError
            XCTAssertEqual(databaseError?.primaryCode, SQLITE_PROTOCOL)
            XCTAssertTrue(databaseError?.message.contains("identity changed") == true)
        }

        let current = try SQLiteReadRecovery.run {
            try reader.readRows("SELECT value FROM items;") { $0.text(0) ?? "" }
        }
        XCTAssertEqual(current, ["new"])
        XCTAssertEqual(Darwin.unlink(pinned.path), 0)
    }

    func testExternalWALReadDiscardsResultWhenPinnedWALIsReplacedInFlight() throws {
        let url = try makeDatabaseURL()
        let writer = SQLiteDatabaseDriver(url: url, enableWAL: true)
        try writer.execute("CREATE TABLE items (value TEXT NOT NULL);")
        try writer.execute("INSERT INTO items (value) VALUES ('before');")

        // Keep a reader open so the fixture retains a live WAL/SHM family.
        let keeper = SQLitePersistentDatabaseReader(url: url, busyTimeoutMilliseconds: 100)
        XCTAssertEqual(
            try keeper.readRows("SELECT value FROM items;") { $0.text(0) ?? "" },
            ["before"]
        )
        try writer.execute("INSERT INTO items (value) VALUES ('after');")

        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path))

        let pinnedDirectory = url.deletingLastPathComponent().appendingPathComponent("pinned-family")
        try FileManager.default.createDirectory(at: pinnedDirectory, withIntermediateDirectories: false)
        XCTAssertEqual(
            Darwin.link(url.path, pinnedDirectory.appendingPathComponent("state_5.sqlite").path),
            0
        )
        XCTAssertEqual(
            Darwin.link(walURL.path, pinnedDirectory.appendingPathComponent("state_5.sqlite-wal").path),
            0
        )
        XCTAssertEqual(
            Darwin.link(shmURL.path, pinnedDirectory.appendingPathComponent("state_5.sqlite-shm").path),
            0
        )

        let reader = SQLiteDatabaseDriver(
            url: url,
            readOnly: true,
            createsFileIfMissing: false,
            consistency: .externallyOwnedWAL
        )
        XCTAssertThrowsError(
            try reader.withConnection { connection in
                let rows = try connection.readRows("SELECT value FROM items ORDER BY rowid;") {
                    $0.text(0) ?? ""
                }
                XCTAssertEqual(rows, ["before", "after"])
                let retainedWAL = URL(fileURLWithPath: walURL.path + ".retained")
                try FileManager.default.moveItem(at: walURL, to: retainedWAL)
                try FileManager.default.copyItem(at: retainedWAL, to: walURL)
                return rows
            }
        ) { error in
            let databaseError = error as? SQLiteDatabaseError
            XCTAssertTrue(databaseError?.isTransientReadFailure == true)
            XCTAssertTrue(
                databaseError?.primaryCode == SQLITE_PROTOCOL
                    || databaseError?.primaryCode == SQLITE_IOERR,
                "the VFS may detect the sidecar replacement before the post-read identity check"
            )
        }
    }

    func testExternalWALCoordinatorAllowsOnlyOneOptedInConnectionAtATime() throws {
        let firstURL = try makeDatabaseURL()
        let secondURL = firstURL.deletingLastPathComponent().appendingPathComponent("second.sqlite")
        for url in [firstURL, secondURL] {
            let writer = SQLiteDatabaseDriver(url: url)
            try writer.execute("CREATE TABLE items (value TEXT NOT NULL);")
            try writer.execute("INSERT INTO items (value) VALUES ('value');")
        }
        let readers = [firstURL, secondURL].map {
            SQLiteDatabaseDriver(
                url: $0,
                readOnly: true,
                createsFileIfMissing: false,
                consistency: .externallyOwnedWAL
            )
        }
        let probe = ConcurrentSQLiteConnectionProbe()
        let group = DispatchGroup()

        for reader in readers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    _ = try reader.withConnection { connection in
                        probe.enter()
                        defer { probe.leave() }
                        Thread.sleep(forTimeInterval: 0.05)
                        return try connection.readRows("SELECT value FROM items;") {
                            $0.text(0) ?? ""
                        }
                    }
                } catch {
                    probe.record(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(probe.failures.isEmpty, "unexpected coordinated read failures: \(probe.failures)")
        XCTAssertEqual(probe.maximumActiveConnections, 1)
    }

    func testExternalWALCoordinatorRejectsNestedConnectionInsteadOfDeadlocking() throws {
        let url = try makeDatabaseURL()
        let writer = SQLiteDatabaseDriver(url: url)
        try writer.execute("CREATE TABLE items (value TEXT NOT NULL);")
        let reader = SQLiteDatabaseDriver(
            url: url,
            readOnly: true,
            createsFileIfMissing: false,
            consistency: .externallyOwnedWAL
        )

        XCTAssertThrowsError(
            try reader.withConnection { _ in
                try reader.readRows("SELECT value FROM items;") { $0.text(0) ?? "" }
            }
        ) { error in
            XCTAssertEqual((error as? SQLiteDatabaseError)?.primaryCode, SQLITE_MISUSE)
        }
    }

    func testPersistentReaderAcceptsStablePinnedWALFamily() throws {
        let url = try makeDatabaseURL()
        let writer = SQLiteDatabaseDriver(url: url, enableWAL: true)
        try writer.execute("CREATE TABLE items (value TEXT NOT NULL);")
        try writer.execute("INSERT INTO items (value) VALUES ('before');")
        let reader = SQLitePersistentDatabaseReader(url: url, busyTimeoutMilliseconds: 100)
        XCTAssertEqual(
            try reader.readRows("SELECT value FROM items;") { $0.text(0) ?? "" },
            ["before"]
        )
        // Keep the reader connection alive while an external writer appends so
        // the fixture really has the same main + WAL + SHM family as state_5.
        try writer.execute("INSERT INTO items (value) VALUES ('while-open');")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path))
        XCTAssertEqual(
            try reader.readRows("SELECT value FROM items ORDER BY rowid;") { $0.text(0) ?? "" },
            ["before", "while-open"],
            "normal WAL activity must remain readable"
        )
        XCTAssertGreaterThan(try openDescriptorCount(for: url), 0)
        XCTAssertGreaterThan(try openDescriptorCount(for: walURL), 0)
        XCTAssertGreaterThan(try openDescriptorCount(for: shmURL), 0)

        let pinnedDirectory = url.deletingLastPathComponent().appendingPathComponent("pinned")
        try FileManager.default.createDirectory(at: pinnedDirectory, withIntermediateDirectories: false)
        let pinnedMain = pinnedDirectory.appendingPathComponent("state_5.sqlite")
        let pinnedWAL = pinnedDirectory.appendingPathComponent("state_5.sqlite-wal")
        let pinnedSHM = pinnedDirectory.appendingPathComponent("state_5.sqlite-shm")
        XCTAssertEqual(Darwin.link(url.path, pinnedMain.path), 0)
        XCTAssertEqual(Darwin.link(walURL.path, pinnedWAL.path), 0)
        XCTAssertEqual(Darwin.link(shmURL.path, pinnedSHM.path), 0)
        XCTAssertEqual(
            try reader.readRows("SELECT value FROM items ORDER BY rowid;") { $0.text(0) ?? "" },
            ["before", "while-open"],
            "stable pinned main/WAL/SHM aliases are a supported sibling-runtime state"
        )
        XCTAssertGreaterThan(try openDescriptorCount(for: url), 0)
        XCTAssertGreaterThan(try openDescriptorCount(for: walURL), 0)
        XCTAssertGreaterThan(try openDescriptorCount(for: shmURL), 0)

        // Leave the stable aliases in place until both SQLite handles are
        // destroyed. Changing link topology underneath a retained Apple SQLite
        // handle is precisely the VFS condition that can poison that handle;
        // state_5 uses short connections instead of this persistent-reader path.
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

    func testReadRecoveryDoesNotClassifyCorruptDataOrPermissionAsTransient() {
        let corruptData = SQLiteDatabaseError(
            operation: "Read SQLite data",
            code: SQLITE_IOERR | (32 << 8),
            message: "database disk image is malformed",
            path: "/tmp/state_5.sqlite"
        )
        let corruptFileSystem = SQLiteDatabaseError(
            operation: "Read SQLite data",
            code: SQLITE_IOERR | (33 << 8),
            message: "file system corruption",
            path: "/tmp/state_5.sqlite"
        )
        let permissionDenied = SQLiteDatabaseError(
            operation: "Open SQLite database",
            code: SQLITE_CANTOPEN,
            message: "permission denied",
            path: "/tmp/state_5.sqlite",
            systemErrno: POSIXErrorCode.EACCES.rawValue
        )
        let replacementGap = SQLiteDatabaseError(
            operation: "Open SQLite database",
            code: SQLITE_CANTOPEN,
            message: "no such file",
            path: "/tmp/state_5.sqlite",
            systemErrno: POSIXErrorCode.ENOENT.rawValue
        )

        XCTAssertFalse(corruptData.isTransientReadFailure)
        XCTAssertFalse(corruptFileSystem.isTransientReadFailure)
        XCTAssertFalse(permissionDenied.isTransientReadFailure)
        XCTAssertTrue(replacementGap.isTransientReadFailure)
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

    private func openDescriptorCount(for url: URL) throws -> Int {
        var expected = stat()
        let status = url.path.withCString { Darwin.lstat($0, &expected) }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var count = 0
        for descriptor in 0..<getdtablesize() {
            var candidate = stat()
            guard Darwin.fstat(descriptor, &candidate) == 0 else { continue }
            if candidate.st_dev == expected.st_dev, candidate.st_ino == expected.st_ino {
                count += 1
            }
        }
        return count
    }

    private func openDescriptorCountIfPresent(for url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try openDescriptorCount(for: url)
    }
}

private final class ConcurrentSQLiteConnectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var recordedFailures: [Error] = []

    var maximumActiveConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    var failures: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailures
    }

    func enter() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        recordedFailures.append(error)
        lock.unlock()
    }
}

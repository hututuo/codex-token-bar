import XCTest
@testable import CodexTokenBar

final class LegacyClaudeSpeedMigrationTests: XCTestCase {
    private typealias SeedRow = (String, Double, String, String, Int64, Double, String?)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-claude-speed-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testImportPreservesPayloadSourceAndConsistentBackup() throws {
        let target = try makeTarget()
        let source = root.appendingPathComponent("claude-local-speed.sqlite")
        let payload = "{ \"session\": \"s-一\", \"model\": \"claude-opus\" }"
        try seedSource(source, rows: [("legacy-1", 1_800_000_000, payload, "claude-opus", 42, 2.5, "legacy-output-delta-v1")])
        let originalSource = try Data(contentsOf: source)
        let oldVersion = try target.readRows("PRAGMA user_version;") { $0.int(0) ?? -1 }.first ?? -1

        let receipt = try LegacyClaudeSpeedMigration.migrate(source: source, target: target.url)
        XCTAssertTrue(receipt.didImport)
        XCTAssertEqual(receipt.rowCount, 1)
        XCTAssertEqual(receipt.digest.count, 64)
        XCTAssertNotNil(receipt.committedAt)
        XCTAssertEqual(try Data(contentsOf: source), originalSource)

        let imported = try target.readRows(
            "SELECT source_identity,id,payload,model,tokens,duration,method FROM legacy_claude_speed;"
        ) { row in
            (row.text(0), row.text(1), row.text(2), row.text(3), row.int64(4), row.double(5), row.text(6))
        }.first!
        XCTAssertEqual(imported.0, receipt.sourceIdentity)
        XCTAssertEqual(imported.1, "legacy-1")
        XCTAssertEqual(imported.2, payload)
        XCTAssertEqual(imported.3, "claude-opus")
        XCTAssertEqual(imported.4, 42)
        XCTAssertEqual(imported.5, 2.5)
        XCTAssertEqual(imported.6, "legacy-output-delta-v1")
        XCTAssertEqual(try target.readRows("SELECT COUNT(*) FROM client_usage_events;") { $0.int(0) ?? 0 }.first, 1)
        XCTAssertEqual(try target.readRows("PRAGMA user_version;") { $0.int(0) ?? -1 }.first, oldVersion)
        XCTAssertEqual(try target.readRows("SELECT COUNT(*) FROM sqlite_master WHERE name='api_speed';") { $0.int(0) ?? 0 }.first, 0)

        let backupURL = try XCTUnwrap(receipt.backupURL)
        let backup = SQLiteDatabaseDriver(url: backupURL, readOnly: true, createsFileIfMissing: false)
        XCTAssertEqual(try backup.readRows("PRAGMA integrity_check;") { $0.text(0) }.first!, "ok")
        XCTAssertEqual(try backup.readRows("PRAGMA user_version;") { $0.int(0) ?? -1 }.first, oldVersion)
        XCTAssertEqual(try backup.readRows("SELECT COUNT(*) FROM client_usage_events;") { $0.int(0) ?? 0 }.first, 1)
        XCTAssertEqual(try backup.readRows("SELECT COUNT(*) FROM sqlite_master WHERE name='legacy_claude_speed';") { $0.int(0) ?? 0 }.first, 0)
    }

    func testRepeatImportIsIdempotentAndDoesNotCreateAnotherBackup() throws {
        let target = try makeTarget()
        let source = root.appendingPathComponent("claude-local-speed.sqlite")
        try seedSource(source, rows: [("same-id", 1_800_000_001, "{\"raw\":true}", "model", 7, 1, nil)], includeMethod: false)

        let first = try LegacyClaudeSpeedMigration.migrate(source: source, target: target.url)
        let second = try LegacyClaudeSpeedMigration.migrate(source: source, target: target.url)
        XCTAssertTrue(first.didImport)
        XCTAssertFalse(second.didImport)
        XCTAssertEqual(second.rowCount, first.rowCount)
        XCTAssertEqual(second.digest, first.digest)
        XCTAssertEqual(second.committedAt, first.committedAt)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try target.readRows("SELECT COUNT(*) FROM legacy_claude_speed;") { $0.int(0) ?? 0 }.first, 1)
        XCTAssertEqual(try backupFiles().count, 1)
    }

    func testInjectedReceiptFailureRollsBackRowsAndKeepsBackup() throws {
        let target = try makeTarget()
        let targetWriter = SQLiteDatabaseDriver(url: target.url, createsFileIfMissing: false)
        try targetWriter.execute("""
        CREATE TABLE legacy_claude_speed (
            source_identity TEXT NOT NULL,id TEXT NOT NULL,ended REAL NOT NULL,payload TEXT NOT NULL,
            model TEXT NOT NULL,tokens INTEGER NOT NULL,duration REAL NOT NULL,method TEXT,
            PRIMARY KEY(source_identity,id)
        ) WITHOUT ROWID;
        CREATE TABLE module_migrations (
            module TEXT NOT NULL,source_identity TEXT NOT NULL,row_count INTEGER NOT NULL,
            digest TEXT NOT NULL,committed_at REAL NOT NULL,PRIMARY KEY(module,source_identity)
        ) WITHOUT ROWID;
        CREATE TRIGGER reject_legacy_receipt BEFORE INSERT ON module_migrations
        WHEN NEW.module='legacy-claude-speed-v1'
        BEGIN SELECT RAISE(ABORT,'injected migration failure'); END;
        """)
        let source = root.appendingPathComponent("claude-local-speed.sqlite")
        try seedSource(source, rows: [("will-rollback", 1_800_000_003, "{}", "model", 9, 1, "old")])

        XCTAssertThrowsError(try LegacyClaudeSpeedMigration.migrate(source: source, target: target.url))
        XCTAssertEqual(try target.readRows("SELECT COUNT(*) FROM client_usage_events;") { $0.int(0) ?? 0 }.first, 1)
        XCTAssertEqual(try target.readRows("SELECT COUNT(*) FROM legacy_claude_speed;") { $0.int(0) ?? 0 }.first, 0)
        XCTAssertEqual(try target.readRows("SELECT COUNT(*) FROM module_migrations;") { $0.int(0) ?? 0 }.first, 0)

        let backupURL = try XCTUnwrap(backupFiles().first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        let backup = SQLiteDatabaseDriver(url: backupURL, readOnly: true, createsFileIfMissing: false)
        XCTAssertEqual(try backup.readRows("PRAGMA integrity_check;") { $0.text(0) }.first!, "ok")
        XCTAssertEqual(try backup.readRows("SELECT COUNT(*) FROM client_usage_events;") { $0.int(0) ?? 0 }.first, 1)
        XCTAssertEqual(try backup.readRows("SELECT COUNT(*) FROM legacy_claude_speed;") { $0.int(0) ?? 0 }.first, 0)
    }

    func testDifferentSourcesKeepSameOriginalIDDistinct() throws {
        let target = try makeTarget()
        let firstSource = root.appendingPathComponent("first.sqlite")
        let secondSource = root.appendingPathComponent("second.sqlite")
        let row: [SeedRow] = [("shared-id", 1_800_000_002, "{}", "model", 8, 2, "old")]
        try seedSource(firstSource, rows: row)
        try seedSource(secondSource, rows: row)

        let first = try LegacyClaudeSpeedMigration.migrate(source: firstSource, target: target.url)
        let second = try LegacyClaudeSpeedMigration.migrate(source: secondSource, target: target.url)
        XCTAssertNotEqual(first.sourceIdentity, second.sourceIdentity)
        XCTAssertEqual(try target.readRows("SELECT COUNT(*) FROM legacy_claude_speed WHERE id='shared-id';") { $0.int(0) ?? 0 }.first, 2)
        XCTAssertEqual(try target.readRows("SELECT COUNT(*) FROM module_migrations WHERE module='legacy-claude-speed-v1';") { $0.int(0) ?? 0 }.first, 2)
        XCTAssertEqual(try backupFiles().count, 2)
    }

    func testMalformedSourceDoesNotMutateTargetOrCreateBackup() throws {
        let target = try makeTarget()
        let source = root.appendingPathComponent("malformed.sqlite")
        try Data("not a sqlite database".utf8).write(to: source)
        let usageBefore = try target.readRows("SELECT COUNT(*) FROM client_usage_events;") { $0.int(0) ?? 0 }.first
        let versionBefore = try target.readRows("PRAGMA user_version;") { $0.int(0) ?? -1 }.first

        XCTAssertThrowsError(try LegacyClaudeSpeedMigration.migrate(source: source, target: target.url))
        XCTAssertEqual(try target.readRows("SELECT COUNT(*) FROM client_usage_events;") { $0.int(0) ?? 0 }.first, usageBefore)
        XCTAssertEqual(try target.readRows("PRAGMA user_version;") { $0.int(0) ?? -1 }.first, versionBefore)
        XCTAssertEqual(try target.readRows("SELECT COUNT(*) FROM sqlite_master WHERE name='legacy_claude_speed';") { $0.int(0) ?? 0 }.first, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    func testMissingOptionalSourceIsNoOp() throws {
        let target = root.appendingPathComponent("unused.sqlite")
        let receipt = try LegacyClaudeSpeedMigration.migrate(
            source: root.appendingPathComponent("missing.sqlite"), target: target
        )
        XCTAssertFalse(receipt.didImport)
        XCTAssertEqual(receipt.rowCount, 0)
        XCTAssertNil(receipt.committedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    private func makeTarget() throws -> SQLiteDatabaseDriver {
        let url = root.appendingPathComponent("multi-client-usage.sqlite")
        let ledger = try MultiClientUsageLedger(url: url)
        _ = try ledger.ingest([
            ClientUsageEvent(
                client: .claudeCode, eventID: "existing", sessionID: "session", model: "existing-model",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), inputTokens: 10, outputTokens: 2,
                cacheReadTokens: 0, cacheWriteTokens: 0
            )
        ])
        return SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
    }

    private func seedSource(
        _ url: URL,
        rows: [SeedRow],
        includeMethod: Bool = true
    ) throws {
        let db = SQLiteDatabaseDriver(url: url)
        let method = includeMethod ? ",method TEXT" : ""
        try db.execute("CREATE TABLE api_speed(id TEXT PRIMARY KEY,ended REAL NOT NULL,payload TEXT NOT NULL,model TEXT NOT NULL,tokens INTEGER NOT NULL,duration REAL NOT NULL\(method));")
        for row in rows {
            let columns = includeMethod ? "id,ended,payload,model,tokens,duration,method" : "id,ended,payload,model,tokens,duration"
            let values = includeMethod ? "?,?,?,?,?,?,?" : "?,?,?,?,?,?"
            var bindings: [SQLiteBinding] = [.text(row.0), .double(row.1), .text(row.2), .text(row.3), .int64(row.4), .double(row.5)]
            if includeMethod { bindings.append(.optionalText(row.6)) }
            try db.execute("INSERT INTO api_speed(\(columns)) VALUES(\(values));", bindings: bindings)
        }
    }

    private func backupFiles() throws -> [URL] {
        let directory = root.appendingPathComponent("backups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }
    }
}

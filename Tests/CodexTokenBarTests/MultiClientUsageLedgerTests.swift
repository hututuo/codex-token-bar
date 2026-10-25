import XCTest
@testable import CodexTokenBar

final class MultiClientUsageLedgerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-client-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func event(_ output: Int64 = 20, client: UsageClient = .claudeCode) -> ClientUsageEvent {
        ClientUsageEvent(client: client, eventID: "s:msg1", sessionID: "s", model: "test-model", timestamp: Date(timeIntervalSince1970: 1800000000), inputTokens: 100, outputTokens: output, cacheReadTokens: 60, cacheWriteTokens: 10, reasoningTokens: nil)
    }
    func testReplayUpdatesAndOtherClientAreIndependentWithoutCodexMutation() throws {
        let codex = root.appendingPathComponent("codex-token-index.sqlite")
        let sentinel = Data("existing Codex raw accounting".utf8); try sentinel.write(to: codex)
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("multi-client-usage.sqlite"))
        XCTAssertEqual(try ledger.ingest([event()]), 1)
        XCTAssertEqual(try ledger.ingest([event()]), 0)
        XCTAssertEqual(try ledger.ingest([event(40)]), 1)
        XCTAssertEqual(try ledger.ingest([event(10)]), 0, "copied/rotated earlier streaming records cannot reduce final counts")
        XCTAssertEqual(try ledger.ingest([event(5, client: .deepseek)]), 1)
        let summaries = try ledger.summaries()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.first { $0.client == .claudeCode }?.outputTokens, 40)
        XCTAssertEqual(summaries.first { $0.client == .claudeCode }?.requests, 1)
        XCTAssertNil(summaries.first?.reasoningTokens)
        XCTAssertEqual(try Data(contentsOf: codex), sentinel)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, 3)
    }
    func testCheckpointAndEventsRollbackTogether() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let checkpoint = MultiClientFileCheckpoint(offset: 100, size: 100, modified: 10, identity: "inode")
        _ = try ledger.ingest([event()], client: .claudeCode, sourceKey: "file", checkpoint: checkpoint)
        var invalid = event(30); invalid.inputTokens = -1
        XCTAssertThrowsError(try ledger.ingest([invalid], client: .claudeCode, sourceKey: "file", checkpoint: .init(offset: 200, size: 200, modified: 11, identity: "inode")))
        XCTAssertEqual(try ledger.checkpoint(client: .claudeCode, sourceKey: "file")?.offset, 100)
        XCTAssertEqual(try ledger.summaries().first?.outputTokens, 20)
    }
    func testBackupIncludesCommittedWALAndFutureSchemaIsNotDowngraded() throws {
        let url = root.appendingPathComponent("usage.sqlite")
        let ledger = try MultiClientUsageLedger(url: url)
        _ = try ledger.ingest([event()])
        let backup = try ledger.backup()
        let copy = SQLiteDatabaseDriver(url: backup, readOnly: true)
        XCTAssertEqual(try copy.readRows("SELECT SUM(output_tokens) FROM client_usage_events") { $0.int64(0) }.first!, 20)
        try ledger.database.execute("PRAGMA user_version=99")
        XCTAssertThrowsError(try MultiClientUsageLedger(url: url))
        XCTAssertEqual(try ledger.database.readRows("PRAGMA user_version") { $0.int(0) }.first!, 99)
    }
    func testDeletionKeepsLedgerAndPartialTailIsNotSkipped() async throws {
        let path = root.appendingPathComponent("session.jsonl")
        let line = "{\"type\":\"assistant\",\"sessionId\":\"s\",\"timestamp\":\"2026-10-25T03:00:00Z\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}}"
        try Data(line.dropLast(4).utf8).write(to: path)
        var preference = MultiClientUsagePreference.defaults[0]; preference.enabled = true; preference.path = path.path
        let scanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("usage.sqlite"), home: root, environment: [:])
        let partial = try await scanner.scan([preference]); XCTAssertTrue(partial.summaries.isEmpty)
        try Data((line + "\n").utf8).write(to: path)
        let complete = try await scanner.scan([preference]); XCTAssertEqual(complete.summaries.first?.outputTokens, 20)
        try FileManager.default.removeItem(at: path)
        let deleted = try await scanner.scan([preference]); XCTAssertEqual(deleted.summaries.first?.outputTokens, 20)
    }
    func testPrefixRewriteInGrowingFileIsRescannedAndAppendDoesNotDoubleCount() async throws {
        let path = root.appendingPathComponent("session.jsonl")
        func line(_ id: String, _ output: Int) -> String {
            "{\"type\":\"assistant\",\"sessionId\":\"s\",\"timestamp\":\"2026-10-25T03:00:00Z\",\"message\":{\"id\":\"\(id)\",\"role\":\"assistant\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":100,\"output_tokens\":\(output)}}}\n"
        }
        var preference = MultiClientUsagePreference.defaults[0]; preference.enabled = true; preference.path = path.path
        let scanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("usage.sqlite"), home: root, environment: [:])
        try Data(line("m1", 20).utf8).write(to: path)
        _ = try await scanner.scan([preference])
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(line("m2", 30).utf8)); try handle.close()
        let appended = try await scanner.scan([preference])
        XCTAssertEqual(appended.summaries.first?.outputTokens, 50)
        let rewrite = try FileHandle(forWritingTo: path)
        try rewrite.write(contentsOf: Data((line("m1", 40) + line("m2", 30) + line("m3", 50)).utf8)); try rewrite.close()
        let rewritten = try await scanner.scan([preference])
        XCTAssertEqual(rewritten.summaries.first?.outputTokens, 120)
        XCTAssertEqual(rewritten.summaries.first?.requests, 3)
    }
    @MainActor func testPreferencesArePersistentAndDefaultsDoNotChangeCodexDisplay() {
        let name = "multi-client-prefs-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: root.appendingPathComponent("usage.sqlite"))
        XCTAssertFalse(store.preferences.contains { $0.enabled || $0.showMenuBar || $0.showSidebar })
        var value = store.preferences[0]; value.color = "#123456"; value.showSidebar = true
        store.update(value)
        let next = MultiClientUsageStore(defaults: defaults, databaseURL: root.appendingPathComponent("usage.sqlite"))
        XCTAssertEqual(next.preferences[0].color, "#123456"); XCTAssertTrue(next.preferences[0].showSidebar)
        XCTAssertNil(defaults.object(forKey: "quotaSidebarEnabled"))
    }
}

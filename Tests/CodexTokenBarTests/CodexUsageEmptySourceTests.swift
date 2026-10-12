import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexUsageEmptySourceTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptySourceHistory-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true
        )
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cache.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cache.path, 1)
        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPersistentExactSnapshotStateForTesting()
    }

    override func tearDownWithError() throws {
        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPersistentExactSnapshotStateForTesting()
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testOneValidOneEmptyAndZeroSourcesKeepIdenticalHistory() throws {
        let file = try seedUsage()
        let empty = home.appendingPathComponent("sessions/empty.jsonl")
        try Data().write(to: empty)
        let analyzer = makeAnalyzer()
        let original = try analyzer.load()
        XCTAssertEqual(original.stats.totalTokens, 120)
        XCTAssertEqual(original.stats.totalCalls, 1)

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try analyzer.usageJSONLFiles(), [empty])
        try assertHistory(analyzer, equals: original)

        try FileManager.default.removeItem(at: empty)
        XCTAssertTrue(try analyzer.usageJSONLFiles().isEmpty)
        resetSnapshotMemory()
        // Fast is deliberately first, before another reader can repair a cache.
        let fast = try analyzer.loadFastSnapshotResult()
        XCTAssertEqual(fast.snapshot.stats.totalTokens, 120)
        XCTAssertEqual(fast.snapshot.stats.totalCalls, 1)
        XCTAssertEqual(fast.snapshot.usagePrecision, .precise)
        try assertHistory(analyzer, equals: original)

        let database = SQLiteDatabaseDriver(url: try databaseURL())
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM events", in: database), 1)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", in: database), 120)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM usage_ledger_sources WHERE missing=0", in: database), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM usage_ledger_bindings WHERE available=1", in: database), 0)
    }

    func testZeroSourcesRebuildsEachSurfaceAfterDerivedSnapshotsAreCleared() throws {
        let file = try seedUsage()
        let analyzer = makeAnalyzer()
        let original = try analyzer.load()
        let database = try databaseURL()
        let parseCount = CodexUsageAnalyzer.fullSessionParseCountForTesting
        try FileManager.default.removeItem(at: file)

        try clearDerivedSnapshots()
        XCTAssertNil(analyzer.loadLastGoodSnapshotResult())
        let fast = try analyzer.loadFastSnapshotResult()
        XCTAssertEqual(fast.snapshot.stats.totalTokens, original.stats.totalTokens)
        XCTAssertEqual(fast.snapshot.usagePrecision, .precise)

        try clearDerivedSnapshots()
        let compact = try XCTUnwrap(analyzer.loadCompactSummary())
        XCTAssertEqual(compact.totalTokens, original.stats.totalTokens)
        XCTAssertNotNil(compact.exactSynchronizationReceipt)
        XCTAssertEqual(compact.exactSynchronizationReceipt?.sourcePaths, [])

        try clearDerivedSnapshots()
        let full = try analyzer.load()
        XCTAssertEqual(full.stats.totalTokens, original.stats.totalTokens)
        XCTAssertEqual(full.stats.totalCalls, original.stats.totalCalls)
        XCTAssertEqual(full.stats.totalThreads, original.stats.totalThreads)
        XCTAssertEqual(full.cacheUsage.total, original.cacheUsage.total)
        XCTAssertEqual(full.cacheUsage.attributionProvenanceEpoch, original.cacheUsage.attributionProvenanceEpoch)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, parseCount)
        XCTAssertEqual(try databaseURL(), database)
    }

    func testZeroSourcesWithoutLedgerDoesNotCreateAnEmptyDatabase() throws {
        let analyzer = makeAnalyzer()
        XCTAssertNil(try analyzer.loadCompactSummary())
        XCTAssertThrowsError(try analyzer.load())
        XCTAssertThrowsError(try analyzer.loadFastSnapshotResult())
        XCTAssertNil(try CodexUsageHistoryIndex.openExisting(codexHome: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerDirectory.path))
    }

    func testZeroSourcesWithMetadataOnlyStillDoesNotCreateLedger() throws {
        let state = SQLiteDatabaseDriver(url: home.appendingPathComponent("state_5.sqlite"))
        try state.execute("""
            CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, first_user_message TEXT,
                preview TEXT, reasoning_effort TEXT, updated_at_ms INTEGER, updated_at INTEGER);
            """)
        let analyzer = makeAnalyzer()
        XCTAssertNil(try analyzer.loadCompactSummary())
        XCTAssertEqual(try analyzer.load().usagePrecision, .metadataOnly)
        let fast = try analyzer.loadFastSnapshotResult()
        XCTAssertEqual(fast.snapshot.usagePrecision, .metadataOnly)
        XCTAssertEqual(fast.freshness, .unavailable)
        XCTAssertNil(try CodexUsageHistoryIndex.openExisting(codexHome: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerDirectory.path))
    }

    func testExistingEmptyLedgerIsNotReportedAsPreciseHistory() throws {
        _ = try CodexUsageHistoryIndex(codexHome: home)
        let analyzer = makeAnalyzer()
        XCTAssertNil(try analyzer.loadCompactSummary())
        XCTAssertThrowsError(try analyzer.load())
        XCTAssertThrowsError(try analyzer.loadFastSnapshotResult())
    }

    func testUnavailableHomeThrowsAndPreservesUnverifiedLastGood() throws {
        _ = try seedUsage()
        let analyzer = makeAnalyzer()
        _ = try analyzer.load()
        let database = SQLiteDatabaseDriver(url: try databaseURL())
        let moved = root.appendingPathComponent("disconnected-home")
        try FileManager.default.moveItem(at: home, to: moved)
        resetSnapshotMemory()

        let lastGood = try XCTUnwrap(analyzer.loadLastGoodSnapshotResult())
        XCTAssertEqual(lastGood.snapshot.stats.totalTokens, 120)
        XCTAssertEqual(lastGood.freshness, .lastGoodUnverified)
        assertDiscoveryFailures(analyzer)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", in: database), 120)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM usage_ledger_sources WHERE missing=1", in: database), 0)
    }

    func testUnreadableHomeIsNotAnEmptyScanAndPreservesLedger() throws {
        _ = try seedUsage()
        let analyzer = makeAnalyzer()
        _ = try analyzer.load()
        let database = SQLiteDatabaseDriver(url: try databaseURL())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: home.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: home.path)) != nil {
            throw XCTSkip("This account can bypass directory permissions.")
        }
        resetSnapshotMemory()
        XCTAssertEqual(analyzer.loadLastGoodSnapshotResult()?.snapshot.stats.totalTokens, 120)
        assertDiscoveryFailures(analyzer)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", in: database), 120)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM usage_ledger_sources WHERE missing=1", in: database), 0)
    }

    func testCorruptLedgerWithZeroSourcesIsNotReplacedOrHidden() throws {
        let file = try seedUsage()
        let analyzer = makeAnalyzer()
        _ = try analyzer.load()
        let database = try databaseURL()
        try FileManager.default.removeItem(at: file)
        try clearDerivedSnapshots()
        let corrupt = Data("synthetic corrupt ledger sentinel".utf8)
        try corrupt.write(to: database)
        XCTAssertThrowsError(try analyzer.loadCompactSummary())
        XCTAssertThrowsError(try analyzer.load())
        XCTAssertThrowsError(try analyzer.loadFastSnapshotResult())
        XCTAssertEqual(try Data(contentsOf: database), corrupt)
    }

    func testUnreadableSessionRootIsNotPublishedAsMissingHistory() throws {
        _ = try seedUsage()
        let analyzer = makeAnalyzer()
        _ = try analyzer.load()
        let database = SQLiteDatabaseDriver(url: try databaseURL())
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sessions.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessions.path)
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) != nil {
            throw XCTSkip("This account can bypass directory permissions.")
        }
        assertDiscoveryFailures(analyzer)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", in: database), 120)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM usage_ledger_sources WHERE missing=1", in: database), 0)
    }

    func testUnreadableStateDatabaseDoesNotPublishAnEmptyScan() throws {
        _ = try seedUsage()
        let stateURL = home.appendingPathComponent("state_5.sqlite")
        let state = SQLiteDatabaseDriver(url: stateURL)
        try state.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT);")
        let analyzer = makeAnalyzer()
        _ = try analyzer.load()
        let database = SQLiteDatabaseDriver(url: try databaseURL())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: stateURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        }
        if (try? Data(contentsOf: stateURL)) != nil {
            throw XCTSkip("This account can bypass file permissions.")
        }
        assertDiscoveryFailures(analyzer)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", in: database), 120)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM usage_ledger_sources WHERE missing=1", in: database), 0)
    }

    func testOrphanedMigrationReceiptIsNotIgnoredOrReplacedWithEmptyLedger() throws {
        _ = try CodexUsageHistoryIndex(codexHome: home)
        let database = try databaseURL()
        try FileManager.default.removeItem(at: database)
        let receipt = URL(fileURLWithPath: database.path + ".schema11-migration.json")
        let invalidReceipt = Data("synthetic invalid migration receipt".utf8)
        try invalidReceipt.write(to: receipt)
        let analyzer = makeAnalyzer()
        XCTAssertThrowsError(try CodexUsageHistoryIndex.openExisting(codexHome: home))
        XCTAssertThrowsError(try analyzer.loadCompactSummary())
        XCTAssertThrowsError(try analyzer.load())
        XCTAssertThrowsError(try analyzer.loadFastSnapshotResult())
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertEqual(try Data(contentsOf: receipt), invalidReceipt)
    }

    private func assertHistory(_ analyzer: CodexUsageAnalyzer, equals original: DashboardSnapshot) throws {
        let full = try analyzer.load()
        let compact = try XCTUnwrap(analyzer.loadCompactSummary())
        let fast = try analyzer.loadFastSnapshotResult()
        XCTAssertEqual(full.stats.totalTokens, original.stats.totalTokens)
        XCTAssertEqual(full.stats.totalCalls, original.stats.totalCalls)
        XCTAssertEqual(full.stats.totalThreads, original.stats.totalThreads)
        XCTAssertEqual(full.cacheUsage.total, original.cacheUsage.total)
        XCTAssertEqual(compact.totalTokens, original.stats.totalTokens)
        XCTAssertEqual(fast.snapshot.stats.totalTokens, original.stats.totalTokens)
        XCTAssertEqual(full.usagePrecision, .precise)
        XCTAssertFalse(full.cacheUsage.attributionSourceMutationDetected)
    }

    private func assertDiscoveryFailures(_ analyzer: CodexUsageAnalyzer) {
        let operations: [() throws -> Void] = [
            { _ = try analyzer.load() },
            { _ = try analyzer.loadFastSnapshotResult() },
            { _ = try analyzer.loadCompactSummary() },
        ]
        for operation in operations {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertTrue(error is CodexUsageDiscoveryError, "\(error)")
            }
        }
    }

    private func makeAnalyzer() -> CodexUsageAnalyzer {
        CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: home, origin: .userSelected))
    }

    private func seedUsage() throws -> URL {
        let file = home.appendingPathComponent("sessions/rollout-empty-source-regression.jsonl")
        let usage: [String: Int] = [
            "input_tokens": 100, "cached_input_tokens": 10, "output_tokens": 20,
            "reasoning_output_tokens": 0, "total_tokens": 120,
        ]
        let event: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600)),
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": ["total_token_usage": usage, "last_token_usage": usage],
            ],
        ]
        var bytes = try JSONSerialization.data(withJSONObject: event)
        bytes.append(0x0a)
        try bytes.write(to: file)
        return file
    }

    private var ledgerDirectory: URL {
        cache.appendingPathComponent("CodexTokenBarSwift/exact-usage-history-v1")
    }

    private func databaseURL() throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: ledgerDirectory, includingPropertiesForKeys: nil)
        return try XCTUnwrap(files.first {
            $0.pathExtension == "sqlite" && $0.deletingPathExtension().lastPathComponent.count == 64
        })
    }

    private func scalar(_ sql: String, in database: SQLiteDatabaseDriver) throws -> Int {
        try XCTUnwrap(database.readRows(sql) { $0.int(0) }.first ?? nil)
    }

    private func resetSnapshotMemory() {
        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPersistentExactSnapshotStateForTesting()
    }

    private func clearDerivedSnapshots() throws {
        resetSnapshotMemory()
        let snapshots = ledgerDirectory.appendingPathComponent("persistent-exact-snapshots-v1")
        if FileManager.default.fileExists(atPath: snapshots.path) {
            try FileManager.default.removeItem(at: snapshots)
        }
    }
}

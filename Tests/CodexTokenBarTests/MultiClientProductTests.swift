import XCTest
@testable import CodexTokenBar

final class MultiClientProductTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("multi-product-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testDiscoveryOnlyUsesInstalledOrLocalEvidence() throws {
        let home = try temporary()
        XCTAssertTrue(UsageClientDetection.detect(home: home, environment: [:], applications: home).isEmpty)
        let data = home.appendingPathComponent(".dsh/sessions")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let app = home.appendingPathComponent("Claude.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(Set(UsageClientDetection.detect(home: home, environment: [:], applications: home).map(\.client)), [.deepseek, .claudeDesktop])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("multi-client-usage.sqlite").path))
    }
    func testDetectionHonorsConfiguredPathsWithoutExecutingAnything() throws {
        let home = try temporary(), binary = home.appendingPathComponent("gemini"), records = home.appendingPathComponent("custom/projects")
        try Data("never execute this fixture".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let detected = UsageClientDetection.detect(home: home, environment: ["PATH":home.path, "CLAUDE_CONFIG_DIR":records.deletingLastPathComponent().path], applications: home)
        XCTAssertEqual(Set(detected.map(\.client)), [.claudeCode, .gemini])
    }
    func testQuotaProvidersNeverFetchAndDoNotInventMissingPercentages() {
        let codex = CodexObservedQuotaProvider(snapshot: .init(fiveHour: .init(label: "5h", usedPercent: 25, resetsAt: nil)))
        XCTAssertFalse(codex.allowsNetwork); XCTAssertEqual(codex.reading().windows.first?.usedPercent, 25)
        let missing = ClaudeCapturedQuotaProvider(snapshot: .missing)
        XCTAssertFalse(missing.allowsNetwork); XCTAssertEqual(missing.reading().state, "notConnected")
        XCTAssertTrue(missing.reading().windows.isEmpty)
        XCTAssertTrue(missing.reading().notice.contains("claude-monitor --statusline"))
        let stale = ClaudeCapturedQuotaProvider(snapshot: .init(state: "stale", capturedAt: nil, fiveHour: nil, sevenDay: nil))
        XCTAssertEqual(stale.reading().state, "unavailable")
        for client in UsageClient.allCases where client != .claudeCode {
            let provider = UnavailableClientQuotaProvider(client: client)
            XCTAssertFalse(provider.allowsNetwork); XCTAssertTrue(provider.reading().windows.isEmpty)
        }
    }
    func testV1UpgradeBacksUpRecordsAndAddsTimeIndex() throws {
        let root = try temporary(), url = root.appendingPathComponent("usage.sqlite")
        let prior = try MultiClientUsageLedger(url: url)
        let event = ClientUsageEvent(client: .gemini, eventID: "e", sessionID: "s", model: "g", timestamp: Date(), inputTokens: 100, outputTokens: 30, cacheReadTokens: nil, cacheWriteTokens: nil, reasoningTokens: 10)
        _ = try prior.ingest([event])
        try prior.database.execute("DROP INDEX client_usage_by_time")
        try prior.database.execute("PRAGMA user_version=1")
        let current = try MultiClientUsageLedger(url: url)
        XCTAssertEqual(try current.summaries().first?.outputTokens, 30)
        XCTAssertEqual(try current.database.readRows("PRAGMA user_version") { $0.int(0) }.first!, 2)
        let copies = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        let old = SQLiteDatabaseDriver(url: copies[0], readOnly: true)
        XCTAssertEqual(try old.readRows("PRAGMA user_version") { $0.int(0) }.first!, 1)
        XCTAssertEqual(try old.readRows("SELECT input_tokens FROM client_usage_events") { $0.int64(0) }.first!, 100)
    }
    func testTrendKeepsUnknownSubsetsAndExcludesOldOrFutureEvents() throws {
        let root = try temporary(), ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let now = Date(timeIntervalSince1970: 1800000000)
        let dates = [now.addingTimeInterval(-120),now.addingTimeInterval(-60),now.addingTimeInterval(-31*86400),now.addingTimeInterval(10)]
        let events = dates.enumerated().map { i, time in ClientUsageEvent(client: .claudeCode, eventID: String(i), sessionID: "s", model: "c", timestamp: time, inputTokens: 100, outputTokens: 20, cacheReadTokens: 80, cacheWriteTokens: nil, reasoningTokens: 5) }
        _ = try ledger.ingest(events)
        let rows = try ledger.trendBuckets(now: now)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.tokens }, 240)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.requests }, 2)
        XCTAssertTrue(rows.allSatisfy { $0.cacheWriteTokens == nil })
        XCTAssertEqual(try ledger.summaries().first?.requests, 4, "trend window never prunes raw history")
    }
    func testCombinedChartConservesTotalsAcross24h7dAnd30d() {
        let now = Date(timeIntervalSince1970: 1800000000)
        let codex = [BinUsage(start: now.addingTimeInterval(-3600), tokens: 110, calls: 1)]
        let other = [ClientTrendBucket(client: .gemini, startUnix: Int64(now.timeIntervalSince1970 - 3600), inputTokens: 100, outputTokens: 20, cacheReadTokens: 80, cacheWriteTokens: 0, reasoningTokens: 5, requests: 1)]
        for days in [1,7,30] {
            let points = ClientUsageChartProjection.points(codex: codex, others: other, days: days, now: now, allowed: ["codex", "gemini"])
            XCTAssertEqual(points.reduce(0) { $0 + $1.tokens }, 230)
            XCTAssertEqual(points.count, (days * 86400 / (days == 1 ? 300 : days == 7 ? 3600 : 21600) + 1) * 2)
            XCTAssertEqual(ClientUsageChartProjection.points(codex: codex, others: other, days: days, now: now, allowed: ["codex"]).reduce(0) { $0 + $1.tokens }, 110)
        }
    }
    @MainActor func testOldPreferencesAndDiscoveryDismissalRemainPersistent() throws {
        let old = Data(##"{"client":"claudeCode","enabled":true,"showSidebar":true,"showMenuBar":false,"color":"#123456","order":0,"style":"compact","path":""}"##.utf8)
        let preference = try JSONDecoder().decode(MultiClientUsagePreference.self, from: old)
        XCTAssertTrue(preference.enabled); XCTAssertFalse(preference.showQuota)
        let name = "multi-product-defaults-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let url = try temporary().appendingPathComponent("usage.sqlite")
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: url)
        store.acknowledge(.claudeCode)
        let restored = MultiClientUsageStore(defaults: defaults, databaseURL: url)
        XCTAssertTrue(restored.acknowledgedClients.contains("claudeCode"))
        XCTAssertFalse(restored.preferences.contains { $0.enabled || $0.showQuota })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

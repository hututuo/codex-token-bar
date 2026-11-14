import XCTest
@testable import CodexTokenBar

final class ClientQuotaHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ client: String = "claudeDesktop", at: Date, used: Double = 9.1135,
                         reset: Date? = nil, id: String = "5h", state: String = "available") -> ClientQuotaReading {
        .init(client: client, state: state, source: "fixture", windows: [.init(label: id, usedPercent: used, resetsAt: reset, id: id)], notice: "", capturedAt: at)
    }

    func testAdditiveHistoryKeepsOldLedgerVersionAndReopensWithoutChangingUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("multi-client-usage.sqlite")
        let ledger = try MultiClientUsageLedger(url: url)
        let before = try ledger.database.readRows("SELECT count(*) FROM client_usage_events") { $0.int(0) }
        let sample = reading(at: now)
        try ledger.recordQuotaHistory([sample], now: now)
        try ledger.recordQuotaHistory([sample], now: now.addingTimeInterval(3600))
        let reopened = try MultiClientUsageLedger(url: url)
        XCTAssertEqual(try reopened.database.readRows("PRAGMA user_version") { $0.int(0) }.first!, 2)
        XCTAssertEqual(try reopened.database.readRows("SELECT count(*) FROM client_usage_events") { $0.int(0) }, before)
        let history = try XCTUnwrap(reopened.quotaHistory(readings: [sample], now: now).first)
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples[0].observedAt, now)
        XCTAssertEqual(history.samples[0].usedPercent, 9.1135, accuracy: 0.000001)
    }

    func testClientsPoolsAndPercentChangesStayIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("multi-client-usage.sqlite"))
        let rows = [reading(at: now), reading("claudeCode", at: now, used: 25),
            reading("antigravity", at: now, used: 99.7554, id: "gemini-weekly"),
            reading("antigravity", at: now, used: 0, id: "3p-5h")]
        try ledger.recordQuotaHistory(rows, now: now)
        try ledger.recordQuotaHistory([reading(at: now.addingTimeInterval(1), used: 10.25)], now: now.addingTimeInterval(1))
        let histories = try ledger.quotaHistory(readings: [rows[0], rows[1], rows[2]], now: now.addingTimeInterval(1))
        XCTAssertEqual(histories.count, 4)
        XCTAssertEqual(histories.first { $0.client == "claudeDesktop" }?.samples.count, 2)
        XCTAssertEqual(histories.first { $0.pool == "gemini" }?.samples.first?.usedPercent, 99.7554)
        XCTAssertEqual(histories.first { $0.pool == "3p" }?.samples.first?.usedPercent, 0)
    }

    func testInvalidApiAndModelRowsCannotEnterHistoryAndIdleCacheIsNotRetimed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("multi-client-usage.sqlite"))
        try ledger.recordQuotaHistory([
            reading(at: now, state: "api"), reading(at: now, used: .nan), reading(at: now, used: 101),
            reading(at: now.addingTimeInterval(61)), reading("antigravity", at: now, id: "gemini-pro-model"),
            reading(at: now, reset: now.addingTimeInterval(-1)),
            reading(at: now.addingTimeInterval(-3600))
        ], now: now)
        let samples = try ledger.quotaHistory(readings: [reading(at: now)], now: now).flatMap(\.samples)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.observedAt, now.addingTimeInterval(-3600))
    }

    func testProjectionKeepsDecimalsAndGapsAtResetAndAfterLongSleep() throws {
        let sample = ClientQuotaHistorySample(windowID: "5h", observedAt: now, usedPercent: 99.7554,
            resetsAt: now.addingTimeInterval(300))
        let history = ClientQuotaHistory(client: "antigravity", source: "fixture", pool: "gemini", samples: [sample])
        let buckets = history.buckets(interval: 300, now: now.addingTimeInterval(1800))
        let observed = try XCTUnwrap(buckets.first { !$0.fiveHourObservations.isEmpty })
        XCTAssertEqual(try XCTUnwrap(observed.fiveHourRemainingPercent), 0.2446, accuracy: 0.000001)
        XCTAssertEqual(observed.fiveHourObservations.first?.observedAt, now)
        XCTAssertNil(buckets.last?.fiveHourRemainingPercent)
        XCTAssertTrue(buckets.filter { $0.start >= now.addingTimeInterval(300) }.allSatisfy { $0.fiveHourRemainingPercent == nil })
        XCTAssertNil(ClientQuotaChartSource.resolve("codex", clients: ["deepseek"]))
        XCTAssertEqual(ClientQuotaChartSource.resolve("codex", clients: ["antigravity"])?.pool, "gemini")
    }

    func testExistingDesktopHistoryImportsOnlyLatestOrganizationAtOriginalTimes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = try JSONSerialization.data(withJSONObject: ["version": 2, "samples": [
            ["t": (now.timeIntervalSince1970 - 600) * 1000, "org": "current", "u": ["fh": 12.5]],
            ["t": now.timeIntervalSince1970 * 1000, "org": "other", "u": ["fh": 90]],
            ["t": now.timeIntervalSince1970 * 1000, "org": "current", "u": ["fh": 25.25]]
        ]])
        try raw.write(to: file)
        let readings = ClaudeLocalQuota.desktopHistoryReadings(home: home, now: now)
        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings.first?.capturedAt, now.addingTimeInterval(-600))
        XCTAssertEqual(readings.last?.windows.first?.usedPercent, 25.25)
        XCTAssertEqual(try Data(contentsOf: file), raw)
    }
}

import XCTest
@testable import CodexTokenBar

final class ModelDayCostTests: XCTestCase {
    func testLocalDayBoundariesFollowTimezoneAndDST() throws {
        for (zone, date, expectedHours) in [("Asia/Shanghai", "2026-11-05T08:00:00Z", 24.0),
            ("America/Los_Angeles", "2026-03-08T12:00:00Z", 23.0),
            ("America/Los_Angeles", "2026-11-01T12:00:00Z", 25.0)] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let day = ModelCostDay(try XCTUnwrap(ISO8601DateFormatter().date(from: date)), calendar: calendar)
            XCTAssertEqual(day.end.timeIntervalSince(day.start), expectedHours * 3600)
            XCTAssertEqual(calendar.component(.hour, from: day.start), 0)
            XCTAssertEqual(calendar.component(.hour, from: day.end), 0)
        }
    }

    func testSingleDayQueryKeepsExactBoundsSelectedClientsUnknownCostsAndOldPricePeriods() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-day-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ledger.sqlite"), writer = try MultiClientUsageLedger(url: path)
        let start = ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z")!, end = start.addingTimeInterval(86400)
        func event(_ id: String, _ at: Date, client: UsageClient = .antigravity, model: String = "gemini-4-argon", cache: Int64? = 40) -> ClientUsageEvent {
            .init(client: client, eventID: id, sessionID: "s", model: model, timestamp: at, inputTokens: 140, outputTokens: 20, cacheReadTokens: cache, cacheWriteTokens: 0)
        }
        _ = try writer.ingest([event("before", start.addingTimeInterval(-0.001)), event("start", start),
            event("last", end.addingTimeInterval(-0.001)), event("end", end), event("unknown", start, cache: nil),
            event("claude", start, client: .claudeCode), event("future-price", ISO8601DateFormatter().date(from:"2026-12-02T00:00:00Z")!)])
        let reader = try MultiClientUsageLedger(url: path, readOnly: true)
        let revision = try writer.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first
        let rows = try reader.summaries(since: start, before: end)
        let gravity = try XCTUnwrap(rows.first { $0.client == .antigravity })
        XCTAssertEqual(gravity.requests, 3); XCTAssertEqual(gravity.inputTokens, 420)
        XCTAssertEqual(gravity.unpricedRequests, 1)
        XCTAssertGreaterThan(gravity.apiCostUSD ?? 0, 0)
        let narrower = try reader.summaries(since: start, before: start.addingTimeInterval(1))
        XCTAssertEqual(narrower.first { $0.client == .antigravity }?.requests, 2, "Cache key includes the end bound")
        let items = ClientModelCostPeriods.modelItems(rows, [], allowed: ["antigravity"])
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?.tokens, 480)
        XCTAssertEqual(items.first?.knownPartialCostUSD, gravity.apiCostUSD)
        XCTAssertNil(items.first?.costUSD)
        let later = try reader.summaries(since: end.addingTimeInterval(86400), before: Date.distantFuture)
        XCTAssertNotEqual(later.first?.apiCostUSD, gravity.apiCostUSD.map { $0 / 2 }, "Event-time price period is retained")
        XCTAssertEqual(try writer.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first, revision)
        let missing = root.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(try MultiClientUsageLedger(url: missing, readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testMissingCodexKeepsAvailableExternalDayAmountVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-partial-day-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ledger.sqlite"), ledger = try MultiClientUsageLedger(url: path), now = Date()
        _ = try ledger.ingest([.init(client: .antigravity, eventID: "one", sessionID: "s", model: "gemini-4-argon", timestamp: now, inputTokens: 140, outputTokens: 20, cacheReadTokens: 40, cacheWriteTokens: 0)])
        let result = DayModelCostResult.read(day: ModelCostDay(now), home: nil, clients: ["codex", "antigravity"], database: path)
        XCTAssertEqual(result.availableClients, ["antigravity"])
        XCTAssertEqual(result.clientRows.first?.requests, 1)
        XCTAssertEqual(result.issues, ["Codex 数据源待读取"])
    }
}

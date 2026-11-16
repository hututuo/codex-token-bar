import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class HeatmapDayUsageTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Row: Decodable {
            let client: String; let model: String?; let input: Int64; let output: Int64
            let cached: Int64?; let costMicroUSD: Int64?; let unpriced: Int
        }
        struct Expected: Decodable {
            let tokens: Int; let calls: Int; let knownCostUSD: Double; let unpriced: Int
            let cacheComplete: Bool; let modelComplete: Bool
        }
        let now: Double; let rows: [Row]; let expected: Expected
    }
    private func fixture() throws -> (Fixture, [ClientTrendBucket]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/multi-client-heatmap.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        return (fixture, try fixture.rows.map { row in
            ClientTrendBucket(client: try XCTUnwrap(UsageClient(rawValue: row.client)), startUnix: Int64(fixture.now),
                inputTokens: row.input, outputTokens: row.output, cacheReadTokens: row.cached,
                cacheWriteTokens: 0, reasoningTokens: nil, requests: 1, apiCostMicroUSD: row.costMicroUSD,
                unpricedRequests: row.unpriced, model: row.model, cacheReadComplete: row.cached != nil, cacheWriteComplete: true)
        })
    }
    func testSharedDailyFixturePreservesKnownMoneyAndClientIdentity() throws {
        let (f, rows) = try fixture()
        let days = HeatmapDayUsage.project(codex: .empty, external: rows,
            allowed: Set(rows.map { $0.client.rawValue }), priceModel: .gpt56Sol)
        let value = try XCTUnwrap(days.first?.usage)
        XCTAssertEqual(value.breakdown.totalTokens, f.expected.tokens)
        XCTAssertEqual(value.breakdown.calls, f.expected.calls)
        XCTAssertEqual(value.knownCostUSD, f.expected.knownCostUSD)
        XCTAssertEqual(value.unpricedRequests, f.expected.unpriced)
        XCTAssertEqual(value.cacheReadComplete, f.expected.cacheComplete)
        XCTAssertEqual(value.modelComplete, f.expected.modelComplete)
        XCTAssertEqual(value.models.count, 3, "Same model remains separate across clients")
        for client in UsageClient.allCases {
            let own = HeatmapDayUsage.project(codex: .empty, external: rows, allowed: [client.rawValue], priceModel: .gpt56Sol)
            XCTAssertEqual(own.reduce(0) { $0 + $1.usage.breakdown.totalTokens },
                rows.filter { $0.client == client }.reduce(0) { $0 + Int($1.tokens) })
        }
        let usage = [DayUsage(date: days[0].date, tokens: value.breakdown.totalTokens, calls: value.breakdown.calls)]
        let heatmap = TokenHeatmap.prepare(dailyUsage: usage, cacheDaily: [], quotaDaily: [],
            mode: .modelCost, recordedDaily: days)
        XCTAssertEqual(heatmap.summaries.first?.modelCostUSD, 1.5)
        XCTAssertEqual(heatmap.summaries.first?.hasUnknownPrices, true)
    }
    func testQuotaPeriodChangesValueWithoutBorrowingMissingWindow() throws {
        let date = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let usage = [DayUsage(date: date, tokens: 0, calls: 0)]
        let quota = [QuotaHistoryDailyBucket(date: date, fiveHourRemainingPercent: 83.125,
            sevenDayRemainingPercent: nil, sampleCount: 2, fiveHourSampleCount: 2, sevenDaySampleCount: 0)]
        let five = TokenHeatmap.prepare(dailyUsage: usage, cacheDaily: [], quotaDaily: quota,
            mode: .quotaRemaining, quotaPeriod: .fiveHour)
        let seven = TokenHeatmap.prepare(dailyUsage: usage, cacheDaily: [], quotaDaily: quota,
            mode: .quotaRemaining, quotaPeriod: .sevenDay)
        XCTAssertEqual(five.summaries.first?.quotaRemainingPercent, 83.125)
        XCTAssertNil(seven.summaries.first?.quotaRemainingPercent)
    }
    func testCodexReferencesAndUnknownPricesNeverInflateKnownCost() throws {
        let date = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let part = TokenCacheBreakdown(inputTokens: 1000, cachedInputTokens: 0, outputTokens: 200,
            reasoningOutputTokens: 0, totalTokens: 1200, calls: 1)
        func project(_ names: [String]) throws -> ChartUsageSummary {
            let rows = names.map { ModelTokenBreakdown(model: $0, breakdown: part) }
            let total = rows.map(\.breakdown).combined
            let cache = TokenCacheUsage(total: total, dailyModelBreakdowns: [.init(start: date, modelBreakdowns: rows)],
                daily: [.init(start: date, breakdown: total)], hourly: [], recentBins: [], sessions: [], turns: [])
            let snapshot = DashboardSnapshot(stats: DashboardSnapshot.empty.stats,
                dailyUsage: [.init(date: date, tokens: total.totalTokens, calls: total.calls)],
                recentBins: [], hourlyUsage: [], pluginUsage: [], cacheUsage: cache, generatedAt: date)
            let result = try XCTUnwrap(HeatmapDayUsage.project(codex: snapshot, external: [], allowed: ["codex"], priceModel: .gpt56Sol).first?.usage)
            let expected = FloatingTodayModelUsagePresentation.knownCostUSD(in:
                FloatingTodayModelUsagePresentation.items(from: rows, fallbackModel: .gpt56Sol))
            XCTAssertEqual(result.hasKnownCost, expected != nil)
            XCTAssertEqual(result.knownCostUSD, expected ?? 0)
            return result
        }
        let references = try project(["gpt-5.3-codex-spark", "codex-auto-review"])
        XCTAssertEqual(references.knownCostUSD, 0)
        XCTAssertTrue(references.heatmapModelText(cost: true).contains("不计入合计"))
        let unknown = try project(["future-unpriced-model", "gpt-5.3-codex-spark"])
        XCTAssertFalse(unknown.hasKnownCost)
        XCTAssertGreaterThan(unknown.unpricedRequests, 0)
        let mixed = try project(["gpt-5.6-sol", "future-unpriced-model", "gpt-5.3-codex-spark"])
        XCTAssertTrue(mixed.heatmapCostText.contains("已知金额"))
    }
    @MainActor
    func testNativeMultiClientHeatmapPreview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CODEX_CYCLE_LAYOUT_OUTPUT"] else { return }
        let (_, rows) = try fixture()
        let days = HeatmapDayUsage.project(codex: .empty, external: rows,
            allowed: ["claudeDesktop", "antigravity"], priceModel: .gpt56Sol)
        let end = days[0].date
        let axis = (-364...0).map { offset in
            DayUsage(date: Calendar.current.date(byAdding: .day, value: offset, to: end)!,
                tokens: offset == 0 ? 1450 : 0, calls: offset == 0 ? 3 : 0)
        }
        for mode in [ActivityMode.modelCost, .modelShare, .cacheHitRate, .quotaRemaining] {
            let quota = [QuotaHistoryDailyBucket(date: end, fiveHourRemainingPercent: 83.125,
                sevenDayRemainingPercent: 12.5, sampleCount: 4, fiveHourSampleCount: 2, sevenDaySampleCount: 2)]
            let view = ActivitySection(dailyUsage: axis, cacheDaily: [], quotaDaily: quota,
                selectedMode: .constant(mode), recordedDaily: days).frame(width: 980)
                .environment(\.colorScheme, .dark).background(AppTheme.pageBackground)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("multiclient-heatmap-\(mode.rawValue).png"))
            window.orderOut(nil)
        }
    }
}

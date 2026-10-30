import Foundation
import XCTest
@testable import CodexTokenBar

final class RecentChartLastBucketPricingTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Row: Decodable {
            let startUnix: TimeInterval
            let model: String
            let breakdown: TokenCacheBreakdown
        }
        let settledThroughUnix: TimeInterval
        let rows: [Row]
    }

    private func input() throws -> RecentChartPreparationInput {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("Tests/Fixtures/last-bucket-chart-cost.json")))
        let end = Date(timeIntervalSince1970: fixture.settledThroughUnix)
        let closed = fixture.rows.filter { $0.startUnix < fixture.settledThroughUnix }
        let byStart = Dictionary(grouping: closed, by: \.startUnix)
        let starts = stride(from: fixture.rows.map(\.startUnix).min()!,
            through: fixture.settledThroughUnix, by: 300)
        let cache = starts.map { time in
            TokenCacheBucket(start: Date(timeIntervalSince1970: time),
                breakdown: (byStart[time] ?? []).map(\.breakdown).combined)
        }
        let hourly = Dictionary(grouping: closed, by: { floor($0.startUnix / 3600) * 3600 })
            .map { time, rows in
                TokenCacheBucket(start: Date(timeIntervalSince1970: time),
                    breakdown: rows.map(\.breakdown).combined)
            }.sorted { $0.start < $1.start }
        return .init(
            bins: cache.map { .init(start: $0.start, tokens: $0.breakdown.totalTokens, calls: $0.breakdown.calls) },
            hourlyBins: hourly.map { .init(start: $0.start, tokens: $0.breakdown.totalTokens, calls: $0.breakdown.calls) },
            cacheRecentBins: cache.filter { $0.start < end }, cacheHourlyBins: hourly,
            attributionEvents: fixture.rows.map {
                .sourceBucket(provenanceEpoch: "last-bucket-regression", sourceID: "local-aggregate",
                    start: Date(timeIntervalSince1970: $0.startUnix), model: $0.model, breakdown: $0.breakdown)
            }, quotaRecentBins: [], quotaHourlyBins: [], settledThrough: end)
    }

    func testAddingEmptyLastBucketKeepsRealUsageAndPriceUnchangedForCodexAndAggregate() throws {
        let original = try input()
        XCTAssertTrue(original.attributionEvents.contains { $0.start == original.settledThrough })
        for aggregate in [false, true] {
            var input = original
            if aggregate {
                input.quotaCostSource = .init(bins: original.bins, hourlyBins: original.hourlyBins,
                    cacheRecentBins: original.cacheRecentBins, cacheHourlyBins: original.cacheHourlyBins,
                    attributionEvents: original.attributionEvents, settledThrough: original.settledThrough)
                input = .init(bins: original.bins.map { .init(start: $0.start, tokens: $0.tokens + 1_000, calls: $0.calls + 1) },
                    hourlyBins: original.hourlyBins, cacheRecentBins: original.cacheRecentBins,
                    cacheHourlyBins: original.cacheHourlyBins, attributionEvents: original.attributionEvents,
                    quotaRecentBins: [], quotaHourlyBins: [], quotaCostSource: input.quotaCostSource)
            }
            let snapshot = RecentChartPreparedSnapshot.build(range: .twentyFourHours, input: input, priceModel: .gpt56Sol)
            let last = snapshot.data.bins.count - 1
            var state = RecentChartConsumptionSelectionState()
            state.click(index: 0, validCount: last + 1)
            let before = try XCTUnwrap(snapshot.consumptionSelection(state: state, hoveredIndex: last - 1, priceCard: .officialAPI(.gpt56Sol)))
            let preview = try XCTUnwrap(snapshot.consumptionSelection(state: state, hoveredIndex: last, priceCard: .officialAPI(.gpt56Sol)))
            state.click(index: last, validCount: last + 1)
            let pinned = try XCTUnwrap(snapshot.consumptionSelection(state: state, priceCard: .officialAPI(.gpt56Sol)))
            XCTAssertEqual(before.breakdown, preview.breakdown)
            XCTAssertEqual(preview, pinned)
            XCTAssertEqual(preview.breakdown.calls, 842)
            XCTAssertEqual(preview.breakdown.totalTokens, 170_322_445)
            XCTAssertEqual(before.fullCurrentAPIPriceEstimate.costUSD, 23.51656288, accuracy: 0.0000001)
            XCTAssertEqual(preview.fullCurrentAPIPriceEstimate.costUSD, before.fullCurrentAPIPriceEstimate.costUSD, accuracy: 0.0000001)
            XCTAssertEqual(preview.fullCurrentAPIPriceEstimate.costUSD, snapshot.bucketCostsUSD.reduce(0, +), accuracy: 0.0000001)
            XCTAssertFalse(snapshot.costAttributionEvents.contains { $0.start >= original.settledThrough! })
            let refreshed = RecentChartPreparedSnapshot.build(range: .twentyFourHours, input: input, priceModel: .gpt56Sol)
            XCTAssertEqual(refreshed.consumptionSelection(state: state, priceCard: .officialAPI(.gpt56Sol)), pinned)
        }
    }

    func testAllRangesUseClosedModelAttributionWithoutChangingRawInput() throws {
        let input = try input()
        let rawEvents = input.attributionEvents
        for range in RecentChartRange.allCases {
            let snapshot = RecentChartPreparedSnapshot.build(range: range, input: input, priceModel: .gpt56Sol)
            var state = RecentChartConsumptionSelectionState()
            state.click(index: 0, validCount: snapshot.data.bins.count)
            state.click(index: snapshot.data.bins.count - 1, validCount: snapshot.data.bins.count)
            let selected = try XCTUnwrap(snapshot.consumptionSelection(state: state, priceCard: .officialAPI(.gpt56Sol)))
            XCTAssertEqual(selected.fullCurrentAPIPriceEstimate.costUSD, 23.51656288, accuracy: 0.0000001, range.rawValue)
            XCTAssertEqual(selected.breakdown.calls, 842, range.rawValue)
            for index in snapshot.data.bins.indices {
                XCTAssertEqual(snapshot.data.modelBreakdowns[index].map(\.breakdown).combined,
                    snapshot.data.cacheBreakdowns[index], "\(range.rawValue), bucket \(index)")
            }
        }
        XCTAssertEqual(input.attributionEvents, rawEvents, "Live/today attribution must retain the open bucket")
    }

    func testClosingBucketAdvancesCountsAndPriceTogetherAndLeavesOldSnapshotStable() throws {
        var input = try input()
        let previous = RecentChartPreparedSnapshot.build(range: .twentyFourHours, input: input, priceModel: .gpt56Sol)
        let end = try XCTUnwrap(input.settledThrough)
        let tail = input.attributionEvents.filter { $0.start == end }.map(\.breakdown).combined
        let closed = TokenCacheBucket(start: end, breakdown: tail)
        input = .init(bins: Array(input.bins.dropLast()) + [.init(start: end, tokens: tail.totalTokens, calls: tail.calls)],
            hourlyBins: [], cacheRecentBins: input.cacheRecentBins + [closed], cacheHourlyBins: [],
            attributionEvents: input.attributionEvents, quotaRecentBins: [], quotaHourlyBins: [],
            settledThrough: end.addingTimeInterval(300))
        let next = RecentChartPreparedSnapshot.build(range: .twentyFourHours, input: input, priceModel: .gpt56Sol)
        func selection(_ snapshot: RecentChartPreparedSnapshot) throws -> QuotaConsumptionSelection {
            var state = RecentChartConsumptionSelectionState()
            state.click(index: 0, validCount: snapshot.data.bins.count)
            state.click(index: snapshot.data.bins.count - 1, validCount: snapshot.data.bins.count)
            return try XCTUnwrap(snapshot.consumptionSelection(state: state, priceCard: .officialAPI(.gpt56Sol)))
        }
        let old = try selection(previous), new = try selection(next)
        XCTAssertEqual(old.fullCurrentAPIPriceEstimate.costUSD, 23.51656288, accuracy: 0.0000001)
        XCTAssertEqual(new.fullCurrentAPIPriceEstimate.costUSD, 23.59885808, accuracy: 0.0000001)
        XCTAssertEqual(new.breakdown.calls, old.breakdown.calls + tail.calls)
        XCTAssertEqual(try selection(previous), old, "Pending/new raw inputs must not reprice the displayed snapshot")
    }
}

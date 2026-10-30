import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class RecentChartPreparationStoreTests: XCTestCase {
    func testAggregateProviderBasisCannotPriceOtherClientUsageAsCodex() {
        func pricedInput(_ tokens: Int) -> RecentChartPreparationInput {
            let base = makeInput(tokens: tokens)
            let buckets = base.bins.map { TokenCacheBucket(start: $0.start, breakdown: .init(
                inputTokens: tokens, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0,
                totalTokens: tokens, calls: 1)) }
            return .init(bins: base.bins, hourlyBins: base.hourlyBins,
                cacheRecentBins: buckets, cacheHourlyBins: buckets, attributionEvents: [],
                quotaRecentBins: [], quotaHourlyBins: [])
        }
        var input = pricedInput(100_000)
        let source = pricedInput(100)
        input.quotaCostSource = .init(bins: source.bins, hourlyBins: source.hourlyBins,
            cacheRecentBins: source.cacheRecentBins, cacheHourlyBins: source.cacheHourlyBins,
            attributionEvents: source.attributionEvents)
        let combined = RecentChartPreparedSnapshot.build(range: .twentyFourHours, input: input, priceModel: .gpt56Sol)
        let original = RecentChartPreparedSnapshot.build(range: .twentyFourHours, input: source, priceModel: .gpt56Sol)
        XCTAssertEqual(combined.data.tokenTotal,200_000)
        XCTAssertEqual(combined.quotaData?.tokenTotal,200)
        XCTAssertGreaterThan(original.bucketCostsUSD.reduce(0,+),0)
        XCTAssertEqual(combined.bucketCostsUSD,original.bucketCostsUSD)
    }
    func testRealClickFixturePrewarmsAllRangesWithoutLosingUsageOrQuotaObservations() async throws {
        let input = makeRecentChartInteractionPreparationInput()
        XCTAssertEqual(input.bins.count, 12)
        XCTAssertEqual(input.hourlyBins.map(\.start), [28_800, 32_400].map {
            Date(timeIntervalSince1970: Double($0))
        })
        XCTAssertEqual(input.hourlyBins.map(\.tokens), [36_000, 42_000])
        XCTAssertEqual(input.hourlyBins.map(\.calls), [36, 42])
        XCTAssertEqual(input.cacheHourlyBins.map { $0.breakdown.totalTokens }, [224_000, 112_000])
        XCTAssertEqual(input.quotaHourlyBins.map(\.fiveHourRemainingPercent), [79, 67])
        XCTAssertEqual(input.quotaHourlyBins.map(\.sevenDayRemainingPercent), [
            input.quotaRecentBins[7].sevenDayRemainingPercent,
            input.quotaRecentBins[11].sevenDayRemainingPercent
        ])
        let fiveHourObservations = input.quotaRecentBins.flatMap(\.fiveHourObservations)
        let sevenDayObservations = input.quotaRecentBins.flatMap(\.sevenDayObservations)
        XCTAssertEqual(input.quotaHourlyBins.flatMap(\.fiveHourObservations), fiveHourObservations)
        XCTAssertEqual(input.quotaHourlyBins.flatMap(\.sevenDayObservations), sevenDayObservations)

        let store = RecentChartPreparationStore()
        defer { store.cancel() }
        store.prepare(input: input, priceModel: .gpt56Sol, preferredRange: .twentyFourHours)
        // The UI only waits for the active plot. Explicitly await 7d and 30d,
        // so background prewarming cannot escape this regression's assertions.
        try await waitForSnapshots(store)
        XCTAssertEqual(store.revision, 3)
        for range in RecentChartRange.allCases {
            let snapshot = try XCTUnwrap(store.snapshot(for: range), range.rawValue)
            XCTAssertEqual(snapshot.data.tokenTotal, 78_000, range.rawValue)
            XCTAssertEqual(snapshot.data.callTotal, 78, range.rawValue)
            XCTAssertEqual(snapshot.data.recentCacheBreakdown, input.cacheRecentBins.map(\.breakdown).combined, range.rawValue)
            XCTAssertEqual(snapshot.bucketCostsUSD.count, snapshot.data.bins.count, range.rawValue)
            if range == .thirtyDays {
                XCTAssertEqual(snapshot.data.bins.count, 120)
                // Two observed hours do not establish a complete six-hour
                // quota value. Preserve that gap rather than inventing one.
                XCTAssertFalse(snapshot.data.hasFiveHourQuota)
                XCTAssertFalse(snapshot.data.hasSevenDayQuota)
            } else {
                XCTAssertEqual(snapshot.data.bins, input.bins, range.rawValue)
                XCTAssertEqual(snapshot.data.fiveHourQuotaObservations, fiveHourObservations, range.rawValue)
                XCTAssertEqual(snapshot.data.sevenDayQuotaObservations, sevenDayObservations, range.rawValue)
            }
        }

        // Legacy history can lack the fine series; its 7d snapshot must use
        // these hourly quota states and retain the original observations too.
        let coarseInput = RecentChartPreparationInput(
            bins: [],
            hourlyBins: input.hourlyBins,
            cacheRecentBins: [],
            cacheHourlyBins: input.cacheHourlyBins,
            attributionEvents: [],
            quotaRecentBins: [],
            quotaHourlyBins: input.quotaHourlyBins
        )
        store.prepare(input: coarseInput, priceModel: .gpt56Sol, preferredRange: .sevenDays)
        try await waitForSnapshots(store)
        let coarse = try XCTUnwrap(store.snapshot(for: .sevenDays)).data
        XCTAssertEqual(coarse.bins, input.hourlyBins)
        XCTAssertEqual(coarse.tokenTotal, 78_000)
        XCTAssertEqual(coarse.recentCacheBreakdown, input.cacheRecentBins.map(\.breakdown).combined)
        XCTAssertEqual(coarse.fiveHourRemainingPercents, input.quotaHourlyBins.map(\.fiveHourRemainingPercent))
        XCTAssertEqual(coarse.sevenDayRemainingPercents, input.quotaHourlyBins.map(\.sevenDayRemainingPercent))
        XCTAssertEqual(coarse.fiveHourQuotaObservations, fiveHourObservations)
        XCTAssertEqual(coarse.sevenDayQuotaObservations, sevenDayObservations)
    }

    func testPreparationRunsOffMainAndTabChangesReuseAllThreeSnapshots() async throws {
        let store = RecentChartPreparationStore()
        defer { store.cancel() }
        let input = makeInput(tokens: 10)
        let calls = ChartPreparationCalls()
        let builder: RecentChartPreparationStore.Builder = { range, input, model in
            calls.record()
            return .build(range: range, input: input, priceModel: model)
        }
        store.prepare(input: input, priceModel: .gpt56Sol, preferredRange: .sevenDays, builder: builder)
        try await waitForSnapshots(store)
        XCTAssertEqual(calls.count, 3)
        XCTAssertFalse(calls.usedMainThread)
        XCTAssertEqual(store.snapshot(for: .sevenDays)?.data.range, .sevenDays)
        for range in RecentChartRange.allCases {
            store.prepare(input: input, priceModel: .gpt56Sol, preferredRange: range, builder: builder)
            XCTAssertNotNil(store.snapshot(for: range))
        }
        XCTAssertEqual(calls.count, 3)

        store.prepare(input: input, priceModel: .gpt56Luna, preferredRange: .thirtyDays, builder: builder)
        XCTAssertNil(store.snapshot(for: .thirtyDays))
        try await waitForSnapshots(store)
        XCTAssertEqual(calls.count, 6)
    }

    func testSupersededWorkerCannotPublishOldHistoryAfterRefresh() async throws {
        let store = RecentChartPreparationStore()
        let started = expectation(description: "old background preparation started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); store.cancel() }
        store.prepare(input: makeInput(tokens: 10), priceModel: .gpt56Sol, preferredRange: .twentyFourHours) { range, input, model in
            started.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return .build(range: range, input: input, priceModel: model)
        }
        await fulfillment(of: [started], timeout: 2)
        store.prepare(input: makeInput(tokens: 20), priceModel: .gpt56Sol, preferredRange: .sevenDays)
        gate.signal()
        try await waitForSnapshots(store)
        for range in RecentChartRange.allCases {
            XCTAssertEqual(store.snapshot(for: range)?.data.tokenTotal, 40)
        }
        XCTAssertEqual(store.revision, 3)
    }

    private func makeInput(tokens: Int) -> RecentChartPreparationInput {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let bins = [0, 1].map { BinUsage(start: start.addingTimeInterval(Double($0) * 300), tokens: tokens, calls: 1) }
        return RecentChartPreparationInput(
            bins: bins,
            hourlyBins: bins,
            cacheRecentBins: [],
            cacheHourlyBins: [],
            attributionEvents: [],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )
    }

    private func waitForSnapshots(_ store: RecentChartPreparationStore) async throws {
        let deadline = Date().addingTimeInterval(2)
        while RecentChartRange.allCases.contains(where: { store.snapshot(for: $0) == nil }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        for range in RecentChartRange.allCases {
            XCTAssertNotNil(store.snapshot(for: range), range.rawValue)
        }
    }
}

private final class ChartPreparationCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0
    private var recordedMainThread = false
    func record() {
        lock.withLock {
            recordedCount += 1
            recordedMainThread = recordedMainThread || Thread.isMainThread
        }
    }
    var count: Int { lock.withLock { recordedCount } }
    var usedMainThread: Bool { lock.withLock { recordedMainThread } }
}

import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class RecentChartPreparationStoreTests: XCTestCase {
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

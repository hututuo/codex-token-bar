import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class ClientModelCostPreparationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let snapshot = DashboardSnapshot.empty
    private func rows(_ input: Int64 = 1_000) -> [ClientUsageSummary] {
        [.init(client: .claudeCode, model: "claude-sonnet-4-6", inputTokens: input, outputTokens: 20,
            cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: nil, requests: 1,
            lastSeen: now, incompleteFields: false, apiCostUSD: 0.05, cacheReadComplete: true)]
    }
    private func value(_ cache: ClientModelCostPeriodsCache, input: Int64 = 1_000,
                       allowed: Set<String> = ["claudeCode"]) -> ClientModelCostPeriods {
        cache.value(codex: snapshot, todayCodex: [], rows: rows(input), today: rows(input),
            sevenDay: rows(input), clientsUpdatedAt: now, allowed: allowed, now: now)
    }

    func testPreparationNeverRunsOnMainAndRetainsAllPriceAndUsageRows() async {
        let probe = CostWorkerProbe()
        let cache = ClientModelCostPeriodsCache { input in
            probe.begin(); defer { probe.end() }
            return input.make()
        }
        XCTAssertTrue(value(cache).isPreparing)
        await cache.waitForPendingComputation()
        let actual = value(cache)
        let expected = ClientModelCostPeriods.make(codex: .empty, todayCodex: [], rows: rows(),
            today: rows(), sevenDay: rows(), allowed: ["claudeCode"], now: now)
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(probe.usedMainThread)
        XCTAssertEqual(probe.count, 1)
    }

    func testRapidInputsCoalesceToOnePendingWorkerAndNeverPublishOldResult() async throws {
        let probe = CostWorkerProbe()
        let cache = ClientModelCostPeriodsCache { input in
            probe.begin(); defer { probe.end() }
            if input.rows.first?.inputTokens == 1_000 { probe.waitUntilReleased() }
            return input.make()
        }
        defer { probe.release() }
        XCTAssertTrue(value(cache).isPreparing)
        for _ in 0..<500 where probe.count == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(probe.count, 1)
        for input in 1_001...1_010 { _ = value(cache, input: Int64(input)) }
        probe.release()
        await cache.waitForPendingComputation()
        let latest = value(cache, input: 1_010)
        XCTAssertFalse(latest.isPreparing)
        XCTAssertEqual(latest.lifetime.first?.tokens, 1_030)
        XCTAssertEqual(probe.peak, 1)
        XCTAssertEqual(probe.count, 2, "Only the running input and newest pending input may be calculated")
        XCTAssertEqual(cache.revision, 1, "The stale running result must never be published")
    }

    func testChangingScopeDoesNotDisplayPreviousClientWhileWaiting() async {
        let cache = ClientModelCostPeriodsCache()
        _ = value(cache)
        await cache.waitForPendingComputation()
        XCTAssertFalse(value(cache).lifetime.isEmpty)
        let other = value(cache, allowed: ["codex"])
        XCTAssertTrue(other.isPreparing)
        XCTAssertTrue(other.lifetime.isEmpty)
        await cache.waitForPendingComputation()
        XCTAssertTrue(value(cache, allowed: ["codex"]).lifetime.isEmpty)
    }

    func testSidebarTodayReusesDashboardLedgerCostsWithoutRepricingCacheWrites() async throws {
        // This deliberately differs from generic token-based pricing: the
        // ledger already resolved historical cache-write duration and tier.
        let known = ClientUsageSummary(client: .claudeCode, model: "claude-opus-5", inputTokens: 1_000_000,
            outputTokens: 20, cacheReadTokens: 0, cacheWriteTokens: 800_000, reasoningTokens: nil,
            requests: 200, lastSeen: now, incompleteFields: false, apiCostUSD: 24.37, cacheReadComplete: true)
        let unknown = ClientUsageSummary(client: .antigravity, model: "gemini-pro-default", inputTokens: 90,
            outputTokens: 10, cacheReadTokens: nil, cacheWriteTokens: nil, reasoningTokens: nil,
            requests: 1, lastSeen: now, incompleteFields: true, apiCostUSD: nil, cacheReadComplete: false)
        let cache = ClientModelCostPeriodsCache()
        func read(_ allowed: Set<String>) -> ClientModelCostPeriods {
            cache.value(codex: .empty, todayCodex: [], rows: [known, unknown], today: [known, unknown],
                sevenDay: [known, unknown], clientsUpdatedAt: now, allowed: allowed, now: now)
        }
        let allowed: Set<String> = ["claudeCode", "antigravity"]
        _ = read(allowed)
        await cache.waitForPendingComputation()
        let actual = read(allowed).groups(.today).flatMap(\.items)
        XCTAssertEqual(actual, ClientModelCostPeriods.make(codex: .empty, todayCodex: [], rows: [known, unknown],
            today: [known, unknown], sevenDay: [known, unknown], allowed: allowed, now: now).groups(.today).flatMap(\.items))
        XCTAssertEqual(try XCTUnwrap(actual.first { $0.label == "Opus5" }?.costUSD), 24.37, accuracy: 0.000001)
        XCTAssertEqual(actual.reduce(0) { $0 + $1.tokens }, 1_000_120)
        XCTAssertEqual(actual.last?.id, "unknown-models")
        XCTAssertTrue(actual.last?.isFallbackEstimate == true)
        XCTAssertEqual(try XCTUnwrap(FloatingTodayModelUsagePresentation.knownCostUSD(in: actual)), 24.37, accuracy: 0.000001)
        XCTAssertTrue(read(["codex"]).today.isEmpty, "Do not show another client's cached fees during a scope switch")
    }
}

private final class CostWorkerProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0, active = 0, maximum = 0
    private var onMain = false, released = false
    func begin() {
        condition.lock(); defer { condition.unlock() }
        calls += 1; active += 1; maximum = max(maximum, active)
        onMain = onMain || Thread.isMainThread
    }
    func end() { condition.lock(); defer { condition.unlock() }; active -= 1 }
    func waitUntilReleased() {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !released { if !condition.wait(until: deadline) { break } }
    }
    func release() { condition.lock(); defer { condition.unlock() }; released = true; condition.broadcast() }
    var count: Int { condition.lock(); defer { condition.unlock() }; return calls }
    var peak: Int { condition.lock(); defer { condition.unlock() }; return maximum }
    var usedMainThread: Bool { condition.lock(); defer { condition.unlock() }; return onMain }
}

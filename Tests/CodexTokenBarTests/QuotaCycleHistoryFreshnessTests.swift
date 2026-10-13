import XCTest
@testable import CodexTokenBar

@MainActor
final class QuotaCycleHistoryFreshnessTests: XCTestCase {
    private func d(_ value: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + value) }
    private func quota(_ value: Double) -> AccountQuotaSnapshot {
        .init(sevenDay: .init(label: "7d", usedPercent: 13, resetsAt: d(10000)),
              planType: "Plus", limitName: "codex", accountName: "a", updatedAt: d(value),
              historyIdentity: .init(homeIdentity: "/fixture", stableAccountKey: "a", planType: "Plus", limitID: "codex"))
    }
    private func history(_ value: Double) -> QuotaHistorySnapshot {
        .init(daily: [], recentBins: [], hourlyBins: [], latest: d(value),
              actualCycles: QuotaActualCycleProjector.project([
                .init(at: d(0), usedPercent: 13, resetsAt: d(10000)),
                .init(at: d(value), usedPercent: 13, resetsAt: d(10000))
              ], now: d(value)), cycleIdentity: quota(value).historyIdentity)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }

    func testHistoryFailureRetainsOldCyclesButMarksStaleAndCanRecover() async throws {
        let original = history(0)
        let client = CycleHistoryProbe(original)
        let store = QuotaHistoryStore(historyClient: client)
        defer { store.clearIdentity() }
        store.record(quota(0))
        try await waitUntil { store.snapshot.latest == self.d(0) }
        XCTAssertFalse(store.snapshot.isStale)
        client.configure(history: original, fails: true)
        store.record(quota(60))
        try await waitUntil { store.snapshot.isStale }
        XCTAssertEqual(store.snapshot.actualCycles, original.actualCycles)
        XCTAssertEqual(quota(60).sevenDay?.remainingPercent, 87, "history failure must not rewrite realtime quota")
        let recovered = history(60)
        client.configure(history: recovered, fails: false)
        store.reload()
        try await waitUntil { !store.snapshot.isStale && store.snapshot.latest == self.d(60) }
        XCTAssertEqual(store.snapshot.actualCycles, recovered.actualCycles)
    }

    func testSuccessfulReadOfOlderHistoryDoesNotPretendFailedWriteCaughtUp() async throws {
        let client = CycleHistoryProbe(history(0))
        let store = QuotaHistoryStore(historyClient: client)
        defer { store.clearIdentity() }
        store.record(quota(60))
        try await waitUntil { store.snapshot.latest == self.d(0) }
        XCTAssertTrue(store.snapshot.isStale)
    }
}

private final class CycleHistoryProbe: QuotaHistoryLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var history: QuotaHistorySnapshot
    private var fails = false
    init(_ history: QuotaHistorySnapshot) { self.history = history }
    func configure(history: QuotaHistorySnapshot, fails: Bool) {
        lock.withLock { self.history = history; self.fails = fails }
    }
    private enum Failure: Error { case syntheticHistoryRead }
    func loadSnapshot(for quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        try lock.withLock {
            if fails { throw Failure.syntheticHistoryRead }
            return history
        }
    }
    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        try await loadSnapshot(for: quota)
    }
    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot { quota }
}

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
    func testMismatchedProjectionTriggersExactlyOneLocalReplay() async throws {
        var old = history(60)
        old.projectionVersion = 2
        let client = CycleHistoryProbe(old)
        let store = QuotaHistoryStore(historyClient: client)
        defer { store.clearIdentity() }
        store.record(quota(60))
        try await waitUntil { client.readCount == 2 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(client.readCount, 2)
        XCTAssertTrue(store.snapshot.isStale)
    }

    func testConsistencyChecksAccountAndObservedDropButIgnoresScheduleMovement() {
        let current = quota(60)
        XCTAssertFalse(QuotaCycleProjectionConsistency.needsRebuild(history(60), quota: current))
        XCTAssertTrue(QuotaCycleProjectionConsistency.needsRebuild(history(60), quota: current, expectedStart: d(60)))
        var corrected = history(60)
        corrected.cycleDiagnostics = [.init(kind: .withdrawn, at: d(70),
            before: .init(at: d(0), usedPercent: 50, resetsAt: d(10000)),
            after: .init(at: d(60), usedPercent: 0, resetsAt: d(20000)))]
        XCTAssertFalse(QuotaCycleProjectionConsistency.needsRebuild(corrected, quota: current, expectedStart: d(60)))
        corrected.cycleIdentity = QuotaHistoryIdentity(homeIdentity: "/fixture", stableAccountKey: "b", planType: "Plus", limitID: "codex")
        XCTAssertTrue(QuotaCycleProjectionConsistency.needsRebuild(corrected, quota: current))
    }

    func testOpeningDuringBackgroundWriteLoadsTheCommittedHistoryAtTheRequestedSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = QuotaHistoryDatabase(databaseURL: root.appendingPathComponent("history.sqlite"))
        let client = LiveQuotaHistoryClient(database: database)
        let store = QuotaHistoryStore(historyClient: client, backgroundProjection: nil)
        let sidebar = UUID(), dashboard = UUID()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var current = quota(0)
        current.updatedAt = now
        current.sevenDay = .init(label: "7d", usedPercent: 13, resetsAt: now.addingTimeInterval(86400))

        store.record(current)
        XCTAssertEqual(store.snapshot, .empty)
        store.setProjectionDemand(.sidebar, consumer: sidebar)
        try await waitUntil { store.snapshot.latest == now }
        XCTAssertEqual(store.snapshot.recentBins.count, 288)
        XCTAssertTrue(store.snapshot.hourlyBins.isEmpty)
        XCTAssertTrue(store.snapshot.daily.isEmpty)
        XCTAssertFalse(store.snapshot.actualCycles.isEmpty)

        store.setProjectionDemand(.dashboard, consumer: dashboard)
        try await waitUntil { store.snapshot.daily.count == 365 }
        XCTAssertEqual(store.snapshot.recentBins.count, 8640)
        XCTAssertEqual(store.snapshot.hourlyBins.count, 8760)
        store.setProjectionDemand(nil, consumer: dashboard)
        try await waitUntil { store.snapshot.recentBins.count == 288 }
        store.setProjectionDemand(nil, consumer: sidebar)
        XCTAssertEqual(store.snapshot, .empty)
        XCTAssertEqual(try database.loadSnapshot(for: current).latest, now)
    }

}

private final class CycleHistoryProbe: QuotaHistoryLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var history: QuotaHistorySnapshot
    private var fails = false
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    init(_ history: QuotaHistorySnapshot) { self.history = history }
    func configure(history: QuotaHistorySnapshot, fails: Bool) {
        lock.withLock { self.history = history; self.fails = fails }
    }
    private enum Failure: Error { case syntheticHistoryRead }
    func loadSnapshot(for quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        try lock.withLock {
            reads += 1
            if fails { throw Failure.syntheticHistoryRead }
            return history
        }
    }
    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        try await loadSnapshot(for: quota)
    }
    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot { quota }
}

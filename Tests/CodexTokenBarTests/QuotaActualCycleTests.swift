import XCTest
@testable import CodexTokenBar

final class QuotaActualCycleTests: XCTestCase {
    private func d(_ value: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + value) }
    private func o(_ at: Double, _ used: Int, _ reset: Double) -> QuotaCycleObservation {
        .init(at: d(at), usedPercent: used, resetsAt: d(reset))
    }
    private struct Scenario: Decodable {
        let name: String
        let now: Double
        let samples: [[Double]]
        let absentRanges: [[Double]]
        let presentRanges: [[Double]]
        let expectedStarts: [Double?]
        let expectedWithdrawn: Int
    }

    func testSharedObservedCycleV3Scenarios() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedFixtures/quota-observed-cycles-v3.json")
        let scenarios = try JSONDecoder().decode([Scenario].self, from: Data(contentsOf: url))
        XCTAssertEqual(scenarios.count, 16)
        for scenario in scenarios {
            let observations = scenario.samples.map {
                QuotaCycleObservation(at: Date(timeIntervalSince1970: $0[0]), usedPercent: Int($0[1]),
                    resetsAt: Date(timeIntervalSince1970: $0[2]))
            }
            let projection = QuotaActualCycleProjector.projectWithDiagnostics(observations,
                now: Date(timeIntervalSince1970: scenario.now)) { from, through in
                let range = [from.timeIntervalSince1970, through.timeIntervalSince1970]
                if scenario.presentRanges.contains(range) { return .present }
                if scenario.absentRanges.contains(where: { $0[0] <= range[0] && $0[1] >= range[1] }) { return .absent }
                return .unknown
            }
            XCTAssertEqual(projection.cycles.map { $0.start?.latest.timeIntervalSince1970 }, scenario.expectedStarts, scenario.name)
            XCTAssertEqual(projection.diagnostics.filter { $0.kind == .withdrawn }.count, scenario.expectedWithdrawn, scenario.name)
            XCTAssertTrue(projection.cycles.first?.isCurrent == true, scenario.name)
            XCTAssertTrue(projection.cycles.allSatisfy { !$0.resetChangePending && $0.pendingBoundary == nil }, scenario.name)
            for pair in zip(projection.cycles, projection.cycles.dropFirst()) {
                XCTAssertEqual(pair.0.start, pair.1.end, scenario.name)
                XCTAssertTrue(pair.0.start?.isExact == true, scenario.name)
            }
        }
    }

    func testFirstObservedPeriodNeverBackdatesAndDeadlineDoesNotExpireIt() {
        let cycles = QuotaActualCycleProjector.project([o(0, 20, 30), o(60, 21, 30)], now: d(10000))
        XCTAssertEqual(cycles.count, 1)
        XCTAssertNil(cycles[0].start)
        XCTAssertEqual(cycles[0].certainStart, d(0))
        XCTAssertEqual(cycles[0].certainEnd, d(60))
        XCTAssertTrue(cycles[0].isCurrent)
        XCTAssertNil(cycles[0].end)
    }

    func testMissingScheduleStillAllowsAUsageReset() {
        let cycles = QuotaActualCycleProjector.project([
            .init(at: d(0), usedPercent: 70, resetsAt: .distantPast),
            .init(at: d(60), usedPercent: 0, resetsAt: .distantPast)
        ], now: d(100))
        XCTAssertEqual(cycles.count, 2)
        XCTAssertNil(cycles[0].scheduledResetAt)
        XCTAssertEqual(cycles[0].start, .exact(d(60)))
    }

    func testFutureAndDuplicateObservationsAreExcludedDeterministically() {
        let input = [o(60, 0, 1000), o(0, 50, 1000), o(60, 40, 1000), o(200, 50, 1000)]
        let cycles = QuotaActualCycleProjector.project(input, now: d(100))
        XCTAssertEqual(cycles.count, 2)
        XCTAssertEqual(cycles[0].start, .exact(d(60)))
        XCTAssertEqual(cycles[0].lastObservedAt, d(60))
    }

    func testReprojectionChangesBoundariesWithoutChangingInput() {
        let input = [o(0, 70, 1000), o(60, 0, 1000), o(360000, 0, 1000), o(360060, 70, 1000)]
        let before = QuotaActualCycleProjector.project(input, now: d(360000))
        let unknown = QuotaActualCycleProjector.project(input, now: d(360060))
        let corrected = QuotaActualCycleProjector.project(input, now: d(360060), consumption: { _, _ in .absent })
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(unknown.count, 2)
        XCTAssertEqual(corrected.count, 1)
        XCTAssertEqual(input.map(\.usedPercent), [70, 0, 0, 70])
    }

    func testHistoryProjectionRestoresAndIsolatesAccountIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota.sqlite")
        func snapshot(_ account: String, _ at: Double, _ used: Int, _ reset: Double) -> AccountQuotaSnapshot {
            AccountQuotaSnapshot(sevenDay: .init(label: "7d", usedPercent: used, resetsAt: d(reset)),
                planType: "Plus", limitName: "codex", accountName: account, updatedAt: d(at),
                historyIdentity: .init(homeIdentity: "/fixture", stableAccountKey: account, planType: "Plus", limitID: "codex"))
        }
        let database = QuotaHistoryDatabase(databaseURL: url)
        let records = [snapshot("a", 0, 50, 10000), snapshot("a", 300, 60, 10000),
                       snapshot("a", 420, 1, 20000), snapshot("a", 480, 2, 20000),
                       snapshot("b", 500, 80, 25000)]
        for record in records { XCTAssertTrue(try database.record(record)) }
        let restarted = QuotaHistoryDatabase(databaseURL: url)
        let a = try restarted.loadSnapshot(for: records[3], now: d(550))
        let b = try restarted.loadSnapshot(for: records[4], now: d(550))
        XCTAssertEqual(a.actualCycles.count, 2)
        XCTAssertEqual(b.actualCycles.count, 1)
        XCTAssertEqual(a.cycleIdentity?.stableAccountKey, "a")
        XCTAssertEqual(b.cycleIdentity?.stableAccountKey, "b")
        XCTAssertNil(b.actualCycles[0].start)
    }
}

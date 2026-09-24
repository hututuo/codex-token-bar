import Foundation
import XCTest
@testable import CodexTokenBar

final class QuotaHistoryProtectionTests: XCTestCase {
    func testFilterPreferenceDefaultsOnAndPersistsExplicitOff() throws {
        let suite = "quota-history-filter-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(QuotaHistoryFilterSettings.isEnabled(defaults: defaults))
        defaults.set(false, forKey: QuotaHistoryFilterSettings.enabledKey)
        XCTAssertFalse(QuotaHistoryFilterSettings.isEnabled(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
        defaults.set(true, forKey: QuotaHistoryFilterSettings.enabledKey)
        XCTAssertTrue(QuotaHistoryFilterSettings.isEnabled(defaults: defaults))
    }

    private struct Case: Decodable {
        let name: String
        let plan: String?
        let now: Double
        let samples: [QuotaHistoryProtection.Sample]
        let fiveRejected: [Int]
        let sevenRejected: [Int]
        let fiveBridges: [[Int]]
        let sevenBridges: [[Int]]
    }
    func testSharedRetrospectiveScenarios() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedFixtures/quota-retrospective-v1.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(cases.count, 40)
        for item in cases {
            let projection = QuotaHistoryProtection.project(item.samples, plan: item.plan, now: item.now)
            XCTAssertEqual(projection.fiveRejected.sorted(), item.fiveRejected, item.name)
            XCTAssertEqual(projection.sevenRejected.sorted(), item.sevenRejected, item.name)
            XCTAssertEqual(projection.fiveBridges, Dictionary(uniqueKeysWithValues: item.fiveBridges.map { ($0[0], $0[1]) }), item.name)
            XCTAssertEqual(projection.sevenBridges, Dictionary(uniqueKeysWithValues: item.sevenBridges.map { ($0[0], $0[1]) }), item.name)
        }
    }
    func testWindowCyclePoliciesRemainIndependent() {
        XCTAssertEqual(QuotaHistoryProtectionPolicy.fiveHour.newCycleResetDelta, 1800)
        XCTAssertEqual(QuotaHistoryProtectionPolicy.sevenDay.newCycleResetDelta, 900)
        let anchor = Date(timeIntervalSince1970: 1_900_000_000)
        for used in [0, 1, 80, 100] {
            XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(currentUsedPercent: used,
                currentResetsAt: anchor.addingTimeInterval(900), acceptedResetsAt: anchor, window: .sevenDay))
            XCTAssertTrue(QuotaHistoryCyclePolicy.startsNewCycle(currentUsedPercent: used,
                currentResetsAt: anchor.addingTimeInterval(901), acceptedResetsAt: anchor, window: .sevenDay))
        }
    }
}

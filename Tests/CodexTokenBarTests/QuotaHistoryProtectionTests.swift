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

    func testNoScheduleOrPlanRateCanRejectAUsageDropWithoutTokenEvidence() {
        for plan in ["Plus", "Pro", "ProLite"] {
            for reset in [1000.0, 2000, 8200] {
                let samples: [QuotaHistoryProtection.Sample] = [
                    .init(at: 0, fiveUsed: nil, fiveReset: nil, sevenUsed: 60, sevenReset: 1000),
                    .init(at: 60, fiveUsed: nil, fiveReset: nil, sevenUsed: 0, sevenReset: reset),
                    .init(at: 120, fiveUsed: nil, fiveReset: nil, sevenUsed: 60, sevenReset: reset)
                ]
                XCTAssertTrue(QuotaHistoryProtection.project(samples, plan: plan, now: 200).sevenRejected.isEmpty)
                let absent = QuotaHistoryProtection.project(samples, plan: plan, now: 200, consumption: { _, _ in .absent })
                XCTAssertEqual(absent.sevenRejected, [1])
                XCTAssertEqual(absent.sevenBridges, [0: 2])
                XCTAssertTrue(QuotaHistoryProtection.project(samples, plan: plan, now: 200,
                    consumption: { _, _ in .present }).sevenRejected.isEmpty)
            }
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

    func testProStableNewResetCannotLoseItsZeroToRateProtection() {
        let samples: [QuotaHistoryProtection.Sample] = [
            .init(at: 0, fiveUsed: nil, fiveReset: nil, sevenUsed: 7, sevenReset: 10000),
            .init(at: 60, fiveUsed: nil, fiveReset: nil, sevenUsed: 0, sevenReset: 20000),
            .init(at: 120, fiveUsed: nil, fiveReset: nil, sevenUsed: 3, sevenReset: 20000),
            .init(at: 180, fiveUsed: nil, fiveReset: nil, sevenUsed: 3, sevenReset: 20000),
            .init(at: 240, fiveUsed: nil, fiveReset: nil, sevenUsed: 3, sevenReset: 20000),
            .init(at: 300, fiveUsed: nil, fiveReset: nil, sevenUsed: 3, sevenReset: 20000),
            .init(at: 360, fiveUsed: nil, fiveReset: nil, sevenUsed: 3, sevenReset: 20000),
            .init(at: 420, fiveUsed: nil, fiveReset: nil, sevenUsed: 4, sevenReset: 20000)
        ]
        let projection = QuotaHistoryProtection.project(samples, plan: "Pro", now: 450)
        XCTAssertTrue(projection.sevenRejected.isEmpty)
        XCTAssertTrue(projection.sevenBridges.isEmpty)
    }
}

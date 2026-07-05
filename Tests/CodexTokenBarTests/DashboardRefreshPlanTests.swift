import XCTest
@testable import CodexTokenBar

final class DashboardRefreshPlanTests: XCTestCase {
    func testManualRefreshUpdatesUsageQuotaAndRadarWithoutQuotaHistory() {
        let plan = DashboardRefreshPlan.make(trigger: .manual, providerSyncVisible: false)

        XCTAssertEqual(plan.trigger, .manual)
        XCTAssertEqual(plan.actions, [
            .refreshUsage,
            .refreshQuota(force: true),
            .refreshRadar
        ])
        XCTAssertFalse(plan.actions.contains(.reloadQuotaHistoryTimeline))
    }

    func testManualRefreshIncludesProviderSyncOnlyWhenVisible() {
        let hiddenPlan = DashboardRefreshPlan.make(trigger: .manual, providerSyncVisible: false)
        let visiblePlan = DashboardRefreshPlan.make(trigger: .manual, providerSyncVisible: true)

        XCTAssertFalse(hiddenPlan.actions.contains(.scanProviders))
        XCTAssertEqual(visiblePlan.actions, [
            .refreshUsage,
            .refreshQuota(force: true),
            .refreshRadar,
            .scanProviders
        ])
    }

    func testWakeRefreshUsesSameDataRefreshPlanWithoutQuotaHistoryReload() {
        let plan = DashboardRefreshPlan.make(trigger: .systemWake, providerSyncVisible: false)

        XCTAssertEqual(plan.trigger, .systemWake)
        XCTAssertEqual(plan.actions, [
            .refreshUsage,
            .refreshQuota(force: true),
            .refreshRadar
        ])
        XCTAssertFalse(plan.actions.contains(.reloadQuotaHistoryTimeline))
    }

    func testQuotaRetryRefreshesOnlyQuotaAndQuotaHistory() {
        let plan = DashboardRefreshPlan.make(trigger: .quotaRetry, providerSyncVisible: true)

        XCTAssertEqual(plan.trigger, .quotaRetry)
        XCTAssertEqual(plan.actions, [
            .refreshQuota(force: true),
            .reloadQuotaHistoryTimeline
        ])
        XCTAssertFalse(plan.actions.contains(.refreshUsage))
        XCTAssertFalse(plan.actions.contains(.refreshRadar))
        XCTAssertFalse(plan.actions.contains(.scanProviders))
    }
}

import XCTest
@testable import CodexTokenBar

final class DashboardRefreshPlanTests: XCTestCase {
    func testManualRefreshReloadsUsageQuotaHistoryAndRadar() {
        let plan = DashboardRefreshPlan.make(
            trigger: .manual,
            context: DashboardRefreshContext(providerSyncVisible: false)
        )

        XCTAssertEqual(plan.trigger, .manual)
        XCTAssertEqual(plan.actions, [
            .refreshUsage,
            .refreshQuota(force: true),
            .reloadQuotaHistoryTimeline,
            .refreshRadar
        ])
    }

    func testManualRefreshScansProvidersOnlyWhenProviderSyncVisible() {
        let hiddenPlan = DashboardRefreshPlan.make(
            trigger: .manual,
            context: DashboardRefreshContext(providerSyncVisible: false)
        )
        let visiblePlan = DashboardRefreshPlan.make(
            trigger: .manual,
            context: DashboardRefreshContext(providerSyncVisible: true)
        )

        XCTAssertFalse(hiddenPlan.actions.contains(.scanProviders))
        XCTAssertEqual(visiblePlan.actions, [
            .refreshUsage,
            .refreshQuota(force: true),
            .reloadQuotaHistoryTimeline,
            .refreshRadar,
            .scanProviders
        ])
    }

    func testSystemWakeRefreshesQuotaHistoryAndSkipsProviderScanEvenWhenProviderSyncVisible() {
        let plan = DashboardRefreshPlan.make(
            trigger: .systemWake,
            context: DashboardRefreshContext(
                providerSyncVisible: true,
                dashboardVisible: false,
                usageStale: false,
                radarVisible: false,
                radarStale: false
            )
        )

        XCTAssertEqual(plan.trigger, .systemWake)
        XCTAssertEqual(plan.actions, [
            .refreshQuota(force: true),
            .reloadQuotaHistoryTimeline
        ])
        XCTAssertFalse(plan.actions.contains(.scanProviders))
    }

    func testSystemWakeRefreshesUsageAndRadarOnlyWhenVisibleOrStale() {
        let active = DashboardRefreshPlan.make(
            trigger: .systemWake,
            context: DashboardRefreshContext(
                providerSyncVisible: false,
                dashboardVisible: true,
                usageStale: false,
                radarVisible: true,
                radarStale: false
            )
        )
        XCTAssertEqual(active.actions, [
            .refreshUsage,
            .refreshQuota(force: true),
            .reloadQuotaHistoryTimeline,
            .refreshRadar
        ])

        let stale = DashboardRefreshPlan.make(
            trigger: .systemWake,
            context: DashboardRefreshContext(
                providerSyncVisible: false,
                dashboardVisible: false,
                usageStale: true,
                radarVisible: false,
                radarStale: true
            )
        )
        XCTAssertEqual(stale.actions, [
            .refreshUsage,
            .refreshQuota(force: true),
            .reloadQuotaHistoryTimeline,
            .refreshRadar
        ])
    }

    func testQuotaRetryRefreshesOnlyQuotaAndQuotaHistory() {
        let plan = DashboardRefreshPlan.make(
            trigger: .quotaRetry,
            context: DashboardRefreshContext(providerSyncVisible: true)
        )

        XCTAssertEqual(plan.trigger, .quotaRetry)
        XCTAssertEqual(plan.actions, [
            .refreshQuota(force: true),
            .reloadQuotaHistoryTimeline
        ])
        XCTAssertFalse(plan.actions.contains(.refreshUsage))
        XCTAssertFalse(plan.actions.contains(.refreshRadar))
        XCTAssertFalse(plan.actions.contains(.scanProviders))
    }

    func testRefreshContextTreatsDashboardWindowAsRadarVisibleEvenWhenFloatingRadarIsOff() {
        let context = DashboardRefreshContext.fromSurfaces(
            providerSyncVisible: false,
            appActive: false,
            dashboardWindowVisible: true,
            floatingPanelEnabled: false,
            statusBarPanelEnabled: false,
            usageStale: false,
            radarDetailsVisible: false,
            floatingPanelShowRadar: false,
            radarStale: false
        )

        XCTAssertTrue(context.radarVisible)
    }

    func testRefreshContextRequiresFloatingPanelEnabledForFloatingRadarPreference() {
        let disabledPanel = DashboardRefreshContext.fromSurfaces(
            providerSyncVisible: false,
            appActive: false,
            dashboardWindowVisible: false,
            floatingPanelEnabled: false,
            statusBarPanelEnabled: false,
            usageStale: false,
            radarDetailsVisible: false,
            floatingPanelShowRadar: true,
            radarStale: false
        )
        let enabledPanel = DashboardRefreshContext.fromSurfaces(
            providerSyncVisible: false,
            appActive: false,
            dashboardWindowVisible: false,
            floatingPanelEnabled: true,
            statusBarPanelEnabled: false,
            usageStale: false,
            radarDetailsVisible: false,
            floatingPanelShowRadar: true,
            radarStale: false
        )

        XCTAssertFalse(disabledPanel.radarVisible)
        XCTAssertTrue(enabledPanel.radarVisible)
    }

    func testRefreshContextStatusBarContributesToUsageVisibilityButNotRadarVisibility() {
        let context = DashboardRefreshContext.fromSurfaces(
            providerSyncVisible: false,
            appActive: false,
            dashboardWindowVisible: false,
            floatingPanelEnabled: false,
            statusBarPanelEnabled: true,
            usageStale: false,
            radarDetailsVisible: false,
            floatingPanelShowRadar: false,
            radarStale: false
        )

        XCTAssertTrue(context.dashboardVisible)
        XCTAssertFalse(context.radarVisible)
    }

    func testDashboardRefreshUsesRefreshContext() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let source = try String(contentsOf: dashboardView, encoding: .utf8)

        XCTAssertTrue(source.contains("DashboardRefreshContext.fromSurfaces("))
        XCTAssertTrue(source.contains("DashboardRefreshPlan.make(trigger: trigger, context:"))
    }
}

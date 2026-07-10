import Foundation
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

    @MainActor
    func testDashboardCompositionUsesOneStableSourceTransitionCoordinator() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let source = try String(contentsOf: dashboardView, encoding: .utf8)

        XCTAssertTrue(source.contains("sourceTransitionCoordinator.transition("))
        XCTAssertTrue(source.contains(".onChange(of: store.dataSourceIdentity)"))
        XCTAssertFalse(source.contains(".onChange(of: store.dataSourceLabel)"))
    }

    @MainActor
    func testSourceTransitionCoordinatorMovesAllOwnersAcrossAToNilToBAndSkipsSameSource() async throws {
        let homeA = try makeTemporaryDirectory(named: "DashboardSourceA")
        let homeB = try makeTemporaryDirectory(named: "DashboardSourceB")
        defer {
            try? FileManager.default.removeItem(at: homeA)
            try? FileManager.default.removeItem(at: homeB)
        }
        let sourceA = CodexDataSource(codexHome: homeA, origin: .userSelected)
        let sourceB = CodexDataSource(codexHome: homeB, origin: .userSelected)
        let equivalentSourceA = CodexDataSource(
            codexHome: homeA,
            origin: .defaultHome,
            expectedHomeIdentity: sourceA.homeIdentity
        )
        let usageStore = CodexUsageStore(
            resolver: DashboardTransitionResolver(source: sourceA),
            snapshotLoader: DashboardTransitionSnapshotLoader(),
            autoStart: false
        )
        let quotaReader = DashboardTransitionQuotaReader(results: [
            .success(dashboardTransitionQuotaSnapshot()),
            .failure(DashboardTransitionError()),
            .failure(DashboardTransitionError())
        ])
        let quotaStore = AccountQuotaStore(quotaReader: quotaReader, observesUserDefaults: false)
        let liveMonitor = LiveRateMonitor(monitoringEnabled: false)
        let taskMonitor = TaskCompletionMonitor(defaults: isolatedDefaults())
        let providerStore = ProviderSyncStore()
        let coordinator = DashboardSourceTransitionCoordinator()

        XCTAssertTrue(coordinator.transition(
            to: sourceA,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        ))
        await waitUntil("source A quota projected") {
            quotaStore.snapshot.accountName == "source-a-account"
        }
        liveMonitor.testPrepareForLiveRateProcessing(selectedThreadID: "thread-a")
        taskMonitor.applyForTesting(result: nil, unreadThreadRead: .available(["thread-a"]))
        XCTAssertEqual(taskMonitor.unreadThreadCount, 1)

        XCTAssertFalse(coordinator.transition(
            to: equivalentSourceA,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        ))
        XCTAssertEqual(liveMonitor.selectedThreadID, "thread-a")
        XCTAssertEqual(taskMonitor.unreadThreadCount, 1)
        let sameSourceReadCount = await quotaReader.readCount()
        XCTAssertEqual(sameSourceReadCount, 1)

        XCTAssertTrue(coordinator.transition(
            to: nil,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        ))
        XCTAssertNil(usageStore.dataSourceIdentity)
        XCTAssertNil(quotaStore.currentDataSourceIdentity)
        XCTAssertNil(liveMonitor.currentDataSourceIdentity)
        XCTAssertNil(taskMonitor.currentDataSourceIdentity)
        XCTAssertNil(providerStore.currentDataSource)
        XCTAssertEqual(liveMonitor.selectedThreadID, "")
        XCTAssertEqual(taskMonitor.unreadThreadCount, 0)
        XCTAssertFalse(quotaStore.snapshot.isAvailable)

        await waitUntil("automatic nil quota failure") {
            quotaStore.snapshot.status.hasPrefix("额度读取失败")
        }

        XCTAssertTrue(coordinator.transition(
            to: sourceB,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        ))
        await waitUntil("source B quota failure") {
            await quotaReader.readCount() == 3 && quotaStore.snapshot.status.hasPrefix("额度读取失败")
        }

        XCTAssertEqual(usageStore.dataSourceIdentity, sourceB.stableIdentityKey)
        XCTAssertEqual(quotaStore.currentDataSourceIdentity, sourceB.stableIdentityKey)
        XCTAssertEqual(liveMonitor.currentDataSourceIdentity, sourceB.stableIdentityKey)
        XCTAssertEqual(taskMonitor.currentDataSourceIdentity, sourceB.stableIdentityKey)
        XCTAssertEqual(providerStore.currentDataSource?.stableIdentityKey, sourceB.stableIdentityKey)
        XCTAssertEqual(usageStore.dataSourceLabel, sourceB.displayPath)
        XCTAssertEqual(usageStore.snapshot.stats.totalTokens, 0)
        XCTAssertFalse(quotaStore.snapshot.isAvailable)
        XCTAssertFalse(quotaStore.snapshot.staleDataDisplayed)
        XCTAssertEqual(liveMonitor.selectedThreadID, "")
        XCTAssertEqual(taskMonitor.unreadThreadCount, 0)
        XCTAssertEqual(providerStore.snapshot.codexHome, sourceB.displayPath)

        let compactSnapshot = TokenDisplaySnapshot.make(
            store: usageStore,
            monitor: liveMonitor,
            quota: quotaStore
        )
        let floating = FloatingPanelPresentationModel(snapshot: compactSnapshot, visibility: .default)
        let status = StatusBarUsageMetricsPresentation(snapshot: compactSnapshot)
        XCTAssertEqual(compactSnapshot.rate, 0)
        XCTAssertEqual(status.totalTokens, "待读取")
        XCTAssertFalse(floating.accessibilityValue.contains("额度剩余 58%"))
        XCTAssertFalse(floating.accessibilityValue.contains("thread-a"))
    }

    @MainActor
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "DashboardSourceTransitionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func dashboardTransitionQuotaSnapshot() -> AccountQuotaSnapshot {
        AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(
                label: "5h",
                usedPercent: 42,
                resetsAt: Date(timeIntervalSince1970: 1_800)
            ),
            planType: "pro",
            limitName: "codex",
            accountName: "source-a-account",
            status: "额度已读取",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

private final class DashboardTransitionResolver: CodexDataSourceResolving {
    private let source: CodexDataSource?

    init(source: CodexDataSource?) {
        self.source = source
    }

    func resolve() -> CodexDataSource? {
        source
    }

    func saveSelectedDirectory(_ directory: URL) -> CodexDataSource? {
        source
    }
}

private struct DashboardTransitionSnapshotLoader: DashboardSnapshotLoading {
    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        .empty
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        .empty
    }
}

private actor DashboardTransitionQuotaReader: QuotaReading {
    private var results: [Result<AccountQuotaSnapshot, Error>]
    private var count = 0

    init(results: [Result<AccountQuotaSnapshot, Error>]) {
        self.results = results
    }

    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        count += 1
        guard !results.isEmpty else { return .failure(DashboardTransitionError()) }
        return results.removeFirst()
    }

    func readCount() -> Int {
        count
    }
}

private struct DashboardTransitionError: LocalizedError {
    var errorDescription: String? {
        "模拟来源读取失败"
    }
}

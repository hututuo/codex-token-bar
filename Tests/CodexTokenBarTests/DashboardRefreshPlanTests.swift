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
        XCTAssertTrue(source.contains(".onChange(of: store.dataSourceBindingKey)"))
        XCTAssertFalse(source.contains(".onChange(of: store.dataSourceLabel)"))
    }

    @MainActor
    func testSameIdentityPathRebindPropagatesWithoutResettingTrustedState() async throws {
        let parent = try makeTemporaryDirectory(named: "DashboardPathRebind")
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldHome = parent.appendingPathComponent("old-home", isDirectory: true)
        let newHome = parent.appendingPathComponent("new-home", isDirectory: true)
        try FileManager.default.createDirectory(at: oldHome, withIntermediateDirectories: true)
        let sourceAtOldPath = CodexDataSource(codexHome: oldHome, origin: .userSelected)
        let preciseUsage = dashboardTransitionUsageSnapshot(totalTokens: 77_777)
        let usageResolver = DashboardTransitionResolver(source: sourceAtOldPath)
        let usageLoader = DashboardTransitionSnapshotLoader(snapshot: preciseUsage)
        let usageStore = CodexUsageStore(
            resolver: usageResolver,
            snapshotLoader: usageLoader,
            autoStart: false
        )
        let quotaReader = DashboardTransitionQuotaReader(results: [
            .success(dashboardTransitionQuotaSnapshot()),
            .success(dashboardTransitionQuotaSnapshot())
        ])
        let quotaStore = AccountQuotaStore(quotaReader: quotaReader, observesUserDefaults: false)
        let liveMonitor = LiveRateMonitor(monitoringEnabled: false)
        let taskMonitor = TaskCompletionMonitor(defaults: isolatedDefaults())
        let providerStore = ProviderSyncStore()
        let coordinator = DashboardSourceTransitionCoordinator()

        usageStore.refresh()
        await waitUntil("old-path precise usage") {
            usageStore.snapshot.stats.totalTokens == 77_777 && !usageStore.isRefreshing
        }
        _ = coordinator.transition(
            to: sourceAtOldPath,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        )
        await waitUntil("old-path quota") {
            quotaStore.snapshot.accountName == "source-a-account"
        }
        let oldRolloutPath = oldHome.appendingPathComponent("sessions/thread-a.jsonl").path
        liveMonitor.testPrepareForLiveRateProcessing(
            selectedThreadID: "thread-a",
            threadOptions: [
                LiveThreadOption(id: "thread-a", title: "A", updatedAtMS: 1, rolloutPath: oldRolloutPath)
            ]
        )
        liveMonitor.testProcessPollInputs(
            streamRows: [
                LiveRateMonitor.LogRow(
                    id: 1,
                    threadID: "thread-a",
                    ts: 1_000,
                    tsNanos: 0,
                    target: "codex_api::sse::responses",
                    feedbackLogBody: #"SSE event: {"type":"response.output_text.delta","delta":"keep rate","item_id":"msg-keep","sequence_number":1}"#
                )
            ],
            rolloutReads: [],
            now: 1_000.2
        )
        taskMonitor.applyForTesting(result: nil, unreadThreadRead: .available(["thread-a"]))
        let quotaBefore = quotaStore.snapshot
        let liveBreakdownBefore = liveMonitor.snapshot.breakdown
        let liveRateBefore = liveMonitor.snapshot.rollingTokensPerSecond
        let liveGenerationBefore = liveMonitor.testSourceGeneration
        let liveBindingGenerationBefore = liveMonitor.testSourceBindingGeneration
        let usageIdentityGenerationBefore = usageStore.sourceIdentityGeneration
        let usageBindingGenerationBefore = usageStore.sourceBindingGeneration
        let quotaIdentityGenerationBefore = quotaStore.sourceIdentityGeneration
        let quotaBindingGenerationBefore = quotaStore.sourceBindingGeneration
        let taskIdentityGenerationBefore = taskMonitor.sourceIdentityGeneration
        let taskBindingGenerationBefore = taskMonitor.sourceBindingGeneration
        let providerStatusBefore = providerStore.snapshot.status

        try FileManager.default.moveItem(at: oldHome, to: newHome)
        let sourceAtNewPath = CodexDataSource(codexHome: newHome, origin: .userSelected)
        XCTAssertEqual(sourceAtNewPath.stableIdentityKey, sourceAtOldPath.stableIdentityKey)
        usageResolver.setSource(sourceAtNewPath)

        let rebind = coordinator.transition(
            to: sourceAtNewPath,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        )

        XCTAssertEqual(rebind, .pathRebind)
        await waitUntil("single new-path owner reads") {
            let usageReadCount = await usageLoader.requestedSourcePaths().count
            let quotaReadCount = await quotaReader.readCount()
            return usageReadCount == 2 && quotaReadCount == 2 && !usageStore.isRefreshing
        }
        XCTAssertEqual(usageStore.currentDataSource?.codexHome.path, newHome.path)
        XCTAssertEqual(usageStore.snapshot.stats.totalTokens, 77_777)
        XCTAssertEqual(quotaStore.snapshot, quotaBefore)
        XCTAssertEqual(quotaStore.currentDataSourcePath, newHome.path)
        let readCountAfterRebind = await quotaReader.readCount()
        XCTAssertEqual(readCountAfterRebind, 2)
        XCTAssertEqual(usageStore.sourceIdentityGeneration, usageIdentityGenerationBefore)
        XCTAssertEqual(usageStore.sourceBindingGeneration, usageBindingGenerationBefore + 1)
        XCTAssertEqual(quotaStore.sourceIdentityGeneration, quotaIdentityGenerationBefore)
        XCTAssertEqual(quotaStore.sourceBindingGeneration, quotaBindingGenerationBefore + 1)
        XCTAssertEqual(liveMonitor.dataSource?.codexHome.path, newHome.path)
        XCTAssertEqual(liveMonitor.selectedThreadID, "thread-a")
        XCTAssertEqual(liveMonitor.snapshot.breakdown, liveBreakdownBefore)
        XCTAssertEqual(liveMonitor.snapshot.rollingTokensPerSecond, liveRateBefore)
        XCTAssertEqual(liveMonitor.testSourceGeneration, liveGenerationBefore)
        XCTAssertEqual(liveMonitor.testSourceBindingGeneration, liveBindingGenerationBefore + 1)
        XCTAssertEqual(taskMonitor.unreadThreadCount, 1)
        XCTAssertEqual(taskMonitor.currentDataSourcePath, newHome.path)
        XCTAssertEqual(taskMonitor.sourceIdentityGeneration, taskIdentityGenerationBefore)
        XCTAssertEqual(taskMonitor.sourceBindingGeneration, taskBindingGenerationBefore + 1)
        XCTAssertEqual(providerStore.currentDataSource?.codexHome.path, newHome.path)
        XCTAssertEqual(providerStore.snapshot.status, providerStatusBefore)
        XCTAssertEqual(providerStore.snapshot.codexHome, sourceAtNewPath.displayPath)

        let noChange = coordinator.transition(
            to: sourceAtNewPath,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        )
        XCTAssertEqual(noChange, .noChange)
        let readCountAfterNoOp = await quotaReader.readCount()
        XCTAssertEqual(readCountAfterNoOp, 2)

        let usageSourcePaths = await usageLoader.requestedSourcePaths()
        XCTAssertEqual(usageSourcePaths, [oldHome.path, newHome.path])

        let requestedSourcePaths = await quotaReader.requestedSourcePaths()
        XCTAssertEqual(
            requestedSourcePaths,
            [oldHome.path, newHome.path]
        )
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

        XCTAssertEqual(coordinator.transition(
            to: sourceA,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        ), .identityTransition)
        await waitUntil("source A quota projected") {
            quotaStore.snapshot.accountName == "source-a-account"
        }
        liveMonitor.testPrepareForLiveRateProcessing(selectedThreadID: "thread-a")
        taskMonitor.applyForTesting(result: nil, unreadThreadRead: .available(["thread-a"]))
        XCTAssertEqual(taskMonitor.unreadThreadCount, 1)

        XCTAssertEqual(coordinator.transition(
            to: equivalentSourceA,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        ), .noChange)
        XCTAssertEqual(liveMonitor.selectedThreadID, "thread-a")
        XCTAssertEqual(taskMonitor.unreadThreadCount, 1)
        let sameSourceReadCount = await quotaReader.readCount()
        XCTAssertEqual(sameSourceReadCount, 1)

        XCTAssertEqual(coordinator.transition(
            to: nil,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        ), .identityTransition)
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

        XCTAssertEqual(coordinator.transition(
            to: sourceB,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskMonitor,
            providerSyncStore: providerStore
        ), .identityTransition)
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

    private func dashboardTransitionUsageSnapshot(totalTokens: Int) -> DashboardSnapshot {
        DashboardSnapshot(
            stats: DashboardStats(
                totalTokens: totalTokens,
                peakDayTokens: totalTokens,
                peakThreadTokens: totalTokens,
                currentStreakDays: 1,
                longestStreakDays: 1,
                totalCalls: 1,
                totalThreads: 1,
                mostUsedReasoning: "中",
                skillsExplored: 0,
                totalSkillsUsed: 0
            ),
            dailyUsage: [DayUsage(date: Date(), tokens: totalTokens, calls: 1)],
            recentBins: [],
            hourlyUsage: [],
            pluginUsage: [],
            cacheUsage: .empty,
            usagePrecision: .precise,
            generatedAt: Date()
        )
    }
}

private final class DashboardTransitionResolver: CodexDataSourceResolving {
    private var source: CodexDataSource?

    init(source: CodexDataSource?) {
        self.source = source
    }

    func resolve() -> CodexDataSource? {
        source
    }

    func saveSelectedDirectory(_ directory: URL) -> CodexDataSource? {
        source
    }

    func setSource(_ source: CodexDataSource?) {
        self.source = source
    }
}

private actor DashboardTransitionSnapshotLoader: DashboardSnapshotLoading {
    let snapshot: DashboardSnapshot
    private var sourcePaths: [String] = []

    init(snapshot: DashboardSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        .empty
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        sourcePaths.append(dataSource.codexHome.path)
        return snapshot
    }

    func requestedSourcePaths() -> [String] {
        sourcePaths
    }
}

private actor DashboardTransitionQuotaReader: QuotaReading {
    private var results: [Result<AccountQuotaSnapshot, Error>]
    private var count = 0
    private var sourcePaths: [String?] = []

    init(results: [Result<AccountQuotaSnapshot, Error>]) {
        self.results = results
    }

    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        count += 1
        sourcePaths.append(dataSource?.codexHome.path)
        guard !results.isEmpty else { return .failure(DashboardTransitionError()) }
        return results.removeFirst()
    }

    func readCount() -> Int {
        count
    }

    func requestedSourcePaths() -> [String?] {
        sourcePaths
    }
}

private struct DashboardTransitionError: LocalizedError {
    var errorDescription: String? {
        "模拟来源读取失败"
    }
}

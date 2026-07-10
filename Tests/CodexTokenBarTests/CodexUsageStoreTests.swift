import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class CodexUsageStoreTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
    }

    override func tearDownWithError() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
        try super.tearDownWithError()
    }

    func testVisibleDashboardRefreshesFasterThanCompactOnlySurfaces() throws {
        var snapshot = LiveRateSnapshot()
        snapshot.rollingTokensPerSecond = 0
        snapshot.updatedAt = Date(timeIntervalSince1970: 2_000)

        let visibleDashboard = UsageRefreshCadencePolicy.decision(
            snapshot: snapshot,
            onlyCompactSurfaceVisible: false,
            now: snapshot.updatedAt
        )
        let compactOnly = UsageRefreshCadencePolicy.decision(
            snapshot: snapshot,
            onlyCompactSurfaceVisible: true,
            now: snapshot.updatedAt
        )

        XCTAssertEqual(visibleDashboard.interval, 180, accuracy: 0.001)
        XCTAssertEqual(compactOnly.interval, 300, accuracy: 0.001)
    }

    func testLiveActivityTemporarilyAcceleratesUsageRefresh() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        var snapshot = LiveRateSnapshot()
        snapshot.rollingTokensPerSecond = 12
        snapshot.updatedAt = now.addingTimeInterval(-5)

        let decision = UsageRefreshCadencePolicy.decision(
            snapshot: snapshot,
            onlyCompactSurfaceVisible: false,
            now: now
        )

        XCTAssertTrue(decision.isActive)
        XCTAssertEqual(decision.interval, 30, accuracy: 0.001)
        XCTAssertEqual(decision.recoveryDelay ?? 0, 25.25, accuracy: 0.001)
    }

    func testLiveActivityCadenceRestoresVisibleDashboardBaselineAfterWindowExpires() {
        let now = Date(timeIntervalSince1970: 2_000)
        var snapshot = LiveRateSnapshot()
        snapshot.rollingTokensPerSecond = 12
        snapshot.updatedAt = now.addingTimeInterval(-31)

        let decision = UsageRefreshCadencePolicy.decision(
            snapshot: snapshot,
            onlyCompactSurfaceVisible: false,
            now: now
        )

        XCTAssertFalse(decision.isActive)
        XCTAssertEqual(decision.interval, 180, accuracy: 0.001)
        XCTAssertNil(decision.recoveryDelay)
    }

    func testLiveActivityCadenceRestoresCompactOnlyBaselineAfterWindowExpires() {
        let now = Date(timeIntervalSince1970: 2_000)
        var snapshot = LiveRateSnapshot()
        snapshot.rollingTokensPerSecond = 12
        snapshot.updatedAt = now.addingTimeInterval(-31)

        let decision = UsageRefreshCadencePolicy.decision(
            snapshot: snapshot,
            onlyCompactSurfaceVisible: true,
            now: now
        )

        XCTAssertFalse(decision.isActive)
        XCTAssertEqual(decision.interval, 300, accuracy: 0.001)
        XCTAssertNil(decision.recoveryDelay)
    }

    func testZeroLiveRateDoesNotKeepUsageRefreshAccelerated() {
        let now = Date(timeIntervalSince1970: 2_000)
        var snapshot = LiveRateSnapshot()
        snapshot.rollingTokensPerSecond = 0
        snapshot.updatedAt = now

        let decision = UsageRefreshCadencePolicy.decision(
            snapshot: snapshot,
            onlyCompactSurfaceVisible: false,
            now: now
        )

        XCTAssertFalse(decision.isActive)
        XCTAssertEqual(decision.interval, 180, accuracy: 0.001)
        XCTAssertNil(decision.recoveryDelay)
    }

    func testUsageRefreshStatusDescribesIncrementalTokenUpdate() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let usageStore = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexUsageStore.swift")
        let source = try String(contentsOf: usageStore, encoding: .utf8)

        XCTAssertTrue(source.contains("正在增量更新 token"))
        XCTAssertFalse(source.contains("正在扫描 \\(dataSource.displayPath)/sessions"))
    }

    func testUsageCacheInitializationUsesInlineNoticeInsteadOfBlockingOverlay() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let usageStore = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexUsageStore.swift")
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let headerView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardHeaderView.swift")
        let storeSource = try String(contentsOf: usageStore, encoding: .utf8)
        let dashboardSource = try String(contentsOf: dashboardView, encoding: .utf8)
        let headerSource = try String(contentsOf: headerView, encoding: .utf8)

        XCTAssertTrue(storeSource.contains("UsageCacheLifecycle.isCurrentCachePrepared"))
        XCTAssertTrue(storeSource.contains("UsageCacheLifecycle.markCurrentCachePrepared()"))
        XCTAssertTrue(storeSource.contains("isPreparingUsageCache"))
        XCTAssertFalse(dashboardSource.contains("if store.isPreparingUsageCache"))
        XCTAssertTrue(dashboardSource.contains("StatStrip("))
        XCTAssertTrue(dashboardSource.contains("isPreparingUsageCache: store.isPreparingUsageCache"))
        XCTAssertTrue(dashboardSource.contains("cacheStatus: store.status"))
        XCTAssertFalse(dashboardSource.contains("UsageCacheInitializationNotice(status: store.status)"))
        XCTAssertFalse(dashboardSource.contains("if store.isInitialLoading {\n                InitialLoadingOverlay"))
        XCTAssertTrue(headerSource.contains("StatStripStatusLinePresentation("))
        XCTAssertTrue(headerSource.contains("正在初始化本地统计缓存"))
    }

    func testStatStripStatusLineUsesStableFooterForCachePreparation() throws {
        let preparing = try XCTUnwrap(StatStripStatusLinePresentation(
            hasPreciseTokenUsage: true,
            isPreparingUsageCache: true,
            cacheStatus: "正在增量更新 token"
        ))
        let metadataOnly = try XCTUnwrap(StatStripStatusLinePresentation(
            hasPreciseTokenUsage: false,
            isPreparingUsageCache: false,
            cacheStatus: "仅显示会话元数据"
        ))
        let preciseIdle = StatStripStatusLinePresentation(
            hasPreciseTokenUsage: true,
            isPreparingUsageCache: false,
            cacheStatus: "token_count · 更新于 12:00"
        )
        let failedMetadata = try XCTUnwrap(StatStripStatusLinePresentation(
            hasPreciseTokenUsage: false,
            isPreparingUsageCache: false,
            cacheStatus: "读取失败：会话目录遍历失败"
        ))
        let stalePrecise = try XCTUnwrap(StatStripStatusLinePresentation(
            hasPreciseTokenUsage: true,
            isPreparingUsageCache: false,
            cacheStatus: "读取失败（保留上次可信数据，当前显示已陈旧）：会话目录遍历失败"
        ))

        XCTAssertEqual(preparing.text, "正在初始化本地统计缓存 · 正在增量更新 token")
        XCTAssertTrue(preparing.showsProgress)
        XCTAssertEqual(metadataOnly.text, "仅显示会话元数据，精确 token 仍在读取，请稍后。")
        XCTAssertFalse(metadataOnly.showsProgress)
        XCTAssertNil(preciseIdle)
        XCTAssertEqual(failedMetadata.text, "读取失败：会话目录遍历失败")
        XCTAssertFalse(failedMetadata.showsProgress)
        XCTAssertTrue(stalePrecise.text.contains("当前显示已陈旧"))
        XCTAssertFalse(stalePrecise.showsProgress)
    }

    func testUsageCacheLifecycleMarksCurrentNamespacePrepared() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageStoreCacheState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", stateRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", stateRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            try? FileManager.default.removeItem(at: stateRoot)
        }

        UsageCacheLifecycle.clearStateForTesting()
        XCTAssertFalse(UsageCacheLifecycle.isCurrentCachePrepared)

        UsageCacheLifecycle.markCurrentCachePrepared()

        XCTAssertTrue(UsageCacheLifecycle.isCurrentCachePrepared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("cache-state.json").path))
    }

    func testInitialPreciseFailurePreservesFastUsageSnapshot() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/.codex"),
            origin: .defaultHome
        )
        let fastSnapshot = makeSnapshot(totalTokens: 88_000, dayTokens: 0)
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(fastSnapshot)],
            preciseResults: [.failure(UsageStoreTestError())]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("initial precise failure") {
            store.status.hasPrefix("读取失败") && !store.isRefreshing
        }

        XCTAssertEqual(store.snapshot.stats.totalTokens, 88_000)
        XCTAssertEqual(store.snapshot.stats.totalThreads, 2)
        XCTAssertTrue(store.status.contains("当前显示已陈旧"))
        XCTAssertFalse(store.isInitialLoading)
    }

    func testColdStartFailureDoesNotPublishPreciseZero() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/cold-failure/.codex"),
            origin: .defaultHome
        )
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.failure(UsageStoreTestError())],
            preciseResults: [.failure(UsageStoreTestError())]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("cold usage failure") {
            store.status.hasPrefix("读取失败") && !store.isRefreshing
        }

        XCTAssertFalse(store.snapshot.hasPreciseTokenUsage)
        XCTAssertEqual(store.snapshot.stats.totalTokens, 0)
        XCTAssertFalse(store.status.contains("当前显示已陈旧"))

        let display = TokenDisplaySnapshot.make(
            store: store,
            monitor: LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false),
            quota: AccountQuotaStore(observesUserDefaults: false)
        )
        XCTAssertEqual(display.metadataOnlyStatusText, "用量读取失败")
        XCTAssertEqual(display.standaloneUsageStatus, "用量读取失败")
    }

    func testMetadataOnlyPreciseResultRemainsDegradedAndDoesNotPrepareCache() async throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageStoreMetadataOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", stateRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", stateRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            try? FileManager.default.removeItem(at: stateRoot)
        }
        UsageCacheLifecycle.clearStateForTesting()

        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/.codex"),
            origin: .defaultHome
        )
        let metadataOnlySnapshot = makeSnapshot(
            totalTokens: 0,
            dayTokens: 0,
            usagePrecision: .metadataOnly
        )
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(metadataOnlySnapshot)],
            preciseResults: [.success(metadataOnlySnapshot)]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("metadata-only usage refresh") {
            store.snapshot.usagePrecision == .metadataOnly && !store.isRefreshing
        }

        XCTAssertFalse(store.snapshot.hasPreciseTokenUsage)
        XCTAssertTrue(store.status.contains("仅显示会话元数据"))
        XCTAssertTrue(store.status.contains("精确 token 仍在读取"))
        XCTAssertFalse(store.status.contains("token_count · 更新于"))
        XCTAssertFalse(UsageCacheLifecycle.isCurrentCachePrepared)
    }

    func testMetadataOnlyTokenDisplayUsesPendingMetricLabels() {
        let snapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "idle",
            rate: 0,
            consumedTokens: 0,
            todayTokens: 0,
            todayRequests: 0,
            usagePrecision: .metadataOnly,
            quota: .empty,
            updatedAt: Date(timeIntervalSince1970: 1_800)
        )

        XCTAssertFalse(snapshot.hasPreciseTokenUsage)
        XCTAssertEqual(snapshot.consumedTokensText, "待读取")
        XCTAssertEqual(snapshot.todayTokensText, "待读取")
        XCTAssertEqual(snapshot.todayRequestsText, "待读取")
        XCTAssertEqual(snapshot.metadataOnlyStatusText, "仅会话元数据")
    }

    func testRefreshFailurePreservesLastSuccessfulUsageSnapshot() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/.codex"),
            origin: .defaultHome
        )
        let successfulSnapshot = makeSnapshot(totalTokens: 12_345, dayTokens: 678)
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(.empty)],
            preciseResults: [
                .success(successfulSnapshot),
                .failure(UsageStoreTestError())
            ]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("successful usage refresh") {
            store.snapshot.stats.totalTokens == 12_345 && !store.isRefreshing
        }

        XCTAssertEqual(store.snapshot.stats.totalTokens, 12_345)
        XCTAssertEqual(store.snapshot.dailyUsage.reduce(0) { $0 + $1.tokens }, 678)

        store.refresh()
        await waitUntil("failed usage refresh") {
            store.status.hasPrefix("读取失败") && !store.isRefreshing
        }

        XCTAssertEqual(store.snapshot.stats.totalTokens, 12_345)
        XCTAssertEqual(store.snapshot.dailyUsage.reduce(0) { $0 + $1.tokens }, 678)
        XCTAssertFalse(store.snapshot.dailyUsage.isEmpty)
        XCTAssertTrue(store.status.contains("当前显示已陈旧"))

        let display = TokenDisplaySnapshot.make(
            store: store,
            monitor: LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false),
            quota: AccountQuotaStore(observesUserDefaults: false)
        )
        XCTAssertEqual(display.standaloneUsageStatus, "用量已陈旧")
    }

    func testFailureAfterSourceSwitchDoesNotRetainPreviousSourceSnapshot() async {
        let sourceA = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/failure-source-a/.codex"),
            origin: .userSelected
        )
        let sourceB = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/failure-source-b/.codex"),
            origin: .userSelected
        )
        let resolver = MutableCodexDataSourceResolver(source: sourceA)
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(.empty)],
            preciseResults: [
                .success(makeSnapshot(totalTokens: 12_345, dayTokens: 678)),
                .failure(UsageStoreTestError())
            ]
        )
        let store = CodexUsageStore(
            resolver: resolver,
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("source A usage snapshot") {
            store.snapshot.stats.totalTokens == 12_345 && !store.isRefreshing
        }

        resolver.source = sourceB
        store.refresh()
        await waitUntil("source B usage failure") {
            store.status.hasPrefix("读取失败") && !store.isRefreshing
        }

        XCTAssertEqual(store.currentDataSource, sourceB)
        XCTAssertEqual(store.snapshot.stats.totalTokens, 0)
        XCTAssertFalse(store.snapshot.hasPreciseTokenUsage)
        XCTAssertFalse(store.status.contains("当前显示已陈旧"))
    }

    func testInFlightRefreshFromOldSourceDoesNotOverwriteNewSourceSnapshot() async {
        let sourceA = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/source-a/.codex"),
            origin: .userSelected
        )
        let sourceB = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/source-b/.codex"),
            origin: .userSelected
        )
        let resolver = MutableCodexDataSourceResolver(source: sourceA)
        let loader = SuspendedDashboardSnapshotLoader()
        let store = CodexUsageStore(
            resolver: resolver,
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("old source precise request") {
            await loader.hasPendingPreciseRequest(for: sourceA)
        }

        resolver.source = sourceB
        store.refresh()
        await waitUntil("new source precise request") {
            await loader.hasPendingPreciseRequest(for: sourceB)
        }

        await loader.completePreciseRequest(for: sourceB, with: makeSnapshot(totalTokens: 22_000, dayTokens: 2_200))
        await waitUntil("new source snapshot published") {
            store.snapshot.stats.totalTokens == 22_000 && store.currentDataSource == sourceB
        }

        await loader.completePreciseRequest(for: sourceA, with: makeSnapshot(totalTokens: 11_000, dayTokens: 1_100))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.snapshot.stats.totalTokens, 22_000)
        XCTAssertEqual(store.currentDataSource, sourceB)
        XCTAssertFalse(store.status.contains(sourceA.displayPath))
    }

    private func makeSnapshot(
        totalTokens: Int,
        dayTokens: Int,
        usagePrecision: DashboardUsagePrecision = .precise
    ) -> DashboardSnapshot {
        let now = Date(timeIntervalSince1970: 1_800)
        return DashboardSnapshot(
            stats: DashboardStats(
                totalTokens: totalTokens,
                peakDayTokens: dayTokens,
                peakThreadTokens: 999,
                currentStreakDays: 1,
                longestStreakDays: 1,
                totalCalls: 3,
                totalThreads: 2,
                mostUsedReasoning: "中",
                skillsExplored: 0,
                totalSkillsUsed: 0
            ),
            dailyUsage: [DayUsage(date: now, tokens: dayTokens, calls: 3)],
            recentBins: [BinUsage(start: now, tokens: dayTokens, calls: 3)],
            hourlyUsage: [BinUsage(start: now, tokens: dayTokens, calls: 3)],
            pluginUsage: [],
            cacheUsage: .empty,
            usagePrecision: usagePrecision,
            generatedAt: now
        )
    }

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
}

private final class MutableCodexDataSourceResolver: CodexDataSourceResolving {
    var source: CodexDataSource?

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

private final class StaticCodexDataSourceResolver: CodexDataSourceResolving {
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

private actor SequentialDashboardSnapshotLoader: DashboardSnapshotLoading {
    private var fastResults: [Result<DashboardSnapshot, Error>]
    private var preciseResults: [Result<DashboardSnapshot, Error>]

    init(
        fastResults: [Result<DashboardSnapshot, Error>],
        preciseResults: [Result<DashboardSnapshot, Error>]
    ) {
        self.fastResults = fastResults
        self.preciseResults = preciseResults
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        try next(from: &fastResults)
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        try next(from: &preciseResults)
    }

    private func next(from results: inout [Result<DashboardSnapshot, Error>]) throws -> DashboardSnapshot {
        guard !results.isEmpty else {
            throw UsageStoreTestError()
        }
        return try results.removeFirst().get()
    }
}

private actor SuspendedDashboardSnapshotLoader: DashboardSnapshotLoading {
    private var preciseContinuations: [String: CheckedContinuation<DashboardSnapshot, Error>] = [:]

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        .empty
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            preciseContinuations[dataSource.codexHome.path] = continuation
        }
    }

    func hasPendingPreciseRequest(for dataSource: CodexDataSource) -> Bool {
        preciseContinuations[dataSource.codexHome.path] != nil
    }

    func completePreciseRequest(for dataSource: CodexDataSource, with snapshot: DashboardSnapshot) {
        preciseContinuations.removeValue(forKey: dataSource.codexHome.path)?.resume(returning: snapshot)
    }
}

private struct UsageStoreTestError: LocalizedError {
    var errorDescription: String? {
        "模拟用量读取失败"
    }
}

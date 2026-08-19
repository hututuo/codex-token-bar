import CoreServices
import Foundation
import SQLite3
import XCTest
@testable import CodexTokenBar

@MainActor
final class CodexUsageStoreTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
        UserDefaults.standard.removeObject(forKey: CodexUsageStore.preciseContinuityStorageKey)
        UserDefaults.standard.removeObject(forKey: CodexUsageStore.legacyPreciseContinuityStorageKey)
    }

    override func tearDownWithError() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
        UserDefaults.standard.removeObject(forKey: CodexUsageStore.preciseContinuityStorageKey)
        UserDefaults.standard.removeObject(forKey: CodexUsageStore.legacyPreciseContinuityStorageKey)
        try super.tearDownWithError()
    }

    func testObservationSessionRotatesOnlyWhenMonitoringResumes() {
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: nil),
            autoStart: false
        )
        let initial = store.preciseObservationSessionID

        store.setBackgroundActivityEnabled(false)
        XCTAssertEqual(store.preciseObservationSessionID, initial)
        store.setBackgroundActivityEnabled(true)
        let resumed = store.preciseObservationSessionID
        XCTAssertNotEqual(resumed, initial)
        store.setBackgroundActivityEnabled(true)
        XCTAssertEqual(store.preciseObservationSessionID, resumed)
    }

    func testObservationSessionRotatesAcrossHomeSwitchAndReturn() {
        let sourceA = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/observer-home-a/.codex"),
            origin: .userSelected
        )
        let sourceB = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/observer-home-b/.codex"),
            origin: .userSelected
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: sourceA),
            autoStart: false
        )
        let observationA = store.preciseObservationSessionID

        XCTAssertTrue(store.setDataSource(sourceB))
        let observationB = store.preciseObservationSessionID
        XCTAssertNotEqual(observationB, observationA)

        XCTAssertFalse(store.setDataSource(sourceB))
        XCTAssertEqual(store.preciseObservationSessionID, observationB)

        XCTAssertTrue(store.setDataSource(sourceA))
        XCTAssertNotEqual(store.preciseObservationSessionID, observationB)
        XCTAssertNotEqual(store.preciseObservationSessionID, observationA)
    }

    func testSessionMutationPolicyIgnoresAppendButCutsOverOnDestructiveOrDroppedEvents() {
        XCTAssertFalse(
            CodexSessionMutationEventPolicy.requiresContinuityCutover(
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            )
        )
        XCTAssertFalse(
            CodexSessionMutationEventPolicy.requiresContinuityCutover(
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            )
        )
        for flag in [
            kFSEventStreamEventFlagItemRemoved,
            kFSEventStreamEventFlagItemRenamed,
            kFSEventStreamEventFlagMustScanSubDirs,
            kFSEventStreamEventFlagUserDropped,
            kFSEventStreamEventFlagKernelDropped,
            kFSEventStreamEventFlagRootChanged,
        ] {
            XCTAssertTrue(
                CodexSessionMutationEventPolicy.requiresContinuityCutover(
                    flags: FSEventStreamEventFlags(flag)
                )
            )
        }
        let home = "/tmp/codex-token-bar-tests/canonical-home"
        XCTAssertTrue(
            CodexSessionMutationEventPolicy.requiresContinuityCutover(
                path: "\(home)/active-rollouts/2026/07/rollout.jsonl",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved),
                watchedRoots: [home]
            )
        )
        XCTAssertTrue(
            CodexSessionMutationEventPolicy.requiresContinuityCutover(
                path: "\(home)/custom/location/rollout.JSONL",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed),
                watchedRoots: [home]
            )
        )
        XCTAssertFalse(
            CodexSessionMutationEventPolicy.requiresContinuityCutover(
                path: "\(home)/active-rollouts/notes.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved),
                watchedRoots: [home]
            )
        )
        XCTAssertTrue(
            CodexSessionMutationEventPolicy.requiresContinuityCutover(
                path: "\(home)/active-rollouts/2026/07",
                flags: FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemRenamed
                        | kFSEventStreamEventFlagItemIsDir
                ),
                watchedRoots: [home]
            ),
            "renaming a directory may remove an entire JSONL subtree"
        )
        XCTAssertFalse(
            CodexSessionMutationEventPolicy.requiresContinuityCutover(
                path: "/tmp/outside-home/rollout.jsonl",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved),
                watchedRoots: [home]
            )
        )
    }

    func testSessionMutationMonitorObservesAnActiveRolloutOutsideSessionsRemovedBetweenPolls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexSessionMutationMonitorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let activeRolloutRoot = root
            .appendingPathComponent("active-rollouts", isDirectory: true)
            .appendingPathComponent("2026/07", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activeRolloutRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = SessionMutationEventProbe()
        let monitor = CodexSessionMutationMonitor()
        XCTAssertTrue(monitor.start(roots: [root]) { _ in
            probe.markObserved()
        })
        defer { monitor.stop() }
        let shortLived = activeRolloutRoot.appendingPathComponent("short-lived.jsonl")
        try Data("event\n".utf8).write(to: shortLived)
        // Still far shorter than the usage polling cadence, but long enough
        // for macOS to publish the create before the destructive file event.
        try await Task.sleep(nanoseconds: 150_000_000)
        try FileManager.default.removeItem(at: shortLived)

        await waitUntil("session deletion FSEvent") {
            probe.wasObserved
        }
    }

    func testSessionMutationMonitorObservesAnActiveRolloutRenameOutsideSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexSessionMutationRenameMonitorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let activeRolloutRoot = root
            .appendingPathComponent("active-rollouts", isDirectory: true)
            .appendingPathComponent("2026/07", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activeRolloutRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = activeRolloutRoot.appendingPathComponent("active.jsonl")
        let destination = activeRolloutRoot.appendingPathComponent("renamed.jsonl")
        try Data("event\n".utf8).write(to: source)
        let probe = SessionMutationEventProbe()
        let monitor = CodexSessionMutationMonitor()
        XCTAssertTrue(monitor.start(roots: [root]) { _ in
            probe.markObserved()
        })
        defer { monitor.stop() }

        try FileManager.default.moveItem(at: source, to: destination)
        await waitUntil("active rollout rename FSEvent") {
            probe.wasObserved
        }
    }

    func testNonOwnerProcessNeverRunsPreciseOrCompactExactMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexUsageStoreNonOwnerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("safety.sqlite")
        let ownerDatabase = SharedAccountUsageSafetyDatabase(
            url: databaseURL,
            claimsObserverOwnership: true
        )
        let nonOwnerDatabase = SharedAccountUsageSafetyDatabase(
            url: databaseURL,
            claimsObserverOwnership: true
        )
        XCTAssertTrue(ownerDatabase.isObserverOwner)
        XCTAssertFalse(nonOwnerDatabase.isObserverOwner)
        let source = CodexDataSource(
            codexHome: directory.appendingPathComponent("home", isDirectory: true),
            origin: .defaultHome
        )
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(makeSnapshot(totalTokens: 321, dayTokens: 12))],
            preciseResults: [.failure(UsageStoreTestError())]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false,
            continuitySafetyDatabase: nonOwnerDatabase
        )

        store.refresh()
        await waitUntil("non-owner fast-only refresh") {
            store.snapshot.stats.totalTokens == 321 && !store.isRefreshing
        }

        XCTAssertNil(store.preciseTimeSeriesContinuityLossID)
        XCTAssertFalse(store.preciseTimeSeriesFresh)
        XCTAssertEqual(store.snapshot.stats.totalTokens, 321)
    }

    func testNonOwnerRetriesTakeoverDuringInflightRefreshAndForcesSafeRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexUsageStoreObserverTakeoverTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("safety.sqlite")
        var ownerDatabase: SharedAccountUsageSafetyDatabase? = SharedAccountUsageSafetyDatabase(
            url: databaseURL,
            claimsObserverOwnership: true
        )
        let takeoverDatabase = SharedAccountUsageSafetyDatabase(
            url: databaseURL,
            claimsObserverOwnership: true
        )
        XCTAssertTrue(ownerDatabase?.isObserverOwner == true)
        XCTAssertFalse(takeoverDatabase.isObserverOwner)

        let source = CodexDataSource(codexHome: home, origin: .defaultHome)
        let coverageAt = Date(timeIntervalSince1970: 3_000)
        let loader = ObserverTakeoverProbeLoader(
            preciseSnapshot: makeSnapshot(
                totalTokens: 777,
                dayTokens: 77,
                preciseTimeSeriesGeneratedAt: coverageAt
            )
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false,
            continuitySafetyDatabase: takeoverDatabase
        )
        let initialObservationSessionID = store.preciseObservationSessionID

        // As non-owner this begins a fast-only read and remains in flight.
        store.refresh()
        await waitUntil("non-owner fast read in flight") {
            await loader.fastLoadCount == 1 && store.isRefreshing
        }
        ownerDatabase = nil

        // A normal retry now acquires ownership. It must not disappear through
        // the in-flight early-return path: the old read is cancelled and a
        // synthetic gap + watcher + full precise scan are established.
        store.refresh()
        await waitUntil("observer takeover precise recovery") {
            takeoverDatabase.isObserverOwner
                && store.snapshot.stats.totalTokens == 777
                && !store.isRefreshing
        }

        XCTAssertNotEqual(store.preciseObservationSessionID, initialObservationSessionID)
        XCTAssertEqual(store.preciseTimeSeriesContinuityLossReason, .observerTakeover)
        XCTAssertNotNil(store.preciseTimeSeriesContinuityLossID)
        XCTAssertTrue(store.preciseSessionMutationMonitoringHealthy)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        let preciseLoadCount = await loader.preciseLoadCount
        XCTAssertEqual(preciseLoadCount, 1)
    }

    func testDurableCutoverAcknowledgementUsesObservedGenerationThenForcesSafeScan() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/attribution-ack/.codex"),
            origin: .defaultHome
        )
        let unsafe = makeSnapshot(
            totalTokens: 1_000,
            dayTokens: 100,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 2_000),
            attributionProvenanceEpoch: "unsafe-epoch",
            attributionGeneration: 12,
            attributionUnsafeSinceGeneration: 9,
            attributionSourceMutationDetected: true
        )
        let safe = makeSnapshot(
            totalTokens: 1_200,
            dayTokens: 120,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 2_300),
            attributionProvenanceEpoch: "unsafe-epoch",
            attributionGeneration: 14,
            attributionUnsafeSinceGeneration: nil,
            attributionSourceMutationDetected: false
        )
        let loader = AttributionSafetyAckProbeLoader(
            preciseResults: [unsafe, safe]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("unsafe attribution snapshot") {
            store.snapshot.cacheUsage.attributionUnsafeSinceGeneration == 9
                && !store.isRefreshing
        }
        store.acknowledgeAttributionSafetyAfterDurableCutover(
            provenanceEpoch: "unsafe-epoch",
            throughGeneration: 12
        )
        await waitUntil("post-ack safe precise scan") {
            store.snapshot.cacheUsage.attributionGeneration == 14
                && store.snapshot.cacheUsage.attributionUnsafeSinceGeneration == nil
                && !store.isRefreshing
        }

        let calls = await loader.acknowledgements
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.epoch, "unsafe-epoch")
        XCTAssertEqual(calls.first?.generation, 12)
    }

    func testPersistentAttributionAmbiguityDoesNotAcknowledgeOrForceRefreshLoop() async {
        let source = CodexDataSource(
            codexHome: URL(
                fileURLWithPath: "/tmp/codex-token-bar-tests/attribution-persistent-ambiguity/.codex"
            ),
            origin: .defaultHome
        )
        let ambiguous = makeSnapshot(
            totalTokens: 1_000,
            dayTokens: 100,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 2_000),
            attributionProvenanceEpoch: "ambiguous-epoch",
            attributionGeneration: 12,
            attributionUnsafeSinceGeneration: 9,
            attributionCurrentScanUnsafeCauseDetected: true,
            attributionSourceMutationDetected: true
        )
        let loader = AttributionSafetyAckProbeLoader(preciseResults: [ambiguous])
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("persistent attribution ambiguity") {
            store.snapshot.cacheUsage.attributionCurrentScanUnsafeCauseDetected
                && !store.isRefreshing
        }
        store.acknowledgeAttributionSafetyAfterDurableCutover(
            provenanceEpoch: "ambiguous-epoch",
            throughGeneration: 12
        )
        for _ in 0..<10 { await Task.yield() }

        let acknowledgements = await loader.acknowledgements
        let preciseLoadCount = await loader.preciseLoadCount
        XCTAssertEqual(acknowledgements.count, 0)
        XCTAssertEqual(preciseLoadCount, 1)
        XCTAssertEqual(store.snapshot.cacheUsage.attributionGeneration, 12)
    }

    func testVisibleAndBackgroundAggregationUseExplicitSettingsWithoutLiveAcceleration() {
        let settings = UsageRefreshCadenceSettings()

        XCTAssertEqual(
            UsageRefreshCadencePolicy.aggregateInterval(
                mainDashboardVisible: true,
                settings: settings
            ),
            5 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            UsageRefreshCadencePolicy.aggregateInterval(
                mainDashboardVisible: false,
                settings: settings
            ),
            30 * 60,
            accuracy: 0.001
        )
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

    func testAttributionCatchUpWaitsForDetailHydrationToFinish() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardView = projectRoot.appendingPathComponent(
            "Sources/CodexTokenBar/DashboardView.swift"
        )
        let source = try String(contentsOf: dashboardView, encoding: .utf8)

        XCTAssertTrue(
            source.contains("!store.isUsageRefreshOrDetailHydrationActive")
        )
        XCTAssertFalse(
            source.contains("sharedAccountAttributionEnabled,\n           !store.isRefreshing")
        )
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
        let stateURL = stateRoot.appendingPathComponent("cache-state.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        let initialData = try Data(contentsOf: stateURL)
        let initialAttributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)

        UsageCacheLifecycle.markCurrentCachePrepared()

        XCTAssertEqual(try Data(contentsOf: stateURL), initialData)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: stateURL.path)[.systemFileNumber] as? NSNumber,
            initialAttributes[.systemFileNumber] as? NSNumber,
            "an already-current cache marker must not be atomically rewritten"
        )
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

    func testTransientSQLiteFailureAutomaticallyClearsStaleStatus() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/transient-state-recovery/.codex"),
            origin: .defaultHome
        )
        let recovered = makeSnapshot(totalTokens: 98_765, dayTokens: 432)
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(.empty)],
            preciseResults: [
                .failure(SQLiteDatabaseError(
                    operation: "Prepare SQLite query",
                    code: SQLITE_IOERR,
                    message: "disk I/O error",
                    path: source.stateDatabase.path
                )),
                .success(recovered),
            ]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false,
            transientDatabaseRecoveryDelay: 0.05
        )

        store.refresh()
        await waitUntil("automatic transient SQLite recovery") {
            store.snapshot.stats.totalTokens == 98_765 && !store.isRefreshing
        }

        XCTAssertFalse(store.status.hasPrefix("读取失败"))
        XCTAssertFalse(store.status.contains("当前显示已陈旧"))
        XCTAssertTrue(store.status.contains("token_count"))
    }

    func testPersistentTransientSQLiteFailureStopsAfterBoundedRecoveryEpisode() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/bounded-state-recovery/.codex"),
            origin: .defaultHome
        )
        let failures: [Result<DashboardSnapshot, Error>] = (0..<6).map { _ in
            .failure(SQLiteDatabaseError(
                operation: "Prepare SQLite query",
                code: SQLITE_IOERR,
                message: "disk I/O error",
                path: source.stateDatabase.path
            ))
        }
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(.empty)],
            preciseResults: failures
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false,
            transientDatabaseRecoveryDelay: 0.05
        )

        store.refresh()
        await waitUntil("bounded transient SQLite recovery episode", timeout: 3) {
            await loader.preciseRequestCount() == 6 && !store.isRefreshing
        }
        let lossID = store.preciseTimeSeriesContinuityLossID
        try? await Task.sleep(nanoseconds: 300_000_000)
        let finalRequestCount = await loader.preciseRequestCount()

        XCTAssertEqual(finalRequestCount, 6)
        XCTAssertEqual(store.preciseTimeSeriesContinuityLossID, lossID)
        XCTAssertTrue(store.status.hasPrefix("读取失败"))
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

    func testIncompletePreciseSnapshotIsNotClassifiedAsMissingJSONL() {
        let numericOnly = makeSnapshot(
            totalTokens: 12_000,
            dayTokens: 1_200,
            usagePrecision: .precise,
            attributionEventsComplete: false
        )
        let metadataOnly = makeSnapshot(
            totalTokens: 0,
            dayTokens: 0,
            usagePrecision: .metadataOnly,
            attributionEventsComplete: false
        )

        XCTAssertEqual(
            PreciseSnapshotClassification(snapshot: numericOnly),
            .numericOnly
        )
        XCTAssertEqual(
            PreciseSnapshotClassification(snapshot: metadataOnly),
            .metadataOnly
        )
    }

    func testPreciseResultNeverUsesAHistoryGuardStatus() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/unbounded-precise/.codex"),
            origin: .userSelected
        )
        let preciseSnapshot = makeSnapshot(
            totalTokens: 12_345,
            dayTokens: 678,
            usagePrecision: .precise
        )
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(preciseSnapshot)],
            preciseResults: [.success(preciseSnapshot)]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("unbounded precise usage refresh") {
            store.snapshot.usagePrecision == .precise && !store.isRefreshing
        }

        XCTAssertTrue(store.snapshot.hasPreciseTokenUsage)
        XCTAssertEqual(store.snapshot.stats.totalTokens, 12_345)
        XCTAssertFalse(store.status.contains("安全上限"), store.status)
        XCTAssertFalse(store.status.contains("扫描受限"), store.status)
        XCTAssertFalse(store.status.contains("精确 token 仍在读取"), store.status)
    }

    func testFullPreciseRefreshPublishesNumericThenFinalPhaseExactlyOnce() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/phased-publication/.codex"),
            origin: .defaultHome
        )
        let numeric = makeSnapshot(
            totalTokens: 1_000,
            dayTokens: 100,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 2_500),
            attributionEventsComplete: false
        )
        let final = makeSnapshot(
            totalTokens: 1_200,
            dayTokens: 120,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 3_000),
            attributionEventsComplete: true
        )
        let loader = BarrierPhasedDashboardSnapshotLoader(
            numeric: numeric,
            final: final
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )
        let numericPublished = expectation(description: "numeric phase published")
        let finalPublished = expectation(description: "final phase published")
        var publishedTokens: [Int] = []
        let cancellable = store.$snapshot.sink { snapshot in
            guard snapshot.stats.totalTokens > 0 else { return }
            publishedTokens.append(snapshot.stats.totalTokens)
            if snapshot.stats.totalTokens == numeric.stats.totalTokens {
                numericPublished.fulfill()
            }
            if snapshot.stats.totalTokens == final.stats.totalTokens {
                finalPublished.fulfill()
            }
        }
        defer { cancellable.cancel() }

        store.refresh()
        await loader.waitUntilPhaseRequestStarted()
        await loader.yieldNumeric()
        await fulfillment(of: [numericPublished], timeout: 1)
        await waitUntilYielding("numeric refresh lifecycle released") {
            !store.isRefreshing
        }
        XCTAssertEqual(store.snapshot.stats.totalTokens, numeric.stats.totalTokens)
        XCTAssertFalse(store.snapshot.cacheUsage.attributionEventsComplete)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertTrue(store.isDetailHydrating)
        XCTAssertTrue(store.isUsageRefreshOrDetailHydrationActive)
        let phaseLoadCountAfterNumeric = await loader.phasedLoadCountValue()
        XCTAssertEqual(phaseLoadCountAfterNumeric, 1)

        await loader.yieldFinal()
        await fulfillment(of: [finalPublished], timeout: 1)
        await waitUntilYielding("final refresh cleanup") {
            !store.isRefreshing
        }
        XCTAssertEqual(store.snapshot.stats.totalTokens, final.stats.totalTokens)
        XCTAssertTrue(store.snapshot.cacheUsage.attributionEventsComplete)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertFalse(store.isDetailHydrating)
        XCTAssertFalse(store.isCompactSummaryPending)
        XCTAssertFalse(store.isUsageRefreshOrDetailHydrationActive)
        XCTAssertEqual(publishedTokens, [numeric.stats.totalTokens, final.stats.totalTokens])
        let phaseLoadCountAfterFinal = await loader.phasedLoadCountValue()
        XCTAssertEqual(phaseLoadCountAfterFinal, 1)
    }

    func testNumericPhaseRemainsDisplayableWhenFinalPrecisePhaseFails() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/phased-failure/.codex"),
            origin: .defaultHome
        )
        let numeric = makeSnapshot(
            totalTokens: 2_000,
            dayTokens: 200,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 3_500),
            attributionEventsComplete: false
        )
        let loader = BarrierPhasedDashboardSnapshotLoader(
            numeric: numeric,
            final: nil
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )
        let numericPublished = expectation(description: "numeric phase published")
        let cancellable = store.$snapshot.sink { snapshot in
            if snapshot.stats.totalTokens == numeric.stats.totalTokens {
                numericPublished.fulfill()
            }
        }
        defer { cancellable.cancel() }

        store.refresh()
        await loader.waitUntilPhaseRequestStarted()
        await loader.yieldNumeric()
        await fulfillment(of: [numericPublished], timeout: 1)
        await waitUntilYielding("numeric lifecycle before detail failure") {
            !store.isRefreshing && store.isDetailHydrating
        }
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        XCTAssertTrue(store.isUsageRefreshOrDetailHydrationActive)
        await loader.yieldFinal()
        await waitUntilYielding("failed final phase") {
            !store.isRefreshing && store.status.contains("会话明细暂不可用")
        }

        XCTAssertEqual(store.snapshot.stats.totalTokens, numeric.stats.totalTokens)
        XCTAssertFalse(store.snapshot.cacheUsage.attributionEventsComplete)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        XCTAssertFalse(store.isDetailHydrating)
        XCTAssertFalse(store.isCompactSummaryPending)
        XCTAssertFalse(store.isUsageRefreshOrDetailHydrationActive)
        XCTAssertTrue(store.status.contains("数值已更新"), store.status)
        XCTAssertFalse(store.status.contains("读取失败"), store.status)
        XCTAssertFalse(store.status.contains("当前显示已陈旧"), store.status)
    }

    func testCompatibleLastGoodFastSnapshotStaysNumericAndMarkedRefreshing() async {
        let source = CodexDataSource(
            codexHome: URL(
                fileURLWithPath: "/tmp/codex-token-bar-tests/stale-compatible-fast/.codex"
            ),
            origin: .defaultHome
        )
        let lastGood = makeSnapshot(
            totalTokens: 42_000,
            dayTokens: 4_200,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 4_000)
        )
        let loader = SuspendedDashboardSnapshotLoader(
            fastResult: DashboardFastSnapshotResult(
                snapshot: lastGood,
                freshness: .staleCompatible
            )
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("stale-compatible fast snapshot") {
            await loader.hasPendingPreciseRequest(for: source)
                && store.snapshot.stats.totalTokens == 42_000
        }

        XCTAssertTrue(store.snapshot.hasPreciseTokenUsage)
        XCTAssertFalse(store.preciseTimeSeriesFresh)
        XCTAssertFalse(store.isCompactSummaryPending)
        XCTAssertTrue(store.status.contains("正在核对上次精确数据"), store.status)
        XCTAssertTrue(store.status.contains("保留旧值"), store.status)
        XCTAssertFalse(store.status.contains("用量已陈旧"), store.status)
        XCTAssertFalse(store.status.contains("仅显示会话元数据"), store.status)
        store.setBackgroundActivityEnabled(false)
    }

    func testCurrentPreciseRefreshPreservesFreshnessWithoutStaleStatus() async {
        let source = CodexDataSource(
            codexHome: URL(
                fileURLWithPath: "/tmp/codex-token-bar-tests/current-refresh-fresh/.codex"
            ),
            origin: .defaultHome
        )
        let current = makeSnapshot(
            totalTokens: 45_000,
            dayTokens: 4_500,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 4_500),
            attributionEventsComplete: true
        )
        let loader = MultiRequestPhasedDashboardSnapshotLoader()
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await loader.waitUntilRequestCount(1)
        await loader.yield(current, request: 0)
        await loader.finish(request: 0)
        await waitUntilYielding("current precise baseline") {
            store.preciseTimeSeriesFresh
                && !store.isUsageRefreshOrDetailHydrationActive
        }

        store.refresh()
        await loader.waitUntilRequestCount(2)

        XCTAssertTrue(store.isRefreshing)
        XCTAssertFalse(store.isDetailHydrating)
        XCTAssertTrue(store.isUsageRefreshOrDetailHydrationActive)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        XCTAssertTrue(store.status.contains("正在增量更新 token"), store.status)
        XCTAssertFalse(store.status.contains("用量已陈旧"), store.status)
        store.setBackgroundActivityEnabled(false)
        XCTAssertFalse(store.isUsageRefreshOrDetailHydrationActive)
    }

    func testActiveAppendStartsNextNumericFlightBeforeEarlierDetailCompletes() async {
        let source = CodexDataSource(
            codexHome: URL(
                fileURLWithPath: "/tmp/codex-token-bar-tests/phased-active-append/.codex"
            ),
            origin: .defaultHome
        )
        let firstNumeric = makeSnapshot(
            totalTokens: 51_377,
            dayTokens: 1_075,
            totalCalls: 7_062,
            dayCalls: 7_062,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 10_000),
            attributionEventsComplete: false
        )
        let secondNumeric = makeSnapshot(
            totalTokens: 51_418,
            dayTokens: 1_115,
            totalCalls: 7_361,
            dayCalls: 7_361,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 10_240),
            attributionEventsComplete: false
        )
        let secondFinal = makeSnapshot(
            totalTokens: 51_418,
            dayTokens: 1_115,
            totalCalls: 7_361,
            dayCalls: 7_361,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 10_240),
            attributionEventsComplete: true
        )
        let loader = MultiRequestPhasedDashboardSnapshotLoader()
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await loader.waitUntilRequestCount(1)
        await loader.yield(firstNumeric, request: 0)
        await waitUntilYielding("first numeric completion") {
            store.snapshot.stats.totalTokens == firstNumeric.stats.totalTokens
                && !store.isRefreshing
                && store.isDetailHydrating
        }
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        XCTAssertTrue(store.isUsageRefreshOrDetailHydrationActive)

        // The first request still has no final/detail phase. A dirty/manual
        // refresh must nevertheless create the next numeric owner.
        store.refresh()
        await loader.waitUntilRequestCount(2)
        await loader.yield(secondNumeric, request: 1)
        await waitUntilYielding("active append numeric catch-up") {
            store.snapshot.stats.totalTokens == secondNumeric.stats.totalTokens
                && !store.isRefreshing
                && store.isDetailHydrating
        }

        XCTAssertEqual(store.snapshot.stats.totalTokens, 51_418)
        XCTAssertEqual(store.snapshot.stats.totalCalls, 7_361)
        XCTAssertEqual(store.snapshot.dailyUsage.reduce(0) { $0 + $1.tokens }, 1_115)
        XCTAssertEqual(store.snapshot.dailyUsage.reduce(0) { $0 + $1.calls }, 7_361)
        XCTAssertFalse(store.snapshot.cacheUsage.attributionEventsComplete)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        XCTAssertTrue(store.status.contains("正在补齐会话明细"), store.status)

        await loader.yield(secondFinal, request: 1)
        await loader.finish(request: 1)
        await waitUntilYielding("second detail completion") {
            store.snapshot.cacheUsage.attributionEventsComplete
                && !store.isUsageRefreshOrDetailHydrationActive
        }
        XCTAssertEqual(store.snapshot.stats.totalTokens, secondNumeric.stats.totalTokens)
        XCTAssertEqual(store.snapshot.stats.totalCalls, secondNumeric.stats.totalCalls)
    }

    func testAutomaticRefreshDoesNotCancelActiveDetailHydration() async {
        let source = CodexDataSource(
            codexHome: URL(
                fileURLWithPath: "/tmp/codex-token-bar-tests/automatic-detail-coalescing/.codex"
            ),
            origin: .defaultHome
        )
        let numeric = makeSnapshot(
            totalTokens: 61_000,
            dayTokens: 6_100,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 12_000),
            attributionEventsComplete: false
        )
        let final = makeSnapshot(
            totalTokens: 61_000,
            dayTokens: 6_100,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 12_000),
            attributionEventsComplete: true
        )
        let loader = MultiRequestPhasedDashboardSnapshotLoader()
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await loader.waitUntilRequestCount(1)
        await loader.yield(numeric, request: 0)
        await waitUntilYielding("automatic coalescing detail phase") {
            store.snapshot.stats.totalTokens == numeric.stats.totalTokens
                && !store.isRefreshing
                && store.isDetailHydrating
        }

        store.requestAutomaticRefreshForTesting()
        await Task.yield()
        let requestCountAfterAutomaticRefresh = await loader.requestCountValue()
        XCTAssertEqual(requestCountAfterAutomaticRefresh, 1)
        XCTAssertTrue(store.isDetailHydrating)
        XCTAssertTrue(store.status.contains("正在补齐会话明细"), store.status)

        await loader.yield(final, request: 0)
        await loader.finish(request: 0)
        await waitUntilYielding("automatic coalescing final phase") {
            store.snapshot.cacheUsage.attributionEventsComplete
                && !store.isUsageRefreshOrDetailHydrationActive
        }
        let requestCountAfterCompletion = await loader.requestCountValue()
        XCTAssertEqual(requestCountAfterCompletion, 1)
    }

    func testStartupPreciseOwnerCoalescesAttributionIntentBeforeOwnerStarts() async {
        let source = CodexDataSource(
            codexHome: URL(
                fileURLWithPath: "/tmp/codex-token-bar-tests/startup-attribution-coalescing/.codex"
            ),
            origin: .defaultHome
        )
        let final = makeSnapshot(
            totalTokens: 62_000,
            dayTokens: 6_200,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 12_500),
            attributionEventsComplete: true
        )
        let loader = MultiRequestPhasedDashboardSnapshotLoader()
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.prepareInitialPreciseRefreshWindowForTesting()
        store.requestAutomaticRefreshForTesting()
        await Task.yield()
        let requestCountBeforeStartupOwner = await loader.requestCountValue()
        XCTAssertEqual(requestCountBeforeStartupOwner, 0)

        store.requestInitialPreciseRefreshForTesting()
        await loader.waitUntilRequestCount(1)
        await loader.yield(final, request: 0)
        await loader.finish(request: 0)
        await waitUntilYielding("coalesced startup precise owner") {
            store.snapshot.stats.totalTokens == final.stats.totalTokens
                && !store.isUsageRefreshOrDetailHydrationActive
        }

        let requestCountAfterStartupOwner = await loader.requestCountValue()
        XCTAssertEqual(requestCountAfterStartupOwner, 1)
    }

    func testStartupPreciseOwnerFailureGetsOneBoundedCompensationPass() async {
        let source = CodexDataSource(
            codexHome: URL(
                fileURLWithPath: "/tmp/codex-token-bar-tests/startup-attribution-failure/.codex"
            ),
            origin: .defaultHome
        )
        let recovered = makeSnapshot(
            totalTokens: 63_000,
            dayTokens: 6_300,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 12_600),
            attributionEventsComplete: true
        )
        let loader = MultiRequestPhasedDashboardSnapshotLoader()
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.prepareInitialPreciseRefreshWindowForTesting()
        store.requestAutomaticRefreshForTesting()
        store.requestInitialPreciseRefreshForTesting()
        await loader.waitUntilRequestCount(1)
        await loader.fail(request: 0)

        await loader.waitUntilRequestCount(2)
        await loader.yield(recovered, request: 1)
        await loader.finish(request: 1)
        await waitUntilYielding("bounded startup compensation") {
            store.snapshot.stats.totalTokens == recovered.stats.totalTokens
                && !store.isUsageRefreshOrDetailHydrationActive
        }

        let requestCountAfterCompensation = await loader.requestCountValue()
        XCTAssertEqual(requestCountAfterCompensation, 2)
    }

    func testDashboardExpansionWaitsForActiveDetailHydrationWithoutSecondNumericOwner() async {
        let source = CodexDataSource(
            codexHome: URL(
                fileURLWithPath: "/tmp/codex-token-bar-tests/expand-during-detail/.codex"
            ),
            origin: .defaultHome
        )
        let numeric = makeSnapshot(
            totalTokens: 64_000,
            dayTokens: 6_400,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 12_700),
            attributionEventsComplete: false
        )
        let final = makeSnapshot(
            totalTokens: 64_000,
            dayTokens: 6_400,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 12_700),
            attributionEventsComplete: true
        )
        let loader = MultiRequestPhasedDashboardSnapshotLoader()
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await loader.waitUntilRequestCount(1)
        await loader.yield(numeric, request: 0)
        await waitUntilYielding("numeric phase before dashboard expansion") {
            store.isDetailHydrating && !store.isRefreshing
        }

        store.setOnlyCompactSurfaceVisible(true)
        store.setOnlyCompactSurfaceVisible(false)
        await Task.yield()
        let requestCountDuringDetailHydration = await loader.requestCountValue()
        XCTAssertEqual(requestCountDuringDetailHydration, 1)
        XCTAssertTrue(store.isDetailHydrating)

        await loader.yield(final, request: 0)
        await loader.finish(request: 0)
        await waitUntilYielding("detail hydration after dashboard expansion") {
            store.snapshot.cacheUsage.attributionEventsComplete
                && !store.isUsageRefreshOrDetailHydrationActive
        }
        let requestCountAfterDetailHydration = await loader.requestCountValue()
        XCTAssertEqual(requestCountAfterDetailHydration, 1)
    }

    func testStalePrecisePhaseCannotPublishAfterSourceBindingChanges() async {
        let sourceA = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/phased-stale-a/.codex"),
            origin: .defaultHome
        )
        let sourceB = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/phased-stale-b/.codex"),
            origin: .defaultHome
        )
        let resolver = MutableCodexDataSourceResolver(source: sourceA)
        let numericA = makeSnapshot(
            totalTokens: 3_000,
            dayTokens: 300,
            preciseTimeSeriesGeneratedAt: nil,
            attributionEventsComplete: false
        )
        let finalB = makeSnapshot(
            totalTokens: 4_000,
            dayTokens: 400,
            preciseTimeSeriesGeneratedAt: Date(timeIntervalSince1970: 4_000),
            attributionEventsComplete: true
        )
        let loader = ControlledPhasedDashboardSnapshotLoader(
            numericBySource: [sourceA.codexHome.path: numericA],
            finalBySource: [sourceB.codexHome.path: finalB]
        )
        let store = CodexUsageStore(
            resolver: resolver,
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await loader.waitUntilPending(source: sourceA)
        resolver.source = sourceB
        store.refresh()
        await loader.waitUntilPending(source: sourceB)
        await loader.yieldFinal(source: sourceB)
        await waitUntilYielding("source B final phase") {
            store.snapshot.stats.totalTokens == finalB.stats.totalTokens
                && !store.isRefreshing
        }

        // The cancelled source-A stream may still deliver its queued value;
        // the store must reject it by generation and source binding.
        await loader.yieldNumeric(source: sourceA)
        await loader.yieldFinal(source: sourceA)
        await Task.yield()
        XCTAssertEqual(store.snapshot.stats.totalTokens, finalB.stats.totalTokens)
        XCTAssertEqual(store.currentDataSource, sourceB)
    }

    func testSameSourceMetadataOnlyRefreshRetainsPreciseValuesAndMarksThemStale() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/same-source-metadata/.codex"),
            origin: .userSelected
        )
        let now = Date()
        let preciseSnapshot = makeSnapshot(totalTokens: 12_345, dayTokens: 678, generatedAt: now)
        let metadataOnlySnapshot = makeSnapshot(
            totalTokens: 0,
            dayTokens: 0,
            usagePrecision: .metadataOnly,
            generatedAt: now
        )
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(.empty)],
            preciseResults: [.success(preciseSnapshot), .success(metadataOnlySnapshot)]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("same-source precise snapshot") {
            store.snapshot.stats.totalTokens == 12_345 && !store.isRefreshing
        }
        let sourceBeforeMetadataRefresh = store.currentDataSource

        store.refresh()
        await waitUntil("same-source metadata-only refresh") {
            !store.isRefreshing
        }

        XCTAssertEqual(store.currentDataSource, sourceBeforeMetadataRefresh)
        XCTAssertEqual(store.snapshot.stats.totalTokens, 12_345)
        XCTAssertEqual(store.snapshot.dailyUsage.reduce(0) { $0 + $1.tokens }, 678)
        XCTAssertTrue(store.snapshot.hasPreciseTokenUsage)
        XCTAssertTrue(store.status.contains("用量已陈旧"), store.status)
        XCTAssertTrue(store.status.contains("仅元数据"), store.status)

        let display = TokenDisplaySnapshot.make(
            store: store,
            monitor: LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false),
            quota: AccountQuotaStore(observesUserDefaults: false)
        )
        XCTAssertEqual(display.consumedTokensText, 12_345.abbreviatedTokens)
        XCTAssertEqual(display.todayTokensText, 678.abbreviatedTokens)
        XCTAssertEqual(display.todayRequestsText, "3")
        XCTAssertEqual(display.standaloneUsageStatus, "用量已陈旧")

        let dashboardStatus = StatStripStatusLinePresentation(
            hasPreciseTokenUsage: store.snapshot.hasPreciseTokenUsage,
            isPreparingUsageCache: false,
            cacheStatus: store.status
        )
        XCTAssertEqual(dashboardStatus?.text.contains("用量已陈旧"), true)
        XCTAssertEqual(dashboardStatus?.showsProgress, false)
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
        XCTAssertFalse(store.isCompactSummaryPending)
        XCTAssertTrue(store.status.contains("当前显示已陈旧"))

        let display = TokenDisplaySnapshot.make(
            store: store,
            monitor: LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false),
            quota: AccountQuotaStore(observesUserDefaults: false)
        )
        XCTAssertEqual(display.standaloneUsageStatus, "用量已陈旧")
    }

    func testExactReadFailurePersistsContinuityLossUntilSafeCutoverAcknowledgesIt() async {
        let suiteName = "CodexUsageStoreContinuityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "continuity-loss-test"
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/continuity/.codex"),
            origin: .defaultHome
        )
        let firstCoverage = Date(timeIntervalSince1970: 1_800)
        let recoveredCoverage = Date(timeIntervalSince1970: 2_100)
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(.empty)],
            preciseResults: [
                .success(makeSnapshot(
                    totalTokens: 1_000,
                    dayTokens: 100,
                    preciseTimeSeriesGeneratedAt: firstCoverage
                )),
                .failure(UsageStoreTestError()),
                .success(makeSnapshot(
                    totalTokens: 1_200,
                    dayTokens: 120,
                    preciseTimeSeriesGeneratedAt: recoveredCoverage
                )),
            ]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false,
            continuityDefaults: defaults,
            continuityStorageKey: storageKey
        )

        store.refresh()
        await waitUntil("continuity initial precise read") {
            store.snapshot.preciseTimeSeriesGeneratedAt == firstCoverage && !store.isRefreshing
        }
        XCTAssertNil(store.preciseTimeSeriesContinuityLostAt)

        store.refresh()
        await waitUntil("continuity exact read failure") {
            store.preciseTimeSeriesContinuityLostAt != nil && !store.isRefreshing
        }
        let loss = store.preciseTimeSeriesContinuityLostAt
        let lossID = store.preciseTimeSeriesContinuityLossID
        XCTAssertTrue(store.preciseContinuityPersistenceHealthy)

        let reloaded = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false,
            continuityDefaults: defaults,
            continuityStorageKey: storageKey
        )
        XCTAssertEqual(reloaded.preciseTimeSeriesContinuityLostAt, loss)
        XCTAssertEqual(reloaded.preciseTimeSeriesContinuityLossID, lossID)

        store.refresh()
        await waitUntil("continuity exact read recovery") {
            store.snapshot.preciseTimeSeriesGeneratedAt == recoveredCoverage && !store.isRefreshing
        }
        XCTAssertEqual(store.preciseTimeSeriesContinuityLostAt, loss)

        store.acknowledgePreciseTimeSeriesContinuityLoss(id: try! XCTUnwrap(lossID))
        XCTAssertNil(store.preciseTimeSeriesContinuityLostAt)
        XCTAssertNil(store.preciseTimeSeriesContinuityLossID)
        XCTAssertNil(
            CodexUsageStore(
                resolver: StaticCodexDataSourceResolver(source: source),
                snapshotLoader: loader,
                autoStart: false,
                continuityDefaults: defaults,
                continuityStorageKey: storageKey
            ).preciseTimeSeriesContinuityLostAt
        )
    }

    func testProductionSafetyDatabaseMigratesAndAtomicallyAcknowledgesContinuityLoss() throws {
        let suiteName = "CodexUsageStoreSafetyContinuityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexUsageStoreSafetyContinuityTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("safety.sqlite")
        let database = SharedAccountUsageSafetyDatabase(url: databaseURL)
        let storageKey = "continuity-safety-migration-test"
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/safety-continuity/.codex"),
            origin: .defaultHome
        )
        let loss = PreciseTimeSeriesContinuityLossRecord(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 2_400)
        )
        defaults.set(
            try JSONEncoder().encode([
                CodexUsageStore.continuityIdentifier(for: source): loss,
            ]),
            forKey: storageKey
        )

        let migrated = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: SequentialDashboardSnapshotLoader(fastResults: [], preciseResults: []),
            autoStart: false,
            continuityDefaults: defaults,
            continuityStorageKey: storageKey,
            legacyContinuityStorageKey: nil,
            continuitySafetyDatabase: database
        )
        XCTAssertEqual(migrated.preciseTimeSeriesContinuityLossID, loss.id)
        XCTAssertEqual(migrated.preciseTimeSeriesContinuityLostAt, loss.detectedAt)
        XCTAssertTrue(migrated.preciseContinuityPersistenceHealthy)

        defaults.removePersistentDomain(forName: suiteName)
        let reloaded = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: SequentialDashboardSnapshotLoader(fastResults: [], preciseResults: []),
            autoStart: false,
            continuityDefaults: defaults,
            continuityStorageKey: storageKey,
            legacyContinuityStorageKey: nil,
            continuitySafetyDatabase: SharedAccountUsageSafetyDatabase(url: databaseURL)
        )
        XCTAssertEqual(reloaded.preciseTimeSeriesContinuityLossID, loss.id)

        reloaded.acknowledgePreciseTimeSeriesContinuityLoss(id: loss.id)
        XCTAssertNil(reloaded.preciseTimeSeriesContinuityLossID)
        XCTAssertNil(
            CodexUsageStore(
                resolver: StaticCodexDataSourceResolver(source: source),
                snapshotLoader: SequentialDashboardSnapshotLoader(fastResults: [], preciseResults: []),
                autoStart: false,
                continuityDefaults: defaults,
                continuityStorageKey: storageKey,
                legacyContinuityStorageKey: nil,
                continuitySafetyDatabase: SharedAccountUsageSafetyDatabase(url: databaseURL)
            ).preciseTimeSeriesContinuityLossID
        )
    }

    func testCorruptProductionContinuityPayloadFailsClosedWithoutDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexUsageStoreSafetyContinuityCorruptionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("safety.sqlite")
        let database = SharedAccountUsageSafetyDatabase(url: databaseURL)
        // The database accepts only JSON objects at its generic boundary; this
        // object is syntactically durable but invalid for the typed continuity
        // schema, which exercises the typed fail-closed path without bypassing
        // the storage contract.
        let corrupt = Data(#"{"unexpected":true}"#.utf8)
        XCTAssertTrue(database.store(corrupt, as: .preciseContinuity))
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/corrupt-safety-continuity/.codex"),
            origin: .defaultHome
        )

        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: SequentialDashboardSnapshotLoader(fastResults: [], preciseResults: []),
            autoStart: false,
            continuitySafetyDatabase: database
        )

        XCTAssertFalse(store.preciseContinuityPersistenceHealthy)
        XCTAssertFalse(database.persistenceHealthy)
        XCTAssertNil(database.load(.preciseContinuity))
        XCTAssertEqual(
            SharedAccountUsageSafetyDatabase(url: databaseURL)
                .load(.preciseContinuity),
            corrupt,
            "typed corruption must fail closed without deleting the evidence"
        )
    }

    func testCorruptContinuityMigrationOffersExplicitSafetyRecovery() throws {
        let suiteName = "CodexUsageStoreCorruptMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexUsageStoreCorruptMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let storageKey = "corrupt-continuity-migration"
        defaults.set(Data(#"{"unexpected":true}"#.utf8), forKey: storageKey)
        let database = SharedAccountUsageSafetyDatabase(
            url: directory.appendingPathComponent("safety.sqlite")
        )
        let source = CodexDataSource(
            codexHome: directory.appendingPathComponent("home", isDirectory: true),
            origin: .defaultHome
        )

        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: SequentialDashboardSnapshotLoader(
                fastResults: [],
                preciseResults: []
            ),
            autoStart: false,
            continuityDefaults: defaults,
            continuityStorageKey: storageKey,
            legacyContinuityStorageKey: nil,
            continuitySafetyDatabase: database
        )

        XCTAssertFalse(store.preciseContinuityPersistenceHealthy)
        XCTAssertTrue(database.recoveryRequired)
        XCTAssertEqual(store.sharedAccountSafetyRecoveryState, .required)
        XCTAssertNotNil(defaults.object(forKey: storageKey))
    }

    func testFailedSessionWatcherSetupRetriesOnNormalRefresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexUsageStoreWatcherRetryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = directory.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = CodexDataSource(codexHome: home, origin: .defaultHome)
        let database = SharedAccountUsageSafetyDatabase(
            url: directory.appendingPathComponent("safety.sqlite"),
            claimsObserverOwnership: true
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: SequentialDashboardSnapshotLoader(
                fastResults: [],
                preciseResults: []
            ),
            autoStart: false,
            continuitySafetyDatabase: database
        )

        store.setBackgroundActivityEnabled(false)
        store.setBackgroundActivityEnabled(true)
        XCTAssertFalse(store.preciseSessionMutationMonitoringHealthy)

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store.refresh()
        XCTAssertTrue(store.preciseSessionMutationMonitoringHealthy)
        store.setBackgroundActivityEnabled(false)
    }

    func testUserRecoveryRebuildsEmptyGenerationThenForcesFreshPreciseObservation() async throws {
        let suiteName = "CodexUsageStoreSafetyRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexUsageStoreSafetyRecoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let database = SharedAccountUsageSafetyDatabase(
            url: directory.appendingPathComponent("safety.sqlite"),
            claimsObserverOwnership: true
        )
        database.reportCorruptPayload(.segments)
        for key in CodexUsageStore.sharedAccountSafetyMigrationStorageKeys {
            defaults.set(Data("{}".utf8), forKey: key)
        }
        let coverageAt = Date(timeIntervalSince1970: 3_300)
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [],
            preciseResults: [.success(makeSnapshot(
                totalTokens: 900,
                dayTokens: 90,
                preciseTimeSeriesGeneratedAt: coverageAt
            ))]
        )
        let source = CodexDataSource(codexHome: home, origin: .defaultHome)
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false,
            continuityDefaults: defaults,
            continuitySafetyDatabase: database
        )
        XCTAssertEqual(store.sharedAccountSafetyRecoveryState, .required)

        let recoveryStarted = await store.rebuildSharedAccountSafetyBaseline()
        XCTAssertTrue(recoveryStarted)
        await waitUntil("fresh precise scan after safety recovery") {
            store.snapshot.preciseTimeSeriesGeneratedAt == coverageAt
                && !store.isRefreshing
        }

        XCTAssertTrue(database.persistenceHealthy)
        XCTAssertEqual(store.sharedAccountSafetyRecoveryState, .awaitingFreshBaseline)
        XCTAssertEqual(store.preciseTimeSeriesContinuityLossReason, .storageRecovery)
        XCTAssertNotNil(store.preciseTimeSeriesContinuityLossID)
        XCTAssertTrue(store.preciseSessionMutationMonitoringHealthy)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        for key in CodexUsageStore.sharedAccountSafetyMigrationStorageKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func testRunningProcessReloadsContinuityGapRecordedByAnotherProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexUsageStoreCrossProcessContinuityTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = SharedAccountUsageSafetyDatabase(
            url: directory.appendingPathComponent("safety.sqlite")
        )
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/cross-process-continuity/.codex"),
            origin: .defaultHome
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: SequentialDashboardSnapshotLoader(fastResults: [], preciseResults: []),
            autoStart: false,
            continuitySafetyDatabase: database
        )
        XCTAssertNil(store.preciseTimeSeriesContinuityLossID)

        let externallyRecorded = PreciseTimeSeriesContinuityLossRecord(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 2_700)
        )
        XCTAssertTrue(
            database.store(
                try JSONEncoder().encode([
                    CodexUsageStore.continuityIdentifier(for: source): externallyRecorded,
                ]),
                as: .preciseContinuity
            )
        )

        store.reloadPreciseTimeSeriesContinuityLoss()

        XCTAssertEqual(store.preciseTimeSeriesContinuityLossID, externallyRecorded.id)
        XCTAssertEqual(store.preciseTimeSeriesContinuityLostAt, externallyRecorded.detectedAt)
        XCTAssertTrue(store.preciseContinuityPersistenceHealthy)
    }

    func testCorruptContinuityStoreFailsClosedInsteadOfDiscardingTheGap() {
        let suiteName = "CodexUsageStoreContinuityCorruptionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "corrupt-continuity-loss-test"
        defaults.set(Data([0xff, 0x00]), forKey: storageKey)
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/corrupt-continuity/.codex"),
            origin: .defaultHome
        )

        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: SequentialDashboardSnapshotLoader(fastResults: [], preciseResults: []),
            autoStart: false,
            continuityDefaults: defaults,
            continuityStorageKey: storageKey
        )

        XCTAssertFalse(store.preciseContinuityPersistenceHealthy)
        XCTAssertNotNil(defaults.data(forKey: storageKey))
    }

    func testLegacyContinuityTimestampMigratesToAStableUUIDGeneration() throws {
        let suiteName = "CodexUsageStoreContinuityMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "continuity-v2-test"
        let legacyKey = "continuity-v1-test"
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/continuity-migration/.codex"),
            origin: .defaultHome
        )
        let detectedAt = Date(timeIntervalSince1970: 2_000)
        defaults.set(
            try JSONEncoder().encode([
                CodexUsageStore.continuityIdentifier(for: source): detectedAt,
            ]),
            forKey: legacyKey
        )

        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: SequentialDashboardSnapshotLoader(fastResults: [], preciseResults: []),
            autoStart: false,
            continuityDefaults: defaults,
            continuityStorageKey: storageKey,
            legacyContinuityStorageKey: legacyKey
        )

        XCTAssertEqual(store.preciseTimeSeriesContinuityLostAt, detectedAt)
        XCTAssertNotNil(store.preciseTimeSeriesContinuityLossID)
        XCTAssertTrue(store.preciseContinuityPersistenceHealthy)
        XCTAssertNotNil(defaults.data(forKey: storageKey))
        XCTAssertNil(defaults.data(forKey: legacyKey))

        let migratedID = try XCTUnwrap(store.preciseTimeSeriesContinuityLossID)
        store.acknowledgePreciseTimeSeriesContinuityLoss(id: migratedID)
        let restarted = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: SequentialDashboardSnapshotLoader(fastResults: [], preciseResults: []),
            autoStart: false,
            continuityDefaults: defaults,
            continuityStorageKey: storageKey,
            legacyContinuityStorageKey: legacyKey
        )
        XCTAssertNil(restarted.preciseTimeSeriesContinuityLossID)
        XCTAssertNil(restarted.preciseTimeSeriesContinuityLostAt)
    }

    func testCorruptLegacyContinuityStoreFailsClosedDuringMigration() {
        let suiteName = "CodexUsageStoreLegacyContinuityCorruptionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "continuity-v2-corrupt-legacy-test"
        let legacyKey = "continuity-v1-corrupt-test"
        defaults.set(Data([0xff, 0x00]), forKey: legacyKey)
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/continuity-corrupt-migration/.codex"),
            origin: .defaultHome
        )

        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: SequentialDashboardSnapshotLoader(fastResults: [], preciseResults: []),
            autoStart: false,
            continuityDefaults: defaults,
            continuityStorageKey: storageKey,
            legacyContinuityStorageKey: legacyKey
        )

        XCTAssertFalse(store.preciseContinuityPersistenceHealthy)
        XCTAssertNotNil(defaults.data(forKey: legacyKey))
        XCTAssertNil(defaults.data(forKey: storageKey))
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
        XCTAssertEqual(store.dataSourceIdentity, sourceB.stableIdentityKey)
        XCTAssertEqual(store.snapshot.stats.totalTokens, 0)
        XCTAssertFalse(store.snapshot.hasPreciseTokenUsage)
        XCTAssertFalse(store.isCompactSummaryPending)
        XCTAssertFalse(store.status.contains("当前显示已陈旧"))
    }

    func testCoordinatorSourceTransitionClearsUsageBeforeNextLoadAndCompactProjection() async {
        let sourceA = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/coordinator-source-a/.codex"),
            origin: .userSelected
        )
        let sourceB = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/coordinator-source-b/.codex"),
            origin: .userSelected
        )
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(.empty)],
            preciseResults: [.success(makeSnapshot(totalTokens: 98_765, dayTokens: 4_321))]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: sourceA),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("source A usage snapshot") {
            store.snapshot.stats.totalTokens == 98_765 && !store.isRefreshing
        }

        XCTAssertTrue(store.setDataSource(sourceB))

        XCTAssertEqual(store.currentDataSource, sourceB)
        XCTAssertEqual(store.dataSourceIdentity, sourceB.stableIdentityKey)
        XCTAssertEqual(store.dataSourceLabel, sourceB.displayPath)
        XCTAssertEqual(store.snapshot.stats.totalTokens, 0)
        XCTAssertFalse(store.snapshot.hasPreciseTokenUsage)
        XCTAssertFalse(store.status.contains("98"))

        let monitor = LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false)
        monitor.setDataSource(sourceB)
        let display = TokenDisplaySnapshot.make(
            store: store,
            monitor: monitor,
            quota: AccountQuotaStore(observesUserDefaults: false)
        )
        let floating = FloatingPanelPresentationModel(snapshot: display, visibility: .default)
        let status = StatusBarUsageMetricsPresentation(snapshot: display)

        XCTAssertEqual(display.consumedTokensText, "待读取")
        XCTAssertEqual(status.totalTokens, "待读取")
        XCTAssertFalse(floating.accessibilityValue.contains("98.8K"))
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

    func testInFlightSameIdentityPathRebindRejectsOldCompletionAndRestartsOnNewPath() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsagePathRebind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldHome = parent.appendingPathComponent("old-home", isDirectory: true)
        let newHome = parent.appendingPathComponent("new-home", isDirectory: true)
        try FileManager.default.createDirectory(at: oldHome, withIntermediateDirectories: true)
        let sourceAtOldPath = CodexDataSource(codexHome: oldHome, origin: .userSelected)
        let resolver = MutableCodexDataSourceResolver(source: sourceAtOldPath)
        let loader = SuspendedDashboardSnapshotLoader()
        let store = CodexUsageStore(resolver: resolver, snapshotLoader: loader, autoStart: false)

        store.refresh()
        await waitUntil("old-path usage request") {
            await loader.hasPendingPreciseRequest(for: sourceAtOldPath)
        }
        let oldBindingKey = store.dataSourceBindingKey
        let identityGeneration = store.sourceIdentityGeneration
        let oldBindingGeneration = store.sourceBindingGeneration
        let oldObservationSessionID = store.preciseObservationSessionID

        try FileManager.default.moveItem(at: oldHome, to: newHome)
        let sourceAtNewPath = CodexDataSource(codexHome: newHome, origin: .userSelected)
        XCTAssertEqual(sourceAtNewPath.stableIdentityKey, sourceAtOldPath.stableIdentityKey)
        resolver.source = sourceAtNewPath

        store.refresh()

        XCTAssertEqual(store.currentDataSource?.codexHome.path, newHome.path)
        XCTAssertNotEqual(store.dataSourceBindingKey, oldBindingKey)
        XCTAssertEqual(store.sourceIdentityGeneration, identityGeneration)
        XCTAssertEqual(store.sourceBindingGeneration, oldBindingGeneration + 1)
        XCTAssertNotEqual(store.preciseObservationSessionID, oldObservationSessionID)
        XCTAssertTrue(store.isRefreshing)
        await waitUntil("new-path usage request") {
            await loader.hasPendingPreciseRequest(for: sourceAtNewPath)
        }

        await loader.completePreciseRequest(
            for: sourceAtOldPath,
            with: makeSnapshot(totalTokens: 11_000, dayTokens: 1_100)
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotEqual(store.snapshot.stats.totalTokens, 11_000)
        XCTAssertTrue(store.isRefreshing)

        await loader.completePreciseRequest(
            for: sourceAtNewPath,
            with: makeSnapshot(totalTokens: 22_000, dayTokens: 2_200)
        )
        await waitUntil("new-path usage completion") {
            store.snapshot.stats.totalTokens == 22_000 && !store.isRefreshing
        }
        XCTAssertFalse(store.setDataSource(sourceAtNewPath))
        XCTAssertEqual(store.sourceBindingGeneration, oldBindingGeneration + 1)
    }

    func testCompactOnlySurfaceRefreshUsesLightSummaryInsteadOfFullRebuild() async {
        let firstPreciseCoverageAt = Date(timeIntervalSince1970: 1_800)
        let secondPreciseCoverageAt = Date(timeIntervalSince1970: 2_100)
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/compact-summary/.codex"),
            origin: .defaultHome
        )
        let loader = CompactSummaryProbeLoader(
            preciseResults: [
                makeSnapshot(
                    totalTokens: 1_000,
                    dayTokens: 100,
                    preciseTimeSeriesGeneratedAt: firstPreciseCoverageAt
                ),
                makeSnapshot(
                    totalTokens: 2_000,
                    dayTokens: 150,
                    preciseTimeSeriesGeneratedAt: secondPreciseCoverageAt
                ),
            ],
            summary: CodexUsageAnalyzer.CompactUsageSummary(
                totalTokens: 1_500,
                todayTokens: 300,
                todayCalls: 7,
                todayModelBreakdowns: [
                    ModelTokenBreakdown(
                        model: "gpt-5.6-luna",
                        breakdown: TokenCacheBreakdown(
                            inputTokens: 260,
                            cachedInputTokens: 200,
                            outputTokens: 40,
                            reasoningOutputTokens: 0,
                            totalTokens: 300,
                            calls: 7
                        )
                    )
                ],
                generatedAt: Date()
            )
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        // 首轮全量建立精确快照。
        store.refresh()
        await waitUntil("initial precise load") {
            store.snapshot.stats.totalTokens == 1_000 && !store.isRefreshing
        }
        XCTAssertEqual(store.snapshot.preciseTimeSeriesGeneratedAt, firstPreciseCoverageAt)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        let chartDaysBeforeCompact = store.snapshot.dailyUsage

        // 仅紧凑 surface 可见：周期刷新走轻量 summary，不再全量重建。
        store.setOnlyCompactSurfaceVisible(true)
        store.refresh()
        await waitUntil("compact summary refresh") {
            store.snapshot.stats.totalTokens == 1_500 && !store.isRefreshing
        }
        var summaryCount = await loader.compactSummaryCount
        var preciseCount = await loader.preciseLoadCount
        XCTAssertEqual(summaryCount, 1)
        XCTAssertEqual(preciseCount, 1)
        XCTAssertEqual(store.snapshot.dailyUsage, chartDaysBeforeCompact)
        XCTAssertEqual(
            store.todayUsageSummary?.tokens,
            300,
            "lightweight summary must not partially overwrite the heatmap day"
        )
        XCTAssertEqual(store.todayUsageSummary?.calls, 7)
        XCTAssertEqual(store.todayModelBreakdowns.first?.model, "gpt-5.6-luna")
        XCTAssertEqual(store.todayModelBreakdowns.first?.breakdown.cachedInputTokens, 200)
        // 重字段（时间序列）保留上次全量构建结果：旧日条目仍在、bins 未动。
        XCTAssertEqual(store.snapshot.dailyUsage.count, 1)
        XCTAssertEqual(store.snapshot.recentBins.first?.tokens, 100)
        XCTAssertEqual(store.snapshot.preciseTimeSeriesGeneratedAt, firstPreciseCoverageAt)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        XCTAssertTrue(store.isCompactSummaryPending)

        // 仪表盘展开：立即触发一次全量刷新补齐重字段。
        store.setOnlyCompactSurfaceVisible(false)
        store.setUsageRefreshCadence(
            UsageRefreshCadenceSettings(),
            mainDashboardVisible: true
        )
        await waitUntil("full refresh after expanding dashboard") {
            store.snapshot.stats.totalTokens == 2_000 && !store.isRefreshing
        }
        summaryCount = await loader.compactSummaryCount
        preciseCount = await loader.preciseLoadCount
        XCTAssertEqual(summaryCount, 1)
        XCTAssertEqual(preciseCount, 2)
        XCTAssertEqual(store.snapshot.preciseTimeSeriesGeneratedAt, secondPreciseCoverageAt)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        XCTAssertFalse(store.isCompactSummaryPending)
    }

    func testCompactSummaryRefreshRetainsModelRowsWhileProjectionIsTemporarilyEmpty() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/compact-model-cache/.codex"),
            origin: .defaultHome
        )
        let generatedAt = Date()
        let modelEvent = TokenCacheAttributionEvent(
            id: "model-cache-sol",
            start: generatedAt,
            model: "gpt-5.6-sol",
            breakdown: TokenCacheBreakdown(
                inputTokens: 100,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: 100,
                calls: 1
            )
        )
        let initial = DashboardSnapshot(
            stats: DashboardStats(
                totalTokens: 100,
                peakDayTokens: 100,
                peakThreadTokens: 100,
                currentStreakDays: 1,
                longestStreakDays: 1,
                totalCalls: 1,
                totalThreads: 1,
                mostUsedReasoning: "",
                skillsExplored: 0,
                totalSkillsUsed: 0
            ),
            dailyUsage: [DayUsage(date: generatedAt, tokens: 100, calls: 1)],
            recentBins: [],
            hourlyUsage: [],
            pluginUsage: [],
            cacheUsage: TokenCacheUsage(
                total: .empty,
                daily: [],
                hourly: [],
                recentBins: [],
                sessions: [],
                turns: [],
                attributionEvents: [modelEvent],
                attributionEventsComplete: true
            ),
            generatedAt: generatedAt
        )
        let emptyProjection = CodexUsageAnalyzer.CompactUsageSummary(
            totalTokens: 120,
            todayTokens: 120,
            todayCalls: 2,
            todayModelBreakdowns: [],
            generatedAt: generatedAt
        )
        let loader = CompactSummarySequenceProbeLoader(
            precise: [initial],
            summaries: [emptyProjection]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("initial model snapshot") {
            !store.isRefreshing && store.todayModelBreakdowns.count == 1
        }
        store.setOnlyCompactSurfaceVisible(true)
        store.refresh()
        await waitUntil("empty model projection refresh") {
            !store.isRefreshing && store.snapshot.stats.totalTokens == 120
        }

        XCTAssertEqual(store.todayModelBreakdowns.map(\.model), ["gpt-5.6-sol"])
    }

    func testFirstLoadTakesTheFullPathEvenWhenOnlyCompactSurfaceIsVisible() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/compact-first-load/.codex"),
            origin: .defaultHome
        )
        let loader = CompactSummaryProbeLoader(
            preciseResults: [makeSnapshot(totalTokens: 1_000, dayTokens: 100)],
            summary: CodexUsageAnalyzer.CompactUsageSummary(
                totalTokens: 9_999,
                todayTokens: 9,
                todayCalls: 9,
                generatedAt: Date()
            )
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.setOnlyCompactSurfaceVisible(true)
        store.refresh()
        await waitUntil("first full load") {
            store.snapshot.stats.totalTokens == 1_000 && !store.isRefreshing
        }
        let summaryCount = await loader.compactSummaryCount
        let preciseCount = await loader.preciseLoadCount
        XCTAssertEqual(summaryCount, 0)
        XCTAssertEqual(preciseCount, 1)
    }

    func testAttributionCoverageRefreshBypassesCompactSummaryOptimization() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/attribution-coverage/.codex"),
            origin: .defaultHome
        )
        let firstCoverage = Date(timeIntervalSince1970: 1_800)
        let secondCoverage = Date(timeIntervalSince1970: 2_100)
        let loader = CompactSummaryProbeLoader(
            preciseResults: [
                makeSnapshot(
                    totalTokens: 1_000,
                    dayTokens: 100,
                    preciseTimeSeriesGeneratedAt: firstCoverage
                ),
                makeSnapshot(
                    totalTokens: 2_000,
                    dayTokens: 200,
                    preciseTimeSeriesGeneratedAt: secondCoverage
                ),
            ],
            summary: CodexUsageAnalyzer.CompactUsageSummary(
                totalTokens: 1_500,
                todayTokens: 150,
                todayCalls: 5,
                generatedAt: Date()
            )
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("initial attribution coverage") {
            store.snapshot.preciseTimeSeriesGeneratedAt == firstCoverage && !store.isRefreshing
        }
        store.setOnlyCompactSurfaceVisible(true)
        store.refreshPreciseTimeSeriesForAttribution()
        await waitUntil("forced attribution coverage") {
            store.snapshot.preciseTimeSeriesGeneratedAt == secondCoverage && !store.isRefreshing
        }

        let compactSummaryCount = await loader.compactSummaryCount
        let preciseLoadCount = await loader.preciseLoadCount
        XCTAssertEqual(compactSummaryCount, 0)
        XCTAssertEqual(preciseLoadCount, 2)
        XCTAssertTrue(store.preciseTimeSeriesFresh)
    }

    func testCompactOnlyNormalTickUsesOneFullAttemptToRecoverAnOpenContinuityGap() async {
        let suiteName = "CodexUsageStoreCompactContinuityRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/compact-continuity-recovery/.codex"),
            origin: .defaultHome
        )
        let firstCoverage = Date(timeIntervalSince1970: 1_800)
        let recoveredCoverage = Date(timeIntervalSince1970: 2_100)
        let loader = ContinuityRecoveryProbeLoader(
            preciseResults: [
                .success(makeSnapshot(
                    totalTokens: 1_000,
                    dayTokens: 100,
                    preciseTimeSeriesGeneratedAt: firstCoverage
                )),
                .failure(UsageStoreTestError()),
                .success(makeSnapshot(
                    totalTokens: 1_200,
                    dayTokens: 120,
                    preciseTimeSeriesGeneratedAt: recoveredCoverage
                )),
            ],
            summary: CodexUsageAnalyzer.CompactUsageSummary(
                totalTokens: 9_999,
                todayTokens: 999,
                todayCalls: 9,
                generatedAt: Date()
            )
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false,
            continuityDefaults: defaults,
            continuityStorageKey: "compact-continuity-recovery-test",
            legacyContinuityStorageKey: nil
        )

        store.refresh()
        await waitUntil("compact continuity initial exact") {
            store.snapshot.preciseTimeSeriesGeneratedAt == firstCoverage && !store.isRefreshing
        }
        store.setOnlyCompactSurfaceVisible(true)
        store.refreshPreciseTimeSeriesForAttribution()
        await waitUntil("compact continuity failed exact") {
            store.preciseTimeSeriesContinuityLossID != nil && !store.isRefreshing
        }

        store.refresh()
        await waitUntil("compact continuity normal-tick recovery") {
            store.snapshot.preciseTimeSeriesGeneratedAt == recoveredCoverage && !store.isRefreshing
        }

        let preciseLoadCount = await loader.preciseLoadCount
        let compactSummaryCount = await loader.compactSummaryCount
        XCTAssertEqual(preciseLoadCount, 3)
        XCTAssertEqual(compactSummaryCount, 0)
        XCTAssertNotNil(
            store.preciseTimeSeriesContinuityLossID,
            "the gap remains until the attribution segment finishes its safe cutover"
        )
    }

    func testExpandingDashboardQueuesFullRefreshBehindInFlightCompactSummary() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/compact-expand-race/.codex"),
            origin: .defaultHome
        )
        let loader = SuspendedCompactSummaryProbeLoader(
            preciseResults: [
                makeSnapshot(totalTokens: 1_000, dayTokens: 100),
                makeSnapshot(totalTokens: 2_000, dayTokens: 200),
            ]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("initial precise load before compact race") {
            store.snapshot.stats.totalTokens == 1_000 && !store.isRefreshing
        }
        store.setOnlyCompactSurfaceVisible(true)
        store.refresh()
        await waitUntil("suspended compact summary") {
            await loader.hasPendingCompactSummary()
        }

        store.setOnlyCompactSurfaceVisible(false)
        await loader.completeCompactSummary(
            CodexUsageAnalyzer.CompactUsageSummary(
                totalTokens: 1_500,
                todayTokens: 150,
                todayCalls: 5,
                generatedAt: Date()
            )
        )
        await waitUntil("queued full refresh after dashboard expansion") {
            store.snapshot.stats.totalTokens == 2_000 && !store.isRefreshing
        }

        let compactSummaryCount = await loader.compactSummaryCount
        let preciseLoadCount = await loader.preciseLoadCount
        XCTAssertEqual(compactSummaryCount, 1)
        XCTAssertEqual(preciseLoadCount, 2)
    }

    func testSnapshotLineageOlderFullCannotRollBackNewerSummaryHeadline() {
        let observed = Date(timeIntervalSince1970: 5_000)
        let current = makeSnapshot(
            totalTokens: 2_000,
            dayTokens: 200,
            generatedAt: observed,
            homeIdentity: "home-a",
            coverageKind: .summary,
            observedThrough: observed,
            settledThrough: observed,
            exactGeneration: 2
        )
        let olderFull = makeSnapshot(
            totalTokens: 1_000,
            dayTokens: 100,
            generatedAt: observed.addingTimeInterval(-1),
            homeIdentity: "home-a",
            coverageKind: .full,
            observedThrough: observed.addingTimeInterval(-60),
            settledThrough: observed.addingTimeInterval(-60),
            exactGeneration: 1
        )

        let merged = CodexUsageStore.mergeSnapshots(olderFull, into: current)
        XCTAssertEqual(merged.stats.totalTokens, 2_000)
        XCTAssertEqual(merged.stats.peakDayTokens, 200)
        XCTAssertEqual(merged.recentBins, olderFull.recentBins)
        XCTAssertEqual(merged.coverageKind, .full)
        XCTAssertEqual(merged.exactGeneration, 2)
    }

    func testSnapshotLineageNewerSummaryKeepsOlderFullDetails() {
        let observed = Date(timeIntervalSince1970: 6_000)
        let olderFull = makeSnapshot(
            totalTokens: 1_000,
            dayTokens: 100,
            generatedAt: observed,
            homeIdentity: "home-a",
            coverageKind: .full,
            observedThrough: observed,
            settledThrough: observed,
            exactGeneration: 1
        )
        let newerSummary = makeSnapshot(
            totalTokens: 2_000,
            dayTokens: 200,
            generatedAt: observed.addingTimeInterval(60),
            homeIdentity: "home-a",
            coverageKind: .summary,
            observedThrough: observed.addingTimeInterval(60),
            settledThrough: observed.addingTimeInterval(60),
            exactGeneration: 2
        )

        let merged = CodexUsageStore.mergeSnapshots(newerSummary, into: olderFull)
        XCTAssertEqual(merged.stats.totalTokens, 2_000)
        XCTAssertEqual(merged.stats.peakDayTokens, 200)
        XCTAssertEqual(merged.recentBins, olderFull.recentBins)
        XCTAssertEqual(merged.coverageKind, .full)
        XCTAssertEqual(merged.exactGeneration, 2)
    }

    func testSnapshotLineageDoesNotMergeDifferentHomes() {
        let current = makeSnapshot(
            totalTokens: 1_000,
            dayTokens: 100,
            homeIdentity: "home-a",
            exactGeneration: 1
        )
        let incoming = makeSnapshot(
            totalTokens: 9_000,
            dayTokens: 900,
            homeIdentity: "home-b",
            exactGeneration: 9
        )

        let merged = CodexUsageStore.mergeSnapshots(incoming, into: current)
        XCTAssertEqual(merged.stats.totalTokens, 1_000)
        XCTAssertEqual(merged.homeIdentity, "home-a")
    }

    func testSnapshotLineageSameMillisecondUsesTheSameLineageBeforeGeneratedAt() {
        let timestamp = Date(timeIntervalSince1970: 7_000)
        let current = makeSnapshot(
            totalTokens: 1_000,
            dayTokens: 100,
            generatedAt: timestamp,
            homeIdentity: "home-a",
            coverageKind: .settled,
            observedThrough: timestamp,
            settledThrough: timestamp,
            exactGeneration: 4
        )
        let incoming = makeSnapshot(
            totalTokens: 2_000,
            dayTokens: 200,
            generatedAt: timestamp,
            homeIdentity: "home-a",
            coverageKind: .settled,
            observedThrough: timestamp,
            settledThrough: timestamp,
            exactGeneration: 4
        )

        let merged = CodexUsageStore.mergeSnapshots(incoming, into: current)
        XCTAssertEqual(merged.stats.totalTokens, 2_000)
        XCTAssertEqual(merged.exactGeneration, 4)
    }

    func testSnapshotLineageReadsLegacyCodableSnapshotWithoutNewFields() throws {
        let snapshot = makeSnapshot(
            totalTokens: 1_000,
            dayTokens: 100,
            homeIdentity: "home-a",
            coverageKind: .full,
            observedThrough: Date(timeIntervalSince1970: 8_000),
            settledThrough: Date(timeIntervalSince1970: 8_000),
            exactGeneration: 8
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(snapshot),
                options: []
            ) as? [String: Any]
        )
        for key in ["homeIdentity", "coverageKind", "observedThrough", "settledThrough", "exactGeneration"] {
            object.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DashboardSnapshot.self, from: legacyData)

        XCTAssertNil(decoded.homeIdentity)
        XCTAssertEqual(decoded.coverageKind, .full)
        XCTAssertNil(decoded.observedThrough)
        XCTAssertNil(decoded.settledThrough)
        XCTAssertNil(decoded.exactGeneration)
        XCTAssertEqual(decoded.stats.totalTokens, snapshot.stats.totalTokens)
    }

    private func makeSnapshot(
        totalTokens: Int,
        dayTokens: Int,
        totalCalls: Int = 3,
        dayCalls: Int? = nil,
        usagePrecision: DashboardUsagePrecision = .precise,
        preciseTimeSeriesGeneratedAt: Date? = nil,
        generatedAt: Date = Date(timeIntervalSince1970: 1_800),
        attributionEventsComplete: Bool? = nil,
        attributionProvenanceEpoch: String? = nil,
        attributionGeneration: Int64? = nil,
        attributionUnsafeSinceGeneration: Int64? = nil,
        attributionCurrentScanUnsafeCauseDetected: Bool = false,
        attributionSourceMutationDetected: Bool = false,
        homeIdentity: String? = nil,
        coverageKind: DashboardSnapshotCoverageKind = .full,
        observedThrough: Date? = nil,
        settledThrough: Date? = nil,
        exactGeneration: Int64? = nil
    ) -> DashboardSnapshot {
        return DashboardSnapshot(
            stats: DashboardStats(
                totalTokens: totalTokens,
                peakDayTokens: dayTokens,
                peakThreadTokens: 999,
                currentStreakDays: 1,
                longestStreakDays: 1,
                totalCalls: totalCalls,
                totalThreads: 2,
                mostUsedReasoning: "中",
                skillsExplored: 0,
                totalSkillsUsed: 0
            ),
            dailyUsage: [DayUsage(
                date: generatedAt,
                tokens: dayTokens,
                calls: dayCalls ?? totalCalls
            )],
            recentBins: [BinUsage(
                start: generatedAt,
                tokens: dayTokens,
                calls: dayCalls ?? totalCalls
            )],
            hourlyUsage: [BinUsage(
                start: generatedAt,
                tokens: dayTokens,
                calls: dayCalls ?? totalCalls
            )],
            pluginUsage: [],
            cacheUsage: TokenCacheUsage(
                total: .empty,
                daily: [],
                hourly: [],
                recentBins: [],
                sessions: [],
                turns: [],
                attributionEvents: [],
                attributionEventsComplete:
                    attributionEventsComplete ?? (usagePrecision == .precise),
                attributionProvenanceEpoch: attributionProvenanceEpoch
                    ?? (usagePrecision == .precise ? "usage-store-test-provenance" : nil),
                attributionGeneration: attributionGeneration,
                attributionUnsafeSinceGeneration: attributionUnsafeSinceGeneration,
                attributionCurrentScanUnsafeCauseDetected:
                    attributionCurrentScanUnsafeCauseDetected,
                attributionSourceMutationDetected: attributionSourceMutationDetected
            ),
            usagePrecision: usagePrecision,
            preciseTimeSeriesGeneratedAt: preciseTimeSeriesGeneratedAt,
            homeIdentity: homeIdentity,
            coverageKind: coverageKind,
            observedThrough: observedThrough,
            settledThrough: settledThrough,
            exactGeneration: exactGeneration,
            generatedAt: generatedAt
        )
    }

    private func waitUntilYielding(
        _ label: String,
        iterations: Int = 10_000,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<iterations {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(label)")
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

private final class SessionMutationEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    var wasObserved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func markObserved() {
        lock.lock()
        observed = true
        lock.unlock()
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

private actor CompactSummaryProbeLoader: DashboardSnapshotLoading {
    private var preciseResults: [DashboardSnapshot]
    private let summary: CodexUsageAnalyzer.CompactUsageSummary
    private(set) var preciseLoadCount = 0
    private(set) var compactSummaryCount = 0

    init(
        preciseResults: [DashboardSnapshot],
        summary: CodexUsageAnalyzer.CompactUsageSummary
    ) {
        self.preciseResults = preciseResults
        self.summary = summary
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        throw UsageStoreTestError()
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        preciseLoadCount += 1
        guard !preciseResults.isEmpty else { throw UsageStoreTestError() }
        return preciseResults.count == 1 ? preciseResults[0] : preciseResults.removeFirst()
    }

    func loadCompactSummary(
        dataSource: CodexDataSource
    ) async throws -> CodexUsageAnalyzer.CompactUsageSummary? {
        compactSummaryCount += 1
        return summary
    }
}

private actor CompactSummarySequenceProbeLoader: DashboardSnapshotLoading {
    private var preciseResults: [DashboardSnapshot]
    private var summaries: [CodexUsageAnalyzer.CompactUsageSummary]

    init(
        precise: [DashboardSnapshot],
        summaries: [CodexUsageAnalyzer.CompactUsageSummary]
    ) {
        self.preciseResults = precise
        self.summaries = summaries
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        throw UsageStoreTestError()
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        guard !preciseResults.isEmpty else { throw UsageStoreTestError() }
        return preciseResults.removeFirst()
    }

    func loadCompactSummary(
        dataSource: CodexDataSource
    ) async throws -> CodexUsageAnalyzer.CompactUsageSummary? {
        guard !summaries.isEmpty else { return nil }
        return summaries.removeFirst()
    }
}

private actor ContinuityRecoveryProbeLoader: DashboardSnapshotLoading {
    private var preciseResults: [Result<DashboardSnapshot, Error>]
    private let summary: CodexUsageAnalyzer.CompactUsageSummary
    private(set) var preciseLoadCount = 0
    private(set) var compactSummaryCount = 0

    init(
        preciseResults: [Result<DashboardSnapshot, Error>],
        summary: CodexUsageAnalyzer.CompactUsageSummary
    ) {
        self.preciseResults = preciseResults
        self.summary = summary
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        throw UsageStoreTestError()
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        preciseLoadCount += 1
        guard !preciseResults.isEmpty else { throw UsageStoreTestError() }
        return try preciseResults.removeFirst().get()
    }

    func loadCompactSummary(
        dataSource: CodexDataSource
    ) async throws -> CodexUsageAnalyzer.CompactUsageSummary? {
        compactSummaryCount += 1
        return summary
    }
}

private actor AttributionSafetyAckProbeLoader: DashboardSnapshotLoading {
    struct Acknowledgement: Equatable, Sendable {
        let epoch: String
        let generation: Int64
    }

    private var preciseResults: [DashboardSnapshot]
    private(set) var acknowledgements: [Acknowledgement] = []
    private(set) var preciseLoadCount = 0

    init(preciseResults: [DashboardSnapshot]) {
        self.preciseResults = preciseResults
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        .empty
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        preciseLoadCount += 1
        guard !preciseResults.isEmpty else { throw UsageStoreTestError() }
        return preciseResults.removeFirst()
    }

    func acknowledgeAttributionSafety(
        dataSource: CodexDataSource,
        provenanceEpoch: String,
        throughGeneration: Int64
    ) async throws -> Bool {
        acknowledgements.append(Acknowledgement(
            epoch: provenanceEpoch,
            generation: throughGeneration
        ))
        return true
    }
}

private actor ObserverTakeoverProbeLoader: DashboardSnapshotLoading {
    private let preciseSnapshot: DashboardSnapshot
    private(set) var fastLoadCount = 0
    private(set) var preciseLoadCount = 0

    init(preciseSnapshot: DashboardSnapshot) {
        self.preciseSnapshot = preciseSnapshot
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        fastLoadCount += 1
        if fastLoadCount == 1 {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        return .empty
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        preciseLoadCount += 1
        return preciseSnapshot
    }
}

private actor SuspendedCompactSummaryProbeLoader: DashboardSnapshotLoading {
    private var preciseResults: [DashboardSnapshot]
    private var compactContinuation:
        CheckedContinuation<CodexUsageAnalyzer.CompactUsageSummary?, Error>?
    private(set) var preciseLoadCount = 0
    private(set) var compactSummaryCount = 0

    init(preciseResults: [DashboardSnapshot]) {
        self.preciseResults = preciseResults
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        throw UsageStoreTestError()
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        preciseLoadCount += 1
        guard !preciseResults.isEmpty else { throw UsageStoreTestError() }
        return preciseResults.count == 1 ? preciseResults[0] : preciseResults.removeFirst()
    }

    func loadCompactSummary(
        dataSource: CodexDataSource
    ) async throws -> CodexUsageAnalyzer.CompactUsageSummary? {
        compactSummaryCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            compactContinuation = continuation
        }
    }

    func hasPendingCompactSummary() -> Bool {
        compactContinuation != nil
    }

    func completeCompactSummary(_ summary: CodexUsageAnalyzer.CompactUsageSummary) {
        compactContinuation?.resume(returning: summary)
        compactContinuation = nil
    }
}

private actor SequentialDashboardSnapshotLoader: DashboardSnapshotLoading {
    private var fastResults: [Result<DashboardSnapshot, Error>]
    private var preciseResults: [Result<DashboardSnapshot, Error>]
    private var preciseRequests = 0

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
        preciseRequests += 1
        return try next(from: &preciseResults)
    }

    func preciseRequestCount() -> Int {
        preciseRequests
    }

    private func next(from results: inout [Result<DashboardSnapshot, Error>]) throws -> DashboardSnapshot {
        guard !results.isEmpty else {
            throw UsageStoreTestError()
        }
        return try results.removeFirst().get()
    }
}

private actor SuspendedDashboardSnapshotLoader: DashboardSnapshotLoading {
    private let fastResult: DashboardFastSnapshotResult
    private var preciseContinuations: [String: CheckedContinuation<DashboardSnapshot, Error>] = [:]

    init(
        fastResult: DashboardFastSnapshotResult = DashboardFastSnapshotResult(
            snapshot: .empty,
            freshness: .unavailable
        )
    ) {
        self.fastResult = fastResult
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        fastResult.snapshot
    }

    func loadFastSnapshotResult(
        dataSource: CodexDataSource
    ) async throws -> DashboardFastSnapshotResult {
        fastResult
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

private actor BarrierPhasedDashboardSnapshotLoader: DashboardSnapshotLoading {
    private let numeric: DashboardSnapshot
    private let final: DashboardSnapshot?
    private var phaseContinuation:
        AsyncThrowingStream<DashboardSnapshot, Error>.Continuation?
    private var phaseRequestStarted = false
    private var phaseRequestStartedContinuation: CheckedContinuation<Void, Never>?
    private(set) var phasedLoadCount = 0

    init(numeric: DashboardSnapshot, final: DashboardSnapshot?) {
        self.numeric = numeric
        self.final = final
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        .empty
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        throw UsageStoreTestError()
    }

    nonisolated func loadSnapshotPhases(
        dataSource: CodexDataSource
    ) -> AsyncThrowingStream<DashboardSnapshot, Error> {
        return AsyncThrowingStream { continuation in
            let registration = Task { [weak self] in
                await self?.register(continuation)
            }
            continuation.onTermination = { _ in
                registration.cancel()
            }
        }
    }

    func waitUntilPhaseRequestStarted() async {
        if phaseRequestStarted { return }
        await withCheckedContinuation { continuation in
            phaseRequestStartedContinuation = continuation
        }
    }

    func phasedLoadCountValue() -> Int {
        phasedLoadCount
    }

    func yieldNumeric() {
        phaseContinuation?.yield(numeric)
    }

    func yieldFinal() {
        guard let phaseContinuation else { return }
        if let final {
            phaseContinuation.yield(final)
            phaseContinuation.finish()
        } else {
            phaseContinuation.finish(throwing: UsageStoreTestError())
        }
        self.phaseContinuation = nil
    }

    private func register(
        _ continuation: AsyncThrowingStream<DashboardSnapshot, Error>.Continuation
    ) {
        phasedLoadCount += 1
        phaseContinuation = continuation
        phaseRequestStarted = true
        phaseRequestStartedContinuation?.resume()
        phaseRequestStartedContinuation = nil
    }
}

private actor MultiRequestPhasedDashboardSnapshotLoader: DashboardSnapshotLoading {
    private var continuations: [
        Int: AsyncThrowingStream<DashboardSnapshot, Error>.Continuation
    ] = [:]
    private var requestCount = 0
    private var requestCountWaiters: [
        Int: [CheckedContinuation<Void, Never>]
    ] = [:]

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        .empty
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        throw UsageStoreTestError()
    }

    nonisolated func loadSnapshotPhases(
        dataSource: CodexDataSource
    ) -> AsyncThrowingStream<DashboardSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let registration = Task { [weak self] in
                await self?.register(continuation)
            }
            continuation.onTermination = { _ in
                registration.cancel()
            }
        }
    }

    func waitUntilRequestCount(_ expected: Int) async {
        if requestCount >= expected { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters[expected, default: []].append(continuation)
        }
    }

    func requestCountValue() -> Int {
        requestCount
    }

    func yield(_ snapshot: DashboardSnapshot, request: Int) {
        continuations[request]?.yield(snapshot)
    }

    func finish(request: Int) {
        continuations.removeValue(forKey: request)?.finish()
    }

    func fail(request: Int) {
        continuations.removeValue(forKey: request)?.finish(throwing: UsageStoreTestError())
    }

    private func register(
        _ continuation: AsyncThrowingStream<DashboardSnapshot, Error>.Continuation
    ) {
        let request = requestCount
        continuations[request] = continuation
        requestCount += 1
        let readyCounts = requestCountWaiters.keys.filter { $0 <= requestCount }
        for count in readyCounts {
            requestCountWaiters.removeValue(forKey: count)?.forEach { $0.resume() }
        }
    }
}

private actor ControlledPhasedDashboardSnapshotLoader: DashboardSnapshotLoading {
    private let numericBySource: [String: DashboardSnapshot]
    private let finalBySource: [String: DashboardSnapshot]
    private var pending: [String: AsyncThrowingStream<DashboardSnapshot, Error>.Continuation] = [:]
    private var pendingWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    init(
        numericBySource: [String: DashboardSnapshot],
        finalBySource: [String: DashboardSnapshot]
    ) {
        self.numericBySource = numericBySource
        self.finalBySource = finalBySource
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        .empty
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        throw UsageStoreTestError()
    }

    nonisolated func loadSnapshotPhases(
        dataSource: CodexDataSource
    ) -> AsyncThrowingStream<DashboardSnapshot, Error> {
        let sourceID = dataSource.codexHome.path
        return AsyncThrowingStream { continuation in
            let registration = Task { [weak self] in
                await self?.register(continuation, for: sourceID)
            }
            continuation.onTermination = { _ in
                registration.cancel()
            }
        }
    }

    func waitUntilPending(source: CodexDataSource) async {
        let sourceID = source.codexHome.path
        if pending[sourceID] != nil { return }
        await withCheckedContinuation { continuation in
            pendingWaiters[sourceID] = continuation
        }
    }

    func yieldNumeric(source: CodexDataSource) {
        let sourceID = source.codexHome.path
        guard let numeric = numericBySource[sourceID] else { return }
        pending[sourceID]?.yield(numeric)
    }

    func yieldFinal(source: CodexDataSource) {
        let sourceID = source.codexHome.path
        guard let continuation = pending[sourceID] else { return }
        if let final = finalBySource[sourceID] {
            continuation.yield(final)
        }
        continuation.finish()
        pending.removeValue(forKey: sourceID)
    }

    private func register(
        _ continuation: AsyncThrowingStream<DashboardSnapshot, Error>.Continuation,
        for sourceID: String
    ) {
        pending[sourceID] = continuation
        pendingWaiters.removeValue(forKey: sourceID)?.resume()
    }
}

private struct UsageStoreTestError: LocalizedError {
    var errorDescription: String? {
        "模拟用量读取失败"
    }
}

import XCTest
@testable import CodexTokenBar

@MainActor
private final class TestAutomaticInterfaceScale {
    var value: Double

    init(_ value: Double) {
        self.value = value
    }
}

final class DashboardRuntimeCompositionTests: XCTestCase {
    @MainActor
    func testSurfacePausePreservesTrustedLiveSnapshot() {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        var trusted = LiveRateSnapshot()
        trusted.rollingTokensPerSecond = 42.4
        trusted.outputTokens = 123
        trusted.status = "可信实时快照"
        monitor.totalSnapshot = trusted

        monitor.setPollingActive(false)
        XCTAssertEqual(monitor.totalSnapshot, trusted)

        monitor.setPollingActive(true)
        XCTAssertEqual(monitor.totalSnapshot, trusted)
    }

    func testBackgroundOwnerActivityRequiresAtLeastOneVisibleSurface() {
        XCTAssertFalse(DashboardBackgroundOwnerActivity.shouldRunExpensiveOwners(
            dashboardVisible: false,
            floatingPanelEnabled: false,
            statusBarPanelEnabled: false
        ))
        XCTAssertTrue(DashboardBackgroundOwnerActivity.shouldRunExpensiveOwners(
            dashboardVisible: true,
            floatingPanelEnabled: false,
            statusBarPanelEnabled: false
        ))
        XCTAssertTrue(DashboardBackgroundOwnerActivity.shouldRunExpensiveOwners(
            dashboardVisible: false,
            floatingPanelEnabled: true,
            statusBarPanelEnabled: false
        ))
        XCTAssertTrue(DashboardBackgroundOwnerActivity.shouldRunExpensiveOwners(
            dashboardVisible: false,
            floatingPanelEnabled: false,
            statusBarPanelEnabled: true
        ))
        XCTAssertTrue(DashboardBackgroundOwnerActivity.shouldRunExpensiveOwners(
            dashboardVisible: false,
            floatingPanelEnabled: false,
            statusBarPanelEnabled: false,
            statusSummaryPresented: true
        ))
    }

    func testPresentedStatusSummaryUsesFullSurfaceCadence() {
        let compactOnly = DashboardBackgroundOwnerActivity.onlyCompactSurfaceVisible(
            dashboardVisible: false,
            floatingPanelEnabled: false,
            statusBarPanelEnabled: true,
            statusSummaryPresented: false
        )
        let iconOnlySummary = DashboardBackgroundOwnerActivity.onlyCompactSurfaceVisible(
            dashboardVisible: false,
            floatingPanelEnabled: false,
            statusBarPanelEnabled: false,
            statusSummaryPresented: true
        )

        XCTAssertTrue(compactOnly)
        XCTAssertFalse(iconOnlySummary)
        XCTAssertFalse(DashboardBackgroundOwnerActivity.onlyCompactSurfaceVisible(
            dashboardVisible: false,
            floatingPanelEnabled: true,
            statusBarPanelEnabled: false,
            statusSummaryPresented: true
        ))

        var snapshot = LiveRateSnapshot()
        snapshot.updatedAt = Date(timeIntervalSince1970: 2_000)
        let decision = UsageRefreshCadencePolicy.decision(
            snapshot: snapshot,
            onlyCompactSurfaceVisible: iconOnlySummary,
            now: snapshot.updatedAt
        )
        XCTAssertEqual(decision.interval, UsageRefreshCadencePolicy.visibleDashboardInterval)
    }

    @MainActor
    func testAllOffPausesExpensiveOwnersAndSurfaceResumeRestartsThem() {
        let suiteName = "DashboardRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: InterfaceScaleSettings.autoEnabledKey)
        var activity: [Bool] = []
        let runtime = DashboardRuntime(
            settings: defaults,
            automaticInterfaceScaleProvider: { 1.0 },
            startupAction: {},
            surfaceApplyAction: { _ in },
            backgroundOwnerActivityAction: { activity.append($0) }
        )
        let consumer = UUID()

        runtime.acquireConsumer(consumer)
        runtime.reportConfiguration(Self.configuration(floating: false, status: false), for: consumer)
        runtime.reportConfiguration(Self.configuration(floating: true, status: false), for: consumer)
        runtime.reportConfiguration(Self.configuration(floating: true, status: false), for: consumer)

        XCTAssertEqual(activity, [false, true])
    }

    @MainActor
    func testIconOnlyStatusSummaryTemporarilyRestoresAndReleasesRuntimeOwners() {
        let suiteName = "DashboardRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: InterfaceScaleSettings.autoEnabledKey)
        var activity: [Bool] = []
        var starts = 0
        var stops = 0
        let runtime = DashboardRuntime(
            settings: defaults,
            automaticInterfaceScaleProvider: { 1.0 },
            startupAction: {},
            surfaceApplyAction: { _ in },
            sideEffectStartAction: { starts += 1 },
            sideEffectStopAction: { stops += 1 },
            backgroundOwnerActivityAction: { activity.append($0) }
        )
        let consumer = UUID()

        runtime.acquireConsumer(consumer)
        runtime.reportConfiguration(Self.configuration(floating: false, status: false), for: consumer)
        runtime.releaseConsumer(consumer)
        XCTAssertEqual(activity, [false])
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)

        runtime.setStatusBarSummaryPresented(true)
        runtime.setStatusBarSummaryPresented(true)
        XCTAssertTrue(runtime.statusBarSummaryPresented)
        XCTAssertEqual(activity, [false, true])
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 1)

        runtime.setStatusBarSummaryPresented(false)
        runtime.setStatusBarSummaryPresented(false)
        XCTAssertFalse(runtime.statusBarSummaryPresented)
        XCTAssertEqual(activity, [false, true, false])
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 2)
    }

    @MainActor
    func testTwoDashboardCompositionsShareEveryLongLivedOwner() {
        let runtime = DashboardRuntime()

        let first = runtime.composition
        let second = runtime.composition

        XCTAssertEqual(ObjectIdentifier(first.usageStore), ObjectIdentifier(second.usageStore))
        XCTAssertEqual(ObjectIdentifier(first.quotaStore), ObjectIdentifier(second.quotaStore))
        XCTAssertEqual(ObjectIdentifier(first.quotaHistoryStore), ObjectIdentifier(second.quotaHistoryStore))
        XCTAssertEqual(ObjectIdentifier(first.radarStore), ObjectIdentifier(second.radarStore))
        XCTAssertEqual(ObjectIdentifier(first.providerSyncStore), ObjectIdentifier(second.providerSyncStore))
        XCTAssertEqual(ObjectIdentifier(first.taskCompletionMonitor), ObjectIdentifier(second.taskCompletionMonitor))
        XCTAssertEqual(ObjectIdentifier(first.liveMonitor), ObjectIdentifier(second.liveMonitor))
        XCTAssertEqual(
            ObjectIdentifier(first.sourceTransitionCoordinator),
            ObjectIdentifier(second.sourceTransitionCoordinator)
        )
    }

    @MainActor
    func testRadarPublicationFromRuntimeOwnedStoreRebindsVisibleSurface() async throws {
        let suiteName = "DashboardRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: InterfaceScaleSettings.autoEnabledKey)
        let radarReader = DashboardRuntimeSuspendedRadarReader()
        let radarStore = CodexRadarStore(
            reader: radarReader,
            feedReader: DashboardRuntimeEmptyRadarFeedReader(),
            detailReader: DashboardRuntimeFailingRadarDetailReader(),
            crowdReader: DashboardRuntimeFailingCrowdRadarReader(),
            detailRefreshDefaults: defaults
        )
        let usageStore = CodexUsageStore(
            resolver: DashboardRuntimeNilDataSourceResolver(),
            snapshotLoader: DashboardRuntimeEmptySnapshotLoader(),
            autoStart: false
        )
        var surfaceBindCount = 0
        let runtime = DashboardRuntime(
            usageStore: usageStore,
            quotaStore: AccountQuotaStore(
                quotaReader: DashboardRuntimeFailingQuotaReader(),
                observesUserDefaults: false
            ),
            quotaHistoryStore: QuotaHistoryStore(historyClient: DashboardRuntimeEmptyQuotaHistoryLoader()),
            radarStore: radarStore,
            taskCompletionMonitor: TaskCompletionMonitor(defaults: defaults),
            liveMonitor: LiveRateMonitor(monitoringEnabled: false),
            settings: defaults,
            notificationCenter: NotificationCenter(),
            automaticInterfaceScaleProvider: { 1.0 },
            surfaceApplyAction: { _ in surfaceBindCount += 1 }
        )
        let consumer = UUID()

        runtime.acquireConsumer(consumer)
        runtime.reportConfiguration(Self.configuration(floating: true, status: false), for: consumer)
        await Self.waitUntil("runtime radar request pending") {
            await radarReader.hasPendingRequest()
        }
        let ownedRadarStore = runtime.composition.radarStore
        XCTAssertEqual(ObjectIdentifier(ownedRadarStore), ObjectIdentifier(radarStore))
        let bindCountBeforePublication = surfaceBindCount
        let snapshot = try JSONDecoder.codexRadar.decode(
            CodexRadarSnapshot.self,
            from: Data(CodexRadarModelsTests.sampleJSON.utf8)
        )

        await radarReader.finish(with: snapshot)
        await Self.waitUntil("radar publication rebinds surface") {
            radarStore.snapshot == snapshot && surfaceBindCount > bindCountBeforePublication
        }

        XCTAssertEqual(runtime.composition.radarStore.snapshot, snapshot)
        XCTAssertGreaterThan(surfaceBindCount, bindCountBeforePublication)
        runtime.releaseConsumer(consumer)
        radarStore.stop()
    }

    @MainActor
    func testRuntimeStartsOnceAndOneConsumerCannotStopAnother() {
        var starts = 0
        let runtime = DashboardRuntime(startupAction: { starts += 1 })
        let first = UUID()
        let second = UUID()

        runtime.acquireConsumer(first)
        runtime.acquireConsumer(first)
        runtime.acquireConsumer(second)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(runtime.activeConsumerCount, 2)

        runtime.releaseConsumer(first)
        XCTAssertEqual(runtime.activeConsumerCount, 1)
        XCTAssertTrue(runtime.isStarted)
        XCTAssertEqual(starts, 1)

        runtime.releaseConsumer(second)
        runtime.acquireConsumer(UUID())
        XCTAssertTrue(runtime.isStarted)
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testSideEffectsRunOnceAcrossConsumersAndStopAfterLastRelease() {
        var starts = 0
        var stops = 0
        var wakes = 0
        var binds = 0
        var cadences = 0
        let coordinator = DashboardRuntimeSideEffectCoordinator<Int>(
            onStart: { starts += 1 },
            onStop: { stops += 1 },
            onWake: { wakes += 1 },
            onSurfaceEvent: { binds += 1 },
            onCadenceEvent: { cadences += 1 },
            onConfiguration: { _ in binds += 1 }
        )
        let first = UUID()
        let second = UUID()

        coordinator.acquire(first)
        coordinator.acquire(second)
        XCTAssertEqual(starts, 1)
        coordinator.reportConfiguration(7, for: first)
        coordinator.reportConfiguration(7, for: first)
        XCTAssertEqual(binds, 1)

        coordinator.handleWake()
        coordinator.handleSurfaceEvent()
        coordinator.handleCadenceEvent()
        XCTAssertEqual(wakes, 1)
        XCTAssertEqual(binds, 2)
        XCTAssertEqual(cadences, 1)

        coordinator.release(first)
        coordinator.handleWake()
        XCTAssertEqual(wakes, 2)
        XCTAssertEqual(stops, 0)

        coordinator.release(second)
        coordinator.handleWake()
        coordinator.handleSurfaceEvent()
        XCTAssertEqual(wakes, 2)
        XCTAssertEqual(binds, 2)
        XCTAssertEqual(stops, 1)
    }

    @MainActor
    func testCompactAppOwnerKeepsSingleSideEffectSubscriptionWithoutWindows() {
        var starts = 0
        var stops = 0
        var wakes = 0
        let coordinator = DashboardRuntimeSideEffectCoordinator<Bool>(
            onStart: { starts += 1 },
            onStop: { stops += 1 },
            onWake: { wakes += 1 },
            onSurfaceEvent: {},
            onCadenceEvent: {},
            onConfiguration: { _ in },
            keepsAppOwnerActive: { $0 }
        )
        let consumer = UUID()

        coordinator.acquire(consumer)
        coordinator.reportConfiguration(true, for: consumer)
        coordinator.release(consumer)
        coordinator.handleWake()

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(wakes, 1)
    }

    @MainActor
    func testRuntimeCompactActionsPersistAndStopAfterLastSurfaceCloses() {
        let suiteName = "DashboardRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var applications: [DashboardRuntimeConfiguration] = []
        var stops = 0
        let runtime = DashboardRuntime(
            settings: defaults,
            startupAction: {},
            surfaceApplyAction: { applications.append($0) },
            sideEffectStopAction: { stops += 1 }
        )
        let first = UUID()
        let second = UUID()
        let enabled = Self.configuration(floating: true, status: true)

        runtime.acquireConsumer(first)
        runtime.acquireConsumer(second)
        runtime.reportConfiguration(enabled, for: first)
        runtime.reportConfiguration(enabled, for: second)
        runtime.releaseConsumer(first)
        runtime.releaseConsumer(second)

        runtime.closeFloatingPanel()
        XCTAssertFalse(runtime.configuration!.floatingPanelEnabled)
        XCTAssertTrue(runtime.configuration!.statusBarPanelEnabled)
        XCTAssertFalse(defaults.bool(forKey: "floatingPanelEnabled"))
        XCTAssertEqual(stops, 0)

        runtime.closeStatusBarPanel()
        XCTAssertFalse(runtime.configuration!.statusBarPanelEnabled)
        XCTAssertFalse(defaults.bool(forKey: "statusBarPanelEnabled"))
        XCTAssertEqual(stops, 1)
        let applicationCount = applications.count

        runtime.closeFloatingPanel()
        runtime.closeStatusBarPanel()
        XCTAssertEqual(applications.count, applicationCount)
        XCTAssertEqual(stops, 1)

        let reappeared = UUID()
        runtime.acquireConsumer(reappeared)
        runtime.reportConfiguration(Self.configuration(floating: false, status: false), for: reappeared)
        XCTAssertEqual(applications.count, applicationCount + 1)
        runtime.reportConfiguration(Self.configuration(floating: false, status: false), for: reappeared)
        XCTAssertEqual(applications.count, applicationCount + 1)
    }

    @MainActor
    func testRuntimeOwnsFloatingLockToggleAndPersistsIt() {
        let suiteName = "DashboardRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var applications = 0
        let runtime = DashboardRuntime(
            settings: defaults,
            startupAction: {},
            surfaceApplyAction: { _ in applications += 1 }
        )
        let consumer = UUID()
        runtime.acquireConsumer(consumer)
        runtime.reportConfiguration(Self.configuration(floating: true, status: false), for: consumer)

        runtime.toggleFloatingPanelLock()

        XCTAssertTrue(runtime.configuration!.floatingPanelLocked)
        XCTAssertTrue(defaults.bool(forKey: "floatingPanelLocked"))
        XCTAssertEqual(applications, 2)
    }

    @MainActor
    func testCompactFloatingOwnerRebindsScaleAfterDefaultsChangeWithoutDashboardConsumer() {
        let suiteName = "DashboardRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let notifications = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1.0, forKey: "floatingPanelScale")
        defaults.set(false, forKey: InterfaceScaleSettings.autoEnabledKey)
        defaults.set(1.0, forKey: InterfaceScaleSettings.manualMultiplierKey)
        var layouts: [FloatingTokenPanelLayout] = []
        let runtime = DashboardRuntime(
            settings: defaults,
            notificationCenter: notifications,
            automaticInterfaceScaleProvider: { 1.0 },
            startupAction: {},
            surfaceApplyAction: { configuration in
                layouts.append(FloatingTokenPanelLayout(
                    scale: configuration.floatingPanelScale,
                    visibility: configuration.floatingPanelVisibility
                ))
            }
        )
        let consumer = UUID()

        runtime.acquireConsumer(consumer)
        runtime.reportConfiguration(Self.configuration(floating: true, status: false), for: consumer)
        runtime.releaseConsumer(consumer)
        XCTAssertEqual(runtime.activeConsumerCount, 0)
        XCTAssertEqual(layouts.map(\.effectiveScale), [1.0])

        defaults.set(1.3, forKey: InterfaceScaleSettings.manualMultiplierKey)
        notifications.post(name: UserDefaults.didChangeNotification, object: defaults)

        XCTAssertEqual(layouts.map(\.effectiveScale), [1.0, 1.3])
        XCTAssertEqual(layouts.last?.size, FloatingTokenPanelMetrics.size(scale: 1.3, visibility: .default))

        notifications.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(layouts.count, 2, "An unchanged effective scale must not rebind the compact surface.")
    }

    @MainActor
    func testCompactFloatingOwnerRebindsAutomaticScaleAfterScreenChanges() {
        let suiteName = "DashboardRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let notifications = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1.0, forKey: "floatingPanelScale")
        defaults.set(true, forKey: InterfaceScaleSettings.autoEnabledKey)
        let automaticScale = TestAutomaticInterfaceScale(1.0)
        var appliedScales: [CGFloat] = []
        let runtime = DashboardRuntime(
            settings: defaults,
            notificationCenter: notifications,
            automaticInterfaceScaleProvider: { automaticScale.value },
            startupAction: {},
            surfaceApplyAction: { appliedScales.append($0.floatingPanelScale.value) }
        )
        let consumer = UUID()

        runtime.acquireConsumer(consumer)
        runtime.reportConfiguration(Self.configuration(floating: true, status: false), for: consumer)
        runtime.releaseConsumer(consumer)

        automaticScale.value = 1.13
        notifications.post(name: NSWindow.didChangeScreenNotification, object: nil)
        notifications.post(name: NSWindow.didChangeScreenNotification, object: nil)

        automaticScale.value = 1.24
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(appliedScales, [1.0, 1.13, 1.24])
    }

    @MainActor
    func testDashboardReportDoesNotRebindAfterRuntimeAlreadyAppliedSameScale() {
        let suiteName = "DashboardRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let notifications = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1.0, forKey: "floatingPanelScale")
        defaults.set(false, forKey: InterfaceScaleSettings.autoEnabledKey)
        defaults.set(1.0, forKey: InterfaceScaleSettings.manualMultiplierKey)
        var applications = 0
        let runtime = DashboardRuntime(
            settings: defaults,
            notificationCenter: notifications,
            automaticInterfaceScaleProvider: { 1.0 },
            startupAction: {},
            surfaceApplyAction: { _ in applications += 1 }
        )
        let consumer = UUID()
        runtime.acquireConsumer(consumer)
        runtime.reportConfiguration(Self.configuration(floating: true, status: false), for: consumer)

        defaults.set(1.3, forKey: InterfaceScaleSettings.manualMultiplierKey)
        notifications.post(name: UserDefaults.didChangeNotification, object: defaults)
        runtime.reportConfiguration(
            Self.configuration(floating: true, status: false, interfaceScale: 1.3),
            for: consumer
        )

        XCTAssertEqual(applications, 2)
    }

    @MainActor
    func testRuntimeKeepsResolvedScaleAcrossConflictingDashboardReports() {
        let suiteName = "DashboardRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let notifications = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1.0, forKey: "floatingPanelScale")
        defaults.set(true, forKey: InterfaceScaleSettings.autoEnabledKey)
        let automaticScale = TestAutomaticInterfaceScale(1.24)
        var applications: [DashboardRuntimeConfiguration] = []
        let runtime = DashboardRuntime(
            settings: defaults,
            notificationCenter: notifications,
            automaticInterfaceScaleProvider: { automaticScale.value },
            startupAction: {},
            surfaceApplyAction: { applications.append($0) }
        )
        let consumer = UUID()
        runtime.acquireConsumer(consumer)

        runtime.reportConfiguration(
            Self.configuration(floating: true, status: false, interfaceScale: 1.0),
            for: consumer
        )
        runtime.reportConfiguration(
            Self.configuration(floating: true, status: false, interfaceScale: 1.0),
            for: consumer
        )

        let statusOnly = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: true,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )
        runtime.reportConfiguration(
            Self.configuration(
                floating: true,
                status: false,
                interfaceScale: 1.0,
                visibility: statusOnly
            ),
            for: consumer
        )

        XCTAssertEqual(applications.map(\.floatingPanelScale.value), [1.24, 1.24])
        XCTAssertEqual(applications.last?.floatingPanelVisibility, statusOnly)

        defaults.set(false, forKey: InterfaceScaleSettings.autoEnabledKey)
        defaults.set(1.3, forKey: InterfaceScaleSettings.manualMultiplierKey)
        notifications.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(applications.last?.floatingPanelScale.value ?? -1, 1.3, accuracy: 0.001)

        defaults.set(1.1, forKey: "floatingPanelScale")
        notifications.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(applications.last?.floatingPanelScale.value ?? -1, 1.43, accuracy: 0.001)
    }

    @MainActor
    func testInitialFloatingBindingCorrectsOnceAfterPanelScreenBecomesKnown() {
        let suiteName = "DashboardRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let notifications = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1.0, forKey: "floatingPanelScale")
        defaults.set(true, forKey: InterfaceScaleSettings.autoEnabledKey)
        let automaticScale = TestAutomaticInterfaceScale(1.0)
        var appliedScales: [CGFloat] = []
        let runtime = DashboardRuntime(
            settings: defaults,
            notificationCenter: notifications,
            automaticInterfaceScaleProvider: { automaticScale.value },
            startupAction: {},
            surfaceApplyAction: { configuration in
                appliedScales.append(configuration.floatingPanelScale.value)
                if appliedScales.count == 1 {
                    automaticScale.value = 1.24
                }
            }
        )
        let consumer = UUID()
        runtime.acquireConsumer(consumer)

        runtime.reportConfiguration(
            Self.configuration(floating: true, status: false, interfaceScale: 1.0),
            for: consumer
        )
        runtime.reportConfiguration(
            Self.configuration(floating: true, status: false, interfaceScale: 1.0),
            for: consumer
        )

        XCTAssertEqual(appliedScales, [1.0, 1.24])
    }

    @MainActor
    func testInactiveTransitionCancelsAfterConfigurationAndReappliesOnReturn() {
        var starts = 0
        var stops = 0
        var applications = 0
        var pending = false
        let coordinator = DashboardRuntimeSideEffectCoordinator<Bool>(
            onStart: { starts += 1 },
            onStop: {
                pending = false
                stops += 1
            },
            onWake: {},
            onSurfaceEvent: {},
            onCadenceEvent: {},
            onConfiguration: { _ in
                pending = true
                applications += 1
            },
            keepsAppOwnerActive: { $0 }
        )
        let first = UUID()

        coordinator.acquire(first)
        coordinator.reportConfiguration(false, for: first)
        XCTAssertTrue(pending)
        coordinator.release(first)
        XCTAssertFalse(pending)
        XCTAssertEqual(stops, 1)

        let second = UUID()
        coordinator.acquire(second)
        coordinator.reportConfiguration(false, for: second)
        coordinator.reportConfiguration(false, for: second)
        XCTAssertTrue(pending)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(applications, 2)

        coordinator.release(second)
        XCTAssertFalse(pending)
        XCTAssertEqual(stops, 2)
    }

    private static func configuration(
        floating: Bool,
        status: Bool,
        interfaceScale: CGFloat = 1,
        visibility: FloatingPanelContentVisibility = .default
    ) -> DashboardRuntimeConfiguration {
        DashboardRuntimeConfiguration(
            floatingPanelEnabled: floating,
            statusBarPanelEnabled: status,
            floatingPanelScale: FloatingTokenPanelScale(baseScale: 1, interfaceScale: interfaceScale),
            floatingPanelVisibility: visibility,
            floatingPanelLocked: false,
            preciseTokenCountingEnabled: false,
            providerSyncVisible: false,
            radarDetailsVisible: false
        )
    }

    @MainActor
    private static func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

private final class DashboardRuntimeNilDataSourceResolver: CodexDataSourceResolving {
    func resolve() -> CodexDataSource? { nil }
    func saveSelectedDirectory(_ directory: URL) -> CodexDataSource? { nil }
}

private actor DashboardRuntimeEmptySnapshotLoader: DashboardSnapshotLoading {
    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot { .empty }
    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot { .empty }
}

private struct DashboardRuntimeTestError: Error, Sendable {}

private actor DashboardRuntimeFailingQuotaReader: QuotaReading {
    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        .failure(DashboardRuntimeTestError())
    }
}

private actor DashboardRuntimeEmptyQuotaHistoryLoader: QuotaHistoryLoading {
    func loadSnapshot(for quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot { .empty }
    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot { .empty }
    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot { quota }
}

private actor DashboardRuntimeSuspendedRadarReader: CodexRadarReading {
    private var continuation: CheckedContinuation<CodexRadarSnapshot, Error>?

    func readRadar() async throws -> CodexRadarSnapshot {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func hasPendingRequest() -> Bool { continuation != nil }

    func finish(with snapshot: CodexRadarSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

private actor DashboardRuntimeEmptyRadarFeedReader: CodexRadarFeedReading {
    func readFeed(from url: URL) async throws -> [CodexRadarFeedItem] { [] }
}

private actor DashboardRuntimeFailingCrowdRadarReader: CodexCrowdRadarReading {
    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot {
        throw DashboardRuntimeTestError()
    }
}

private actor DashboardRuntimeFailingRadarDetailReader: CodexRadarDetailReading {
    func readRadarDetail() async throws -> CodexRadarSnapshot {
        throw DashboardRuntimeTestError()
    }
}

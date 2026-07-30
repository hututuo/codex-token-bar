import AppKit
import Combine
import Foundation

@MainActor
final class DashboardRuntimeSideEffectCoordinator<Configuration: Equatable> {
    private var consumers: [UUID] = []
    private var configurations: [UUID: Configuration] = [:]
    private var appliedConfiguration: Configuration?
    private var appOwnerActive = false
    private let onStart: () -> Void
    private let onStop: () -> Void
    private let onWake: () -> Void
    private let onSurfaceEvent: () -> Void
    private let onCadenceEvent: () -> Void
    private let onConfiguration: (Configuration) -> Void
    private let keepsAppOwnerActive: (Configuration) -> Bool

    var activeConsumerCount: Int { consumers.count }

    init(
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onWake: @escaping () -> Void,
        onSurfaceEvent: @escaping () -> Void,
        onCadenceEvent: @escaping () -> Void,
        onConfiguration: @escaping (Configuration) -> Void,
        keepsAppOwnerActive: @escaping (Configuration) -> Bool = { _ in false }
    ) {
        self.onStart = onStart
        self.onStop = onStop
        self.onWake = onWake
        self.onSurfaceEvent = onSurfaceEvent
        self.onCadenceEvent = onCadenceEvent
        self.onConfiguration = onConfiguration
        self.keepsAppOwnerActive = keepsAppOwnerActive
    }

    func acquire(_ id: UUID) {
        guard !consumers.contains(id) else { return }
        let wasInactive = !isActive
        consumers.append(id)
        if wasInactive { onStart() }
    }

    func release(_ id: UUID) {
        let wasPrimary = consumers.first == id
        consumers.removeAll { $0 == id }
        configurations.removeValue(forKey: id)
        guard !consumers.isEmpty else {
            if !appOwnerActive {
                appliedConfiguration = nil
                onStop()
            }
            return
        }
        if wasPrimary, let primary = consumers.first, let configuration = configurations[primary] {
            apply(configuration)
        }
    }

    func setAppOwnerActive(_ active: Bool) {
        guard appOwnerActive != active else { return }
        let wasActive = isActive
        appOwnerActive = active
        if !wasActive && isActive {
            onStart()
        } else if wasActive && !isActive {
            appliedConfiguration = nil
            onStop()
        }
    }

    func reportConfiguration(_ configuration: Configuration, for id: UUID) {
        guard consumers.contains(id) else { return }
        configurations[id] = configuration
        guard consumers.first == id else { return }
        apply(configuration)
    }

    func applyAppConfiguration(_ configuration: Configuration) {
        apply(configuration)
    }

    func handleWake() {
        guard isActive else { return }
        onWake()
    }

    func handleSurfaceEvent() {
        guard isActive else { return }
        onSurfaceEvent()
    }

    func handleCadenceEvent() {
        guard isActive else { return }
        onCadenceEvent()
    }

    private func apply(_ configuration: Configuration) {
        guard appliedConfiguration != configuration else { return }
        appliedConfiguration = configuration
        onConfiguration(configuration)
        setAppOwnerActive(keepsAppOwnerActive(configuration))
    }


    private var isActive: Bool {
        appOwnerActive || !consumers.isEmpty
    }
}

struct DashboardRuntimeConfiguration: Equatable {
    let floatingPanelEnabled: Bool
    let statusBarPanelEnabled: Bool
    let floatingPanelScale: FloatingTokenPanelScale
    let floatingPanelVisibility: FloatingPanelContentVisibility
    let floatingPanelLocked: Bool
    let preciseTokenCountingEnabled: Bool
    let providerSyncVisible: Bool
    let radarDetailsVisible: Bool
    let statusBarMetricConfiguration: StatusBarMetricConfiguration
    let statusSummaryConfiguration: StatusSummaryConfiguration

    init(
        floatingPanelEnabled: Bool,
        statusBarPanelEnabled: Bool,
        floatingPanelScale: FloatingTokenPanelScale,
        floatingPanelVisibility: FloatingPanelContentVisibility,
        floatingPanelLocked: Bool,
        preciseTokenCountingEnabled: Bool,
        providerSyncVisible: Bool,
        radarDetailsVisible: Bool,
        statusBarMetricConfiguration: StatusBarMetricConfiguration = .default,
        statusSummaryConfiguration: StatusSummaryConfiguration = .default
    ) {
        self.floatingPanelEnabled = floatingPanelEnabled
        self.statusBarPanelEnabled = statusBarPanelEnabled
        self.floatingPanelScale = floatingPanelScale
        self.floatingPanelVisibility = floatingPanelVisibility
        self.floatingPanelLocked = floatingPanelLocked
        self.preciseTokenCountingEnabled = preciseTokenCountingEnabled
        self.providerSyncVisible = providerSyncVisible
        self.radarDetailsVisible = radarDetailsVisible
        self.statusBarMetricConfiguration = statusBarMetricConfiguration
        self.statusSummaryConfiguration = statusSummaryConfiguration
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.floatingPanelEnabled == rhs.floatingPanelEnabled
            && lhs.statusBarPanelEnabled == rhs.statusBarPanelEnabled
            && lhs.floatingPanelScale == rhs.floatingPanelScale
            && lhs.floatingPanelVisibility == rhs.floatingPanelVisibility
            && lhs.floatingPanelLocked == rhs.floatingPanelLocked
            && lhs.preciseTokenCountingEnabled == rhs.preciseTokenCountingEnabled
            && lhs.providerSyncVisible == rhs.providerSyncVisible
            && lhs.radarDetailsVisible == rhs.radarDetailsVisible
            && lhs.statusBarMetricConfiguration == rhs.statusBarMetricConfiguration
            && lhs.statusSummaryConfiguration == rhs.statusSummaryConfiguration
    }
}

enum DashboardBackgroundOwnerActivity {
    static func shouldRunExpensiveOwners(
        dashboardVisible: Bool,
        floatingPanelEnabled: Bool,
        statusBarPanelEnabled: Bool,
        statusSummaryPresented: Bool = false
    ) -> Bool {
        dashboardVisible
            || floatingPanelEnabled
            || statusBarPanelEnabled
            || statusSummaryPresented
    }

    static func onlyCompactSurfaceVisible(
        dashboardVisible: Bool,
        floatingPanelEnabled: Bool,
        statusBarPanelEnabled: Bool,
        statusSummaryPresented: Bool
    ) -> Bool {
        !dashboardVisible
            && !statusSummaryPresented
            && (floatingPanelEnabled || statusBarPanelEnabled)
    }
}

@MainActor
struct DashboardRuntimeComposition {
    let usageStore: CodexUsageStore
    let quotaStore: AccountQuotaStore
    let quotaHistoryStore: QuotaHistoryStore
    let radarStore: CodexRadarStore
    let providerSyncStore: ProviderSyncStore
    let taskCompletionMonitor: TaskCompletionMonitor
    let liveMonitor: LiveRateMonitor
    let sourceTransitionCoordinator: DashboardSourceTransitionCoordinator
}

@MainActor
final class DashboardRuntime: ObservableObject {
    let usageStore: CodexUsageStore
    let quotaStore: AccountQuotaStore
    let quotaHistoryStore: QuotaHistoryStore
    let radarStore: CodexRadarStore
    let providerSyncStore: ProviderSyncStore
    let taskCompletionMonitor: TaskCompletionMonitor
    let liveMonitor: LiveRateMonitor
    let sourceTransitionCoordinator: DashboardSourceTransitionCoordinator

    private let startupAction: (() -> Void)?
    private let floatingPanel: FloatingTokenPanelController
    private let statusBarPanel: StatusBarTokenController
    private let settings: UserDefaults
    private let notificationCenter: NotificationCenter
    private let automaticInterfaceScaleProvider: @MainActor () -> Double
    private let surfaceApplyAction: ((DashboardRuntimeConfiguration) -> Void)?
    private let sideEffectStartAction: (() -> Void)?
    private let sideEffectStopAction: (() -> Void)?
    private let backgroundOwnerActivityAction: ((Bool) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private var cadenceRecoveryTask: Task<Void, Never>?
    private var isCorrectingFloatingPanelScale = false
    private var expensiveOwnersActive: Bool?
    private var autoResumeQuotaBackgroundEnabled = false
    private(set) var statusBarSummaryPresented = false
    private var dashboardOpenAction: (() -> Void)?
    private(set) var configuration: DashboardRuntimeConfiguration?
    private(set) var isStarted = false

    private lazy var sideEffects = DashboardRuntimeSideEffectCoordinator<DashboardRuntimeConfiguration>(
        onStart: { [weak self] in self?.startSideEffects() },
        onStop: { [weak self] in self?.stopSideEffects() },
        onWake: { [weak self] in self?.refreshForSystemWake() },
        onSurfaceEvent: { [weak self] in self?.bindDisplaySurfaces() },
        onCadenceEvent: { [weak self] in
            self?.updateUsageRefreshCadence()
            self?.updateBackgroundOwnerActivity()
        },
        onConfiguration: { [weak self] configuration in
            self?.configuration = configuration
            self?.liveMonitor.setPreciseTokenCountingEnabled(configuration.preciseTokenCountingEnabled)
            self?.bindDisplaySurfaces()
            self?.updateUsageRefreshCadence()
            self?.updateBackgroundOwnerActivity()
        },
        keepsAppOwnerActive: { [weak self] configuration in
            configuration.floatingPanelEnabled
                || configuration.statusBarPanelEnabled
                || self?.statusBarSummaryPresented == true
        }
    )

    var activeConsumerCount: Int { sideEffects.activeConsumerCount }

    var composition: DashboardRuntimeComposition {
        DashboardRuntimeComposition(
            usageStore: usageStore,
            quotaStore: quotaStore,
            quotaHistoryStore: quotaHistoryStore,
            radarStore: radarStore,
            providerSyncStore: providerSyncStore,
            taskCompletionMonitor: taskCompletionMonitor,
            liveMonitor: liveMonitor,
            sourceTransitionCoordinator: sourceTransitionCoordinator
        )
    }

    init(
        usageStore: CodexUsageStore = CodexUsageStore(),
        quotaStore: AccountQuotaStore = AccountQuotaStore(),
        quotaHistoryStore: QuotaHistoryStore = QuotaHistoryStore(),
        radarStore: CodexRadarStore = CodexRadarStore(),
        providerSyncStore: ProviderSyncStore = ProviderSyncStore(),
        taskCompletionMonitor: TaskCompletionMonitor = TaskCompletionMonitor(),
        liveMonitor: LiveRateMonitor = LiveRateMonitor(),
        sourceTransitionCoordinator: DashboardSourceTransitionCoordinator = DashboardSourceTransitionCoordinator(),
        floatingPanel: FloatingTokenPanelController = FloatingTokenPanelController(),
        statusBarPanel: StatusBarTokenController = StatusBarTokenController(),
        settings: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        automaticInterfaceScaleProvider: (@MainActor () -> Double)? = nil,
        startupAction: (() -> Void)? = nil,
        surfaceApplyAction: ((DashboardRuntimeConfiguration) -> Void)? = nil,
        sideEffectStartAction: (() -> Void)? = nil,
        sideEffectStopAction: (() -> Void)? = nil,
        backgroundOwnerActivityAction: ((Bool) -> Void)? = nil
    ) {
        self.usageStore = usageStore
        self.quotaStore = quotaStore
        self.quotaHistoryStore = quotaHistoryStore
        self.radarStore = radarStore
        self.providerSyncStore = providerSyncStore
        self.taskCompletionMonitor = taskCompletionMonitor
        self.liveMonitor = liveMonitor
        self.sourceTransitionCoordinator = sourceTransitionCoordinator
        self.floatingPanel = floatingPanel
        self.statusBarPanel = statusBarPanel
        self.settings = settings
        self.notificationCenter = notificationCenter
        self.automaticInterfaceScaleProvider = automaticInterfaceScaleProvider ?? { [weak floatingPanel] in
            InterfaceScaleSettings.autoScale(
                for: floatingPanel?.panel?.screen ?? InterfaceScaleSettings.activeScreen()
            )
        }
        self.startupAction = startupAction
        self.surfaceApplyAction = surfaceApplyAction
        self.sideEffectStartAction = sideEffectStartAction
        self.sideEffectStopAction = sideEffectStopAction
        self.backgroundOwnerActivityAction = backgroundOwnerActivityAction
    }

    func acquireConsumer(_ id: UUID, preciseTokenCountingEnabled: Bool = false) {
        liveMonitor.setPreciseTokenCountingEnabled(preciseTokenCountingEnabled)
        if !isStarted {
            isStarted = true
            if let startupAction {
                startupAction()
            } else {
                quotaStore.setHistoryStore(quotaHistoryStore)
                quotaHistoryStore.start()
                synchronizeSourceTransition()
                quotaStore.start(dataSource: usageStore.currentDataSource)
                radarStore.start()
            }
        } else if startupAction == nil {
            synchronizeSourceTransition()
        }
        sideEffects.acquire(id)
    }

    func releaseConsumer(_ id: UUID) {
        sideEffects.release(id)
    }

    func setDashboardOpenAction(_ action: @escaping () -> Void) {
        dashboardOpenAction = action
    }

    func reportConfiguration(_ configuration: DashboardRuntimeConfiguration, for id: UUID) {
        sideEffects.reportConfiguration(normalizedConfiguration(configuration), for: id)
    }

    func reportConfiguration(
        floatingPanelEnabled: Bool,
        statusBarPanelEnabled: Bool,
        floatingPanelVisibility: FloatingPanelContentVisibility,
        floatingPanelLocked: Bool,
        preciseTokenCountingEnabled: Bool,
        providerSyncVisible: Bool,
        radarDetailsVisible: Bool,
        statusBarMetricConfiguration: StatusBarMetricConfiguration = .default,
        statusSummaryConfiguration: StatusSummaryConfiguration = .default,
        for id: UUID
    ) {
        sideEffects.reportConfiguration(
            DashboardRuntimeConfiguration(
                floatingPanelEnabled: floatingPanelEnabled,
                statusBarPanelEnabled: statusBarPanelEnabled,
                floatingPanelScale: resolveFloatingPanelScaleFromSettings(),
                floatingPanelVisibility: floatingPanelVisibility,
                floatingPanelLocked: floatingPanelLocked,
                preciseTokenCountingEnabled: preciseTokenCountingEnabled,
                providerSyncVisible: providerSyncVisible,
                radarDetailsVisible: radarDetailsVisible,
                statusBarMetricConfiguration: statusBarMetricConfiguration,
                statusSummaryConfiguration: statusSummaryConfiguration
            ),
            for: id
        )
    }

    func toggleFloatingPanelLock() {
        guard let configuration else { return }
        settings.set(!configuration.floatingPanelLocked, forKey: "floatingPanelLocked")
        applyAppConfiguration(configuration.replacing(
            floatingPanelLocked: !configuration.floatingPanelLocked
        ))
    }

    func closeFloatingPanel() {
        guard let configuration, configuration.floatingPanelEnabled else { return }
        settings.set(false, forKey: "floatingPanelEnabled")
        applyAppConfiguration(configuration.replacing(floatingPanelEnabled: false))
    }

    func closeStatusBarPanel() {
        guard let configuration, configuration.statusBarPanelEnabled else { return }
        settings.set(false, forKey: "statusBarPanelEnabled")
        applyAppConfiguration(configuration.replacing(statusBarPanelEnabled: false))
    }

    func setStatusBarSummaryPresented(_ presented: Bool) {
        guard configuration != nil, statusBarSummaryPresented != presented else { return }
        statusBarSummaryPresented = presented
        if presented {
            sideEffects.setAppOwnerActive(true)
        }
        updateUsageRefreshCadence()
        updateBackgroundOwnerActivity()
        if !presented {
            let keepsPersistentOwner = configuration.map {
                $0.floatingPanelEnabled || $0.statusBarPanelEnabled
            } ?? false
            sideEffects.setAppOwnerActive(keepsPersistentOwner)
        }
    }

    func setAutoResumeQuotaBackgroundEnabled(_ enabled: Bool) {
        guard autoResumeQuotaBackgroundEnabled != enabled else { return }
        autoResumeQuotaBackgroundEnabled = enabled
        if enabled {
            quotaStore.setHistoryStore(quotaHistoryStore)
            quotaHistoryStore.start()
            synchronizeSourceTransition()
            quotaStore.start(dataSource: usageStore.currentDataSource)
        } else if expensiveOwnersActive != true {
            quotaStore.stop()
        }
    }

    @discardableResult
    func synchronizeSourceTransition() -> DashboardSourceTransitionResult {
        sourceTransitionCoordinator.transition(
            to: usageStore.currentDataSource,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskCompletionMonitor,
            providerSyncStore: providerSyncStore
        )
    }

    func refreshAllData(trigger: DashboardRefreshTrigger, context: DashboardRefreshContext) {
        let plan = DashboardRefreshPlan.make(trigger: trigger, context: context)
        for action in plan.actions {
            switch action {
            case .refreshUsage:
                usageStore.refresh()
                synchronizeSourceTransition()
            case let .refreshQuota(force):
                quotaStore.refresh(force: force)
            case .refreshRadar:
                radarStore.refresh()
            case .scanProviders:
                providerSyncStore.scan(dataSource: providerSyncStore.currentDataSource)
            case .reloadQuotaHistoryTimeline:
                quotaHistoryStore.reload()
            }
        }
    }

    private func startSideEffects() {
        sideEffectStartAction?()
        guard cancellables.isEmpty else { return }
        notificationCenter.publisher(
            for: UserDefaults.didChangeNotification,
            object: settings
        ).sink { [weak self] _ in
            self?.refreshFloatingPanelScaleFromSettings()
        }.store(in: &cancellables)
        for name in [
            NSWindow.didChangeScreenNotification,
            NSApplication.didChangeScreenParametersNotification
        ] {
            notificationCenter.publisher(for: name).sink { [weak self] _ in
                self?.refreshFloatingPanelScaleFromSettings()
            }.store(in: &cancellables)
        }

        guard startupAction == nil else { return }
        usageStore.$dataSourceBindingKey.dropFirst().sink { [weak self] _ in
            self?.synchronizeSourceTransition()
        }.store(in: &cancellables)
        radarStore.$snapshot.dropFirst().sink { [weak self] _ in
            self?.sideEffects.handleSurfaceEvent()
        }.store(in: &cancellables)
        radarStore.$diagnostics.dropFirst().sink { [weak self] _ in
            self?.sideEffects.handleSurfaceEvent()
        }.store(in: &cancellables)
        radarStore.$staleDataDisplayed.dropFirst().sink { [weak self] _ in
            self?.sideEffects.handleSurfaceEvent()
        }.store(in: &cancellables)
        radarStore.$feedStaleDataDisplayed.dropFirst().sink { [weak self] _ in
            self?.sideEffects.handleSurfaceEvent()
        }.store(in: &cancellables)
        liveMonitor.$totalSnapshot.dropFirst().sink { [weak self] _ in
            self?.sideEffects.handleCadenceEvent()
        }.store(in: &cancellables)

        let appNotifications = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSApplication.didBecomeActiveNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ]
        for name in appNotifications {
            notificationCenter.publisher(for: name).sink { [weak self] _ in
                self?.sideEffects.handleCadenceEvent()
            }.store(in: &cancellables)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.sideEffects.handleWake() }
            .store(in: &cancellables)
    }

    private func stopSideEffects() {
        cancellables.removeAll()
        cadenceRecoveryTask?.cancel()
        cadenceRecoveryTask = nil
        applyBackgroundOwnerActivity(false)
        sideEffectStopAction?()
    }

    private func updateBackgroundOwnerActivity() {
        guard let configuration else { return }
        applyBackgroundOwnerActivity(
            DashboardBackgroundOwnerActivity.shouldRunExpensiveOwners(
                dashboardVisible: hasVisibleDashboardWindow(),
                floatingPanelEnabled: configuration.floatingPanelEnabled,
                statusBarPanelEnabled: configuration.statusBarPanelEnabled,
                statusSummaryPresented: statusBarSummaryPresented
            )
        )
    }

    private func applyBackgroundOwnerActivity(_ active: Bool) {
        guard expensiveOwnersActive != active else { return }
        expensiveOwnersActive = active
        if let backgroundOwnerActivityAction {
            backgroundOwnerActivityAction(active)
            return
        }
        usageStore.setBackgroundActivityEnabled(active)
        liveMonitor.setPollingActive(active)
        if active {
            quotaStore.start(dataSource: usageStore.currentDataSource)
            radarStore.start()
        } else {
            if !autoResumeQuotaBackgroundEnabled {
                quotaStore.stop()
            }
            radarStore.stop()
        }
    }

    private func bindDisplaySurfaces() {
        guard let configuration else { return }
        if let surfaceApplyAction {
            surfaceApplyAction(configuration)
            _ = correctFloatingPanelScaleAfterBinding(configuration)
            return
        }
        if configuration.floatingPanelEnabled {
            floatingPanel.show(
                store: usageStore,
                monitor: liveMonitor,
                quota: quotaStore,
                radar: radarStore,
                taskCompletionMonitor: taskCompletionMonitor,
                scale: configuration.floatingPanelScale,
                visibility: configuration.floatingPanelVisibility,
                isLocked: configuration.floatingPanelLocked,
                onOpenDashboard: { [weak self] in self?.dashboardOpenAction?() },
                onToggleLock: { [weak self] in self?.toggleFloatingPanelLock() },
                onClose: { [weak self] in self?.closeFloatingPanel() }
            )
            if correctFloatingPanelScaleAfterBinding(configuration) {
                return
            }
        } else {
            floatingPanel.close()
        }
        statusBarPanel.show(
            store: usageStore,
            monitor: liveMonitor,
            quota: quotaStore,
            radar: radarStore,
            taskCompletionMonitor: taskCompletionMonitor,
            metricsEnabled: configuration.statusBarPanelEnabled,
            configuration: configuration.statusBarMetricConfiguration,
            summaryConfiguration: configuration.statusSummaryConfiguration,
            onOpenDashboard: { [weak self] in self?.dashboardOpenAction?() },
            onOpenSettings: { [weak self] in
                guard let self else { return }
                AppSettingsRouteRequest.request(
                    .statusBar,
                    defaults: self.settings,
                    notificationCenter: self.notificationCenter
                )
                self.dashboardOpenAction?()
            },
            onClose: { [weak self] in self?.closeStatusBarPanel() },
            onPopoverPresentationChanged: { [weak self] presented in
                self?.setStatusBarSummaryPresented(presented)
            }
        )
    }

    private func updateUsageRefreshCadence() {
        guard let configuration else { return }
        let onlyCompactSurfaceVisible = DashboardBackgroundOwnerActivity.onlyCompactSurfaceVisible(
            dashboardVisible: hasVisibleDashboardWindow(),
            floatingPanelEnabled: configuration.floatingPanelEnabled,
            statusBarPanelEnabled: configuration.statusBarPanelEnabled,
            statusSummaryPresented: statusBarSummaryPresented
        )
        let decision = UsageRefreshCadencePolicy.decision(
            snapshot: liveMonitor.totalSnapshot,
            onlyCompactSurfaceVisible: onlyCompactSurfaceVisible
        )
        usageStore.setOnlyCompactSurfaceVisible(onlyCompactSurfaceVisible)
        usageStore.setRefreshInterval(decision.interval)
        UsageRefreshCadenceRecoveryScheduler.schedule(
            replacing: &cadenceRecoveryTask,
            after: decision.recoveryDelay
        ) { [weak self] in
            self?.updateUsageRefreshCadence()
        }
    }

    private func refreshFloatingPanelScaleFromSettings() {
        guard let configuration, configuration.floatingPanelEnabled else { return }
        let scale = resolveFloatingPanelScaleFromSettings()
        guard scale != configuration.floatingPanelScale else { return }
        sideEffects.applyAppConfiguration(configuration.replacing(floatingPanelScale: scale))
    }

    private func resolveFloatingPanelScaleFromSettings() -> FloatingTokenPanelScale {
        let baseScale = (settings.object(forKey: "floatingPanelScale") as? NSNumber)?.doubleValue
            ?? FloatingTokenPanelMetrics.defaultScale
        let autoEnabled = (settings.object(forKey: InterfaceScaleSettings.autoEnabledKey) as? NSNumber)?.boolValue
            ?? InterfaceScaleSettings.defaultAutoEnabled
        let manualMultiplier = (settings.object(forKey: InterfaceScaleSettings.manualMultiplierKey) as? NSNumber)?.doubleValue
            ?? InterfaceScaleSettings.defaultManualMultiplier
        let interfaceScale = autoEnabled
            ? InterfaceScaleSettings.clampedEffective(automaticInterfaceScaleProvider())
            : InterfaceScaleSettings.effectiveScale(
                manualMultiplier: manualMultiplier,
                autoEnabled: false,
                screen: nil
            )
        return FloatingTokenPanelScale(
            baseScale: baseScale,
            interfaceScale: CGFloat(interfaceScale)
        )
    }

    private func normalizedConfiguration(
        _ configuration: DashboardRuntimeConfiguration
    ) -> DashboardRuntimeConfiguration {
        configuration.replacing(floatingPanelScale: resolveFloatingPanelScaleFromSettings())
    }

    @discardableResult
    private func correctFloatingPanelScaleAfterBinding(
        _ configuration: DashboardRuntimeConfiguration
    ) -> Bool {
        guard configuration.floatingPanelEnabled, !isCorrectingFloatingPanelScale else { return false }
        let normalized = normalizedConfiguration(configuration)
        guard normalized.floatingPanelScale != configuration.floatingPanelScale else { return false }
        isCorrectingFloatingPanelScale = true
        defer { isCorrectingFloatingPanelScale = false }
        sideEffects.applyAppConfiguration(normalized)
        return true
    }

    private func refreshForSystemWake() {
        guard let configuration else { return }
        let context = DashboardRefreshContext.fromSurfaces(
            providerSyncVisible: configuration.providerSyncVisible,
            appActive: NSApplication.shared.isActive,
            dashboardWindowVisible: hasVisibleDashboardWindow(),
            floatingPanelEnabled: configuration.floatingPanelEnabled,
            statusBarPanelEnabled: configuration.statusBarPanelEnabled,
            usageStale: Date().timeIntervalSince(usageStore.snapshot.generatedAt) >= 5 * 60,
            radarDetailsVisible: configuration.radarDetailsVisible,
            floatingPanelShowRadar: configuration.floatingPanelVisibility.showRadar,
            radarStale: radarStore.snapshot == nil
        )
        refreshAllData(trigger: .systemWake, context: context)
    }

    private func hasVisibleDashboardWindow() -> Bool {
        let application = NSApplication.shared
        guard !application.isHidden else { return false }
        return application.windows.contains { window in
            window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
                && !(window is NSPanel)
                && window.contentViewController != nil
        }
    }

    private func applyAppConfiguration(_ configuration: DashboardRuntimeConfiguration) {
        sideEffects.applyAppConfiguration(normalizedConfiguration(configuration))
    }
}

private extension DashboardRuntimeConfiguration {
    func replacing(
        floatingPanelEnabled: Bool? = nil,
        statusBarPanelEnabled: Bool? = nil,
        floatingPanelScale: FloatingTokenPanelScale? = nil,
        floatingPanelLocked: Bool? = nil
    ) -> DashboardRuntimeConfiguration {
        DashboardRuntimeConfiguration(
            floatingPanelEnabled: floatingPanelEnabled ?? self.floatingPanelEnabled,
            statusBarPanelEnabled: statusBarPanelEnabled ?? self.statusBarPanelEnabled,
            floatingPanelScale: floatingPanelScale ?? self.floatingPanelScale,
            floatingPanelVisibility: floatingPanelVisibility,
            floatingPanelLocked: floatingPanelLocked ?? self.floatingPanelLocked,
            preciseTokenCountingEnabled: preciseTokenCountingEnabled,
            providerSyncVisible: providerSyncVisible,
            radarDetailsVisible: radarDetailsVisible,
            statusBarMetricConfiguration: statusBarMetricConfiguration,
            statusSummaryConfiguration: statusSummaryConfiguration
        )
    }
}

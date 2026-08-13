import AppKit
import SwiftUI

/// Decides whether a stale exact-time-series marker actually needs another
/// scan for the current quota observation. Compact summaries intentionally
/// leave the heavy time series at its last exact coverage; that alone must not
/// turn every compact tick into a full rebuild. The caller still keeps the
/// explicit continuity-recovery path separate and fail-closed.
enum DashboardPreciseCatchUpPolicy {
    static let recentBinDuration: TimeInterval = 5 * 60
    static let sevenDayDuration: TimeInterval = 7 * 24 * 60 * 60

    static func needsPreciseCoverage(
        quotaUpdatedAt: Date?,
        resetAt: Date?,
        preciseCoverageAt: Date?,
        requiredLocalObservationAfter: Date?
    ) -> Bool {
        guard let quotaUpdatedAt,
              let resetAt else {
            // Without a usable quota observation there is no new account
            // boundary to compare against; wait for the normal quota path.
            return false
        }
        let cycleStart = resetAt.addingTimeInterval(-sevenDayDuration)
        let comparisonBoundary = min(
            resetAt,
            max(
                cycleStart,
                Date(
                    timeIntervalSince1970: floor(
                        quotaUpdatedAt.timeIntervalSince1970 / recentBinDuration
                    ) * recentBinDuration
                )
            )
        )
        let requiredCoverage = max(
            comparisonBoundary,
            requiredLocalObservationAfter ?? comparisonBoundary
        )
        guard let preciseCoverageAt else { return true }
        return preciseCoverageAt < requiredCoverage
    }
}

struct DashboardView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var loginItemStore: LoginItemStore
    @ObservedObject var updateSettingsStore: AppUpdateSettingsStore
    @ObservedObject var threadDeleteBridge: CodexThreadDeleteBridgeController
    @ObservedObject var autoResumeController: AutoResumeTaskManager
    private let runtime: DashboardRuntime
    @State private var runtimeConsumerID = UUID()
    @ObservedObject private var store: CodexUsageStore
    @ObservedObject private var quotaStore: AccountQuotaStore
    @ObservedObject private var quotaHistoryStore: QuotaHistoryStore
    @ObservedObject private var radarStore: CodexRadarStore
    @ObservedObject private var providerSyncStore: ProviderSyncStore
    @ObservedObject private var taskCompletionMonitor: TaskCompletionMonitor
    @ObservedObject private var liveMonitor: LiveRateMonitor
    private var sourceTransitionCoordinator: DashboardSourceTransitionCoordinator {
        runtime.sourceTransitionCoordinator
    }
    @AppStorage("floatingPanelEnabled") private var floatingPanelEnabled = true
    @AppStorage("statusBarPanelEnabled") private var statusBarPanelEnabled = true
    @AppStorage(StatusBarMetricConfiguration.versionKey) private var statusBarMetricConfigurationVersion = StatusBarMetricConfiguration.currentVersion
    @AppStorage(StatusBarMetricConfiguration.orderKey) private var statusBarMetricOrderRaw = StatusBarMetricConfiguration.defaultOrderRaw
    @AppStorage(StatusBarMetricConfiguration.selectionKey) private var statusBarMetricSelectionRaw = StatusBarMetricConfiguration.defaultSelectionRaw
    @AppStorage(StatusBarMetricConfiguration.showsIconKey) private var statusBarMetricShowsIcon = StatusBarMetricConfiguration.defaultShowsIcon
    @AppStorage(StatusBarMetricConfiguration.labelStyleKey) private var statusBarMetricLabelStyleRaw = StatusBarMetricConfiguration.defaultLabelStyle.rawValue
    @AppStorage(StatusSummaryConfiguration.versionKey) private var statusSummaryConfigurationVersion = StatusSummaryConfiguration.currentVersion
    @AppStorage(StatusSummaryConfiguration.orderKey) private var statusSummaryOrderRaw = StatusSummaryConfiguration.defaultOrderRaw
    @AppStorage(StatusSummaryConfiguration.selectionKey) private var statusSummarySelectionRaw = StatusSummaryConfiguration.defaultSelectionRaw
    @AppStorage("liveRateMonitoringEnabled") private var liveRateMonitoringEnabled = true
    @AppStorage("preciseTokenCountingEnabled") private var preciseTokenCountingEnabled = false
    @AppStorage(SharedAccountUsageAttributionSettings.enabledKey) private var sharedAccountAttributionEnabled = SharedAccountUsageAttributionSettings.defaultEnabled
    @AppStorage(SharedAccountUsageAttributionSettings.tierKey) private var sharedAccountRadarTierRaw = SharedAccountUsageAttributionSettings.defaultTier.rawValue
    @AppStorage(SharedAccountUsageAttributionSettings.priceModelKey) private var sharedAccountPriceModelRaw = OfficialAPIPriceModel.gpt56Sol.rawValue
    @AppStorage("floatingPanelOpacity") private var floatingPanelOpacity = 0.88
    @AppStorage("floatingPanelScale") private var floatingPanelScale = FloatingTokenPanelMetrics.defaultScale
    @AppStorage(InterfaceScaleSettings.autoEnabledKey) private var interfaceScaleAutoEnabled = InterfaceScaleSettings.defaultAutoEnabled
    @AppStorage(InterfaceScaleSettings.manualMultiplierKey) private var interfaceScaleManualMultiplier = InterfaceScaleSettings.defaultManualMultiplier
    @AppStorage(TokenRateScaleSettings.key) private var tokenRateFullScale = TokenRateScaleSettings.defaultValue
    @AppStorage("floatingPanelLocked") private var floatingPanelLocked = false
    @AppStorage(FloatingPanelAppearance.startHexKey) private var floatingPanelGradientStartHex = FloatingPanelAppearance.defaultStartHex
    @AppStorage(FloatingPanelAppearance.endHexKey) private var floatingPanelGradientEndHex = FloatingPanelAppearance.defaultEndHex
    @AppStorage(FloatingPanelAppearance.directionKey) private var floatingPanelGradientDirection = FloatingPanelAppearance.defaultDirection
    @AppStorage(FloatingPanelAppearance.styleKey) private var floatingPanelGradientStyle = FloatingPanelAppearance.defaultStyle
    @AppStorage(FloatingQuotaColorStyle.modeKey) private var floatingQuotaColorMode = FloatingQuotaColorStyle.defaultMode
    @AppStorage(FloatingQuotaColorStyle.fixedHexKey) private var floatingQuotaFixedHex = FloatingQuotaColorStyle.defaultFixedHex
    @AppStorage(FloatingPanelAppearance.unreadEffectKey) private var floatingPanelUnreadEffect = FloatingPanelAppearance.defaultUnreadEffect
    @AppStorage(FloatingPanelAppearance.textWhiteOverrideKey) private var floatingPanelTextTone = FloatingPanelAppearance.defaultTextWhiteOverride
    @AppStorage(FloatingPanelContentVisibility.rateAndBarKey) private var floatingPanelShowRateAndBar = FloatingPanelContentVisibility.default.showRateAndBar
    @AppStorage(FloatingPanelContentVisibility.usageStatusKey) private var floatingPanelShowUsageStatus = FloatingPanelContentVisibility.default.showUsageStatus
    @AppStorage(FloatingPanelContentVisibility.metricsKey) private var floatingPanelShowMetrics = FloatingPanelContentVisibility.default.showMetrics
    @AppStorage(FloatingPanelContentVisibility.runningThreadsKey) private var floatingPanelShowRunningThreads = FloatingPanelContentVisibility.default.showRunningThreads
    @AppStorage(FloatingPanelContentVisibility.todayModelShareKey) private var floatingPanelShowTodayModelShare = FloatingPanelContentVisibility.default.showTodayModelShare
    @AppStorage(FloatingPanelContentVisibility.todayModelCostKey) private var floatingPanelShowTodayModelCost = FloatingPanelContentVisibility.default.showTodayModelCost
    @AppStorage(FloatingPanelContentVisibility.quotaKey) private var floatingPanelShowQuota = FloatingPanelContentVisibility.default.showQuota
    @AppStorage(FloatingPanelContentVisibility.radarKey) private var floatingPanelShowRadar = FloatingPanelContentVisibility.default.showRadar
    @AppStorage(FloatingPanelContentVisibility.crowdRadarKey) private var floatingPanelShowCrowdRadar = FloatingPanelContentVisibility.default.showCrowdRadar
    @AppStorage(FloatingPanelContentVisibility.orderKey) private var floatingPanelContentOrderRaw = FloatingPanelContentVisibility.defaultOrderRaw
    @AppStorage(FloatingPanelContentVisibility.pagePairsKey) private var floatingPanelPagePairsRaw = FloatingPanelContentVisibility.defaultPagePairsRaw
    @AppStorage(FloatingPanelContentVisibility.pageNavigationArrowsKey) private var floatingPanelShowPageNavigationArrows = FloatingPanelContentVisibility.default.showPageNavigationArrows
    @AppStorage("setupGuideCompletedV01") private var setupGuideCompleted = false
    @State private var showingProviderSync = false
    @State private var showingSetupGuide = false
    @State private var showingResetCreditDetails = false
    @State private var showingCodexRadarDetails = false
    @State private var showingSharedAccountAttributionDetails = false
    @State private var showingInterfaceScaleMenu = false
    @State private var showingPaletteMenu = false
    @State private var showingUnreadEffectMenu = false
    @State private var showingContentSettingsMenu = false
    @State private var showingAppSettings = false
    @State private var showingSessionManager = false
    @State private var appSettingsInitialCategory: AppSettingsCategory = .general
    @State private var exportAlert: DashboardExportAlertPresentation?
    @State private var sharedAccountAttributionResult: SharedAccountUsageAttributionResult?
    private let sharedAccountSafetyDatabase = SharedAccountUsageSafetyDatabase.shared
    private let sharedAccountHighWatermarkStore = UserDefaultsSharedAccountUsageHighWatermarkStore(
        safetyDatabase: .shared
    )
    private let sharedAccountSegmentStore = UserDefaultsSharedAccountUsageSegmentStore(
        safetyDatabase: .shared
    )

    init(
        loginItemStore: LoginItemStore,
        updateSettingsStore: AppUpdateSettingsStore,
        threadDeleteBridge: CodexThreadDeleteBridgeController,
        autoResumeController: AutoResumeTaskManager,
        runtime: DashboardRuntime
    ) {
        self.loginItemStore = loginItemStore
        self.updateSettingsStore = updateSettingsStore
        self.threadDeleteBridge = threadDeleteBridge
        self.autoResumeController = autoResumeController
        self.runtime = runtime
        let composition = runtime.composition
        _store = ObservedObject(wrappedValue: composition.usageStore)
        _quotaStore = ObservedObject(wrappedValue: composition.quotaStore)
        _quotaHistoryStore = ObservedObject(wrappedValue: composition.quotaHistoryStore)
        _radarStore = ObservedObject(wrappedValue: composition.radarStore)
        _providerSyncStore = ObservedObject(wrappedValue: composition.providerSyncStore)
        _taskCompletionMonitor = ObservedObject(wrappedValue: composition.taskCompletionMonitor)
        _liveMonitor = ObservedObject(wrappedValue: composition.liveMonitor)
        DisplayModeMigration.repairStartup()
    }

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .ignoresSafeArea()
                .onTapGesture {
                    NotificationCenter.default.post(name: .dashboardBlankAreaClicked, object: nil)
                }

            GeometryReader { proxy in
                let requestedScale = requestedInterfaceScale
                let contentScale = InterfaceScaleSettings.dashboardScale(
                    requestedScale: requestedScale,
                    availableWidth: proxy.size.width
                )
                let logicalWidth = proxy.size.width / max(contentScale, 0.1)

                ScrollView(.vertical, showsIndicators: false) {
                    InterfaceScaledContainer(scale: contentScale, visualWidth: proxy.size.width) {
                        dashboardContent(logicalWidth: logicalWidth)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showingResetCreditDetails {
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        AppTheme.pageBackground.opacity(0.32)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showingResetCreditDetails = false
                            }

                        AccountQuotaResetCreditDetailView(
                            snapshot: quotaStore.snapshot,
                            onClose: { showingResetCreditDetails = false }
                        )
                        .frame(width: min(560, max(460, proxy.size.width - 108)))
                        .frame(maxHeight: max(360, proxy.size.height - 90))
                        .padding(.top, 78)
                    }
                }
                .zIndex(9)
            }

            if showingCodexRadarDetails {
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        AppTheme.pageBackground.opacity(0.34)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showingCodexRadarDetails = false
                            }

                        radarDetailOverlayCard
                        .frame(width: min(900, max(680, proxy.size.width - 108)))
                        .frame(maxHeight: max(520, proxy.size.height - 90))
                        .padding(.top, 58)
                    }
                }
                .zIndex(9)
            }

            if showingSharedAccountAttributionDetails,
               let sharedAccountAttributionResult {
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        AppTheme.pageBackground.opacity(0.34)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showingSharedAccountAttributionDetails = false
                            }

                        SharedAccountUsageAttributionDetailView(
                            result: sharedAccountAttributionResult,
                            safetyRecoveryState: store.sharedAccountSafetyRecoveryState,
                            recoveryAvailable: sharedAccountSafetyDatabase.recoveryRequired,
                            onRebuildSafetyBaseline: {
                                Task { @MainActor in
                                    if await store.rebuildSharedAccountSafetyBaseline() {
                                        quotaStore.refresh(force: true)
                                    }
                                }
                            },
                            onClose: { showingSharedAccountAttributionDetails = false }
                        )
                        .frame(width: min(820, max(680, proxy.size.width - 108)))
                        .frame(maxHeight: max(520, proxy.size.height - 90))
                        .padding(.top, 58)
                    }
                }
                .zIndex(9)
            }

            if showingInterfaceScaleMenu {
                GeometryReader { proxy in
                    let cardFrame = centeredInterfaceScaleCardFrame(in: proxy, width: 358, estimatedHeight: 352)

                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showingInterfaceScaleMenu = false
                            }

                        InterfaceScaleSettingsCard(
                            autoEnabled: $interfaceScaleAutoEnabled,
                            manualMultiplier: $interfaceScaleManualMultiplier,
                            closeAction: { showingInterfaceScaleMenu = false }
                        )
                        .frame(width: cardFrame.width)
                        .offset(x: cardFrame.minX, y: cardFrame.minY)
                    }
                }
                .zIndex(11)
                .transition(.identity)
            }

        }
        .overlayPreferenceValue(FloatingPanelPaletteButtonBoundsKey.self) { anchor in
            GeometryReader { proxy in
                if showingPaletteMenu {
                    let cardFrame = floatingSettingsCardFrame(in: proxy, anchor: anchor, width: 338, estimatedHeight: 430)

                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                closePaletteMenu()
                            }

                        FloatingPanelPaletteMenu(
                            startHex: $floatingPanelGradientStartHex,
                            endHex: $floatingPanelGradientEndHex,
                            directionRaw: $floatingPanelGradientDirection,
                            styleRaw: $floatingPanelGradientStyle,
                            quotaModeRaw: $floatingQuotaColorMode,
                            quotaFixedHex: $floatingQuotaFixedHex,
                            closeAction: closePaletteMenu
                        )
                        .frame(width: cardFrame.width)
                        .offset(x: cardFrame.minX, y: cardFrame.minY)
                    }
                    .zIndex(10)
                    .transition(.identity)
                }
            }
        }
        .overlayPreferenceValue(FloatingUnreadEffectButtonBoundsKey.self) { anchor in
            GeometryReader { proxy in
                if showingUnreadEffectMenu {
                    let cardFrame = floatingSettingsCardFrame(in: proxy, anchor: anchor, width: 332, estimatedHeight: 260)

                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showingUnreadEffectMenu = false
                            }

                        FloatingUnreadEffectMenu(
                            selection: $floatingPanelUnreadEffect,
                            closeAction: { showingUnreadEffectMenu = false }
                        )
                        .frame(width: cardFrame.width)
                        .offset(x: cardFrame.minX, y: cardFrame.minY)
                    }
                    .zIndex(10)
                    .transition(.identity)
                }
            }
        }
        .overlayPreferenceValue(FloatingPanelContentSettingsButtonBoundsKey.self) { anchor in
            GeometryReader { proxy in
                if showingContentSettingsMenu {
                    let cardFrame = floatingSettingsCardFrame(in: proxy, anchor: anchor, width: 312, estimatedHeight: 316)

                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showingContentSettingsMenu = false
                            }

                        FloatingPanelContentSettingsMenu(
                            closeAction: { showingContentSettingsMenu = false }
                        )
                        .frame(width: cardFrame.width)
                        .offset(x: cardFrame.minX, y: cardFrame.minY)
                    }
                    .zIndex(10)
                    .transition(.identity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.isInitialLoading)
        .onExitCommand {
            showingResetCreditDetails = false
            showingCodexRadarDetails = false
            showingSharedAccountAttributionDetails = false
            closePaletteMenu()
            showingUnreadEffectMenu = false
            showingContentSettingsMenu = false
            showingInterfaceScaleMenu = false
        }
        .onAppear {
            runtime.setDashboardOpenAction {
                StartupPresentation.showDashboardWindow {
                    openWindow(id: "dashboard")
                }
            }
            applyDisplaySurfaceDefaultsIfNeeded()
            runtime.acquireConsumer(
                runtimeConsumerID,
                preciseTokenCountingEnabled: preciseTokenCountingEnabled
            )
            reportRuntimeConfiguration()
            consumePendingSettingsRequest()
            migrateSharedAccountPriceModelIfNeeded()
            refreshSharedAccountAttribution()
            if !setupGuideCompleted {
                showingSetupGuide = true
            } else {
                StartupPresentation.hideDashboardIfNeeded()
            }
        }
        .onChange(of: runtimeConfigurationSignature) {
            reportRuntimeConfiguration()
        }
        .onChange(of: sharedAccountAttributionInputSignature) {
            refreshSharedAccountAttribution()
        }
        .onChange(of: showingInterfaceScaleMenu) {
            guard showingInterfaceScaleMenu else { return }
            closePaletteMenu()
            showingUnreadEffectMenu = false
            showingContentSettingsMenu = false
            showingResetCreditDetails = false
            showingCodexRadarDetails = false
            showingSharedAccountAttributionDetails = false
        }
        .onChange(of: showingPaletteMenu) {
            guard showingPaletteMenu else { return }
            showingInterfaceScaleMenu = false
            showingContentSettingsMenu = false
        }
        .onChange(of: showingUnreadEffectMenu) {
            guard showingUnreadEffectMenu else { return }
            showingInterfaceScaleMenu = false
            showingContentSettingsMenu = false
        }
        .onChange(of: showingContentSettingsMenu) {
            guard showingContentSettingsMenu else { return }
            closePaletteMenu()
            showingUnreadEffectMenu = false
            showingInterfaceScaleMenu = false
            showingResetCreditDetails = false
            showingCodexRadarDetails = false
            showingSharedAccountAttributionDetails = false
        }
        .onDisappear {
            runtime.releaseConsumer(runtimeConsumerID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardBlankAreaClicked)) { _ in
            showingResetCreditDetails = false
            showingCodexRadarDetails = false
            showingSharedAccountAttributionDetails = false
            closePaletteMenu()
            showingUnreadEffectMenu = false
            showingContentSettingsMenu = false
            showingInterfaceScaleMenu = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            showingCodexRadarDetails = false
            showingSharedAccountAttributionDetails = false
            closePaletteMenu()
            showingUnreadEffectMenu = false
            showingContentSettingsMenu = false
            showingInterfaceScaleMenu = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardShowSettings)) { notification in
            let pendingCategory = AppSettingsRouteRequest.consume()
            if let category = notification.object as? AppSettingsCategory ?? pendingCategory {
                appSettingsInitialCategory = category
            }
            showingAppSettings = true
        }
        .sheet(isPresented: $showingProviderSync) {
            ProviderSyncPage(
                store: providerSyncStore,
                dataSource: providerSyncStore.currentDataSource
            )
        }
        .sheet(isPresented: $showingSessionManager) {
            SessionManagementView(
                dataSource: store.currentDataSource,
                autoResumeManager: autoResumeController,
                onClose: { showingSessionManager = false }
            )
            .frame(idealWidth: 1180, idealHeight: 760)
        }
        .sheet(isPresented: $showingSetupGuide) {
            InterfaceScaledContainer(scale: requestedInterfaceScale, visualWidth: 560 * requestedInterfaceScale) {
                SetupGuideView(
                    dataSource: store.currentDataSource,
                    dataSourceLabel: store.dataSourceLabel,
                    dataSourceOrigin: store.dataSourceOrigin,
                    loginItemStore: loginItemStore,
                    updateSettingsStore: updateSettingsStore,
                    onChooseDirectory: {
                        store.chooseDataSourceDirectory()
                        synchronizeSourceTransition()
                    },
                    onFinish: {
                        setupGuideCompleted = true
                        showingSetupGuide = false
                    }
                )
            }
        }
        .sheet(isPresented: $showingAppSettings) {
            AppSettingsView(
                loginItemStore: loginItemStore,
                updateSettingsStore: updateSettingsStore,
                autoResumeController: autoResumeController,
                threadDeleteBridge: threadDeleteBridge,
                selectedCategory: $appSettingsInitialCategory,
                floatingPanelEnabled: $floatingPanelEnabled,
                statusBarPanelEnabled: $statusBarPanelEnabled,
                statusBarMetricShowsIcon: $statusBarMetricShowsIcon,
                statusBarMetricOrderRaw: $statusBarMetricOrderRaw,
                statusBarMetricSelectionRaw: $statusBarMetricSelectionRaw,
                statusBarMetricLabelStyleRaw: $statusBarMetricLabelStyleRaw,
                statusSummaryOrderRaw: $statusSummaryOrderRaw,
                statusSummarySelectionRaw: $statusSummarySelectionRaw,
                statusBarPreviewValues: statusBarMetricValues,
                liveRateMonitoringEnabled: $liveRateMonitoringEnabled,
                preciseTokenCountingEnabled: $preciseTokenCountingEnabled,
                tokenRateFullScale: $tokenRateFullScale,
                floatingPanelLocked: $floatingPanelLocked,
                interfaceScaleAutoEnabled: $interfaceScaleAutoEnabled,
                interfaceScaleManualMultiplier: $interfaceScaleManualMultiplier,
                floatingPanelOpacity: $floatingPanelOpacity,
                floatingPanelScale: $floatingPanelScale,
                floatingPanelTextTone: $floatingPanelTextTone,
                gradientStartHex: $floatingPanelGradientStartHex,
                gradientEndHex: $floatingPanelGradientEndHex,
                gradientDirection: $floatingPanelGradientDirection,
                gradientStyle: $floatingPanelGradientStyle,
                quotaColorMode: $floatingQuotaColorMode,
                quotaFixedHex: $floatingQuotaFixedHex,
                unreadEffect: $floatingPanelUnreadEffect,
                showRateAndBar: $floatingPanelShowRateAndBar,
                showUsageStatus: $floatingPanelShowUsageStatus,
                showMetrics: $floatingPanelShowMetrics,
                showRunningThreads: $floatingPanelShowRunningThreads,
                showTodayModelShare: $floatingPanelShowTodayModelShare,
                showTodayModelCost: $floatingPanelShowTodayModelCost,
                showQuota: $floatingPanelShowQuota,
                showRadar: $floatingPanelShowRadar,
                showCrowdRadar: $floatingPanelShowCrowdRadar,
                contentOrderRaw: $floatingPanelContentOrderRaw,
                pagePairsRaw: $floatingPanelPagePairsRaw,
                showPageNavigationArrows: $floatingPanelShowPageNavigationArrows,
                floatingPreviewSnapshot: floatingPanelPreviewSnapshot,
                floatingPreviewRadarPresentation: floatingPanelPreviewRadarPresentation,
                defaultCodexHome: store.currentDataSource?.codexHome,
                dataSourceLabel: store.dataSourceLabel,
                dataSourceOrigin: store.dataSourceOrigin,
                onChooseDirectory: {
                    store.chooseDataSourceDirectory()
                    synchronizeSourceTransition()
                },
                onOpenProviderSync: {
                    providerSyncStore.scan(dataSource: providerSyncStore.currentDataSource)
                    showingAppSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showingProviderSync = true
                    }
                },
                onOpenSessionManager: {
                    showingAppSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showingSessionManager = true
                    }
                },
                onThreadDeleteConnectionAction: {
                    threadDeleteBridge.performConnectionAction()
                },
                onClose: { showingAppSettings = false }
            )
        }
        .alert(item: $exportAlert) { presentation in
            Alert(
                title: Text(presentation.title),
                message: Text(presentation.message),
                dismissButton: .default(Text("好"))
            )
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    refreshAllData()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)

                Button {
                    presentExportResult(Exporter.exportCSV(snapshot: store.snapshot))
                } label: {
                    Label("导出 CSV", systemImage: "tablecells")
                }

                Button {
                    presentExportResult(Exporter.exportPNG(snapshot: store.snapshot))
                } label: {
                    Label("导出 PNG", systemImage: "photo")
                }
            }
        }
    }

    private var radarDetailOverlayCard: some View {
        CodexRadarDetailCard(
            snapshot: radarStore.detailDisplaySnapshot,
            crowdSnapshot: radarStore.crowdSnapshot,
            crowdStaleDataDisplayed: radarStore.crowdStaleDataDisplayed,
            feedItems: radarStore.feedItems,
            status: radarStore.detailDisplayStatus,
            isRefreshing: radarStore.isDetailRefreshing || radarStore.isRefreshing,
            diagnostics: radarStore.detailDisplayDiagnostics,
            staleDataDisplayed: radarStore.detailDisplayStaleDataDisplayed,
            feedStaleDataDisplayed: radarStore.feedStaleDataDisplayed,
            onRefresh: {
                radarStore.refreshDetail()
                radarStore.refresh()
            },
            onClose: { showingCodexRadarDetails = false }
        )
    }

    private var selectedSharedAccountRadarTier: SharedAccountRadarTier {
        SharedAccountRadarTier.storedValue(for: sharedAccountRadarTierRaw)
    }

    private var selectedSharedAccountPriceModel: OfficialAPIPriceModel {
        OfficialAPIPriceModel.storedValue(for: sharedAccountPriceModelRaw)
    }

    private var sharedAccountAttributionInputSignature: String {
        let quota = quotaStore.snapshot
        let radar = radarStore.snapshot?.modelIQ.quotaRadar
        let identity = quota.historyIdentity
        let radarRows = radar?.rows.map { row -> String in
            let sevenDay = row.sevenD.map { String($0) } ?? "-"
            return [row.tier, sevenDay, row.basis].joined(separator: ":")
        }.joined(separator: "|") ?? ""
        let usageGeneratedAt = String(format: "%.3f", store.snapshot.generatedAt.timeIntervalSince1970)
        let preciseTimeSeriesGeneratedAt = store.snapshot.preciseTimeSeriesGeneratedAt.map {
            String(format: "%.3f", $0.timeIntervalSince1970)
        } ?? ""
        let preciseContinuityLostAt = store.preciseTimeSeriesContinuityLostAt.map {
            String(format: "%.3f", $0.timeIntervalSince1970)
        } ?? ""
        let preciseContinuityLossID = store.preciseTimeSeriesContinuityLossID?.uuidString ?? ""
        let recentBinCount = String(store.snapshot.cacheUsage.recentBins.count)
        let latestBinStart = store.snapshot.cacheUsage.recentBins.last.map {
            String(format: "%.3f", $0.start.timeIntervalSince1970)
        } ?? ""
        let sevenDayQuota = quota.sevenDay.map { quota in
            let resetTimestamp = quota.resetsAt?.timeIntervalSince1970 ?? -1
            return "\(quota.usedPercent):\(resetTimestamp)"
        } ?? ""
        let quotaUpdatedAt = quota.updatedAt.map {
            String(format: "%.3f", $0.timeIntervalSince1970)
        } ?? ""
        let components: [String] = [
            sharedAccountAttributionEnabled ? "1" : "0",
            selectedSharedAccountRadarTier.rawValue,
            selectedSharedAccountPriceModel.rawValue,
            store.snapshot.usagePrecision.rawValue,
            usageGeneratedAt,
            store.preciseTimeSeriesFresh ? "precise-fresh" : "precise-stale",
            preciseTimeSeriesGeneratedAt,
            preciseContinuityLostAt,
            preciseContinuityLossID,
            store.preciseTimeSeriesContinuityLossReason?.rawValue ?? "",
            store.preciseContinuityPersistenceHealthy ? "continuity-store-ok" : "continuity-store-failed",
            String(describing: store.sharedAccountSafetyRecoveryState),
            store.preciseObservationSessionID.uuidString,
            store.preciseSessionMutationMonitoringHealthy ? "session-watch-ok" : "session-watch-failed",
            recentBinCount,
            latestBinStart,
            sevenDayQuota,
            quotaUpdatedAt,
            quota.staleDataDisplayed ? "quota-stale" : "quota-fresh",
            identity?.homeIdentity ?? "",
            identity?.stableAccountKey ?? "",
            identity?.planType ?? "",
            identity?.limitID ?? "",
            radar?.date ?? "",
            radar?.basisDate ?? "",
            radar?.updatedAt ?? "",
            radar?.sourceKind ?? "",
            radar?.sevenDayPolicy ?? "",
            radarStore.staleDataDisplayed ? "radar-stale" : "radar-fresh",
            radarRows,
        ]
        return components.joined(separator: "\u{1f}")
    }

    private func migrateSharedAccountPriceModelIfNeeded() {
        let migrated = OfficialAPIPriceModel.storedValue(for: sharedAccountPriceModelRaw).rawValue
        if migrated != sharedAccountPriceModelRaw {
            sharedAccountPriceModelRaw = migrated
        }
    }

    private func refreshSharedAccountAttribution() {
        sharedAccountSegmentStore.setObserverInstanceID(
            store.preciseObservationSessionID
        )
        let tier = selectedSharedAccountRadarTier
        let model = selectedSharedAccountPriceModel
        let quota = quotaStore.snapshot
        let radar = radarStore.snapshot?.modelIQ.quotaRadar
        let safetyLock = sharedAccountAttributionEnabled
            && sharedAccountSafetyDatabase.isObserverOwner
            ? sharedAccountSafetyDatabase.acquireCrossProcessLock()
            : nil
        defer { safetyLock?.release() }
        let storageCoordinationHealthy = !sharedAccountAttributionEnabled
            || (safetyLock != nil && sharedAccountSafetyDatabase.isObserverOwner)
        if sharedAccountAttributionEnabled, storageCoordinationHealthy {
            store.reloadPreciseTimeSeriesContinuityLoss()
        }
        let continuityLoss = store.preciseTimeSeriesContinuityLostAt
        let continuityLossID = store.preciseTimeSeriesContinuityLossID
        let continuityLossReason = store.preciseTimeSeriesContinuityLossReason
        let cacheUsage = store.snapshot.cacheUsage
        let indexSafetyGapID = UserDefaultsSharedAccountUsageSegmentStore
            .attributionSafetyGapID(
                provenanceEpoch: cacheUsage.attributionProvenanceEpoch,
                unsafeSinceGeneration: cacheUsage.attributionUnsafeSinceGeneration,
                currentScanUnsafeCauseDetected:
                    cacheUsage.attributionCurrentScanUnsafeCauseDetected
            )
        var segment: SharedAccountUsageSegment?
        if sharedAccountAttributionEnabled,
           storageCoordinationHealthy,
           let sevenDayQuota = quota.sevenDay,
           let resetAt = sevenDayQuota.resetsAt,
           resetAt > Date(),
           let historyIdentity = quota.historyIdentity {
            if !quota.staleDataDisplayed, let quotaUpdatedAt = quota.updatedAt {
                let cycleStart = resetAt.addingTimeInterval(
                    -SharedAccountUsageAttributionEstimator.sevenDayDuration
                )
                if cacheUsage.attributionCurrentScanUnsafeCauseDetected {
                    // A duplicate/rewrite is still present in the current exact
                    // scan. Do not create or advance any synthetic baseline from
                    // this quota poll; the first clean scan must reset it.
                    segment = sharedAccountSegmentStore.existingSegment(
                        identity: historyIdentity,
                        resetAt: resetAt
                    )
                } else if store.preciseTimeSeriesFresh,
                   let gapDetectedAt = continuityLoss,
                   let gapID = continuityLossID,
                   let recoveredCoverageAt = store.snapshot.preciseTimeSeriesGeneratedAt {
                    segment = sharedAccountSegmentStore.beginContinuityGapCutover(
                        identity: historyIdentity,
                        resetAt: resetAt,
                        cycleStart: cycleStart,
                        quotaUpdatedAt: quotaUpdatedAt,
                        accountUsedPercent: Double(sevenDayQuota.usedPercent),
                        gapID: gapID,
                        gapDetectedAt: gapDetectedAt,
                        recoveredCoverageAt: recoveredCoverageAt,
                        cutoverReason: continuityLossReason == .storageRecovery
                            ? .storageRecovery
                            : .continuityGap
                    )
                } else if store.preciseTimeSeriesFresh,
                          let gapID = indexSafetyGapID,
                          let unsafeSince = cacheUsage.attributionUnsafeSinceGeneration,
                          let recoveredCoverageAt = store.snapshot.preciseTimeSeriesGeneratedAt {
                    segment = sharedAccountSegmentStore.beginContinuityGapCutover(
                        identity: historyIdentity,
                        resetAt: resetAt,
                        cycleStart: cycleStart,
                        quotaUpdatedAt: quotaUpdatedAt,
                        accountUsedPercent: Double(sevenDayQuota.usedPercent),
                        gapID: gapID,
                        gapDetectedAt: store.snapshot.generatedAt,
                        recoveredCoverageAt: recoveredCoverageAt,
                        cleanRecoveryGeneration: unsafeSince
                    )
                } else {
                    let existing = sharedAccountSegmentStore.existingSegment(
                        identity: historyIdentity,
                        resetAt: resetAt
                    )
                    if let existing,
                       !existing.baselineReady,
                       existing.effectiveCutoverReason.isContinuityRecovery,
                       !store.preciseTimeSeriesFresh {
                        // A quota poll alone cannot finish a recovery cutover;
                        // wait until a new exact snapshot covers that poll.
                        segment = existing
                    } else {
                        segment = sharedAccountSegmentStore.resolve(
                            identity: historyIdentity,
                            resetAt: resetAt,
                            cycleStart: cycleStart,
                            quotaUpdatedAt: quotaUpdatedAt,
                            accountUsedPercent: Double(sevenDayQuota.usedPercent)
                        )
                    }
                }
            } else {
                segment = sharedAccountSegmentStore.existingSegment(
                    identity: historyIdentity,
                    resetAt: resetAt
                )
            }
        } else {
            segment = nil
        }
        func estimate(
            segment: SharedAccountUsageSegment?,
            highWatermark: SharedAccountUsageHighWatermarkRecord? = nil,
            forceStorageUnavailable: Bool = false
        ) -> SharedAccountUsageAttributionResult {
            SharedAccountUsageAttributionEstimator.estimate(
                enabled: sharedAccountAttributionEnabled,
                preciseUsageReady: store.snapshot.hasPreciseTokenUsage
                    && store.snapshot.cacheUsage.attributionEventsComplete,
                recentBins: store.snapshot.cacheUsage.recentBins,
                recentAttributionEvents: store.snapshot.cacheUsage.attributionEventsComplete
                    ? store.snapshot.cacheUsage.attributionEvents
                    : nil,
                attributionProvenanceEpoch:
                    store.snapshot.cacheUsage.attributionProvenanceEpoch,
                attributionSourceMutationDetected:
                    store.snapshot.cacheUsage.attributionSourceMutationDetected,
                sevenDayQuota: quota.sevenDay,
                quotaUpdatedAt: segment?.comparisonUpdatedAt ?? quota.updatedAt,
                historyIdentity: quota.historyIdentity,
                radar: radar,
                tier: tier,
                model: model,
                preciseUsageFresh: store.preciseTimeSeriesFresh,
                persistenceHealthy: !forceStorageUnavailable
                    && storageCoordinationHealthy
                    && sharedAccountSafetyDatabase.persistenceHealthy
                    && store.preciseContinuityPersistenceHealthy
                    && store.preciseSessionMutationMonitoringHealthy
                    && sharedAccountSegmentStore.persistenceHealthy
                    && sharedAccountHighWatermarkStore.persistenceHealthy,
                preciseUsageGeneratedAt: store.snapshot.preciseTimeSeriesGeneratedAt,
                segment: segment,
                highWatermark: highWatermark,
                quotaDataStale: quota.staleDataDisplayed,
                radarDataStale: radarStore.staleDataDisplayed
            )
        }

        let rawResult = estimate(segment: segment)
        var highWatermark: SharedAccountUsageHighWatermarkRecord?
        var result = rawResult
        if !cacheUsage.attributionCurrentScanUnsafeCauseDetected,
           SharedAccountUsageAttributionPersistencePolicy.shouldMergeHighWatermark(
            attributionUnsafeSinceGeneration: cacheUsage.attributionUnsafeSinceGeneration
        ),
           let key = rawResult.highWatermarkKey,
           let candidate = rawResult.highWatermarkCandidate {
            let merged = sharedAccountHighWatermarkStore.merge(candidate, for: key)
            highWatermark = merged
            result = estimate(segment: segment, highWatermark: merged)
        }

        // An unchanged quota percentage normally keeps the last meaningful
        // comparison timestamp. If known local usage is waiting in a now-closed
        // bucket, advance exactly once when a later quota poll crosses the next
        // 5-minute boundary, then ask the precise index to catch up if needed.
        if !cacheUsage.attributionCurrentScanUnsafeCauseDetected,
           result.state == .awaitingQuotaRefresh,
           result.usagePendingQuotaRefresh,
           let currentSegment = segment,
           currentSegment.baselineReady,
           let sevenDayQuota = quota.sevenDay,
           let resetAt = sevenDayQuota.resetsAt,
           resetAt > Date(),
           let actualQuotaUpdatedAt = quota.updatedAt,
           let historyIdentity = quota.historyIdentity,
           !quota.staleDataDisplayed,
           let advanced = sharedAccountSegmentStore.advanceComparisonAcrossCompletedBoundaryIfNeeded(
               identity: historyIdentity,
               resetAt: resetAt,
               quotaUpdatedAt: actualQuotaUpdatedAt,
               accountUsedPercent: Double(sevenDayQuota.usedPercent)
           ) {
            segment = advanced
            result = estimate(segment: advanced, highWatermark: highWatermark)
        }

        let attributionCatchUpRequested =
            SharedAccountUsageAttributionAutoRefreshPolicy.shouldRequestPreciseCatchUp(
                result: result,
                continuityLossID: continuityLossID,
                segment: segment
            )
        let explicitContinuityRecovery = continuityLossID != nil
            && attributionCatchUpRequested
        let quotaCoverageNeedsCatchUp = DashboardPreciseCatchUpPolicy.needsPreciseCoverage(
            quotaUpdatedAt: quota.updatedAt,
            resetAt: quota.sevenDay?.resetsAt,
            preciseCoverageAt: store.snapshot.preciseTimeSeriesGeneratedAt,
            requiredLocalObservationAfter: segment?.requiredLocalObservationAfter
        )
        if attributionCatchUpRequested,
           sharedAccountAttributionEnabled,
           !store.isUsageRefreshOrDetailHydrationActive,
           !quota.staleDataDisplayed,
           (explicitContinuityRecovery || quotaCoverageNeedsCatchUp) {
            // A manual/global refresh starts local usage and quota reads next to
            // each other, so the quota observation can finish a moment later.
            // Run one explicit full time-series pass after that point instead of
            // leaving attribution permanently stale or trusting a compact summary.
            store.refreshPreciseTimeSeriesForAttribution()
        }

        if !cacheUsage.attributionCurrentScanUnsafeCauseDetected,
           let continuityLossID,
           let segment,
           segment.effectiveCutoverReason.isContinuityRecovery,
           segment.continuityGapID == continuityLossID,
           segment.baselineReady,
           let requiredCoverage = segment.requiredLocalObservationAfter,
           store.preciseTimeSeriesFresh,
           let generatedAt = store.snapshot.preciseTimeSeriesGeneratedAt,
           generatedAt >= requiredCoverage,
           store.preciseContinuityPersistenceHealthy,
           sharedAccountSegmentStore.persistenceHealthy,
           sharedAccountHighWatermarkStore.persistenceHealthy,
           result.state != .preciseUsageStale {
            store.acknowledgePreciseTimeSeriesContinuityLoss(id: continuityLossID)
        }

        if let indexSafetyGapID,
           continuityLossID == nil,
           let segment,
           segment.effectiveCutoverReason == .continuityGap,
           segment.continuityGapID == indexSafetyGapID,
           segment.baselineReady,
           let provenanceEpoch = cacheUsage.attributionProvenanceEpoch,
           let generation = cacheUsage.attributionGeneration,
           let unsafeSince = cacheUsage.attributionUnsafeSinceGeneration,
           segment.cutoverRecoveryGeneration == unsafeSince,
           !cacheUsage.attributionCurrentScanUnsafeCauseDetected,
           store.preciseTimeSeriesFresh,
           store.preciseContinuityPersistenceHealthy,
           store.preciseSessionMutationMonitoringHealthy,
           sharedAccountSegmentStore.persistenceHealthy,
           sharedAccountHighWatermarkStore.persistenceHealthy,
           result.state != .attributionStorageUnavailable,
           result.state != .preciseUsageStale {
            // The new segment is already durable and this unsafe snapshot was
            // never merged into its high-water record. Clear only the exact
            // epoch/generation observed here; success triggers a fresh precise
            // scan before any safe-generation candidate can enter the segment.
            store.acknowledgeAttributionSafetyAfterDurableCutover(
                provenanceEpoch: provenanceEpoch,
                throughGeneration: generation
            )
        }

        if sharedAccountAttributionEnabled, storageCoordinationHealthy {
            store.reloadPreciseTimeSeriesContinuityLoss()
            if !store.preciseContinuityPersistenceHealthy
                || store.preciseTimeSeriesContinuityLossID != continuityLossID {
                // A writer that could not take the wider file lock still
                // commits the gap atomically. Recheck before publication and
                // invalidate this computation; the published continuity change
                // triggers a clean recomputation after the lock is released.
                result = estimate(
                    segment: nil,
                    forceStorageUnavailable: true
                )
            }
        }
        sharedAccountAttributionResult = result
    }

    private func presentExportResult(_ result: DashboardExportResult) {
        guard let presentation = DashboardExportAlertPresentation(result: result) else { return }
        exportAlert = presentation
    }

    @ViewBuilder
    private func dashboardContent(logicalWidth: CGFloat) -> some View {
        VStack(spacing: 18) {
            HeaderView(
                snapshot: store.snapshot,
                quotaSnapshot: quotaStore.snapshot,
                status: store.status,
                dataSourceLabel: store.dataSourceLabel,
                dataSourceOrigin: store.dataSourceOrigin,
                isRefreshing: store.isRefreshing,
                unreadThreadCount: taskCompletionMonitor.unreadThreadCount,
                runningThreadSummary: taskCompletionMonitor.runningThreadSummary,
                presentationMode: .dashboard,
                onRefresh: {
                    refreshAllData()
                },
                onMarkAllRead: {
                    taskCompletionMonitor.markAllRead()
                    reportRuntimeConfiguration()
                },
                onChangeDirectory: {
                    store.chooseDataSourceDirectory()
                    synchronizeSourceTransition()
                },
                onOpenProviderSync: {
                    showingProviderSync = true
                    providerSyncStore.scan(dataSource: providerSyncStore.currentDataSource)
                },
                onOpenSessionManagement: {
                    showingSessionManager = true
                },
                onOpenSettings: {
                    openAppSettings(.general)
                },
                onOpenSessionEnhancements: {
                    openAppSettings(.sessionEnhancements)
                },
                onOpenAutoResume: {
                    openAppSettings(.autoResume)
                },
                threadDeleteStatus: threadDeleteBridge.status,
                autoResumeEnabled: autoResumeController.hasProtectedTasks,
                showingInterfaceScaleMenu: $showingInterfaceScaleMenu,
                interfaceScaleAutoEnabled: $interfaceScaleAutoEnabled,
                interfaceScaleManualMultiplier: $interfaceScaleManualMultiplier,
                showingResetCreditDetails: $showingResetCreditDetails
            )

            StatStrip(
                snapshot: store.snapshot,
                todayModelBreakdowns: store.todayModelBreakdowns,
                planLabel: quotaStore.snapshot.planType ?? "",
                isPreparingUsageCache: store.isPreparingUsageCache,
                cacheStatus: store.status
            )

            CodexRadarStrip(
                snapshot: radarStore.snapshot,
                crowdSnapshot: radarStore.crowdSnapshot,
                crowdStaleDataDisplayed: radarStore.crowdStaleDataDisplayed,
                status: radarStore.status,
                isRefreshing: radarStore.isRefreshing,
                diagnostics: radarStore.diagnostics,
                staleDataDisplayed: radarStore.staleDataDisplayed,
                feedStaleDataDisplayed: radarStore.feedStaleDataDisplayed,
                onRefresh: radarStore.refresh,
                onShowDetails: {
                    showingSharedAccountAttributionDetails = false
                    showingCodexRadarDetails = true
                }
            )

            LiveRateView(
                monitor: liveMonitor,
                floatingPanelEnabled: $floatingPanelEnabled,
                statusBarPanelEnabled: $statusBarPanelEnabled,
                liveRateMonitoringEnabled: $liveRateMonitoringEnabled,
                floatingPanelShowRateAndBar: $floatingPanelShowRateAndBar,
                tokenRateFullScale: $tokenRateFullScale,
                onOpenSettings: { showingAppSettings = true }
            )

            ActivitySection(
                dailyUsage: store.snapshot.dailyUsage,
                cacheDaily: store.snapshot.cacheUsage.daily,
                dailyModelBreakdowns: store.snapshot.cacheUsage.dailyModelBreakdowns,
                attributionEvents: store.snapshot.cacheUsage.attributionEvents,
                quotaDaily: quotaHistoryStore.snapshot.daily,
                selectedMode: $store.selectedMode
            )

            RecentUsageChart(
                bins: store.snapshot.recentBins,
                hourlyBins: store.snapshot.hourlyUsage,
                cacheRecentBins: store.snapshot.cacheUsage.recentBins,
                cacheHourlyBins: store.snapshot.cacheUsage.hourly,
                attributionEvents: store.snapshot.cacheUsage.attributionEvents,
                attributionEventsComplete: store.snapshot.cacheUsage.attributionEventsComplete,
                quotaRecentBins: quotaHistoryStore.snapshot.recentBins,
                quotaHourlyBins: quotaHistoryStore.snapshot.hourlyBins,
                currentFiveHourQuotaPresent: quotaStore.snapshot.fiveHour != nil,
                currentSevenDayQuotaPresent: quotaStore.snapshot.sevenDay != nil,
                sharedAccountAttributionContext: sharedAccountAttributionEnabled
                    ? sharedAccountAttributionResult.map(
                        QuotaSelectionAttributionContext.init(result:)
                    )
                    : nil
            )
            // Live-rate publications invalidate DashboardView frequently. Keep an
            // unchanged historical chart out of those unrelated render passes.
            .equatable()

            CacheHitRankingSection(cacheUsage: store.snapshot.cacheUsage)
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 20)
        .frame(minWidth: logicalWidth, maxWidth: .infinity, alignment: .top)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(name: .dashboardBlankAreaClicked, object: nil)
                }
        )
    }

    private func openAppSettings(_ category: AppSettingsCategory) {
        appSettingsInitialCategory = category
        showingAppSettings = true
    }

    private func refreshAllData(trigger: DashboardRefreshTrigger = .manual) {
        let context = DashboardRefreshContext.fromSurfaces(
            providerSyncVisible: showingProviderSync,
            appActive: NSApp.isActive,
            dashboardWindowVisible: hasVisibleDashboardWindow(),
            floatingPanelEnabled: floatingPanelEnabled,
            statusBarPanelEnabled: statusBarPanelEnabled,
            usageStale: Date().timeIntervalSince(store.snapshot.generatedAt) >= 5 * 60,
            radarDetailsVisible: showingCodexRadarDetails,
            floatingPanelShowRadar: floatingPanelShowRadar,
            radarStale: radarStore.snapshot == nil
        )
        runtime.refreshAllData(trigger: trigger, context: context)
    }

    private var requestedInterfaceScale: CGFloat {
        CGFloat(
            InterfaceScaleSettings.effectiveScale(
                manualMultiplier: interfaceScaleManualMultiplier,
                autoEnabled: interfaceScaleAutoEnabled,
                screen: InterfaceScaleSettings.activeScreen()
            )
        )
    }

    private var floatingPanelContentVisibility: FloatingPanelContentVisibility {
        FloatingPanelContentVisibility(
            showRateAndBar: floatingPanelShowRateAndBar,
            showUsageStatus: floatingPanelShowUsageStatus,
            showMetrics: floatingPanelShowMetrics,
            showRunningThreads: floatingPanelShowRunningThreads,
            showTodayModelShare: floatingPanelShowTodayModelShare,
            showTodayModelCost: floatingPanelShowTodayModelCost,
            showQuota: floatingPanelShowQuota,
            showRadar: floatingPanelShowRadar,
            showCrowdRadar: floatingPanelShowCrowdRadar,
            showPageNavigationArrows: floatingPanelShowPageNavigationArrows,
            groupOrder: FloatingPanelContentVisibility.order(from: floatingPanelContentOrderRaw),
            pagePairs: FloatingPanelContentVisibility.pagePairs(from: floatingPanelPagePairsRaw)
        )
    }

    private var statusBarMetricConfiguration: StatusBarMetricConfiguration {
        StatusBarMetricConfiguration(
            version: statusBarMetricConfigurationVersion,
            orderRaw: statusBarMetricOrderRaw,
            selectionRaw: statusBarMetricSelectionRaw,
            showsIcon: statusBarMetricShowsIcon,
            labelStyle: StatusBarMetricLabelStyle(rawValue: statusBarMetricLabelStyleRaw)
                ?? StatusBarMetricConfiguration.defaultLabelStyle
        )
    }

    private var statusBarMetricValues: StatusBarMetricValues {
        let snapshot = TokenDisplaySnapshot.make(
            store: store,
            monitor: liveMonitor,
            quota: quotaStore,
            runningThreads: taskCompletionMonitor.runningThreadSummary
        )
        let radar = CodexRadarPresentationState(
            snapshot: radarStore.snapshot,
            status: radarStore.status,
            diagnostics: radarStore.diagnostics,
            staleDataDisplayed: radarStore.staleDataDisplayed,
            feedStaleDataDisplayed: radarStore.feedStaleDataDisplayed,
            crowdSnapshot: radarStore.crowdSnapshot
        )
        return StatusBarMetricValues(
            snapshot: snapshot,
            radar: radar,
            rateAvailable: liveMonitor.monitoringEnabled && liveMonitor.currentDataSourceIdentity != nil,
            unreadThreadCount: taskCompletionMonitor.statusBarUnreadThreadCount
        )
    }

    private var floatingPanelPreviewSnapshot: TokenDisplaySnapshot {
        TokenDisplaySnapshot.make(
            store: store,
            monitor: liveMonitor,
            quota: quotaStore,
            runningThreads: taskCompletionMonitor.runningThreadSummary
        )
    }

    private var floatingPanelPreviewRadarPresentation: CodexRadarPresentationState {
        CodexRadarPresentationState(
            snapshot: radarStore.snapshot,
            status: radarStore.status,
            diagnostics: radarStore.diagnostics,
            staleDataDisplayed: radarStore.staleDataDisplayed,
            feedStaleDataDisplayed: radarStore.feedStaleDataDisplayed,
            crowdSnapshot: radarStore.crowdSnapshot
        )
    }

    private var statusSummaryConfiguration: StatusSummaryConfiguration {
        StatusSummaryConfiguration(
            version: statusSummaryConfigurationVersion,
            orderRaw: statusSummaryOrderRaw,
            selectionRaw: statusSummarySelectionRaw
        )
    }

    private var runtimeConfigurationSignature: String {
        [
            floatingPanelEnabled ? "1" : "0",
            statusBarPanelEnabled ? "1" : "0",
            String(statusBarMetricConfigurationVersion),
            statusBarMetricOrderRaw,
            statusBarMetricSelectionRaw,
            statusBarMetricShowsIcon ? "1" : "0",
            statusBarMetricLabelStyleRaw,
            String(statusSummaryConfigurationVersion),
            statusSummaryOrderRaw,
            statusSummarySelectionRaw,
            String(floatingPanelScale),
            floatingPanelContentOrderRaw,
            floatingPanelShowRateAndBar ? "1" : "0",
            floatingPanelShowUsageStatus ? "1" : "0",
            floatingPanelShowMetrics ? "1" : "0",
            floatingPanelShowRunningThreads ? "1" : "0",
            floatingPanelShowTodayModelShare ? "1" : "0",
            floatingPanelShowTodayModelCost ? "1" : "0",
            floatingPanelShowQuota ? "1" : "0",
            floatingPanelShowRadar ? "1" : "0",
            floatingPanelShowCrowdRadar ? "1" : "0",
            floatingPanelPagePairsRaw,
            floatingPanelShowPageNavigationArrows ? "1" : "0",
            interfaceScaleAutoEnabled ? "1" : "0",
            String(interfaceScaleManualMultiplier),
            floatingPanelLocked ? "1" : "0",
            preciseTokenCountingEnabled ? "1" : "0",
            showingProviderSync ? "1" : "0",
            showingCodexRadarDetails ? "1" : "0"
        ].joined(separator: "|")
    }

    private func centeredInterfaceScaleCardFrame(
        in proxy: GeometryProxy,
        width: CGFloat,
        estimatedHeight: CGFloat
    ) -> CGRect {
        let cardWidth = min(width, max(300, proxy.size.width - 88))
        let x = max(44, (proxy.size.width - cardWidth) / 2)
        let availableY = max(28, proxy.size.height - estimatedHeight - 28)
        let y = min(max(28, (proxy.size.height - estimatedHeight) / 2), availableY)
        return CGRect(x: x, y: y, width: cardWidth, height: 0)
    }

    private func floatingSettingsCardFrame(
        in proxy: GeometryProxy,
        anchor: Anchor<CGRect>?,
        width: CGFloat,
        estimatedHeight: CGFloat
    ) -> CGRect {
        let cardWidth = min(width, max(292, proxy.size.width - 108))
        let horizontalMargin: CGFloat = 54
        guard let anchor else {
            return CGRect(
                x: max(horizontalMargin, (proxy.size.width - cardWidth) / 2),
                y: 142,
                width: cardWidth,
                height: 0
            )
        }

        let buttonFrame = proxy[anchor]
        let maxX = max(horizontalMargin, proxy.size.width - cardWidth - horizontalMargin)
        let x = min(max(buttonFrame.minX - 4, horizontalMargin), maxX)
        let y = min(max(buttonFrame.maxY + 8, 88), max(88, proxy.size.height - estimatedHeight))
        return CGRect(x: x, y: y, width: cardWidth, height: 0)
    }

    private func closePaletteMenu() {
        showingPaletteMenu = false
        NSColorPanel.shared.close()
    }

    private func applyDisplaySurfaceDefaultsIfNeeded() {
        DisplayModeMigration.applyViewDefaults(
            floatingPanelEnabled: &floatingPanelEnabled,
            statusBarPanelEnabled: &statusBarPanelEnabled
        )
    }

    private func consumePendingSettingsRequest() {
        guard let category = AppSettingsRouteRequest.consume() else { return }
        appSettingsInitialCategory = category
        showingAppSettings = true
    }

    private func synchronizeSourceTransition() {
        sourceTransitionCoordinator.transition(
            to: store.currentDataSource,
            usageStore: store,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskCompletionMonitor,
            providerSyncStore: providerSyncStore
        )
    }

    private func reportRuntimeConfiguration() {
        runtime.reportConfiguration(
            floatingPanelEnabled: floatingPanelEnabled,
            statusBarPanelEnabled: statusBarPanelEnabled,
            floatingPanelVisibility: floatingPanelContentVisibility,
            floatingPanelLocked: floatingPanelLocked,
            preciseTokenCountingEnabled: preciseTokenCountingEnabled,
            providerSyncVisible: showingProviderSync,
            radarDetailsVisible: showingCodexRadarDetails,
            statusBarMetricConfiguration: statusBarMetricConfiguration,
            statusSummaryConfiguration: statusSummaryConfiguration,
            for: runtimeConsumerID
        )
    }

    private func hasVisibleDashboardWindow() -> Bool {
        guard !NSApp.isHidden else { return false }
        return NSApp.windows.contains { window in
            window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
                && !(window is NSPanel)
                && window.contentViewController != nil
        }
    }
}

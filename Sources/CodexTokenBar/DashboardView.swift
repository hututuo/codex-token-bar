import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var loginItemStore: LoginItemStore
    @ObservedObject var updateSettingsStore: AppUpdateSettingsStore
    @ObservedObject var threadDeleteBridge: CodexThreadDeleteBridgeController
    @ObservedObject var autoResumeController: AutoResumeController
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
    @AppStorage("statusBarPanelEnabled") private var statusBarPanelEnabled = false
    @AppStorage("liveRateMonitoringEnabled") private var liveRateMonitoringEnabled = true
    @AppStorage("preciseTokenCountingEnabled") private var preciseTokenCountingEnabled = false
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
    @AppStorage(FloatingPanelContentVisibility.quotaKey) private var floatingPanelShowQuota = FloatingPanelContentVisibility.default.showQuota
    @AppStorage(FloatingPanelContentVisibility.radarKey) private var floatingPanelShowRadar = FloatingPanelContentVisibility.default.showRadar
    @AppStorage(FloatingPanelContentVisibility.crowdRadarKey) private var floatingPanelShowCrowdRadar = FloatingPanelContentVisibility.default.showCrowdRadar
    @AppStorage(FloatingPanelContentVisibility.orderKey) private var floatingPanelContentOrderRaw = FloatingPanelContentVisibility.defaultOrderRaw
    @AppStorage("setupGuideCompletedV01") private var setupGuideCompleted = false
    @State private var showingProviderSync = false
    @State private var showingSetupGuide = false
    @State private var showingResetCreditDetails = false
    @State private var showingCodexRadarDetails = false
    @State private var showingInterfaceScaleMenu = false
    @State private var showingPaletteMenu = false
    @State private var showingUnreadEffectMenu = false
    @State private var showingContentSettingsMenu = false
    @State private var showingAppSettings = false
    @State private var appSettingsInitialCategory: AppSettingsCategory = .general
    @State private var exportAlert: DashboardExportAlertPresentation?

    init(
        loginItemStore: LoginItemStore,
        updateSettingsStore: AppUpdateSettingsStore,
        threadDeleteBridge: CodexThreadDeleteBridgeController,
        autoResumeController: AutoResumeController,
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
                    let cardFrame = floatingSettingsCardFrame(in: proxy, anchor: anchor, width: 312, estimatedHeight: 272)

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
            if !setupGuideCompleted {
                showingSetupGuide = true
            } else {
                StartupPresentation.hideDashboardIfNeeded()
            }
        }
        .onChange(of: runtimeConfigurationSignature) {
            reportRuntimeConfiguration()
        }
        .onChange(of: showingInterfaceScaleMenu) {
            guard showingInterfaceScaleMenu else { return }
            closePaletteMenu()
            showingUnreadEffectMenu = false
            showingContentSettingsMenu = false
            showingResetCreditDetails = false
            showingCodexRadarDetails = false
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
        }
        .onDisappear {
            runtime.releaseConsumer(runtimeConsumerID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardBlankAreaClicked)) { _ in
            showingResetCreditDetails = false
            showingCodexRadarDetails = false
            closePaletteMenu()
            showingUnreadEffectMenu = false
            showingContentSettingsMenu = false
            showingInterfaceScaleMenu = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            showingCodexRadarDetails = false
            closePaletteMenu()
            showingUnreadEffectMenu = false
            showingContentSettingsMenu = false
            showingInterfaceScaleMenu = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardShowSettings)) { _ in
            showingAppSettings = true
        }
        .sheet(isPresented: $showingProviderSync) {
            ProviderSyncPage(
                store: providerSyncStore,
                dataSource: providerSyncStore.currentDataSource
            )
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
                showQuota: $floatingPanelShowQuota,
                showRadar: $floatingPanelShowRadar,
                showCrowdRadar: $floatingPanelShowCrowdRadar,
                contentOrderRaw: $floatingPanelContentOrderRaw,
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
                autoResumeEnabled: autoResumeController.configuration.enabled,
                showingInterfaceScaleMenu: $showingInterfaceScaleMenu,
                interfaceScaleAutoEnabled: $interfaceScaleAutoEnabled,
                interfaceScaleManualMultiplier: $interfaceScaleManualMultiplier,
                showingResetCreditDetails: $showingResetCreditDetails
            )

            StatStrip(
                snapshot: store.snapshot,
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
                onShowDetails: { showingCodexRadarDetails = true }
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
                quotaDaily: quotaHistoryStore.snapshot.daily,
                selectedMode: $store.selectedMode
            )

            RecentUsageChart(
                bins: store.snapshot.recentBins,
                hourlyBins: store.snapshot.hourlyUsage,
                cacheRecentBins: store.snapshot.cacheUsage.recentBins,
                cacheHourlyBins: store.snapshot.cacheUsage.hourly,
                quotaRecentBins: quotaHistoryStore.snapshot.recentBins,
                quotaHourlyBins: quotaHistoryStore.snapshot.hourlyBins,
                currentFiveHourQuotaPresent: quotaStore.snapshot.fiveHour != nil,
                currentSevenDayQuotaPresent: quotaStore.snapshot.sevenDay != nil
            )

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
            showQuota: floatingPanelShowQuota,
            showRadar: floatingPanelShowRadar,
            showCrowdRadar: floatingPanelShowCrowdRadar,
            groupOrder: FloatingPanelContentVisibility.order(from: floatingPanelContentOrderRaw)
        )
    }

    private var runtimeConfigurationSignature: String {
        [
            floatingPanelEnabled ? "1" : "0",
            statusBarPanelEnabled ? "1" : "0",
            String(floatingPanelScale),
            floatingPanelContentOrderRaw,
            floatingPanelShowRateAndBar ? "1" : "0",
            floatingPanelShowUsageStatus ? "1" : "0",
            floatingPanelShowMetrics ? "1" : "0",
            floatingPanelShowQuota ? "1" : "0",
            floatingPanelShowRadar ? "1" : "0",
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

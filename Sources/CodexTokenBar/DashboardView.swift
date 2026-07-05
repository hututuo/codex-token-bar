import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var loginItemStore: LoginItemStore
    @ObservedObject var updateSettingsStore: AppUpdateSettingsStore
    private let floatingPanel: FloatingTokenPanelController
    private let statusBarPanel: StatusBarTokenController
    @StateObject private var store = CodexUsageStore()
    @StateObject private var quotaStore = AccountQuotaStore()
    @StateObject private var quotaHistoryStore = QuotaHistoryStore()
    @StateObject private var radarStore = CodexRadarStore()
    @StateObject private var providerSyncStore = ProviderSyncStore()
    @State private var taskCompletionMonitor = TaskCompletionMonitor()
    @State private var liveMonitor = LiveRateMonitor()
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
    @AppStorage(FloatingPanelAppearance.unreadEffectKey) private var floatingPanelUnreadEffect = FloatingPanelAppearance.defaultUnreadEffect
    @AppStorage(FloatingPanelContentVisibility.rateAndBarKey) private var floatingPanelShowRateAndBar = FloatingPanelContentVisibility.default.showRateAndBar
    @AppStorage(FloatingPanelContentVisibility.usageStatusKey) private var floatingPanelShowUsageStatus = FloatingPanelContentVisibility.default.showUsageStatus
    @AppStorage(FloatingPanelContentVisibility.metricsKey) private var floatingPanelShowMetrics = FloatingPanelContentVisibility.default.showMetrics
    @AppStorage(FloatingPanelContentVisibility.quotaKey) private var floatingPanelShowQuota = FloatingPanelContentVisibility.default.showQuota
    @AppStorage(FloatingPanelContentVisibility.radarKey) private var floatingPanelShowRadar = FloatingPanelContentVisibility.default.showRadar
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

    private let activeUsageRefreshInterval: TimeInterval = 30

    init(
        loginItemStore: LoginItemStore,
        updateSettingsStore: AppUpdateSettingsStore,
        floatingPanel: FloatingTokenPanelController,
        statusBarPanel: StatusBarTokenController
    ) {
        self.loginItemStore = loginItemStore
        self.updateSettingsStore = updateSettingsStore
        self.floatingPanel = floatingPanel
        self.statusBarPanel = statusBarPanel
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

                        CodexRadarDetailCard(
                            snapshot: radarStore.snapshot,
                            feedItems: radarStore.feedItems,
                            status: radarStore.status,
                            isRefreshing: radarStore.isRefreshing,
                            onRefresh: radarStore.refresh,
                            onClose: { showingCodexRadarDetails = false }
                        )
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
                    let cardFrame = floatingSettingsCardFrame(in: proxy, anchor: anchor, width: 338, estimatedHeight: 338)

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
            applyDisplaySurfaceDefaultsIfNeeded()
            liveMonitor.setPreciseTokenCountingEnabled(preciseTokenCountingEnabled)
            quotaStore.setHistoryStore(quotaHistoryStore)
            quotaHistoryStore.start()
            quotaStore.start()
            radarStore.start()
            taskCompletionMonitor.start(dataSource: store.currentDataSource)
            updateTokenDisplaySurface()
            updateUsageRefreshCadence()
            if !setupGuideCompleted {
                showingSetupGuide = true
            } else {
                StartupPresentation.hideDashboardIfNeeded()
            }
        }
        .onChange(of: floatingPanelEnabled) {
            updateTokenDisplaySurface()
            updateUsageRefreshCadence()
        }
        .onChange(of: statusBarPanelEnabled) {
            updateTokenDisplaySurface()
            updateUsageRefreshCadence()
        }
        .onChange(of: floatingPanelScale) {
            updateTokenDisplaySurface()
        }
        .onChange(of: floatingPanelContentVisibility) {
            updateTokenDisplaySurface()
        }
        .onChange(of: interfaceScaleAutoEnabled) {
            updateTokenDisplaySurface()
        }
        .onChange(of: interfaceScaleManualMultiplier) {
            updateTokenDisplaySurface()
        }
        .onChange(of: floatingPanelLocked) {
            updateTokenDisplaySurface()
        }
        .onReceive(radarStore.$snapshot) { _ in
            syncFloatingPanelRadarSnapshot()
        }
        .onReceive(liveMonitor.$totalSnapshot) { snapshot in
            updateUsageRefreshCadence(liveSnapshot: snapshot)
        }
        .onChange(of: store.dataSourceLabel) {
            taskCompletionMonitor.start(dataSource: store.currentDataSource)
        }
        .onChange(of: preciseTokenCountingEnabled) {
            liveMonitor.setPreciseTokenCountingEnabled(preciseTokenCountingEnabled)
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            updateUsageRefreshCadence()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            updateUsageRefreshCadence()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updateUsageRefreshCadence()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            refreshAllData()
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
            updateUsageRefreshCadence()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
            updateUsageRefreshCadence()
        }
        .sheet(isPresented: $showingProviderSync) {
            ProviderSyncPage(
                store: providerSyncStore,
                dataSource: store.currentDataSource
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
                    onChooseDirectory: store.chooseDataSourceDirectory,
                    onFinish: {
                        setupGuideCompleted = true
                        showingSetupGuide = false
                    }
                )
            }
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
                    Exporter.exportCSV(snapshot: store.snapshot)
                } label: {
                    Label("导出 CSV", systemImage: "tablecells")
                }

                Button {
                    Exporter.exportPNG(snapshot: store.snapshot)
                } label: {
                    Label("导出 PNG", systemImage: "photo")
                }
            }
        }
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
                onRefresh: refreshAllData,
                onChangeDirectory: store.chooseDataSourceDirectory,
                onOpenProviderSync: {
                    showingProviderSync = true
                    providerSyncStore.scan(dataSource: store.currentDataSource)
                },
                showingInterfaceScaleMenu: $showingInterfaceScaleMenu,
                interfaceScaleAutoEnabled: $interfaceScaleAutoEnabled,
                interfaceScaleManualMultiplier: $interfaceScaleManualMultiplier,
                showingResetCreditDetails: $showingResetCreditDetails
            )

            StatStrip(stats: store.snapshot.stats)

            if store.isPreparingUsageCache {
                UsageCacheInitializationNotice(status: store.status)
            }

            CodexRadarStrip(
                snapshot: radarStore.snapshot,
                status: radarStore.status,
                isRefreshing: radarStore.isRefreshing,
                onRefresh: radarStore.refresh,
                onShowDetails: { showingCodexRadarDetails = true }
            )

            LiveRateView(
                monitor: liveMonitor,
                floatingPanelEnabled: $floatingPanelEnabled,
                statusBarPanelEnabled: $statusBarPanelEnabled,
                liveRateMonitoringEnabled: $liveRateMonitoringEnabled,
                floatingPanelShowRateAndBar: $floatingPanelShowRateAndBar,
                preciseTokenCountingEnabled: $preciseTokenCountingEnabled,
                floatingPanelOpacity: $floatingPanelOpacity,
                floatingPanelScale: $floatingPanelScale,
                tokenRateFullScale: $tokenRateFullScale,
                floatingPanelGradientStartHex: $floatingPanelGradientStartHex,
                floatingPanelGradientEndHex: $floatingPanelGradientEndHex,
                floatingPanelGradientDirection: $floatingPanelGradientDirection,
                floatingPanelGradientStyle: $floatingPanelGradientStyle,
                floatingPanelUnreadEffect: $floatingPanelUnreadEffect,
                showingPaletteMenu: $showingPaletteMenu,
                showingUnreadEffectMenu: $showingUnreadEffectMenu,
                showingContentSettingsMenu: $showingContentSettingsMenu
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
                quotaHourlyBins: quotaHistoryStore.snapshot.hourlyBins
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

    private func refreshAllData() {
        let trace = RefreshPerformanceProbe.begin("dashboard.manualRefresh", metadata: [
            "providerSyncVisible": showingProviderSync ? "1" : "0"
        ])
        store.refresh()
        trace?.mark("usageStore.refresh.called")
        quotaStore.refresh(force: true)
        trace?.mark("quotaStore.refresh.called")
        radarStore.refresh()
        trace?.mark("radarStore.refresh.called")
        if showingProviderSync {
            providerSyncStore.scan(dataSource: store.currentDataSource)
            trace?.mark("providerSync.scan.called")
        }
        trace?.end("dispatched")
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

    private var effectiveFloatingPanelScale: Double {
        Double(
            FloatingTokenPanelMetrics.clampedScale(
                floatingPanelScale * Double(requestedInterfaceScale)
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
            groupOrder: FloatingPanelContentVisibility.order(from: floatingPanelContentOrderRaw)
        )
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

    private func updateTokenDisplaySurface() {
        if floatingPanelEnabled {
            floatingPanel.show(
                store: store,
                monitor: liveMonitor,
                quota: quotaStore,
                radar: radarStore,
                taskCompletionMonitor: taskCompletionMonitor,
                scale: effectiveFloatingPanelScale,
                visibility: floatingPanelContentVisibility,
                isLocked: floatingPanelLocked,
                onToggleLock: {
                    floatingPanelLocked.toggle()
                },
                onClose: {
                    floatingPanelEnabled = false
                }
            )
        } else {
            floatingPanel.close()
        }

        if statusBarPanelEnabled {
            statusBarPanel.show(store: store, monitor: liveMonitor, quota: quotaStore) {
                statusBarPanelEnabled = false
            }
        } else {
            statusBarPanel.close()
        }
    }

    private func syncFloatingPanelRadarSnapshot() {
        guard floatingPanelEnabled else { return }
        updateTokenDisplaySurface()
    }

    private func updateUsageRefreshCadence(liveSnapshot: LiveRateSnapshot? = nil) {
        let onlyCompactSurfaceVisible = (floatingPanelEnabled || statusBarPanelEnabled) && !hasVisibleDashboardWindow()
        let baselineInterval: TimeInterval = onlyCompactSurfaceVisible ? 300 : 180
        let snapshot = liveSnapshot ?? liveMonitor.totalSnapshot
        let isActive = isUsageRefreshActivityActive(snapshot: snapshot)
        store.setRefreshInterval(isActive ? activeUsageRefreshInterval : baselineInterval)
    }

    private func isUsageRefreshActivityActive(snapshot: LiveRateSnapshot) -> Bool {
        snapshot.rollingTokensPerSecond > 0.05
            || Date().timeIntervalSince(snapshot.updatedAt) < activeUsageRefreshInterval
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

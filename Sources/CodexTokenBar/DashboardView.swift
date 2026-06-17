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
    @StateObject private var providerSyncStore = ProviderSyncStore()
    @State private var taskCompletionMonitor = TaskCompletionMonitor()
    @State private var liveMonitor = LiveRateMonitor()
    @AppStorage("tokenDisplayMode") private var tokenDisplayModeRaw = TokenDisplayMode.floating.rawValue
    @AppStorage("floatingPanelEnabled") private var floatingPanelEnabled = true
    @AppStorage("statusBarPanelEnabled") private var statusBarPanelEnabled = false
    @AppStorage("displaySurfacePairMigrationV01") private var displaySurfacePairMigrationApplied = false
    @AppStorage("tokenDisplayModeDefaultedToFloatingV021") private var tokenDisplayModeDefaultedToFloating = false
    @AppStorage("tokenDisplayModeDefaultedToFloatingQuotaV01") private var tokenDisplayModeDefaultedToFloatingQuota = false
    @AppStorage("tokenDisplayModeDefaultedToFloatingQuotaV02") private var tokenDisplayModeDefaultedToFloatingQuotaV02 = false
    @AppStorage("tokenDisplayModeInitialDefaultAppliedV03") private var tokenDisplayModeInitialDefaultApplied = false
    @AppStorage("tokenDisplayModeUserSelected") private var tokenDisplayModeUserSelected = false
    @AppStorage("tokenDisplayModePanelCloseRepairV01") private var tokenDisplayModePanelCloseRepairApplied = false
    @AppStorage("preciseTokenCountingEnabled") private var preciseTokenCountingEnabled = false
    @AppStorage("floatingPanelOpacity") private var floatingPanelOpacity = 0.88
    @AppStorage("floatingPanelScale") private var floatingPanelScale = FloatingTokenPanelMetrics.defaultScale
    @AppStorage(TokenRateScaleSettings.key) private var tokenRateFullScale = TokenRateScaleSettings.defaultValue
    @AppStorage("floatingPanelLocked") private var floatingPanelLocked = false
    @AppStorage(FloatingPanelAppearance.startHexKey) private var floatingPanelGradientStartHex = FloatingPanelAppearance.defaultStartHex
    @AppStorage(FloatingPanelAppearance.endHexKey) private var floatingPanelGradientEndHex = FloatingPanelAppearance.defaultEndHex
    @AppStorage(FloatingPanelAppearance.directionKey) private var floatingPanelGradientDirection = FloatingPanelAppearance.defaultDirection
    @AppStorage(FloatingPanelAppearance.styleKey) private var floatingPanelGradientStyle = FloatingPanelAppearance.defaultStyle
    @AppStorage(FloatingPanelAppearance.unreadEffectKey) private var floatingPanelUnreadEffect = FloatingPanelAppearance.defaultUnreadEffect
    @AppStorage("setupGuideCompletedV01") private var setupGuideCompleted = false
    @State private var showingProviderSync = false
    @State private var showingSetupGuide = false
    @State private var showingResetCreditDetails = false
    @State private var showingPaletteMenu = false
    @State private var showingUnreadEffectMenu = false

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
        Self.applyStartupDisplayModeRepairIfNeeded()
    }

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .ignoresSafeArea()
                .onTapGesture {
                    NotificationCenter.default.post(name: .dashboardBlankAreaClicked, object: nil)
                }

            GeometryReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
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
                            showingResetCreditDetails: $showingResetCreditDetails
                        )

                        StatStrip(stats: store.snapshot.stats)

                        LiveRateView(
                            monitor: liveMonitor,
                            floatingPanelEnabled: $floatingPanelEnabled,
                            statusBarPanelEnabled: $statusBarPanelEnabled,
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
                            showingUnreadEffectMenu: $showingUnreadEffectMenu
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
                    .frame(minWidth: proxy.size.width, maxWidth: .infinity, alignment: .top)
                    .background(
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                NotificationCenter.default.post(name: .dashboardBlankAreaClicked, object: nil)
                            }
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.isInitialLoading {
                InitialLoadingOverlay(status: store.status)
                    .transition(.opacity)
                    .zIndex(10)
            }

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
        .animation(.easeInOut(duration: 0.18), value: store.isInitialLoading)
        .onExitCommand {
            showingResetCreditDetails = false
            closePaletteMenu()
            showingUnreadEffectMenu = false
        }
        .onAppear {
            applyDisplaySurfaceDefaultsIfNeeded()
            liveMonitor.setPreciseTokenCountingEnabled(preciseTokenCountingEnabled)
            quotaStore.setHistoryStore(quotaHistoryStore)
            quotaHistoryStore.start()
            quotaStore.start()
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
        .onChange(of: floatingPanelLocked) {
            updateTokenDisplaySurface()
        }
        .onChange(of: store.dataSourceLabel) {
            taskCompletionMonitor.start(dataSource: store.currentDataSource)
        }
        .onChange(of: preciseTokenCountingEnabled) {
            liveMonitor.setPreciseTokenCountingEnabled(preciseTokenCountingEnabled)
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
        .onReceive(NotificationCenter.default.publisher(for: .dashboardBlankAreaClicked)) { _ in
            showingResetCreditDetails = false
            closePaletteMenu()
            showingUnreadEffectMenu = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            closePaletteMenu()
            showingUnreadEffectMenu = false
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
        .toolbar {
            ToolbarItemGroup {
                Button {
                    refreshAllData()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)

                Button {
                    Exporter.exportCSV(snapshot: store.snapshot)
                } label: {
                    Label("Export CSV", systemImage: "tablecells")
                }

                Button {
                    Exporter.exportPNG(snapshot: store.snapshot)
                } label: {
                    Label("Export PNG", systemImage: "photo")
                }
            }
        }
    }

    private func refreshAllData() {
        store.refresh()
        quotaStore.refresh()
        if showingProviderSync {
            providerSyncStore.scan(dataSource: store.currentDataSource)
        }
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
        tokenDisplayModeDefaultedToFloating = true
        tokenDisplayModeDefaultedToFloatingQuota = true
        tokenDisplayModeDefaultedToFloatingQuotaV02 = true

        let currentMode = TokenDisplayMode(rawValue: tokenDisplayModeRaw)
        if !tokenDisplayModeInitialDefaultApplied && !tokenDisplayModeUserSelected,
           currentMode == nil || currentMode == .off {
            tokenDisplayModeRaw = TokenDisplayMode.floating.rawValue
        }
        tokenDisplayModeInitialDefaultApplied = true

        if !tokenDisplayModePanelCloseRepairApplied,
           currentMode == nil || currentMode == .off {
            tokenDisplayModeRaw = TokenDisplayMode.floating.rawValue
            tokenDisplayModeUserSelected = false
        }
        tokenDisplayModePanelCloseRepairApplied = true

        guard !displaySurfacePairMigrationApplied else { return }
        let mode = TokenDisplayMode(rawValue: tokenDisplayModeRaw)
        if mode == .statusBar {
            floatingPanelEnabled = false
            statusBarPanelEnabled = true
        } else if mode == .off {
            floatingPanelEnabled = false
            statusBarPanelEnabled = false
        } else {
            floatingPanelEnabled = true
        }
        displaySurfacePairMigrationApplied = true
    }

    private static func applyStartupDisplayModeRepairIfNeeded() {
        let defaults = UserDefaults.standard
        let defaultAppliedKey = "tokenDisplayModeInitialDefaultAppliedV03"
        let userSelectedKey = "tokenDisplayModeUserSelected"
        let panelCloseRepairKey = "tokenDisplayModePanelCloseRepairV01"

        let rawMode = defaults.string(forKey: "tokenDisplayMode")
        let mode = rawMode.flatMap(TokenDisplayMode.init(rawValue:))

        if !defaults.bool(forKey: defaultAppliedKey), !defaults.bool(forKey: userSelectedKey) {
            if mode == nil || mode == .off {
                defaults.set(TokenDisplayMode.floating.rawValue, forKey: "tokenDisplayMode")
            }
            defaults.set(true, forKey: defaultAppliedKey)
            return
        }

        if !defaults.bool(forKey: panelCloseRepairKey), mode == nil || mode == .off {
            defaults.set(TokenDisplayMode.floating.rawValue, forKey: "tokenDisplayMode")
            defaults.set(false, forKey: userSelectedKey)
        }
        defaults.set(true, forKey: panelCloseRepairKey)
    }

    private func updateTokenDisplaySurface() {
        if floatingPanelEnabled {
            floatingPanel.show(
                store: store,
                monitor: liveMonitor,
                quota: quotaStore,
                taskCompletionMonitor: taskCompletionMonitor,
                scale: floatingPanelScale,
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

    private func updateUsageRefreshCadence() {
        let onlyCompactSurfaceVisible = (floatingPanelEnabled || statusBarPanelEnabled) && !hasVisibleDashboardWindow()
        store.setRefreshInterval(onlyCompactSurfaceVisible ? 180 : 300)
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

extension Notification.Name {
    static let dashboardBlankAreaClicked = Notification.Name("CodexTokenBarDashboardBlankAreaClicked")
}

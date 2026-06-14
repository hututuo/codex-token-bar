import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var loginItemStore: LoginItemStore
    @ObservedObject var updateSettingsStore: AppUpdateSettingsStore
    @StateObject private var store = CodexUsageStore()
    @StateObject private var quotaStore = AccountQuotaStore()
    @StateObject private var quotaHistoryStore = QuotaHistoryStore()
    @StateObject private var providerSyncStore = ProviderSyncStore()
    @StateObject private var floatingPanel = FloatingTokenPanelController()
    @StateObject private var statusBarPanel = StatusBarTokenController()
    @StateObject private var taskCompletionMonitor = TaskCompletionMonitor()
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

    init(loginItemStore: LoginItemStore, updateSettingsStore: AppUpdateSettingsStore) {
        self.loginItemStore = loginItemStore
        self.updateSettingsStore = updateSettingsStore
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
                            }
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
                            floatingPanelUnreadEffect: $floatingPanelUnreadEffect
                        )

                        ActivitySection(
                            dailyUsage: store.snapshot.dailyUsage,
                            cacheDaily: store.snapshot.cacheUsage.daily,
                            quotaDaily: quotaHistoryStore.snapshot.daily,
                            selectedMode: $store.selectedMode
                        )

                        RecentUsageChart(
                            bins: store.snapshot.recentBins,
                            cacheRecentBins: store.snapshot.cacheUsage.recentBins,
                            quotaRecentBins: quotaHistoryStore.snapshot.recentBins
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
        }
        .animation(.easeInOut(duration: 0.18), value: store.isInitialLoading)
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

private struct InitialLoadingOverlay: View {
    let status: String

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .opacity(0.82)
                .ignoresSafeArea()

            Color.black
                .opacity(0.06)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .progressViewStyle(.circular)

                VStack(spacing: 4) {
                    Text("正在加载本地统计")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 320)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
    }
}

struct HeaderView: View {
    let snapshot: DashboardSnapshot
    let quotaSnapshot: AccountQuotaSnapshot
    let status: String
    let dataSourceLabel: String
    let dataSourceOrigin: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onChangeDirectory: () -> Void
    let onOpenProviderSync: () -> Void

    @AppStorage("customAccountDisplayName") private var customAccountDisplayName = ""
    @State private var isEditingDisplayName = false
    @State private var displayNameDraft = ""
    @FocusState private var displayNameFieldFocused: Bool

    private var accountDisplayName: String {
        let trimmed = customAccountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? quotaSnapshot.accountDisplayName : trimmed
    }

    private var planDisplayName: String {
        "Codex Token Bar"
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 72, height: 72)
                Text("CX")
                    .font(.system(size: 27, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 9) {
                if isEditingDisplayName {
                    TextField("昵称", text: $displayNameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .regular))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .frame(width: 300)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(AppTheme.raisedBackground, in: Capsule())
                        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
                        .focused($displayNameFieldFocused)
                        .onSubmit(saveDisplayNameDraft)
                        .onChange(of: displayNameFieldFocused) { _, isFocused in
                            if !isFocused {
                                saveDisplayNameDraft()
                            }
                        }
                        .onAppear {
                            displayNameDraft = accountDisplayName
                            displayNameFieldFocused = true
                        }
                } else {
                    Button {
                        displayNameDraft = accountDisplayName
                        isEditingDisplayName = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .opacity(0)
                            Text(accountDisplayName)
                                .font(.system(size: 24, weight: .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary.opacity(0.75))
                        }
                        .frame(maxWidth: 360)
                    }
                    .buttonStyle(.plain)
                    .help("点击修改顶部昵称；留空会恢复本地账户名")
                }

                HStack(spacing: 9) {
                    Text(planDisplayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 132, alignment: .leading)
                    Text("Local")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(AppTheme.borderStrong, lineWidth: 1)
                        )
                    DataSourceBadge(path: dataSourceLabel, origin: dataSourceOrigin)
                    Text(status)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Button(action: onRefresh) {
                        Label(isRefreshing ? "刷新中" : "立即刷新", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshing)

                    Button(action: onChangeDirectory) {
                        Label("更改目录", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    Button(action: onOpenProviderSync) {
                        Label("会话消失修复", systemImage: "wrench.and.screwdriver")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
                .font(.system(size: 14))
                .padding(.leading, 12)
                .frame(maxWidth: 980)

                AccountQuotaStrip(snapshot: quotaSnapshot)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardBlankAreaClicked)) { _ in
            guard isEditingDisplayName else { return }
            saveDisplayNameDraft()
        }
    }

    private func saveDisplayNameDraft() {
        customAccountDisplayName = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingDisplayName = false
    }
}

struct DataSourceBadge: View {
    let path: String
    let origin: String

    var body: some View {
        Label {
            HStack(spacing: 5) {
                Text(origin)
                    .foregroundStyle(.secondary)
                Text(path)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(AppTheme.raisedBackground)
        )
        .overlay(
            Capsule()
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .frame(maxWidth: 260)
        .help(path)
    }
}

struct StatStrip: View {
    let stats: DashboardStats

    var body: some View {
        HStack(spacing: 0) {
            StatCell(value: stats.totalTokens.abbreviatedTokens, label: "累计 Token 数")
            Divider().frame(height: 40)
            StatCell(value: stats.peakDayTokens.abbreviatedTokens, label: "峰值 Token 数")
            Divider().frame(height: 40)
            StatCell(value: stats.peakThreadTokens.abbreviatedTokens, label: "单会话最大 Token")
            Divider().frame(height: 40)
            StatCell(value: "\(stats.currentStreakDays) 天", label: "当前连续天数")
            Divider().frame(height: 40)
            StatCell(value: "\(stats.longestStreakDays) 天", label: "最长连续天数")
        }
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .frame(maxWidth: 980)
    }

}

struct StatCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.72)
                .lineLimit(1)

            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ActivitySection: View {
    let dailyUsage: [DayUsage]
    let cacheDaily: [TokenCacheBucket]
    let quotaDaily: [QuotaHistoryDailyBucket]
    @Binding var selectedMode: ActivityMode

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Token 活动")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                ActivityModeSelector(selectedMode: $selectedMode)
            }

            TokenHeatmap(dailyUsage: dailyUsage, cacheDaily: cacheDaily, quotaDaily: quotaDaily, mode: selectedMode)
        }
        .frame(maxWidth: 980)
    }
}

struct ActivityModeSelector: View {
    @Binding var selectedMode: ActivityMode

    private let regularModes: [ActivityMode] = [.daily, .weekly, .cumulative]
    private let specialModes: [ActivityMode] = [.cacheHitRate, .quotaRemaining]

    var body: some View {
        HStack(spacing: 4) {
            Text("Mode")
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            HStack(spacing: 2) {
                ForEach(regularModes) { mode in
                    modeButton(mode, width: 42)
                }

                HStack(spacing: 2) {
                    ForEach(specialModes) { mode in
                        modeButton(mode, width: 42, groupedSpecial: true)
                    }
                }
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.accentBlue.opacity(0.26), lineWidth: 1)
                )
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.raisedBackground)
            )
        }
    }

    private func modeButton(_ mode: ActivityMode, width: CGFloat, groupedSpecial: Bool = false) -> some View {
        Button {
            selectedMode = mode
        } label: {
            Text(mode.rawValue)
                .font(.system(size: groupedSpecial ? 12 : 13, weight: selectedMode == mode ? .semibold : .medium))
                .foregroundStyle(labelColor(for: mode))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: width, height: 25)
                .background(background(for: mode))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func labelColor(for mode: ActivityMode) -> Color {
        return .primary
    }

    @ViewBuilder
    private func background(for mode: ActivityMode) -> some View {
        if selectedMode == mode {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppTheme.accentBlue.opacity(mode.isSpecial ? 0.13 : 0.18))
        } else {
            Color.clear
        }
    }
}

private struct HeatmapMonthMarker: Identifiable {
    let label: String
    let column: Int
    let nextColumn: Int

    var id: String {
        "\(label)-\(column)"
    }
}

private struct HeatmapPreparedData {
    let summaries: [HeatmapUsageSummary]
    let maxTokens: Int
    let columns: [[Int]]
    let monthMarkers: [HeatmapMonthMarker]

    static let empty = HeatmapPreparedData(summaries: [], maxTokens: 1, columns: [], monthMarkers: [])
}

struct TokenHeatmap: View {
    let dailyUsage: [DayUsage]
    let cacheDaily: [TokenCacheBucket]
    let quotaDaily: [QuotaHistoryDailyBucket]
    let mode: ActivityMode
    @State private var hoveredIndex: Int?
    @State private var rangeStartIndex: Int?
    @State private var rangeEndIndex: Int?
    @State private var preparedData: HeatmapPreparedData

    private let rows = 7
    private let gap: CGFloat = 4
    private let trailingInset: CGFloat = 9

    init(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket], quotaDaily: [QuotaHistoryDailyBucket], mode: ActivityMode) {
        self.dailyUsage = dailyUsage
        self.cacheDaily = cacheDaily
        self.quotaDaily = quotaDaily
        self.mode = mode
        _preparedData = State(initialValue: .empty)
    }

    var body: some View {
        GeometryReader { proxy in
            let summaries = preparedData.summaries
            let columns = preparedData.columns
            let selectedIndex = hoveredIndex ?? summaries.indices.last
            let cellSize = adaptiveCellSize(containerWidth: proxy.size.width, columnCount: columns.count)
            let gridWidth = gridWidth(columnCount: columns.count, cellSize: cellSize)
            let gridHeight = gridHeight(cellSize: cellSize)
            let rangeSelection = normalizedRangeSelection(dayCount: summaries.count)
            let rangeSummary = rangeSelection.flatMap { makeRangeSummary(range: $0) }

            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(columns.indices, id: \.self) { columnIndex in
                            VStack(spacing: gap) {
                                ForEach(0..<rows, id: \.self) { rowIndex in
                                    if let dayIndex = columns[columnIndex][safe: rowIndex],
                                       let summary = summaries[safe: dayIndex] {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(color(for: summary, maxTokens: preparedData.maxTokens))
                                            .frame(width: cellSize, height: cellSize)
                                    } else {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color.clear)
                                            .frame(width: cellSize, height: cellSize)
                                    }
                                }
                            }
                        }
                    }

                    if let rangeSelection {
                        ForEach(rangeSelection.lowerBound...rangeSelection.upperBound, id: \.self) { index in
                            let isEndpoint = index == rangeSelection.lowerBound || index == rangeSelection.upperBound
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(AppTheme.accentBlue.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(AppTheme.accentBlue.opacity(isEndpoint ? 0.98 : 0.50), lineWidth: isEndpoint ? 2.0 : 1.1)
                                )
                                .frame(width: cellSize, height: cellSize)
                                .offset(
                                    x: CGFloat(index / rows) * (cellSize + gap),
                                    y: CGFloat(index % rows) * (cellSize + gap)
                                )
                                .allowsHitTesting(false)
                        }
                    }

                    if let selectedIndex,
                       summaries.indices.contains(selectedIndex) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(AppTheme.accentBlue, lineWidth: 1.9)
                            .frame(width: cellSize, height: cellSize)
                            .offset(
                                x: CGFloat(selectedIndex / rows) * (cellSize + gap),
                                y: CGFloat(selectedIndex % rows) * (cellSize + gap)
                            )
                            .allowsHitTesting(false)
                    }

                    HoverTrackingArea(
                        onMove: { location in
                            let nextIndex = nearestDayIndex(
                                at: location,
                                columnCount: columns.count,
                                dayCount: summaries.count,
                                cellSize: cellSize
                            )
                            if hoveredIndex != nextIndex {
                                hoveredIndex = nextIndex
                            }
                        },
                        onClick: { location in
                            guard let clickedIndex = nearestDayIndex(
                                at: location,
                                columnCount: columns.count,
                                dayCount: summaries.count,
                                cellSize: cellSize
                            ) else { return }
                            updateRangeSelection(clickedIndex)
                        },
                        onExit: {
                            if hoveredIndex != nil {
                                hoveredIndex = nil
                            }
                        }
                    )
                    .frame(width: gridWidth, height: gridHeight)
                }
                .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

                MonthLabels(markers: preparedData.monthMarkers, cellSize: cellSize, gap: gap)
                HeatmapHoverInfo(
                    summary: hoveredIndex.flatMap { summaries[safe: $0] } ?? summaries.last,
                    rangeSummary: rangeSummary,
                    hasRangeStart: rangeStartIndex != nil
                )
            }
        }
        .frame(height: 180)
        .onAppear(perform: refreshPreparedData)
        .onChange(of: dailyUsage) { _, _ in
            clearRangeSelection()
            refreshPreparedData()
        }
        .onChange(of: cacheDaily) { _, _ in
            clearRangeSelection()
            refreshPreparedData()
        }
        .onChange(of: quotaDaily) { _, _ in
            clearRangeSelection()
            refreshPreparedData()
        }
        .onChange(of: mode) { _, _ in
            hoveredIndex = nil
            clearRangeSelection()
            refreshPreparedData()
        }
    }

    private func adaptiveCellSize(containerWidth: CGFloat, columnCount: Int) -> CGFloat {
        guard columnCount > 0 else { return 12 }
        let targetWidth = max(0, containerWidth - trailingInset)
        let availableForCells = targetWidth - CGFloat(columnCount - 1) * gap
        return max(10, availableForCells / CGFloat(columnCount))
    }

    private func gridHeight(cellSize: CGFloat) -> CGFloat {
        CGFloat(rows) * cellSize + CGFloat(rows - 1) * gap
    }

    private func gridWidth(columnCount: Int, cellSize: CGFloat) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        return CGFloat(columnCount) * cellSize + CGFloat(columnCount - 1) * gap
    }

    private func nearestDayIndex(at location: CGPoint, columnCount: Int, dayCount: Int, cellSize: CGFloat) -> Int? {
        guard dayCount > 0, columnCount > 0 else { return nil }
        let pitch = cellSize + gap
        let rawColumn = Int(((location.x - cellSize / 2) / pitch).rounded())
        let rawRow = Int(((location.y - cellSize / 2) / pitch).rounded())
        let column = min(max(rawColumn, 0), columnCount - 1)
        let row = min(max(rawRow, 0), rows - 1)
        let center = CGPoint(
            x: CGFloat(column) * pitch + cellSize / 2,
            y: CGFloat(row) * pitch + cellSize / 2
        )
        let distance = hypot(location.x - center.x, location.y - center.y)
        guard distance <= cellSize else { return nil }

        let dayIndex = column * rows + row
        guard dayIndex < dayCount else { return nil }
        return dayIndex
    }

    private func color(for summary: HeatmapUsageSummary, maxTokens: Int) -> Color {
        if summary.isCacheRate {
            guard summary.calls > 0, let cacheBreakdown = summary.cacheBreakdown else {
                return AppTheme.emptyCell
            }
            return AppTheme.cacheHitColor(rate: cacheBreakdown.cacheHitRate)
        }

        if summary.isQuotaRemaining {
            guard let percent = summary.quotaRemainingPercent else {
                return AppTheme.emptyCell
            }
            return AppTheme.quotaRemainingColor(percent: percent)
        }

        let value = summary.tokens
        guard value > 0 else { return AppTheme.emptyCell }
        let ratio = min(1.0, Double(value) / Double(max(maxTokens, 1)))
        return AppTheme.heatmapColor(ratio: ratio)
    }

    private func refreshPreparedData() {
        preparedData = Self.prepare(dailyUsage: dailyUsage, cacheDaily: cacheDaily, quotaDaily: quotaDaily, mode: mode)
    }

    private func updateRangeSelection(_ index: Int) {
        if rangeStartIndex == nil || rangeEndIndex != nil {
            rangeStartIndex = index
            rangeEndIndex = nil
        } else {
            rangeEndIndex = index
        }
    }

    private func clearRangeSelection() {
        rangeStartIndex = nil
        rangeEndIndex = nil
    }

    private func normalizedRangeSelection(dayCount: Int) -> ClosedRange<Int>? {
        guard let start = rangeStartIndex, dayCount > 0 else { return nil }
        let clampedStart = min(max(start, 0), dayCount - 1)
        let clampedEnd = min(max(rangeEndIndex ?? start, 0), dayCount - 1)
        return min(clampedStart, clampedEnd)...max(clampedStart, clampedEnd)
    }

    private func makeRangeSummary(range: ClosedRange<Int>) -> HeatmapRangeSummary? {
        guard !dailyUsage.isEmpty,
              let firstDay = dailyUsage[safe: range.lowerBound],
              let lastDay = dailyUsage[safe: range.upperBound] else {
            return nil
        }

        let days = range.compactMap { dailyUsage[safe: $0] }
        let title = rangeTitle(first: firstDay.date, last: lastDay.date)

        if mode == .cacheHitRate {
            let calendar = Calendar.current
            let cacheByDay = Dictionary(uniqueKeysWithValues: cacheDaily.map { bucket in
                (calendar.startOfDay(for: bucket.start), bucket.breakdown)
            })
            let breakdown = days.compactMap { day in
                cacheByDay[calendar.startOfDay(for: day.date)]
            }.combined
            return HeatmapRangeSummary(
                title: title,
                dayCount: days.count,
                tokens: breakdown.totalTokens,
                calls: breakdown.calls,
                cacheBreakdown: breakdown,
                quotaAverageRemainingPercent: nil
            )
        }

        if mode == .quotaRemaining {
            let calendar = Calendar.current
            let quotaByDay = Dictionary(uniqueKeysWithValues: quotaDaily.map { bucket in
                (calendar.startOfDay(for: bucket.date), bucket)
            })
            let values = days.compactMap { day in
                quotaByDay[calendar.startOfDay(for: day.date)]?.sevenDayRemainingPercent
            }
            return HeatmapRangeSummary(
                title: title,
                dayCount: days.count,
                tokens: 0,
                calls: values.count,
                cacheBreakdown: nil,
                quotaAverageRemainingPercent: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            )
        }

        let tokenTotal = days.reduce(0) { $0 + $1.tokens }
        let callTotal = days.reduce(0) { $0 + $1.calls }
        return HeatmapRangeSummary(
            title: title,
            dayCount: days.count,
            tokens: tokenTotal,
            calls: callTotal,
            cacheBreakdown: nil,
            quotaAverageRemainingPercent: nil
        )
    }

    private func rangeTitle(first: Date, last: Date) -> String {
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return DateFormatter.fullDay.string(from: first)
        }
        return "\(DateFormatter.fullDay.string(from: first)) - \(DateFormatter.fullDay.string(from: last))"
    }

    private static func prepare(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket], quotaDaily: [QuotaHistoryDailyBucket], mode: ActivityMode) -> HeatmapPreparedData {
        let summaries = makeSummaries(dailyUsage: dailyUsage, cacheDaily: cacheDaily, quotaDaily: quotaDaily, mode: mode)
        let columns = makeColumnIndices(dayCount: summaries.count)
        return HeatmapPreparedData(
            summaries: summaries,
            maxTokens: max(summaries.map(\.tokens).max() ?? 1, 1),
            columns: columns,
            monthMarkers: monthMarkers(dailyUsage: dailyUsage, endColumn: max(columns.count, 1))
        )
    }

    private static func makeColumnIndices(dayCount: Int) -> [[Int]] {
        stride(from: 0, to: dayCount, by: 7).map { start in
            Array(start..<min(start + 7, dayCount))
        }
    }

    private static func makeSummaries(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket], quotaDaily: [QuotaHistoryDailyBucket], mode: ActivityMode) -> [HeatmapUsageSummary] {
        switch mode {
        case .daily:
            return dailyUsage.map { day in
                HeatmapUsageSummary(
                    title: DateFormatter.fullDay.string(from: day.date),
                    tokens: day.tokens,
                    calls: day.calls,
                    iconName: "calendar"
                )
            }
        case .weekly:
            return weeklySummaries(dailyUsage: dailyUsage)
        case .cumulative:
            var runningTokens = 0
            var runningCalls = 0
            return dailyUsage.map { day in
                runningTokens += day.tokens
                runningCalls += day.calls
                return HeatmapUsageSummary(
                    title: "截至 \(DateFormatter.fullDay.string(from: day.date))",
                    tokens: runningTokens,
                    calls: runningCalls,
                    iconName: "sum"
                )
            }
        case .cacheHitRate:
            return cacheHitRateSummaries(dailyUsage: dailyUsage, cacheDaily: cacheDaily)
        case .quotaRemaining:
            return quotaRemainingSummaries(dailyUsage: dailyUsage, quotaDaily: quotaDaily)
        }
    }

    private static func quotaRemainingSummaries(dailyUsage: [DayUsage], quotaDaily: [QuotaHistoryDailyBucket]) -> [HeatmapUsageSummary] {
        let calendar = Calendar.current
        let quotaByDay = Dictionary(uniqueKeysWithValues: quotaDaily.map { bucket in
            (calendar.startOfDay(for: bucket.date), bucket)
        })

        return dailyUsage.map { day in
            let date = calendar.startOfDay(for: day.date)
            let bucket = quotaByDay[date]
            return HeatmapUsageSummary(
                title: DateFormatter.fullDay.string(from: day.date),
                tokens: Int((bucket?.sevenDayRemainingPercent ?? 0).rounded()),
                calls: bucket?.sampleCount ?? 0,
                iconName: "gauge.with.dots.needle.67percent",
                quotaRemainingPercent: bucket?.sevenDayRemainingPercent,
                isQuotaRemaining: true
            )
        }
    }

    private static func cacheHitRateSummaries(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket]) -> [HeatmapUsageSummary] {
        let calendar = Calendar.current
        let cacheByDay = Dictionary(uniqueKeysWithValues: cacheDaily.map { bucket in
            (calendar.startOfDay(for: bucket.start), bucket.breakdown)
        })

        return dailyUsage.map { day in
            let date = calendar.startOfDay(for: day.date)
            let breakdown = cacheByDay[date]
            return HeatmapUsageSummary(
                title: DateFormatter.fullDay.string(from: day.date),
                tokens: breakdown?.totalTokens ?? 0,
                calls: breakdown?.calls ?? 0,
                iconName: "bolt.horizontal.circle",
                cacheBreakdown: breakdown,
                isCacheRate: true
            )
        }
    }

    private static func weeklySummaries(dailyUsage: [DayUsage]) -> [HeatmapUsageSummary] {
        let calendar = Calendar.current
        var weekTotals: [String: (tokens: Int, calls: Int, first: Date, last: Date)] = [:]

        for day in dailyUsage {
            let key = "\(calendar.component(.yearForWeekOfYear, from: day.date))-\(calendar.component(.weekOfYear, from: day.date))"
            if let current = weekTotals[key] {
                weekTotals[key] = (
                    current.tokens + day.tokens,
                    current.calls + day.calls,
                    min(current.first, day.date),
                    max(current.last, day.date)
                )
            } else {
                weekTotals[key] = (day.tokens, day.calls, day.date, day.date)
            }
        }

        return dailyUsage.map { day in
            let key = "\(calendar.component(.yearForWeekOfYear, from: day.date))-\(calendar.component(.weekOfYear, from: day.date))"
            let total = weekTotals[key] ?? (day.tokens, day.calls, day.date, day.date)
            return HeatmapUsageSummary(
                title: "\(DateFormatter.monthDay.string(from: total.first)) - \(DateFormatter.monthDay.string(from: total.last))",
                tokens: total.tokens,
                calls: total.calls,
                iconName: "calendar.badge.clock"
            )
        }
    }

    private static func monthMarkers(dailyUsage: [DayUsage], endColumn: Int) -> [HeatmapMonthMarker] {
        guard !dailyUsage.isEmpty else { return [] }

        var markers: [HeatmapMonthMarker] = []
        var previousMonth = -1
        let calendar = Calendar.current

        for (index, day) in dailyUsage.enumerated() {
            let month = calendar.component(.month, from: day.date)
            guard month != previousMonth else { continue }

            previousMonth = month
            let column = index / 7
            let nextColumn = nextMonthColumn(after: index, dailyUsage: dailyUsage) ?? endColumn
            markers.append(HeatmapMonthMarker(label: "\(month)月", column: column, nextColumn: nextColumn))
        }

        return markers
    }

    private static func nextMonthColumn(after index: Int, dailyUsage: [DayUsage]) -> Int? {
        guard index < dailyUsage.count else { return nil }
        let calendar = Calendar.current
        let month = calendar.component(.month, from: dailyUsage[index].date)
        for next in (index + 1)..<dailyUsage.count {
            let nextMonth = calendar.component(.month, from: dailyUsage[next].date)
            if nextMonth != month {
                return next / 7
            }
        }
        return nil
    }

}

struct HeatmapUsageSummary {
    let title: String
    let tokens: Int
    let calls: Int
    let iconName: String
    let cacheBreakdown: TokenCacheBreakdown?
    let isCacheRate: Bool
    let quotaRemainingPercent: Double?
    let isQuotaRemaining: Bool

    init(
        title: String,
        tokens: Int,
        calls: Int,
        iconName: String,
        cacheBreakdown: TokenCacheBreakdown? = nil,
        isCacheRate: Bool = false,
        quotaRemainingPercent: Double? = nil,
        isQuotaRemaining: Bool = false
    ) {
        self.title = title
        self.tokens = tokens
        self.calls = calls
        self.iconName = iconName
        self.cacheBreakdown = cacheBreakdown
        self.isCacheRate = isCacheRate
        self.quotaRemainingPercent = quotaRemainingPercent
        self.isQuotaRemaining = isQuotaRemaining
    }

    var average: Int {
        calls > 0 ? tokens / calls : 0
    }
}

struct HeatmapRangeSummary {
    let title: String
    let dayCount: Int
    let tokens: Int
    let calls: Int
    let cacheBreakdown: TokenCacheBreakdown?
    let quotaAverageRemainingPercent: Double?

    var average: Int {
        calls > 0 ? tokens / calls : 0
    }

    var compactTitle: String {
        title
            .replacingOccurrences(of: "年", with: ".")
            .replacingOccurrences(of: "月", with: ".")
            .replacingOccurrences(of: "日", with: "")
            .replacingOccurrences(of: " - ", with: "-")
    }
}

struct HeatmapHoverInfo: View {
    let summary: HeatmapUsageSummary?
    let rangeSummary: HeatmapRangeSummary?
    let hasRangeStart: Bool

    var body: some View {
        GeometryReader { proxy in
            let leftWidth = max(300, proxy.size.width * 0.43)
            HStack(spacing: 14) {
                singleDayContent
                    .frame(width: leftWidth, alignment: .leading)

                Rectangle()
                    .fill(AppTheme.border)
                    .frame(width: 1, height: 22)

                rangeContent
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .layoutPriority(1)
            }
        }
        .frame(height: 20)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.insetBackground)
        )
    }

    @ViewBuilder
    private var singleDayContent: some View {
        HStack(spacing: 12) {
            if let summary {
                Image(systemName: summary.iconName)
                    .foregroundStyle(AppTheme.accentBlue)
                Text(summary.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if summary.isCacheRate, let breakdown = summary.cacheBreakdown {
                    Text(breakdown.cacheHitRate.percentString)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                    Text("命中 \(breakdown.cachedInputTokens.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("未命中 \(breakdown.uncachedInputTokens.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("\(breakdown.calls) calls")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else if summary.isQuotaRemaining {
                    Text(summary.quotaRemainingPercent.map { "\(Int($0.rounded()))% 7d 剩余" } ?? "暂无额度记录")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(summary.quotaRemainingPercent.map { AppTheme.quotaRemainingColor(percent: $0) } ?? .secondary)
                    Text("\(summary.calls) samples")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(summary.tokens.abbreviatedTokens) tokens")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                    Text("\(summary.calls) calls")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("avg \(summary.average.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "cursorarrow.rays")
                    .foregroundStyle(Color.secondary)
                Text("悬停查看单日")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var rangeContent: some View {
        HStack(spacing: 12) {
            if let rangeSummary {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(AppTheme.accentBlue)
                Text("总计")
                    .font(.system(size: 13, weight: .semibold))
                Text(rangeSummary.compactTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(2)
                Text("\(rangeSummary.dayCount) 天")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)

                if let breakdown = rangeSummary.cacheBreakdown {
                    Text(breakdown.cacheHitRate.percentString)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                    Text("命中 \(breakdown.cachedInputTokens.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("未命中 \(breakdown.uncachedInputTokens.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("\(breakdown.calls) calls")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else if let quotaAverage = rangeSummary.quotaAverageRemainingPercent {
                    Text("\(Int(quotaAverage.rounded()))% 7d 平均剩余")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.quotaRemainingColor(percent: quotaAverage))
                    Text("\(rangeSummary.calls) samples")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(rangeSummary.tokens.abbreviatedTokens) tokens")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                    Text("\(rangeSummary.calls) calls")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("avg \(rangeSummary.average.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else if hasRangeStart {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(AppTheme.accentBlue)
                Text("已选起点，再点一个日期")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "hand.tap")
                    .foregroundStyle(.secondary)
                Text("点击开始和结束日期，可显示范围总计")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

private struct MonthLabels: View {
    let markers: [HeatmapMonthMarker]
    let cellSize: CGFloat
    let gap: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(markers) { marker in
                Text(marker.label)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: width(for: marker), alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func width(for marker: HeatmapMonthMarker) -> CGFloat {
        CGFloat(max(2, marker.nextColumn - marker.column)) * (cellSize + gap)
    }
}

private enum CacheRankingScope: String, CaseIterable, Identifiable {
    case sessions = "会话"
    case turns = "单轮"

    var id: String { rawValue }
}

private struct CacheRankingItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let context: String?
    let breakdown: TokenCacheBreakdown
}

struct CacheHitRankingSection: View {
    let cacheUsage: TokenCacheUsage
    @State private var scope: CacheRankingScope = .sessions
    @State private var excludesSingleTurnSessions = true
    @State private var excludesFirstTurns = true

    private let minimumInputTokens = 1_000

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("缓存命中排行")
                        .font(.system(size: 19, weight: .semibold))
                    Text(rankingSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    CacheRankingCheckmark(
                        isOn: scope == .sessions ? $excludesSingleTurnSessions : $excludesFirstTurns,
                        title: scope == .sessions ? "排除单轮会话" : "排除首轮"
                    )

                    Picker("", selection: $scope) {
                        ForEach(CacheRankingScope.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 132)
                }
            }

            if rankingItems.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                    Text("暂无可排行的缓存命中数据")
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(AppTheme.insetBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 5) {
                    ForEach(Array(rankingItems.enumerated()), id: \.element.id) { index, item in
                        CacheRankingRow(rank: index + 1, item: item)
                    }
                }
            }
        }
        .frame(maxWidth: 980)
    }

    private var rankingItems: [CacheRankingItem] {
        let source: [CacheRankingItem]
        switch scope {
        case .sessions:
            source = cacheUsage.sessions
                .filter { !excludesSingleTurnSessions || $0.breakdown.calls > 1 }
                .map { session in
                CacheRankingItem(
                    id: session.id,
                    title: session.title,
                    subtitle: sessionSubtitle(session),
                    context: nil,
                    breakdown: session.breakdown
                )
            }
        case .turns:
            source = cacheUsage.turns
                .filter { !excludesFirstTurns || $0.turnIndexInSession > 1 }
                .map { turn in
                let time = DateFormatter.monthDayHourMinute.string(from: turn.timestamp)
                return CacheRankingItem(
                    id: turn.id,
                    title: "问：\(turn.userPrompt.isEmpty ? "暂无可见问题" : turn.userPrompt)",
                    subtitle: "答：\(turn.assistantResponse.isEmpty ? "暂无可见回答" : turn.assistantResponse)",
                    context: "\(turn.sessionTitle) · 第 \(turn.turnIndexInSession) 轮 · \(time)",
                    breakdown: turn.breakdown
                )
            }
        }

        return source
            .filter { $0.breakdown.inputTokens >= minimumInputTokens && $0.breakdown.calls > 0 }
            .sorted { lhs, rhs in
                let leftRate = lhs.breakdown.cacheHitRate
                let rightRate = rhs.breakdown.cacheHitRate
                if abs(leftRate - rightRate) > 0.0001 {
                    return leftRate < rightRate
                }
                return lhs.breakdown.uncachedInputTokens > rhs.breakdown.uncachedInputTokens
            }
            .prefix(10)
            .map { $0 }
    }

    private var rankingSubtitle: String {
        switch scope {
        case .sessions:
            return excludesSingleTurnSessions ? "低命中优先 · 已排除只有一轮的会话" : "低命中优先 · 包含单轮会话"
        case .turns:
            return excludesFirstTurns ? "低命中优先 · 已排除每个会话首轮" : "低命中优先 · 包含首轮"
        }
    }

    private func sessionSubtitle(_ session: SessionCacheUsage) -> String {
        let time = session.lastUpdated.map { DateFormatter.monthDayHourMinute.string(from: $0) } ?? "未知时间"
        return "\(session.breakdown.calls) 轮 · \(time)"
    }
}

private struct CacheRankingCheckmark: View {
    @Binding var isOn: Bool
    let title: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? AppTheme.accentBlue : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(AppTheme.raisedBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isOn ? AppTheme.accentBlue.opacity(0.25) : AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CacheRankingRow: View {
    let rank: Int
    let item: CacheRankingItem

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 21, height: 21)
                .background(AppTheme.accentBlue.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let context = item.context {
                    Text(context)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CacheHitMeter(breakdown: item.breakdown)
                .frame(width: 154)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.breakdown.cacheHitRate.percentString)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.cacheHitColor(rate: item.breakdown.cacheHitRate))
                Text("未命中 \(item.breakdown.uncachedInputTokens.abbreviatedTokens)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

private struct CacheHitMeter: View {
    let breakdown: TokenCacheBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.insetBackground)
                    Capsule()
                        .fill(AppTheme.cacheHitColor(rate: breakdown.cacheHitRate))
                        .frame(width: proxy.size.width * CGFloat(max(0, min(1, breakdown.cacheHitRate))))
                    Capsule()
                        .stroke(AppTheme.border, lineWidth: 1)
                }
            }
            .frame(height: 7)

            HStack(spacing: 6) {
                Text("命中 \(breakdown.cachedInputTokens.abbreviatedTokens)")
                Text("输入 \(breakdown.inputTokens.abbreviatedTokens)")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
    }
}

private struct RecentChartPreparedData {
    let maxTokens: Int
    let maxCalls: Int
    let tokenTotal: Int
    let callTotal: Int
    let recentCacheBreakdown: TokenCacheBreakdown
    let cacheBreakdowns: [TokenCacheBreakdown]
    let carriedCacheHitRates: [Double]
    let fiveHourRemainingPercents: [Double?]
    let sevenDayRemainingPercents: [Double?]
    let latestFiveHourRemaining: Double?
    let latestSevenDayRemaining: Double?
    let hasCacheCalls: Bool
    let hasFiveHourQuota: Bool
    let hasSevenDayQuota: Bool
    let markerIndices: [Int]

    static let empty = RecentChartPreparedData(
        maxTokens: 1,
        maxCalls: 1,
        tokenTotal: 0,
        callTotal: 0,
        recentCacheBreakdown: .empty,
        cacheBreakdowns: [],
        carriedCacheHitRates: [],
        fiveHourRemainingPercents: [],
        sevenDayRemainingPercents: [],
        latestFiveHourRemaining: nil,
        latestSevenDayRemaining: nil,
        hasCacheCalls: false,
        hasFiveHourQuota: false,
        hasSevenDayQuota: false,
        markerIndices: []
    )
}

private struct RecentChartPlotData {
    let tokenPoints: [CGPoint]
    let callPoints: [CGPoint]
    let cachePoints: [CGPoint]
    let fiveHourQuotaPoints: [CGPoint?]
    let sevenDayQuotaPoints: [CGPoint?]

    init(bins: [BinUsage], prepared: RecentChartPreparedData, plot: CGRect, step: CGFloat) {
        tokenPoints = bins.indices.map { index in
            let x = plot.minX + CGFloat(index) * step
            let y = plot.maxY - CGFloat(bins[index].tokens) / CGFloat(prepared.maxTokens) * plot.height
            return CGPoint(x: x, y: y)
        }
        callPoints = bins.indices.map { index in
            let x = plot.minX + CGFloat(index) * step
            let y = plot.maxY - CGFloat(bins[index].calls) / CGFloat(prepared.maxCalls) * plot.height
            return CGPoint(x: x, y: y)
        }
        cachePoints = bins.indices.map { index in
            let x = plot.minX + CGFloat(index) * step
            let rate = prepared.carriedCacheHitRates[safe: index] ?? 0
            let y = plot.maxY - CGFloat(rate) * plot.height
            return CGPoint(x: x, y: y)
        }
        fiveHourQuotaPoints = bins.indices.map { index in
            guard let value = prepared.fiveHourRemainingPercents[safe: index],
                  let percent = value else { return nil }
            let x = plot.minX + CGFloat(index) * step
            let y = plot.maxY - CGFloat(max(0, min(100, percent)) / 100.0) * plot.height
            return CGPoint(x: x, y: y)
        }
        sevenDayQuotaPoints = bins.indices.map { index in
            guard let value = prepared.sevenDayRemainingPercents[safe: index],
                  let percent = value else { return nil }
            let x = plot.minX + CGFloat(index) * step
            let y = plot.maxY - CGFloat(max(0, min(100, percent)) / 100.0) * plot.height
            return CGPoint(x: x, y: y)
        }
    }
}

private let recentChartHoverBubbleVerticalOffset: CGFloat = 50

struct RecentUsageChart: View {
    let bins: [BinUsage]
    let cacheRecentBins: [TokenCacheBucket]
    let quotaRecentBins: [QuotaHistoryRecentBucket]
    private static let dataLineWidth: CGFloat = 1.55
    private static let hoverRingLineWidth: CGFloat = 1.55
    @AppStorage("recentChartShowTokens") private var showTokens = true
    @AppStorage("recentChartShowCalls") private var showCalls = true
    @AppStorage("recentChartShowCacheHitRate") private var showCacheHitRate = true
    @AppStorage("recentChartShowFiveHourQuota") private var showFiveHourQuota = true
    @AppStorage("recentChartShowSevenDayQuota") private var showSevenDayQuota = true
    @State private var hoveredIndex: Int?
    @State private var preparedData: RecentChartPreparedData

    init(bins: [BinUsage], cacheRecentBins: [TokenCacheBucket], quotaRecentBins: [QuotaHistoryRecentBucket]) {
        self.bins = bins
        self.cacheRecentBins = cacheRecentBins
        self.quotaRecentBins = quotaRecentBins
        _preparedData = State(initialValue: .empty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近 24 小时")
                        .font(.system(size: 19, weight: .semibold))
                    Text("5 分钟粒度 · 5 分钟自动刷新")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 7) {
                    HStack(spacing: 14) {
                        ChartLegend(color: .blue, label: "Token", value: preparedData.tokenTotal.abbreviatedTokens)
                        ChartLegend(color: .orange, label: "调用", value: "\(preparedData.callTotal)")
                        ChartLegend(color: AppTheme.accentCyan, label: "命中率", value: preparedData.recentCacheBreakdown.cacheHitRate.percentString)
                        ChartLegend(color: .purple, label: "5h", value: Self.percentText(preparedData.latestFiveHourRemaining))
                        ChartLegend(color: .green, label: "7d", value: Self.percentText(preparedData.latestSevenDayRemaining))
                    }

                    HStack(spacing: 5) {
                        ChartLineToggle(title: "Token", color: .blue, isOn: $showTokens)
                        ChartLineToggle(title: "调用", color: .orange, isOn: $showCalls)
                        ChartLineToggle(title: "命中率", color: AppTheme.accentCyan, isOn: $showCacheHitRate)
                        ChartLineToggle(title: "5h", color: .purple, isOn: $showFiveHourQuota)
                        ChartLineToggle(title: "7d", color: .green, isOn: $showSevenDayQuota)
                    }
                }
            }

            GeometryReader { proxy in
                let plot = CGRect(x: 0, y: 18, width: proxy.size.width, height: proxy.size.height - 42)
                let step = plot.width / CGFloat(max(bins.count - 1, 1))
                let activeIndex = hoveredIndex.flatMap { bins.indices.contains($0) ? $0 : nil }
                let plotData = RecentChartPlotData(bins: bins, prepared: preparedData, plot: plot, step: step)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.accentBlue.opacity(0.10), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: plot.width, height: plot.height)
                        .offset(x: plot.minX, y: plot.minY)

                    ForEach(0..<4, id: \.self) { line in
                        let y = plot.minY + CGFloat(line) * plot.height / 3
                        Path { path in
                            path.move(to: CGPoint(x: plot.minX, y: y))
                            path.addLine(to: CGPoint(x: plot.maxX, y: y))
                        }
                        .stroke(AppTheme.grid, style: StrokeStyle(lineWidth: 1, dash: [4, 8]))
                    }

                    if showTokens {
                        tokenAreaPath(points: plotData.tokenPoints, plot: plot)
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.accentBlue.opacity(0.22), AppTheme.accentBlue.opacity(0.055), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        linePath(points: plotData.tokenPoints)
                            .stroke(AppTheme.accentBlue, style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round))
                    }

                    if showCalls {
                        linePath(points: plotData.callPoints)
                            .stroke(AppTheme.accentOrange, style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round))
                    }

                    if showCacheHitRate && preparedData.hasCacheCalls {
                        linePath(points: plotData.cachePoints)
                            .stroke(AppTheme.accentCyan, style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round, dash: [5, 5]))
                    }

                    if showFiveHourQuota && preparedData.hasFiveHourQuota {
                        optionalLinePath(points: plotData.fiveHourQuotaPoints)
                            .stroke(.purple.opacity(0.92), style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round, dash: [3, 6]))
                    }

                    if showSevenDayQuota && preparedData.hasSevenDayQuota {
                        optionalLinePath(points: plotData.sevenDayQuotaPoints)
                            .stroke(.green.opacity(0.88), style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round, dash: [7, 5]))
                    }

                    if let activeIndex {
                        let tokenPoint = plotData.tokenPoints[safe: activeIndex] ?? .zero
                        let callPoint = plotData.callPoints[safe: activeIndex] ?? .zero
                        let cachePoint = plotData.cachePoints[safe: activeIndex] ?? .zero
                        let fiveHourPoint = plotData.fiveHourQuotaPoints[safe: activeIndex] ?? nil
                        let sevenDayPoint = plotData.sevenDayQuotaPoints[safe: activeIndex] ?? nil

                        Path { path in
                            path.move(to: CGPoint(x: tokenPoint.x, y: plot.minY))
                            path.addLine(to: CGPoint(x: tokenPoint.x, y: plot.maxY))
                        }
                        .stroke(AppTheme.accentBlue.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))

                        if showTokens {
                            Circle()
                                .fill(AppTheme.pageBackground)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().stroke(AppTheme.accentBlue, lineWidth: Self.hoverRingLineWidth))
                                .position(tokenPoint)
                        }

                        if showCalls {
                            Circle()
                                .fill(AppTheme.pageBackground)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(AppTheme.accentOrange, lineWidth: Self.hoverRingLineWidth))
                                .position(callPoint)
                        }

                        if showCacheHitRate && preparedData.cacheBreakdowns[safe: activeIndex]?.calls ?? 0 > 0 {
                            Circle()
                                .fill(AppTheme.pageBackground)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(AppTheme.accentCyan, lineWidth: Self.hoverRingLineWidth))
                                .position(cachePoint)
                        }

                        if showFiveHourQuota, let fiveHourPoint {
                            Circle()
                                .fill(AppTheme.pageBackground)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(.purple, lineWidth: Self.hoverRingLineWidth))
                                .position(fiveHourPoint)
                        }

                        if showSevenDayQuota, let sevenDayPoint {
                            Circle()
                                .fill(AppTheme.pageBackground)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(.green, lineWidth: Self.hoverRingLineWidth))
                                .position(sevenDayPoint)
                        }

                        ChartHoverBubble(
                            bin: bins[activeIndex],
                            cacheBreakdown: preparedData.cacheBreakdowns[safe: activeIndex],
                            fiveHourRemaining: preparedData.fiveHourRemainingPercents[safe: activeIndex] ?? nil,
                            sevenDayRemaining: preparedData.sevenDayRemainingPercents[safe: activeIndex] ?? nil,
                            isHovering: true
                        )
                            .chartBubblePlacement(tokenX: tokenPoint.x, plot: plot)
                            .zIndex(10)
                    }

                    HoverTrackingArea(
                        onMove: { location in
                            let plotLocation = CGPoint(
                                x: location.x + plot.minX,
                                y: location.y + plot.minY
                            )
                            hoveredIndex = hoverIndex(at: plotLocation, in: plot, step: step)
                        },
                        onExit: {
                            hoveredIndex = nil
                        }
                    )
                    .frame(width: plot.width, height: plot.height)
                    .position(x: plot.midX, y: plot.midY)

                    ChartTimeMarkers(bins: bins, markerIndices: preparedData.markerIndices, plot: plot)
                }
            }
            .frame(height: 185)
        }
        .frame(maxWidth: 980)
        .onAppear(perform: refreshPreparedData)
        .onChange(of: bins) { _, _ in
            refreshPreparedData()
        }
        .onChange(of: cacheRecentBins) { _, _ in
            refreshPreparedData()
        }
        .onChange(of: quotaRecentBins) { _, _ in
            refreshPreparedData()
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        Path { path in
            appendSmoothPolyline(points, to: &path)
        }
    }

    private func tokenAreaPath(points: [CGPoint], plot: CGRect) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: plot.maxY))
        path.addLine(to: first)
        appendSmoothPolyline(points, to: &path, moveToStart: false)
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.addLine(to: CGPoint(x: last.x, y: plot.maxY))
        path.closeSubpath()
        return path
    }

    private func optionalLinePath(points: [CGPoint?]) -> Path {
        var path = Path()
        appendSmoothPolyline(points.compactMap { $0 }, to: &path)
        return path
    }

    private func appendSmoothPolyline(_ points: [CGPoint], to path: inout Path, moveToStart: Bool = true) {
        guard let first = points.first else { return }
        if moveToStart {
            path.move(to: first)
        }

        guard points.count > 2 else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return
        }

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = CGPoint(
                x: (previous.x + current.x) / 2,
                y: (previous.y + current.y) / 2
            )
            path.addQuadCurve(to: midpoint, control: previous)
        }

        if let last = points.last {
            path.addLine(to: last)
        }
    }

    private func hoverIndex(at location: CGPoint, in plot: CGRect, step: CGFloat) -> Int? {
        guard plot.contains(location), !bins.isEmpty else { return nil }
        let rawIndex = Int(round((location.x - plot.minX) / max(step, 1)))
        return min(max(rawIndex, bins.startIndex), bins.index(before: bins.endIndex))
    }

    private func refreshPreparedData() {
        preparedData = Self.prepare(bins: bins, cacheRecentBins: cacheRecentBins, quotaRecentBins: quotaRecentBins)
    }

    private static func prepare(bins: [BinUsage], cacheRecentBins: [TokenCacheBucket], quotaRecentBins: [QuotaHistoryRecentBucket]) -> RecentChartPreparedData {
        let cacheByStart = Dictionary(uniqueKeysWithValues: cacheRecentBins.map { bucket in
            (bucket.start, bucket.breakdown)
        })
        let quotaByBin = Dictionary(uniqueKeysWithValues: quotaRecentBins.map { bucket in
            (timeBinKey(bucket.start), bucket)
        })
        let cacheBreakdowns = bins.map { bin in
            cacheByStart[bin.start] ?? .empty
        }
        let carriedRates = carriedCacheHitRates(cacheBreakdowns: cacheBreakdowns)
        let quotaBuckets = bins.map { bin in
            quotaByBin[timeBinKey(bin.start)]
        }
        let fiveHourRemaining = quotaBuckets.map { $0?.fiveHourRemainingPercent }
        let sevenDayRemaining = quotaBuckets.map { $0?.sevenDayRemainingPercent }
        let last = bins.count - 1
        let markerIndices: [Int] = bins.count > 1
            ? [0, last / 4, last / 2, (last * 3) / 4, last].reduce(into: [Int]()) { result, index in
                if !result.contains(index) {
                    result.append(index)
                }
            }
            : []

        return RecentChartPreparedData(
            maxTokens: max(bins.map(\.tokens).max() ?? 1, 1),
            maxCalls: max(bins.map(\.calls).max() ?? 1, 1),
            tokenTotal: bins.reduce(0) { $0 + $1.tokens },
            callTotal: bins.reduce(0) { $0 + $1.calls },
            recentCacheBreakdown: cacheBreakdowns.combined,
            cacheBreakdowns: cacheBreakdowns,
            carriedCacheHitRates: carriedRates,
            fiveHourRemainingPercents: fiveHourRemaining,
            sevenDayRemainingPercents: sevenDayRemaining,
            latestFiveHourRemaining: fiveHourRemaining.reversed().compactMap { $0 }.first,
            latestSevenDayRemaining: sevenDayRemaining.reversed().compactMap { $0 }.first,
            hasCacheCalls: cacheBreakdowns.contains { $0.calls > 0 },
            hasFiveHourQuota: fiveHourRemaining.contains { $0 != nil },
            hasSevenDayQuota: sevenDayRemaining.contains { $0 != nil },
            markerIndices: markerIndices
        )
    }

    private static func timeBinKey(_ date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / 300.0))
    }

    private static func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    private static func carriedCacheHitRates(cacheBreakdowns: [TokenCacheBreakdown]) -> [Double] {
        var carriedRate = cacheBreakdowns.first(where: { $0.calls > 0 })?.cacheHitRate ?? 0
        return cacheBreakdowns.map { breakdown in
            if breakdown.calls > 0 {
                carriedRate = breakdown.cacheHitRate
                return breakdown.cacheHitRate
            }
            return carriedRate
        }
    }
}

struct ChartLegend: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(label == "命中率" ? .primary : .secondary)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 12))
    }
}

struct ChartLineToggle: View {
    let title: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? color : .secondary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? color.opacity(0.10) : AppTheme.raisedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isOn ? color.opacity(0.28) : AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func chartBubblePlacement(tokenX: CGFloat, plot: CGRect) -> some View {
        modifier(ChartBubblePlacementModifier(tokenX: tokenX, plot: plot))
    }
}

private struct ChartBubblePlacementModifier: ViewModifier {
    let tokenX: CGFloat
    let plot: CGRect

    func body(content: Content) -> some View {
        let plot = self.plot
        let tokenX = self.tokenX
        content
            .fixedSize(horizontal: true, vertical: false)
            .alignmentGuide(.leading) { dimensions in
                let lower = plot.minX
                let upper = max(lower, plot.maxX - dimensions.width)
                let centered = tokenX - dimensions.width / 2
                return -min(max(centered, lower), upper)
            }
            .alignmentGuide(.top) { dimensions in
                -(plot.minY - recentChartHoverBubbleVerticalOffset - dimensions.height / 2)
            }
            .frame(width: plot.width, height: plot.height, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

struct ChartHoverBubble: View {
    let bin: BinUsage
    let cacheBreakdown: TokenCacheBreakdown?
    let fiveHourRemaining: Double?
    let sevenDayRemaining: Double?
    let isHovering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(isHovering ? "当前点" : "最新点")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovering ? AppTheme.accentBlue : .secondary)
                Text(timeRange)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(bin.tokens.abbreviatedTokens)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.accentBlue)
            Text("请求 \(bin.calls) 次 · avg \(average.abbreviatedTokens)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let cacheBreakdown, cacheBreakdown.calls > 0 {
                Text("缓存命中 \(cacheBreakdown.cacheHitRate.percentString) · 命中 \(cacheBreakdown.cachedInputTokens.abbreviatedTokens)")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.accentCyan)
            }
            if fiveHourRemaining != nil || sevenDayRemaining != nil {
                Text("额度 5h \(percentText(fiveHourRemaining)) · 7d \(percentText(sevenDayRemaining))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .fixedSize(horizontal: true, vertical: false)
        .background(AppTheme.hoverBubble, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.borderStrong, lineWidth: 1)
        )
    }

    private var average: Int {
        bin.calls > 0 ? bin.tokens / bin.calls : 0
    }

    private var timeRange: String {
        let end = bin.start.addingTimeInterval(5 * 60)
        return "\(DateFormatter.hourMinute.string(from: bin.start)) - \(DateFormatter.hourMinute.string(from: end))"
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }
}

struct ChartTimeMarkers: View {
    let bins: [BinUsage]
    let markerIndices: [Int]
    let plot: CGRect

    var body: some View {
        ForEach(markerIndices, id: \.self) { index in
            if let bin = bins[safe: index] {
                Text(DateFormatter.hourMinute.string(from: bin.start))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .position(x: xPosition(for: index), y: plot.maxY + 20)
            }
        }
    }

    private func xPosition(for index: Int) -> CGFloat {
        plot.minX + CGFloat(index) * plot.width / CGFloat(max(bins.count - 1, 1))
    }
}

struct HoverTrackingArea: NSViewRepresentable {
    let onMove: (CGPoint) -> Void
    var onClick: ((CGPoint) -> Void)? = nil
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        view.onClick = onClick
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove
        nsView.onClick = onClick
        nsView.onExit = onExit
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint) -> Void)?
        var onClick: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?
        private var currentTrackingArea: NSTrackingArea?

        override var isFlipped: Bool {
            true
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard currentTrackingArea == nil else { return }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            currentTrackingArea = area
            addTrackingArea(area)
        }

        override func mouseMoved(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            onClick?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
        }
    }
}

private extension Notification.Name {
    static let dashboardBlankAreaClicked = Notification.Name("CodexTokenBarDashboardBlankAreaClicked")
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension DateFormatter {
    static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static let fullDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let monthDayHourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

extension NumberFormatter {
    static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

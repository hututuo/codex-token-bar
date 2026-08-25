import AppKit
import SwiftUI

enum AppSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case sessionEnhancements
    case codexInstances
    case autoResume
    case surfaces
    case statusBar
    case monitoring
    case floatingPanel
    // Legacy route kept for requests created by older builds. It is omitted
    // from the sidebar and resolves to the unified floating-panel page.
    case content
    case alertsAndUpdates
    case dataAndMaintenance

    static let allCases: [AppSettingsCategory] = [
        .general,
        .sessionEnhancements,
        .codexInstances,
        .autoResume,
        .surfaces,
        .statusBar,
        .monitoring,
        .floatingPanel,
        .alertsAndUpdates,
        .dataAndMaintenance,
    ]

    var id: String { rawValue }

    var canonical: AppSettingsCategory {
        self == .content ? .floatingPanel : self
    }

    var title: String {
        switch self {
        case .general: return "常规"
        case .sessionEnhancements: return "会话增强"
        case .codexInstances: return "Codex 实例"
        case .autoResume: return "自动续跑"
        case .surfaces: return "显示面"
        case .statusBar: return "状态栏"
        case .monitoring: return "监控与额度"
        case .floatingPanel, .content: return "悬浮窗"
        case .alertsAndUpdates: return "提醒与更新"
        case .dataAndMaintenance: return "数据与维护"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "启动与基础行为"
        case .sessionEnhancements: return "会话管理、导出、移动、输入与阅读体验"
        case .codexInstances: return "多开、隔离、同步与回滚"
        case .autoResume: return "按所选失败原因、定时或额度恢复继续任务"
        case .surfaces: return "主界面与辅助显示面"
        case .statusBar: return "顶部指标、顺序与紧凑显示"
        case .monitoring: return "实时速率、统计与刷新"
        case .floatingPanel, .content: return "位置、外观、内容与翻页"
        case .alertsAndUpdates: return "未读反馈与版本检查"
        case .dataAndMaintenance: return "目录与修复工具"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .sessionEnhancements: return "sparkles.rectangle.stack"
        case .codexInstances: return "square.stack.3d.up"
        case .autoResume: return "play.circle"
        case .surfaces: return "rectangle.3.group"
        case .statusBar: return "menubar.rectangle"
        case .monitoring: return "speedometer"
        case .floatingPanel, .content: return "rectangle.on.rectangle"
        case .alertsAndUpdates: return "bell.badge"
        case .dataAndMaintenance: return "wrench.and.screwdriver"
        }
    }
}

enum AppSettingsRouteRequest {
    static let pendingCategoryKey = "pendingAppSettingsCategoryV01"

    static func request(
        _ category: AppSettingsCategory,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(category.rawValue, forKey: pendingCategoryKey)
        notificationCenter.post(name: .dashboardShowSettings, object: category)
    }

    static func consume(defaults: UserDefaults = .standard) -> AppSettingsCategory? {
        guard let rawValue = defaults.string(forKey: pendingCategoryKey) else { return nil }
        defaults.removeObject(forKey: pendingCategoryKey)
        return AppSettingsCategory(rawValue: rawValue)?.canonical
    }
}

struct AppSettingsView: View {
    @ObservedObject var loginItemStore: LoginItemStore
    @ObservedObject var updateSettingsStore: AppUpdateSettingsStore
    @ObservedObject var autoResumeController: AutoResumeTaskManager
    @ObservedObject var threadDeleteBridge: CodexThreadDeleteBridgeController
    @Binding var selectedCategory: AppSettingsCategory
    @Binding var floatingPanelEnabled: Bool
    @Binding var statusBarPanelEnabled: Bool
    @Binding var statusBarMetricShowsIcon: Bool
    @Binding var statusBarMetricOrderRaw: String
    @Binding var statusBarMetricSelectionRaw: String
    @Binding var statusBarMetricLabelStyleRaw: String
    @Binding var statusSummaryOrderRaw: String
    @Binding var statusSummarySelectionRaw: String
    let statusBarPreviewValues: StatusBarMetricValues
    @Binding var liveRateMonitoringEnabled: Bool
    @Binding var preciseTokenCountingEnabled: Bool
    @Binding var tokenRateFullScale: Double
    @Binding var floatingPanelLocked: Bool
    @Binding var interfaceScaleAutoEnabled: Bool
    @Binding var interfaceScaleManualMultiplier: Double
    @Binding var floatingPanelOpacity: Double
    @Binding var floatingPanelScale: Double
    @Binding var floatingPanelTextTone: Double
    @Binding var gradientStartHex: String
    @Binding var gradientEndHex: String
    @Binding var gradientDirection: String
    @Binding var gradientStyle: String
    @Binding var quotaColorMode: String
    @Binding var quotaFixedHex: String
    @Binding var unreadEffect: String
    @Binding var showRateAndBar: Bool
    @Binding var showUsageStatus: Bool
    @Binding var showMetrics: Bool
    @Binding var showRunningThreads: Bool
    @Binding var showTodayModelShare: Bool
    @Binding var showTodayModelCost: Bool
    @Binding var showQuota: Bool
    @Binding var showRadar: Bool
    @Binding var showCrowdRadar: Bool
    @Binding var crowdRadarPageCount: Int
    @Binding var contentOrderRaw: String
    @Binding var pagePairsRaw: String
    @Binding var showPageNavigationArrows: Bool
    let floatingPreviewSnapshot: TokenDisplaySnapshot
    let floatingPreviewRadarPresentation: CodexRadarPresentationState
    let defaultCodexHome: URL?
    let dataSourceLabel: String
    let dataSourceOrigin: String
    let onChooseDirectory: () -> Void
    let onOpenProviderSync: () -> Void
    let onOpenSessionManager: () -> Void
    let onThreadDeleteConnectionAction: () -> Void
    let onClose: () -> Void

    @AppStorage(UsageRefreshCadenceSettings.lightRefreshIntervalStorageKey)
    private var usageLightRefreshIntervalRaw = String(UsageRefreshCadenceSettings.defaultLightRefreshIntervalSeconds)
    @AppStorage(UsageRefreshCadenceSettings.visibleAggregateIntervalStorageKey)
    private var usageVisibleAggregateIntervalRaw = String(UsageRefreshCadenceSettings.defaultVisibleAggregateIntervalMinutes)
    @AppStorage(UsageRefreshCadenceSettings.backgroundAggregateIntervalStorageKey)
    private var usageBackgroundAggregateIntervalRaw = String(UsageRefreshCadenceSettings.defaultBackgroundAggregateIntervalMinutes)
    @AppStorage(AccountQuotaRefreshCadence.storageKey) private var quotaRefreshCadenceRaw = AccountQuotaRefreshCadence.defaultRawValue
    @AppStorage(SharedAccountUsageAttributionSettings.enabledKey) private var sharedAccountAttributionEnabled = SharedAccountUsageAttributionSettings.defaultEnabled
    @AppStorage(SharedAccountUsageAttributionSettings.tierKey) private var sharedAccountRadarTierRaw = SharedAccountUsageAttributionSettings.defaultTier.rawValue
    @AppStorage(SharedAccountUsageAttributionSettings.priceModelKey) private var sharedAccountPriceModelRaw = OfficialAPIPriceModel.gpt56Sol.rawValue
    @FocusState private var focusedCategory: AppSettingsCategory?
    @State private var floatingPreviewSelectedRowID: String?
    @State private var floatingPreviewScrollTarget: String?

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Rectangle()
                .fill(AppTheme.border)
                .frame(width: 1)

            settingsContent
        }
        .frame(width: 1040, height: 680)
        .background(AppTheme.panelBackground)
        .onExitCommand(perform: onClose)
        .onAppear {
            selectedCategory = selectedCategory.canonical
            usageLightRefreshIntervalRaw = UsageRefreshCadenceSettings.normalizedLightRawValue(
                usageLightRefreshIntervalRaw
            )
            usageVisibleAggregateIntervalRaw = UsageRefreshCadenceSettings.normalizedAggregateRawValue(
                usageVisibleAggregateIntervalRaw
            )
            usageBackgroundAggregateIntervalRaw = UsageRefreshCadenceSettings.normalizedBackgroundAggregateRawValue(
                usageBackgroundAggregateIntervalRaw
            )
            sharedAccountRadarTierRaw = SharedAccountRadarTier.storedValue(for: sharedAccountRadarTierRaw).rawValue
            sharedAccountPriceModelRaw = OfficialAPIPriceModel.storedValue(for: sharedAccountPriceModelRaw).rawValue
            if selectedCategory == .autoResume {
                autoResumeController.refreshThreads()
            }
        }
        .onChange(of: selectedCategory) {
            if selectedCategory != selectedCategory.canonical {
                selectedCategory = selectedCategory.canonical
                return
            }
            if selectedCategory == .autoResume {
                autoResumeController.refreshThreads()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("总体设置")
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("总体设置")
                    .font(.system(size: 18, weight: .semibold))
                Text("Codex Token Bar")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(spacing: 4) {
                ForEach(AppSettingsCategory.allCases) { category in
                    sidebarButton(category)
                }
            }
            .padding(.horizontal, 9)
            .onMoveCommand(perform: moveSidebarSelection)

            Spacer(minLength: 16)

            Label("更改会立即生效", systemImage: "checkmark.circle")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .frame(width: 204)
        .background(AppTheme.panelBackgroundAlt)
    }

    private func sidebarButton(_ category: AppSettingsCategory) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            selectedCategory = category
            focusedCategory = category
        } label: {
            HStack(spacing: 9) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 17)
                Text(category.title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                Spacer(minLength: 4)
            }
            .foregroundStyle(isSelected ? AppTheme.accentBlue : Color.primary.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(height: 37)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AppTheme.selectedControlBackground : Color.clear)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(AppTheme.accentBlue)
                        .frame(width: 3, height: 19)
                        .padding(.leading, 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focusedCategory, equals: category)
        .accessibilityLabel(category.title)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityHint("切换到\(category.subtitle)")
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedCategory.title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(selectedCategory.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭总体设置")
                .accessibilityLabel("关闭总体设置")
            }
            .padding(.horizontal, 24)
            .frame(height: 72)

            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)

            if selectedCategory.canonical == .floatingPanel {
                floatingPanelSettingsWorkspace
                    .id(selectedCategory)
            } else {
                ScrollView {
                    selectedCategoryContent
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id(selectedCategory)
            }
        }
    }

    @ViewBuilder
    private var selectedCategoryContent: some View {
        VStack(spacing: 18) {
            switch selectedCategory {
            case .general:
                generalSettings
            case .sessionEnhancements:
                sessionEnhancementSettings
            case .codexInstances:
                CodexInstanceSettingsView(defaultCodexHome: defaultCodexHome)
            case .autoResume:
                AutoResumeSettingsView(controller: autoResumeController)
            case .surfaces:
                surfaceSettings
            case .statusBar:
                statusBarSettings
            case .monitoring:
                monitoringSettings
            case .floatingPanel, .content:
                floatingPanelSettings
            case .alertsAndUpdates:
                alertsAndUpdateSettings
            case .dataAndMaintenance:
                dataAndMaintenanceSettings
            }
        }
    }

    private var generalSettings: some View {
        Group {
            settingsSection(title: "启动", subtitle: "控制应用是否随登录自动运行") {
                settingsToggle("开机自启", systemImage: "power", isOn: loginItemBinding)
            }

            settingsSection(title: "设置行为", subtitle: "这里的选项无需单独保存") {
                settingsInfoRow(
                    "即时生效",
                    systemImage: "bolt.fill",
                    detail: "切换标签页或关闭设置后，当前选择都会继续保留。"
                )
            }
        }
    }

    private var sessionEnhancementSettings: some View {
        Group {
            settingsSection(
                title: "完整会话管理",
                subtitle: "按项目查看全部会话、上下文、官方归档、恢复包和容量清理"
            ) {
                settingsActionRow(
                    "会话管理工作面",
                    systemImage: "rectangle.stack.badge.gearshape",
                    detail: "独立三栏页面；列表每次显示 100 个，但可持续加载到完整目录。",
                    buttonTitle: "打开会话管理",
                    buttonSystemImage: "arrow.up.right.square",
                    action: onOpenSessionManager
                )
            }

            settingsSection(
                title: "Codex 页面连接",
                subtitle: "通过仅限本机的调试端口加载增强；功能开关变化后会自动重连，无需重启 Codex"
            ) {
                settingsActionRow(
                    threadDeleteBridge.status.connected ? "会话增强已连接" : "会话增强未连接",
                    systemImage: threadDeleteBridge.status.connected
                        ? "link.circle.fill"
                        : "link.badge.plus",
                    detail: threadDeleteBridge.status.message,
                    buttonTitle: threadDeleteBridge.status.connectionActionTitle,
                    buttonSystemImage: "arrow.clockwise",
                    statusColor: threadDeleteBridge.status.connected
                        ? AppTheme.accentGreen
                        : AppTheme.accentAmber,
                    enabled: !threadDeleteBridge.status.isBusy,
                    action: onThreadDeleteConnectionAction
                )
            }

            settingsSection(
                title: "Codex 侧栏增强",
                subtitle: "保留非破坏性的快捷能力；永久删除统一进入完整会话管理"
            ) {
                settingsActionRow(
                    "侧栏直接删除已迁移",
                    systemImage: "trash",
                    detail: CodexLegacySessionDeletePolicy.migrationMessage,
                    buttonTitle: "打开会话管理",
                    buttonSystemImage: "arrow.up.right.square",
                    action: onOpenSessionManager
                )
                settingsToggle(
                    "Markdown 导出",
                    systemImage: "arrow.down.doc",
                    isOn: markdownExportBinding
                )
                settingsToggle(
                    "会话项目移动",
                    systemImage: "folder.badge.arrow.forward",
                    isOn: projectMoveBinding
                )
                settingsToggle(
                    "会话 ID 标识",
                    systemImage: "number.square",
                    isOn: threadIDBadgeBinding
                )
            }

            settingsSection(
                title: "输入与阅读",
                subtitle: "改善富文本粘贴、大屏阅读和多任务切换体验"
            ) {
                settingsToggle(
                    "粘贴修复",
                    systemImage: "doc.on.clipboard",
                    isOn: pasteFixBinding
                )
                settingsToggle(
                    "对话居中宽度",
                    systemImage: "arrow.left.and.right",
                    isOn: conversationViewBinding
                )
                if threadDeleteBridge.enhancementSettings.conversationView {
                    settingsSlider(
                        "最大宽度",
                        systemImage: "rectangle.compress.vertical",
                        value: conversationWidthBinding,
                        range: 320...4_000,
                        display: "\(threadDeleteBridge.enhancementSettings.conversationViewMaxWidth) px",
                        step: 10
                    )
                }
                settingsToggle(
                    "切换对话保留位置",
                    systemImage: "arrow.up.and.down.text.horizontal",
                    isOn: threadScrollRestoreBinding
                )
            }

            settingsSection(
                title: "开源归属",
                subtitle: "本页会话增强基于 Codex++ v1.2.41 的“对话与输入”实现迁入"
            ) {
                settingsActionRow(
                    "Codex++ · AGPL-3.0",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    detail: "保留 BigPizzaV3/CodexPlusPlus 的版权与 GNU AGPL v3 许可；Token Bar 对迁入实现作了 Swift 原生桥接和当前 Codex 结构适配。",
                    buttonTitle: "查看上游源码",
                    buttonSystemImage: "arrow.up.right.square",
                    action: openCodexPlusPlusSource
                )
            }
        }
    }

    private var surfaceSettings: some View {
        Group {
            settingsSection(title: "辅助显示面", subtitle: "状态栏的内容与入口集中在独立设置页") {
                settingsToggle("悬浮窗", systemImage: "rectangle.on.rectangle", isOn: $floatingPanelEnabled)
            }

            settingsSection(title: "主界面缩放", subtitle: "自动适配窗口，也可以固定界面大小") {
                settingsToggle("界面自动适配", systemImage: "textformat.size", isOn: $interfaceScaleAutoEnabled)
                settingsSlider(
                    "界面大小",
                    systemImage: "textformat.size.larger",
                    value: $interfaceScaleManualMultiplier,
                    range: InterfaceScaleSettings.manualRange,
                    display: InterfaceScaleSettings.displayValue(interfaceScaleManualMultiplier),
                    disabled: interfaceScaleAutoEnabled
                )
            }
        }
    }

    private var statusBarSettings: some View {
        Group {
            settingsSection(title: "实时预览", subtitle: "按当前数据展示，选择和顺序更改会立即反映") {
                statusBarPreview
            }

            settingsSection(title: "显示方式", subtitle: "关闭实时指标后，同一个入口会切换为固定闪电图标") {
                settingsToggle("状态栏（实验）", systemImage: "menubar.rectangle", isOn: $statusBarPanelEnabled)
                settingsToggle("显示闪电图标", systemImage: "bolt.circle.fill", isOn: $statusBarMetricShowsIcon)
                settingsPicker(
                    "标签样式",
                    systemImage: "textformat",
                    selection: $statusBarMetricLabelStyleRaw,
                    options: StatusBarMetricLabelStyle.allCases.map { ($0.rawValue, $0.title) }
                )
            }

            settingsSection(title: "指标与顺序", subtitle: "选择要显示的指标，并用箭头调整从左到右的顺序") {
                ForEach(orderedStatusBarMetrics) { metric in
                    statusBarMetricRow(metric)
                }
                statusBarRestoreDefaultsRow
            }

            settingsSection(title: "摘要内容与排序", subtitle: "编排点击状态栏后弹出的摘要卡片") {
                ForEach(orderedStatusSummarySections) { section in
                    statusSummarySectionRow(section)
                }
                statusSummaryRestoreDefaultsRow
            }
        }
    }

    private var monitoringSettings: some View {
        Group {
            settingsSection(title: "速率与统计", subtitle: "控制本地实时监控和 token 计算精度") {
                settingsToggle("实时速率监控", systemImage: "speedometer", isOn: $liveRateMonitoringEnabled)
                settingsToggle("精确 token 统计", systemImage: "number", isOn: $preciseTokenCountingEnabled)
                settingsSlider(
                    "速率满刻度",
                    systemImage: "gauge.with.dots.needle.67percent",
                    value: $tokenRateFullScale,
                    range: TokenRateScaleSettings.range,
                    display: TokenRateScaleSettings.displayValue(tokenRateFullScale),
                    step: 10
                )
            }

            settingsSection(
                title: "本地统计刷新",
                subtitle: "轻量摘要与主界面图表分开调度；图表只在安全的墙钟边界更新"
            ) {
                settingsCompactPicker(
                    "轻量摘要",
                    detail: "悬浮窗、状态栏和主界面摘要",
                    systemImage: "text.bubble",
                    selection: usageLightRefreshIntervalBinding,
                    options: UsageRefreshCadenceSettings.lightRefreshIntervalOptions.map {
                        (String($0), UsageRefreshCadenceSettings.lightRefreshIntervalLabel($0))
                    }
                )
                settingsCompactPicker(
                    "主界面图表",
                    detail: "主界面打开时的折线、热力图和模型统计",
                    systemImage: "chart.xyaxis.line",
                    selection: usageVisibleAggregateIntervalBinding,
                    options: UsageRefreshCadenceSettings.aggregateIntervalOptions.map {
                        (String($0), UsageRefreshCadenceSettings.aggregateIntervalLabel($0))
                    }
                )
                settingsCompactPicker(
                    "后台图表",
                    detail: "主界面关闭时的图表聚合，降低后台开销",
                    systemImage: "chart.bar.xaxis",
                    selection: usageBackgroundAggregateIntervalBinding,
                    options: UsageRefreshCadenceSettings.aggregateIntervalOptions.map {
                        (String($0), UsageRefreshCadenceSettings.aggregateIntervalLabel($0))
                    }
                )
            }

            settingsSection(title: "额度", subtitle: "设置官方额度数据的自动刷新频率") {
                settingsPicker(
                    "额度刷新",
                    systemImage: "clock.arrow.circlepath",
                    selection: $quotaRefreshCadenceRaw,
                    options: AccountQuotaRefreshCadence.allCases.map { ($0.rawValue, $0.label) }
                )
            }

            settingsSection(
                title: "共享账号用量归因",
                subtitle: "用本机同基准 API 金额占 Radar 套餐总额的比例，对照账号本周期实际下降"
            ) {
                settingsToggle(
                    "显示共享账号归因",
                    systemImage: "person.2",
                    isOn: $sharedAccountAttributionEnabled
                )
                if sharedAccountAttributionEnabled {
                    settingsPicker(
                        "Radar 套餐",
                        systemImage: "dot.radiowaves.left.and.right",
                        selection: sharedAccountRadarTierBinding,
                        options: SharedAccountRadarTier.allCases.map { ($0.rawValue, $0.title) }
                    )
                    .settingsRowDivider()
                    settingsPicker(
                        "未知模型回退",
                        systemImage: "cpu",
                        selection: sharedAccountPriceModelBinding,
                        options: OfficialAPIPriceModel.selectableCases.map { ($0.rawValue, $0.title) }
                    )
                    .settingsRowDivider()
                    settingsInfoRow(
                        "计算口径",
                        systemImage: "function",
                        detail: "已记录的 Sol、Terra、Luna 会逐次自动计价；旧记录和未知路由才使用上方回退模型。本机占比 = 本机等价金额 ÷ Radar 套餐 7 天总额 × 100；负差额不会归零。"
                    )
                }
            }
        }
    }

    private var floatingPanelSettings: some View {
        VStack(spacing: 14) {
            settingsSection(title: "窗口与文字", subtitle: "常用设置两列排布，减少纵向占用") {
                LazyVGrid(columns: floatingCompactGridColumns, spacing: 9) {
                    floatingCompactToggleCard(
                        "锁定位置",
                        systemImage: "lock",
                        isOn: $floatingPanelLocked
                    )
                    floatingCompactSliderCard(
                        "透明度",
                        systemImage: "circle.lefthalf.filled",
                        value: $floatingPanelOpacity,
                        range: 0.45...0.98,
                        display: "\(Int((floatingPanelOpacity * 100).rounded()))%"
                    )
                    floatingCompactSliderCard(
                        "大小",
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        value: $floatingPanelScale,
                        range: FloatingTokenPanelMetrics.scaleRange,
                        display: "\(Int((floatingPanelScale * 100).rounded()))%"
                    )
                    floatingCompactSliderCard(
                        "字体颜色",
                        systemImage: "textformat",
                        value: $floatingPanelTextTone,
                        range: -1...1,
                        display: FloatingPanelTextTonePreference.displayText(for: floatingPanelTextTone)
                    )
                }
                .padding(10)
            }

            settingsSection(title: "外观", subtitle: "统一设置文字、背景渐变和额度条配色") {
                LazyVGrid(columns: floatingCompactGridColumns, spacing: 9) {
                    floatingCompactColorCard(
                        "起始色",
                        systemImage: "circle.fill",
                        hex: $gradientStartHex,
                        fallback: FloatingPanelAppearance.defaultStartHex
                    )
                    floatingCompactColorCard(
                        "结束色",
                        systemImage: "circle.lefthalf.filled",
                        hex: $gradientEndHex,
                        fallback: FloatingPanelAppearance.defaultEndHex
                    )
                    floatingCompactPickerCard(
                        "渐变方向",
                        systemImage: "arrow.up.right",
                        selection: $gradientDirection,
                        options: FloatingPanelGradientDirection.allCases.map { ($0.rawValue, $0.label) }
                    )
                    floatingCompactPickerCard(
                        "渐变类型",
                        systemImage: "swirl.circle.righthalf.filled",
                        selection: $gradientStyle,
                        options: FloatingPanelGradientStyle.allCases.map { ($0.rawValue, $0.label) }
                    )
                    floatingCompactPickerCard(
                        "额度条配色",
                        systemImage: "chart.bar.fill",
                        selection: $quotaColorMode,
                        options: FloatingQuotaColorMode.allCases.map { ($0.rawValue, $0.label) }
                    )
                    if quotaColorMode == FloatingQuotaColorMode.fixed.rawValue {
                        floatingCompactColorCard(
                            "额度固定色",
                            systemImage: "circle.fill",
                            hex: $quotaFixedHex,
                            fallback: FloatingQuotaColorStyle.defaultFixedHex
                        )
                    }
                }
                .padding(10)
            }

            contentSettings
        }
    }

    private var floatingCompactGridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 210), spacing: 9),
            GridItem(.flexible(minimum: 210), spacing: 9),
        ]
    }

    private func floatingCompactToggleCard(
        _ title: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.border.opacity(0.8), lineWidth: 1))
    }

    private func floatingCompactSliderCard(
        _ title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(display)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Slider(value: value, in: range, step: 0.01)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.border.opacity(0.8), lineWidth: 1))
    }

    private func floatingCompactPickerCard(
        _ title: String,
        systemImage: String,
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { value, label in Text(label).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(title)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.border.opacity(0.8), lineWidth: 1))
    }

    private func floatingCompactColorCard(
        _ title: String,
        systemImage: String,
        hex: Binding<String>,
        fallback: String
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            Spacer(minLength: 6)
            ColorPicker("", selection: colorBinding(hex: hex, fallback: fallback), supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.border.opacity(0.8), lineWidth: 1))
    }

    private var floatingPanelSettingsWorkspace: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    floatingPanelSettings
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: floatingPreviewScrollTarget) {
                    guard let target = floatingPreviewScrollTarget else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo("floating-structure-row:\(target)", anchor: .center)
                    }
                    DispatchQueue.main.async {
                        floatingPreviewScrollTarget = nil
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(AppTheme.border)
                .frame(width: 1)

            FloatingPanelLivePreview(
                visibility: floatingContentVisibilityBinding.wrappedValue,
                snapshot: floatingPreviewSnapshot,
                radarPresentation: floatingPreviewRadarPresentation,
                opacity: floatingPanelOpacity,
                scale: floatingPanelScale,
                textTone: floatingPanelTextTone,
                appearance: FloatingPanelAppearance(
                    startHex: gradientStartHex,
                    endHex: gradientEndHex,
                    directionRaw: gradientDirection,
                    styleRaw: gradientStyle
                ),
                quotaColorMode: quotaColorMode,
                quotaFixedHex: quotaFixedHex,
                selectedRowID: Binding(
                    get: { floatingPreviewSelectedRowID },
                    set: { selectedRowID in
                        floatingPreviewSelectedRowID = selectedRowID
                        floatingPreviewScrollTarget = selectedRowID
                    }
                )
            )
            .frame(width: 258, alignment: .top)
            .padding(.horizontal, 14)
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contentSettings: some View {
        FloatingPanelStructureEditor(
            visibility: floatingContentVisibilityBinding,
            snapshot: floatingPreviewSnapshot,
            radarPresentation: floatingPreviewRadarPresentation,
            opacity: floatingPanelOpacity,
            scale: floatingPanelScale,
            textTone: floatingPanelTextTone,
            appearance: FloatingPanelAppearance(
                startHex: gradientStartHex,
                endHex: gradientEndHex,
                directionRaw: gradientDirection,
                styleRaw: gradientStyle
            ),
            quotaColorMode: quotaColorMode,
            quotaFixedHex: quotaFixedHex,
            selectedRowID: $floatingPreviewSelectedRowID,
            showsPreview: false
        )
    }

    private var statusBarPreview: some View {
        let previewConfiguration = statusBarPanelEnabled
            ? statusBarMetricConfiguration
            : StatusBarMetricConfiguration(
                version: statusBarMetricConfiguration.version,
                orderedMetricIDs: statusBarMetricConfiguration.orderedMetricIDs,
                selectedMetricIDs: [],
                showsIcon: true,
                labelStyle: statusBarMetricConfiguration.labelStyle
            )
        let presentation = StatusBarMetricsPresentation.make(
            values: statusBarPreviewValues,
            configuration: previewConfiguration
        )
        let showsRecoveryIcon = previewConfiguration.showsIcon || presentation.text.isEmpty

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if showsRecoveryIcon {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundStyle(AppTheme.accentBlue)
                }
                if presentation.text.isEmpty {
                    Text("仅保留恢复图标")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(presentation.columns.enumerated()), id: \.offset) { entry in
                            let column = entry.element
                            VStack(alignment: .leading, spacing: 0) {
                                Text(column.top.text.isEmpty ? "\u{200B}" : column.top.text)
                                    .font(.system(
                                        size: 8.75,
                                        weight: .semibold,
                                        design: .monospaced
                                    ))
                                    .foregroundStyle(column.top.isSecondary ? .secondary : .primary)
                                    .frame(height: 10)
                                Text(column.bottom.text.isEmpty ? "\u{200B}" : column.bottom.text)
                                    .font(.system(
                                        size: 8.75,
                                        weight: .semibold,
                                        design: .monospaced
                                    ))
                                    .foregroundStyle(column.bottom.isSecondary ? .secondary : .primary)
                                    .frame(height: 10)
                            }
                            .fixedSize()
                        }
                    }
                    .accessibilityLabel(presentation.accessibilityValue)
                }
                Spacer(minLength: 10)
                Text(statusBarPanelEnabled ? "实时指标" : "仅图标")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(statusBarPanelEnabled ? AppTheme.accentBlue : Color.secondary)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.72)

            if !statusBarMetricShowsIcon && presentation.text.isEmpty {
                Text("没有可用文字时会自动保留图标，避免失去设置入口。")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("状态栏实时预览")
        .accessibilityValue(presentation.accessibilityValue)
    }

    private var alertsAndUpdateSettings: some View {
        Group {
            settingsSection(title: "未读提醒", subtitle: "任务完成后在悬浮窗上显示柔和反馈") {
                settingsPicker("未读提醒", systemImage: "bell.badge", selection: $unreadEffect, options: FloatingPanelUnreadEffect.allCases.map { ($0.rawValue, $0.label) })
            }

            settingsSection(title: "版本更新", subtitle: "后台定期检查 Codex Token Bar 新版本") {
                settingsToggle("自动检查更新", systemImage: "arrow.triangle.2.circlepath", isOn: automaticUpdateBinding)
            }
        }
    }

    private var dataAndMaintenanceSettings: some View {
        Group {
            settingsSection(title: "数据来源", subtitle: "查看当前 Codex Home，或选择另一个本地目录") {
                settingsActionRow(
                    "Codex 数据目录",
                    systemImage: "externaldrive",
                    detail: "\(dataSourceOrigin) · \(dataSourceLabel)",
                    buttonTitle: "更改目录",
                    buttonSystemImage: "folder.badge.gearshape",
                    action: onChooseDirectory
                )
            }

            settingsSection(title: "Provider 维护", subtitle: "扫描并修复会话与本地状态中的 Provider 不一致") {
                settingsActionRow(
                    "Provider 修复",
                    systemImage: "cross.case",
                    detail: "打开专用检查页，先预览受影响项目，再选择是否修复。",
                    buttonTitle: "打开修复工具",
                    buttonSystemImage: "arrow.up.right.square",
                    action: onOpenProviderSync
                )
            }

        }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(get: { loginItemStore.isOn }, set: { loginItemStore.setEnabled($0) })
    }

    private var automaticUpdateBinding: Binding<Bool> {
        Binding(
            get: { updateSettingsStore.automaticChecksEnabled },
            set: { updateSettingsStore.setAutomaticChecksEnabled($0) }
        )
    }

    private var usageLightRefreshIntervalBinding: Binding<String> {
        Binding(
            get: {
                UsageRefreshCadenceSettings.normalizedLightRawValue(usageLightRefreshIntervalRaw)
            },
            set: {
                usageLightRefreshIntervalRaw = UsageRefreshCadenceSettings.normalizedLightRawValue($0)
            }
        )
    }

    private var usageVisibleAggregateIntervalBinding: Binding<String> {
        Binding(
            get: {
                UsageRefreshCadenceSettings.normalizedAggregateRawValue(usageVisibleAggregateIntervalRaw)
            },
            set: {
                usageVisibleAggregateIntervalRaw = UsageRefreshCadenceSettings.normalizedAggregateRawValue($0)
            }
        )
    }

    private var usageBackgroundAggregateIntervalBinding: Binding<String> {
        Binding(
            get: {
                UsageRefreshCadenceSettings.normalizedBackgroundAggregateRawValue(usageBackgroundAggregateIntervalRaw)
            },
            set: {
                usageBackgroundAggregateIntervalRaw = UsageRefreshCadenceSettings.normalizedBackgroundAggregateRawValue($0)
            }
        )
    }

    private var sharedAccountRadarTierBinding: Binding<String> {
        Binding(
            get: { SharedAccountRadarTier.storedValue(for: sharedAccountRadarTierRaw).rawValue },
            set: { sharedAccountRadarTierRaw = SharedAccountRadarTier.storedValue(for: $0).rawValue }
        )
    }

    private var sharedAccountPriceModelBinding: Binding<String> {
        Binding(
            get: { OfficialAPIPriceModel.storedValue(for: sharedAccountPriceModelRaw).rawValue },
            set: { sharedAccountPriceModelRaw = OfficialAPIPriceModel.storedValue(for: $0).rawValue }
        )
    }

    private var markdownExportBinding: Binding<Bool> {
        Binding(
            get: { threadDeleteBridge.enhancementSettings.markdownExport },
            set: { threadDeleteBridge.setMarkdownExportEnabled($0) }
        )
    }

    private var pasteFixBinding: Binding<Bool> {
        Binding(
            get: { threadDeleteBridge.enhancementSettings.pasteFix },
            set: { threadDeleteBridge.setPasteFixEnabled($0) }
        )
    }

    private var projectMoveBinding: Binding<Bool> {
        Binding(
            get: { threadDeleteBridge.enhancementSettings.projectMove },
            set: { threadDeleteBridge.setProjectMoveEnabled($0) }
        )
    }

    private var threadIDBadgeBinding: Binding<Bool> {
        Binding(
            get: { threadDeleteBridge.enhancementSettings.threadIDBadge },
            set: { threadDeleteBridge.setThreadIDBadgeEnabled($0) }
        )
    }

    private var conversationViewBinding: Binding<Bool> {
        Binding(
            get: { threadDeleteBridge.enhancementSettings.conversationView },
            set: { threadDeleteBridge.setConversationViewEnabled($0) }
        )
    }

    private var threadScrollRestoreBinding: Binding<Bool> {
        Binding(
            get: { threadDeleteBridge.enhancementSettings.threadScrollRestore },
            set: { threadDeleteBridge.setThreadScrollRestoreEnabled($0) }
        )
    }

    private var conversationWidthBinding: Binding<Double> {
        Binding(
            get: { Double(threadDeleteBridge.enhancementSettings.conversationViewMaxWidth) },
            set: { threadDeleteBridge.setConversationViewMaxWidth(Int($0.rounded())) }
        )
    }

    private func openCodexPlusPlusSource() {
        guard let url = URL(string: "https://github.com/BigPizzaV3/CodexPlusPlus") else { return }
        NSWorkspace.shared.open(url)
    }

    private var orderedGroups: [FloatingPanelContentGroup] {
        FloatingPanelContentVisibility.order(from: contentOrderRaw)
    }

    private var pageCapableGroups: [FloatingPanelContentGroup] {
        orderedGroups.filter(\.supportsPaging)
    }

    private var pagePairs: [FloatingPanelPagePair] {
        FloatingPanelContentVisibility.pagePairs(from: pagePairsRaw)
    }

    private var floatingContentVisibilityBinding: Binding<FloatingPanelContentVisibility> {
        Binding(
            get: {
                FloatingPanelContentVisibility(
                    showRateAndBar: showRateAndBar,
                    showUsageStatus: showUsageStatus,
                    showMetrics: showMetrics,
                    showRunningThreads: showRunningThreads,
                    showTodayModelShare: showTodayModelShare,
                    showTodayModelCost: showTodayModelCost,
                    showQuota: showQuota,
                    showRadar: showRadar,
                    showCrowdRadar: showCrowdRadar,
                    crowdRadarPageCount: crowdRadarPageCount,
                    showPageNavigationArrows: showPageNavigationArrows,
                    groupOrder: orderedGroups,
                    pagePairs: pagePairs
                )
            },
            set: { next in
                showRateAndBar = next.showRateAndBar
                showUsageStatus = next.showUsageStatus
                showMetrics = next.showMetrics
                showRunningThreads = next.showRunningThreads
                showTodayModelShare = next.showTodayModelShare
                showTodayModelCost = next.showTodayModelCost
                showQuota = next.showQuota
                showRadar = next.showRadar
                showCrowdRadar = next.showCrowdRadar
                crowdRadarPageCount = next.crowdRadarPageCount
                showPageNavigationArrows = next.showPageNavigationArrows
                contentOrderRaw = FloatingPanelContentVisibility.encodedOrder(next.groupOrder)
                pagePairsRaw = FloatingPanelContentVisibility.encodedPagePairs(next.pagePairs)
            }
        )
    }

    private var statusBarMetricConfiguration: StatusBarMetricConfiguration {
        StatusBarMetricConfiguration(
            orderRaw: statusBarMetricOrderRaw,
            selectionRaw: statusBarMetricSelectionRaw,
            showsIcon: statusBarMetricShowsIcon,
            labelStyle: StatusBarMetricLabelStyle(rawValue: statusBarMetricLabelStyleRaw)
                ?? StatusBarMetricConfiguration.defaultLabelStyle
        )
    }

    private var orderedStatusBarMetrics: [StatusBarMetricID] {
        statusBarMetricConfiguration.orderedMetricIDs
    }

    private var statusSummaryConfiguration: StatusSummaryConfiguration {
        StatusSummaryConfiguration(
            orderRaw: statusSummaryOrderRaw,
            selectionRaw: statusSummarySelectionRaw
        )
    }

    private var orderedStatusSummarySections: [StatusSummarySectionID] {
        statusSummaryConfiguration.orderedSectionIDs
    }

    private func moveSidebarSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down else { return }
        let categories = AppSettingsCategory.allCases
        guard let currentIndex = categories.firstIndex(of: focusedCategory ?? selectedCategory) else { return }
        let delta = direction == .up ? -1 : 1
        let nextIndex = min(max(currentIndex + delta, 0), categories.count - 1)
        let next = categories[nextIndex]
        selectedCategory = next
        focusedCategory = next
    }

    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) { content() }
                .background(AppTheme.solidControlBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 10)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .accessibilityLabel(title)
                .accessibilityValue(isOn.wrappedValue ? "已开启" : "已关闭")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .settingsRowDivider()
    }

    private func settingsSlider(
        _ title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String,
        step: Double = 0.01,
        disabled: Bool = false,
        compact: Bool = false
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: compact ? 62 : 88, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(display)
            Text(display)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 6 : 8)
        .disabled(disabled)
        .opacity(disabled ? 0.48 : 1)
        .settingsRowDivider()
    }

    private func settingsPicker(
        _ title: String,
        systemImage: String,
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 10)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { value, label in Text(label).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 170, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .settingsRowDivider()
    }

    private func settingsCompactPicker(
        _ title: String,
        detail: String,
        systemImage: String,
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(title)
            .accessibilityValue(selection.wrappedValue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 45)
        .settingsRowDivider()
    }

    private func settingsColor(_ title: String, systemImage: String, hex: Binding<String>, fallback: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 10)
            ColorPicker("", selection: colorBinding(hex: hex, fallback: fallback), supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .settingsRowDivider()
    }

    private func settingsInfoRow(_ title: String, systemImage: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsActionRow(
        _ title: String,
        systemImage: String,
        detail: String,
        buttonTitle: String,
        buttonSystemImage: String,
        statusColor: Color? = nil,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(statusColor ?? AppTheme.accentBlue)
                .frame(width: 18)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            settingsActionButton(buttonTitle, systemImage: buttonSystemImage, action: action)
                .disabled(!enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(AppTheme.selectedControlBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(AppTheme.accentBlue.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.accentBlue)
        .accessibilityLabel(title)
    }

    private func colorBinding(hex: Binding<String>, fallback: String) -> Binding<Color> {
        Binding(
            get: { Color(floatingPanelHex: hex.wrappedValue) ?? Color(floatingPanelHex: fallback) ?? AppTheme.accentBlue },
            set: { if let next = $0.floatingPanelHexString() { hex.wrappedValue = next } }
        )
    }

    private func contentRow(_ group: FloatingPanelContentGroup) -> some View {
        let order = orderedGroups
        let index = order.firstIndex(of: group) ?? 0
        return HStack(spacing: 9) {
            Image(systemName: group.systemImage).foregroundStyle(AppTheme.accentBlue).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).font(.system(size: 11.5, weight: .semibold))
                if let subtitle = group.settingsSubtitle {
                    Text(subtitle)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            Button { move(group, by: -1) } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0)
                .accessibilityLabel("向上移动\(group.title)")
            Button { move(group, by: 1) } label: { Image(systemName: "arrow.down") }
                .disabled(index == order.count - 1)
                .accessibilityLabel("向下移动\(group.title)")
            Toggle("", isOn: visibilityBinding(for: group)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .accessibilityLabel("显示\(group.title)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .settingsRowDivider()
    }

    private func pagePairRow(_ group: FloatingPanelContentGroup) -> some View {
        let pair = pagePairs.first { $0.contains(group) }
        let isDefault = pair?.first == group
        return HStack(spacing: 9) {
            Image(systemName: group.systemImage)
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(group.title)
                        .font(.system(size: 11.5, weight: .semibold))
                    if pair != nil {
                        Text(isDefault ? "默认页" : "第二页")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(isDefault ? AppTheme.accentBlue : Color.secondary)
                    }
                }
                Text(pair == nil ? "单独占一行" : "与 \(pair?.partner(of: group)?.title ?? "--") 共用一行")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Picker("翻页搭档", selection: pagePartnerBinding(for: group)) {
                Text("单独显示").tag("")
                ForEach(pageCapableGroups.filter { $0 != group }) { candidate in
                    Text(candidate.title).tag(candidate.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            if pair?.second == group {
                Button("设为默认") {
                    pagePairsRaw = FloatingPanelContentVisibility.encodedPagePairs(
                        FloatingPanelContentVisibility.swappingDefaultPage(
                            in: pagePairs,
                            for: group
                        )
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .settingsRowDivider()
    }

    private func statusBarMetricRow(_ metric: StatusBarMetricID) -> some View {
        let order = orderedStatusBarMetrics
        let index = order.firstIndex(of: metric) ?? 0
        return HStack(spacing: 9) {
            Image(systemName: metric.systemImage)
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(metric.settingsSubtitle)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Button { moveStatusBarMetric(metric, by: -1) } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(index == 0)
            .accessibilityLabel("向左移动\(metric.title)")
            Button { moveStatusBarMetric(metric, by: 1) } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(index == order.count - 1)
            .accessibilityLabel("向右移动\(metric.title)")
            Toggle("", isOn: statusBarMetricSelectionBinding(for: metric))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("显示\(metric.title)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .settingsRowDivider()
    }

    private var statusBarRestoreDefaultsRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.counterclockwise")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("默认组合")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("实时速率、5 小时额度、7 天额度、今日模型榜")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Button("恢复默认") {
                statusBarMetricOrderRaw = StatusBarMetricConfiguration.defaultOrderRaw
                statusBarMetricSelectionRaw = StatusBarMetricConfiguration.defaultSelectionRaw
                statusBarMetricShowsIcon = StatusBarMetricConfiguration.defaultShowsIcon
                statusBarMetricLabelStyleRaw = StatusBarMetricConfiguration.defaultLabelStyle.rawValue
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityHint("恢复默认指标、顺序和图标设置")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
    }

    private func statusSummarySectionRow(_ section: StatusSummarySectionID) -> some View {
        let order = orderedStatusSummarySections
        let index = order.firstIndex(of: section) ?? 0
        return HStack(spacing: 9) {
            Image(systemName: section.systemImage)
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 16)
            Text(section.title)
                .font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 10)
            Button { moveStatusSummarySection(section, by: -1) } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(index == 0)
            .accessibilityLabel("向上移动\(section.title)")
            Button { moveStatusSummarySection(section, by: 1) } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(index == order.count - 1)
            .accessibilityLabel("向下移动\(section.title)")
            Toggle("", isOn: statusSummarySelectionBinding(for: section))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("显示\(section.title)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .settingsRowDivider()
    }

    private var statusSummaryRestoreDefaultsRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.counterclockwise")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text("恢复全部摘要卡片")
                .font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 10)
            Button("恢复默认") {
                statusSummaryOrderRaw = StatusSummaryConfiguration.defaultOrderRaw
                statusSummarySelectionRaw = StatusSummaryConfiguration.defaultSelectionRaw
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    private func visibilityBinding(for group: FloatingPanelContentGroup) -> Binding<Bool> {
        switch group {
        case .rateAndBar: return $showRateAndBar
        case .usageStatus: return $showUsageStatus
        case .metrics: return $showMetrics
        case .runningThreads: return $showRunningThreads
        case .todayModelShare: return $showTodayModelShare
        case .todayModelCost: return $showTodayModelCost
        case .quota: return $showQuota
        case .radar: return $showRadar
        case .crowdRadar: return $showCrowdRadar
        }
    }

    private func pagePartnerBinding(for group: FloatingPanelContentGroup) -> Binding<String> {
        Binding(
            get: { pagePairs.first(where: { $0.contains(group) })?.partner(of: group)?.rawValue ?? "" },
            set: { rawValue in
                let partner = FloatingPanelContentGroup(rawValue: rawValue)
                let next = FloatingPanelContentVisibility.replacingPagePartner(
                    in: pagePairs,
                    for: group,
                    with: partner
                )
                pagePairsRaw = FloatingPanelContentVisibility.encodedPagePairs(next)
                if partner != nil {
                    visibilityBinding(for: group).wrappedValue = true
                    visibilityBinding(for: partner!).wrappedValue = true
                }
            }
        )
    }

    private func move(_ group: FloatingPanelContentGroup, by delta: Int) {
        var order = orderedGroups
        guard let index = order.firstIndex(of: group) else { return }
        let destination = min(max(index + delta, 0), order.count - 1)
        guard destination != index else { return }
        order.remove(at: index)
        order.insert(group, at: destination)
        contentOrderRaw = FloatingPanelContentVisibility.encodedOrder(order)
    }

    private func statusBarMetricSelectionBinding(for metric: StatusBarMetricID) -> Binding<Bool> {
        Binding(
            get: {
                StatusBarMetricConfiguration.selection(from: statusBarMetricSelectionRaw).contains(metric)
            },
            set: { isSelected in
                var selection = StatusBarMetricConfiguration.selection(from: statusBarMetricSelectionRaw)
                if isSelected {
                    selection.insert(metric)
                } else {
                    selection.remove(metric)
                }
                statusBarMetricSelectionRaw = StatusBarMetricConfiguration.encodedSelection(
                    selection,
                    orderedBy: orderedStatusBarMetrics
                )
            }
        )
    }

    private func moveStatusBarMetric(_ metric: StatusBarMetricID, by delta: Int) {
        var order = orderedStatusBarMetrics
        guard let index = order.firstIndex(of: metric) else { return }
        let destination = min(max(index + delta, 0), order.count - 1)
        guard destination != index else { return }
        order.remove(at: index)
        order.insert(metric, at: destination)
        statusBarMetricOrderRaw = StatusBarMetricConfiguration.encodedOrder(order)
    }

    private func statusSummarySelectionBinding(
        for section: StatusSummarySectionID
    ) -> Binding<Bool> {
        Binding(
            get: {
                StatusSummaryConfiguration.selection(from: statusSummarySelectionRaw).contains(section)
            },
            set: { isSelected in
                var selection = StatusSummaryConfiguration.selection(from: statusSummarySelectionRaw)
                if isSelected {
                    selection.insert(section)
                } else {
                    selection.remove(section)
                }
                statusSummarySelectionRaw = StatusSummaryConfiguration.encodedSelection(
                    selection,
                    orderedBy: orderedStatusSummarySections
                )
            }
        )
    }

    private func moveStatusSummarySection(_ section: StatusSummarySectionID, by delta: Int) {
        var order = orderedStatusSummarySections
        guard let index = order.firstIndex(of: section) else { return }
        let destination = min(max(index + delta, 0), order.count - 1)
        guard destination != index else { return }
        order.remove(at: index)
        order.insert(section, at: destination)
        statusSummaryOrderRaw = StatusSummaryConfiguration.encodedOrder(order)
    }
}

private extension View {
    func settingsRowDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border.opacity(0.55))
                .frame(height: 1)
                .padding(.leading, 38)
        }
    }
}

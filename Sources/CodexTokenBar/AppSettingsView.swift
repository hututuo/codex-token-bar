import AppKit
import SwiftUI

enum AppSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case sessionEnhancements
    case codexInstances
    case autoResume
    case surfaces
    case monitoring
    case floatingPanel
    case content
    case alertsAndUpdates
    case dataAndMaintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .sessionEnhancements: return "会话增强"
        case .codexInstances: return "Codex 实例"
        case .autoResume: return "自动续跑"
        case .surfaces: return "显示面"
        case .monitoring: return "监控与额度"
        case .floatingPanel: return "悬浮窗"
        case .content: return "内容与排序"
        case .alertsAndUpdates: return "提醒与更新"
        case .dataAndMaintenance: return "数据与维护"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "启动与基础行为"
        case .sessionEnhancements: return "删除、导出、移动、输入与阅读体验"
        case .codexInstances: return "多开、隔离、同步与回滚"
        case .autoResume: return "容量中断、定时或额度恢复后继续任务"
        case .surfaces: return "主界面与辅助显示面"
        case .monitoring: return "实时速率、统计与刷新"
        case .floatingPanel: return "位置、尺寸与视觉样式"
        case .content: return "悬浮窗信息和排列顺序"
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
        case .monitoring: return "speedometer"
        case .floatingPanel: return "rectangle.on.rectangle"
        case .content: return "list.bullet.rectangle"
        case .alertsAndUpdates: return "bell.badge"
        case .dataAndMaintenance: return "wrench.and.screwdriver"
        }
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
    @Binding var showQuota: Bool
    @Binding var showRadar: Bool
    @Binding var showCrowdRadar: Bool
    @Binding var contentOrderRaw: String
    let defaultCodexHome: URL?
    let dataSourceLabel: String
    let dataSourceOrigin: String
    let onChooseDirectory: () -> Void
    let onOpenProviderSync: () -> Void
    let onThreadDeleteConnectionAction: () -> Void
    let onClose: () -> Void

    @AppStorage(AccountQuotaRefreshCadence.storageKey) private var quotaRefreshCadenceRaw = AccountQuotaRefreshCadence.defaultRawValue
    @FocusState private var focusedCategory: AppSettingsCategory?

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Rectangle()
                .fill(AppTheme.border)
                .frame(width: 1)

            settingsContent
        }
        .frame(width: 920, height: 650)
        .background(AppTheme.panelBackground)
        .onExitCommand(perform: onClose)
        .onAppear {
            if selectedCategory == .autoResume {
                autoResumeController.refreshThreads()
            }
        }
        .onChange(of: selectedCategory) {
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

            ScrollView {
                selectedCategoryContent
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .id(selectedCategory)
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
            case .monitoring:
                monitoringSettings
            case .floatingPanel:
                floatingPanelSettings
            case .content:
                contentSettings
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
                title: "会话管理",
                subtitle: "在 Codex 侧栏为每个任务增加可靠的管理操作"
            ) {
                settingsToggle(
                    "会话删除",
                    systemImage: "trash",
                    isOn: sessionDeleteBinding
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
            settingsSection(title: "辅助显示面", subtitle: "常用开关仍保留在主界面的实时速率卡") {
                settingsToggle("悬浮窗", systemImage: "rectangle.on.rectangle", isOn: $floatingPanelEnabled)
                settingsToggle("状态栏", systemImage: "menubar.rectangle", isOn: $statusBarPanelEnabled)
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

            settingsSection(title: "额度", subtitle: "设置官方额度数据的自动刷新频率") {
                settingsPicker(
                    "额度刷新",
                    systemImage: "clock.arrow.circlepath",
                    selection: $quotaRefreshCadenceRaw,
                    options: AccountQuotaRefreshCadence.allCases.map { ($0.rawValue, $0.label) }
                )
            }
        }
    }

    private var floatingPanelSettings: some View {
        Group {
            settingsSection(title: "实时预览", subtitle: "颜色、透明度和尺寸会直接反映在这里") {
                floatingPanelPreview
            }

            settingsSection(title: "窗口行为", subtitle: "调整悬浮窗的位置与占用空间") {
                settingsToggle("锁定悬浮窗位置", systemImage: "lock", isOn: $floatingPanelLocked)
                settingsSlider(
                    "透明度",
                    systemImage: "circle.lefthalf.filled",
                    value: $floatingPanelOpacity,
                    range: 0.45...0.98,
                    display: "\(Int((floatingPanelOpacity * 100).rounded()))%"
                )
                settingsSlider(
                    "大小",
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    value: $floatingPanelScale,
                    range: FloatingTokenPanelMetrics.scaleRange,
                    display: "\(Int((floatingPanelScale * 100).rounded()))%"
                )
            }

            settingsSection(title: "外观", subtitle: "统一设置文字、背景渐变和额度条配色") {
                settingsSlider(
                    "字体颜色",
                    systemImage: "textformat",
                    value: $floatingPanelTextTone,
                    range: -1...1,
                    display: FloatingPanelTextTonePreference.displayText(for: floatingPanelTextTone)
                )
                settingsColor("起始色", systemImage: "circle.fill", hex: $gradientStartHex, fallback: FloatingPanelAppearance.defaultStartHex)
                settingsColor("结束色", systemImage: "circle.lefthalf.filled", hex: $gradientEndHex, fallback: FloatingPanelAppearance.defaultEndHex)
                settingsPicker("渐变方向", systemImage: "arrow.up.right", selection: $gradientDirection, options: FloatingPanelGradientDirection.allCases.map { ($0.rawValue, $0.label) })
                settingsPicker("渐变类型", systemImage: "swirl.circle.righthalf.filled", selection: $gradientStyle, options: FloatingPanelGradientStyle.allCases.map { ($0.rawValue, $0.label) })
                settingsPicker("额度条配色", systemImage: "chart.bar.fill", selection: $quotaColorMode, options: FloatingQuotaColorMode.allCases.map { ($0.rawValue, $0.label) })
                if quotaColorMode == FloatingQuotaColorMode.fixed.rawValue {
                    settingsColor("额度固定色", systemImage: "circle.fill", hex: $quotaFixedHex, fallback: FloatingQuotaColorStyle.defaultFixedHex)
                }
            }
        }
    }

    private var contentSettings: some View {
        settingsSection(title: "显示内容", subtitle: "选择悬浮窗信息，并用箭头调整从上到下的顺序") {
            ForEach(orderedGroups) { group in
                contentRow(group)
            }
        }
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

    private var floatingPanelPreview: some View {
        let appearance = FloatingPanelAppearance(
            startHex: gradientStartHex,
            endHex: gradientEndHex,
            directionRaw: gradientDirection,
            styleRaw: gradientStyle
        )
        let tone = FloatingPanelTextTonePreference.mode(for: floatingPanelTextTone)
        let palette = tone.manualWhite.map(FloatingPanelReadableTextPalette.init(fixedWhite:))
            ?? FloatingPanelReadableTextPalette(
                backgroundLuminance: appearance.readableTextPalette.backgroundLuminance,
                automaticStrength: tone.automaticStrength
            )
        let quotaStyle = FloatingQuotaColorStyle(
            modeRaw: quotaColorMode,
            fixedHex: quotaFixedHex,
            gradientAppearance: appearance
        )
        let scaleProgress = (FloatingTokenPanelMetrics.clampedScale(floatingPanelScale) - 0.75) / 1.25
        let previewWidth = 350 + 150 * scaleProgress

        return VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(appearance.gradientShapeStyle)
                    .opacity(floatingPanelOpacity)

                VStack(spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("实时速率")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(palette.secondaryColor)
                            Text("128 token/s")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(palette.primaryColor)
                        }
                        Spacer(minLength: 12)
                        Text("额度 72%")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(palette.primaryColor)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.primaryColor.opacity(0.16))
                            Capsule()
                                .fill(quotaStyle.fillStyle(remainingPercent: 72, expectedRemainingPercent: 68))
                                .frame(width: proxy.size.width * 0.72)
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        Text("本次 1,248 token")
                        Spacer(minLength: 8)
                        Text("今日 42.6K")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(palette.secondaryColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .frame(width: previewWidth, height: 116 + 12 * scaleProgress)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.borderStrong.opacity(0.45), lineWidth: 1)
            )

            Text("示例数据 · 实际悬浮窗内容由“内容与排序”控制")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
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

    private var sessionDeleteBinding: Binding<Bool> {
        Binding(
            get: { threadDeleteBridge.enhancementSettings.sessionDelete },
            set: { threadDeleteBridge.setSessionDeleteEnabled($0) }
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
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 88, alignment: .leading)
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
        .padding(.vertical, 8)
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

    private func visibilityBinding(for group: FloatingPanelContentGroup) -> Binding<Bool> {
        switch group {
        case .rateAndBar: return $showRateAndBar
        case .usageStatus: return $showUsageStatus
        case .metrics: return $showMetrics
        case .runningThreads: return $showRunningThreads
        case .quota: return $showQuota
        case .radar: return $showRadar
        case .crowdRadar: return $showCrowdRadar
        }
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

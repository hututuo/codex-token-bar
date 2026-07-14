import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var loginItemStore: LoginItemStore
    @ObservedObject var updateSettingsStore: AppUpdateSettingsStore
    @Binding var floatingPanelEnabled: Bool
    @Binding var statusBarPanelEnabled: Bool
    @Binding var liveRateMonitoringEnabled: Bool
    @Binding var preciseTokenCountingEnabled: Bool
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
    @Binding var showQuota: Bool
    @Binding var showRadar: Bool
    @Binding var contentOrderRaw: String
    let onClose: () -> Void
    @AppStorage(AccountQuotaRefreshCadence.storageKey) private var quotaRefreshCadenceRaw = AccountQuotaRefreshCadence.defaultRawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("总体设置")
                        .font(.system(size: 17, weight: .semibold))
                    Text("启动、显示面和悬浮窗选项集中管理")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭总体设置")
                .accessibilityLabel("关闭总体设置")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle().fill(AppTheme.border).frame(height: 1)

            ScrollView {
                VStack(spacing: 16) {
                    settingsSection(title: "常规", subtitle: "启动、更新与统计") {
                        settingsToggle("开机自启", systemImage: "power", isOn: loginItemBinding)
                        settingsToggle("自动检查更新", systemImage: "arrow.triangle.2.circlepath", isOn: automaticUpdateBinding)
                        settingsToggle("实时速率监控", systemImage: "speedometer", isOn: $liveRateMonitoringEnabled)
                        settingsToggle("精确 token 统计", systemImage: "number", isOn: $preciseTokenCountingEnabled)
                        settingsPicker(
                            "额度刷新",
                            systemImage: "clock.arrow.circlepath",
                            selection: $quotaRefreshCadenceRaw,
                            options: AccountQuotaRefreshCadence.allCases.map { ($0.rawValue, $0.label) }
                        )
                    }

                    settingsSection(title: "显示面", subtitle: "常用开关仍保留在实时速率卡") {
                        settingsToggle("悬浮窗", systemImage: "rectangle.on.rectangle", isOn: $floatingPanelEnabled)
                        settingsToggle("状态栏", systemImage: "menubar.rectangle", isOn: $statusBarPanelEnabled)
                        settingsToggle("锁定悬浮窗位置", systemImage: "lock", isOn: $floatingPanelLocked)
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

                    settingsSection(title: "悬浮窗外观", subtitle: "颜色、尺寸与提醒效果") {
                        settingsSlider("透明度", systemImage: "circle.lefthalf.filled", value: $floatingPanelOpacity, range: 0.45...0.98, display: "\(Int((floatingPanelOpacity * 100).rounded()))%")
                        settingsSlider("大小", systemImage: "arrow.up.left.and.arrow.down.right", value: $floatingPanelScale, range: FloatingTokenPanelMetrics.scaleRange, display: "\(Int((floatingPanelScale * 100).rounded()))%")
                        settingsSlider("字体颜色", systemImage: "textformat", value: $floatingPanelTextTone, range: -1...1, display: FloatingPanelTextTonePreference.displayText(for: floatingPanelTextTone))
                        settingsColor("起始色", systemImage: "circle.fill", hex: $gradientStartHex, fallback: FloatingPanelAppearance.defaultStartHex)
                        settingsColor("结束色", systemImage: "circle.lefthalf.filled", hex: $gradientEndHex, fallback: FloatingPanelAppearance.defaultEndHex)
                        settingsPicker("渐变方向", systemImage: "arrow.up.right", selection: $gradientDirection, options: FloatingPanelGradientDirection.allCases.map { ($0.rawValue, $0.label) })
                        settingsPicker("渐变类型", systemImage: "swirl.circle.righthalf.filled", selection: $gradientStyle, options: FloatingPanelGradientStyle.allCases.map { ($0.rawValue, $0.label) })
                        settingsPicker("额度条配色", systemImage: "chart.bar.fill", selection: $quotaColorMode, options: FloatingQuotaColorMode.allCases.map { ($0.rawValue, $0.label) })
                        if quotaColorMode == FloatingQuotaColorMode.fixed.rawValue {
                            settingsColor("额度固定色", systemImage: "circle.fill", hex: $quotaFixedHex, fallback: FloatingQuotaColorStyle.defaultFixedHex)
                        }
                        settingsPicker("未读提醒", systemImage: "bell.badge", selection: $unreadEffect, options: FloatingPanelUnreadEffect.allCases.map { ($0.rawValue, $0.label) })
                    }

                    settingsSection(title: "显示内容", subtitle: "选择悬浮窗信息并调整顺序") {
                        ForEach(orderedGroups) { group in
                            contentRow(group)
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 660, height: 650)
        .background(AppTheme.panelBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("总体设置")
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

    private var orderedGroups: [FloatingPanelContentGroup] {
        FloatingPanelContentVisibility.order(from: contentOrderRaw)
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
                .background(AppTheme.solidControlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
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
        .padding(.horizontal, 11)
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.border.opacity(0.55)).frame(height: 1).padding(.leading, 36) }
    }

    private func settingsSlider(
        _ title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String,
        disabled: Bool = false
    ) -> some View {
        AlignedSettingSliderRow(title: title, systemImage: systemImage, value: value, range: range, displayValue: display)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .disabled(disabled)
            .opacity(disabled ? 0.48 : 1)
            .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.border.opacity(0.55)).frame(height: 1).padding(.leading, 36) }
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
            .frame(width: 170, alignment: .trailing)
            .accessibilityLabel(title)
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.border.opacity(0.55)).frame(height: 1).padding(.leading, 36) }
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
        .padding(.horizontal, 11)
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.border.opacity(0.55)).frame(height: 1).padding(.leading, 36) }
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
                    Text(subtitle).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
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
        .padding(.horizontal, 11)
        .frame(minHeight: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.border.opacity(0.55)).frame(height: 1).padding(.leading, 36) }
    }

    private func visibilityBinding(for group: FloatingPanelContentGroup) -> Binding<Bool> {
        switch group {
        case .rateAndBar: return $showRateAndBar
        case .usageStatus: return $showUsageStatus
        case .metrics: return $showMetrics
        case .quota: return $showQuota
        case .radar: return $showRadar
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

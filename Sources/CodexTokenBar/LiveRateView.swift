import AppKit
import SwiftUI

struct FloatingUnreadEffectButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct FloatingPanelPaletteButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private enum LiveRatePanelLayout {
    static let contentHeight: CGFloat = 106
    static let contentSpacing: CGFloat = 12
}

struct LiveRateView: View {
    let monitor: LiveRateMonitor
    @Binding var floatingPanelEnabled: Bool
    @Binding var statusBarPanelEnabled: Bool
    @Binding var preciseTokenCountingEnabled: Bool
    @Binding var floatingPanelOpacity: Double
    @Binding var floatingPanelScale: Double
    @Binding var tokenRateFullScale: Double
    @Binding var floatingPanelGradientStartHex: String
    @Binding var floatingPanelGradientEndHex: String
    @Binding var floatingPanelGradientDirection: String
    @Binding var floatingPanelGradientStyle: String
    @Binding var floatingPanelUnreadEffect: String
    @Binding var showingPaletteMenu: Bool
    @Binding var showingUnreadEffectMenu: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LiveRateHeader(monitor: monitor, onReset: monitor.reset)

            GeometryReader { proxy in
                let columnWidth = max(0, (proxy.size.width - LiveRatePanelLayout.contentSpacing) / 2)

                HStack(alignment: .top, spacing: LiveRatePanelLayout.contentSpacing) {
                    LiveRateInstrumentReader(monitor: monitor, fullScale: $tokenRateFullScale)
                        .frame(width: columnWidth, height: LiveRatePanelLayout.contentHeight)

                    LiveRateControls(
                        floatingPanelEnabled: $floatingPanelEnabled,
                        statusBarPanelEnabled: $statusBarPanelEnabled,
                        preciseTokenCountingEnabled: $preciseTokenCountingEnabled,
                        floatingPanelOpacity: $floatingPanelOpacity,
                        floatingPanelScale: $floatingPanelScale,
                        floatingPanelGradientStartHex: $floatingPanelGradientStartHex,
                        floatingPanelGradientEndHex: $floatingPanelGradientEndHex,
                        floatingPanelGradientDirection: $floatingPanelGradientDirection,
                        floatingPanelGradientStyle: $floatingPanelGradientStyle,
                        floatingPanelUnreadEffect: $floatingPanelUnreadEffect,
                        showingPaletteMenu: $showingPaletteMenu,
                        showingUnreadEffectMenu: $showingUnreadEffectMenu
                    )
                    .frame(width: columnWidth, height: LiveRatePanelLayout.contentHeight)
                }
            }
            .frame(height: LiveRatePanelLayout.contentHeight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 980)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

private struct LiveRateHeader: View {
    @ObservedObject var monitor: LiveRateMonitor
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("全会话实时速度")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            Text(monitor.totalSnapshot.status)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            LiveRateResetButton(action: onReset)
        }
    }
}

private struct LiveRateInstrumentReader: View {
    @ObservedObject var monitor: LiveRateMonitor
    @Binding var fullScale: Double

    var body: some View {
        LiveRateInstrument(snapshot: monitor.totalSnapshot, fullScale: $fullScale)
    }
}

struct LiveRateInstrument: View {
    let snapshot: LiveRateSnapshot
    @Binding var fullScale: Double

    private var fillFraction: CGFloat {
        let scale = TokenRateScaleSettings.clamped(fullScale)
        return CGFloat(min(max(snapshot.rollingTokensPerSecond, 0), scale) / scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .lastTextBaseline, spacing: 7) {
                        Text(String(format: "%.1f", snapshot.rollingTokensPerSecond))
                            .font(.system(size: 23, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text("tok/s")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text("全会话输出")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 116, alignment: .leading)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("实时速率")
                        Spacer(minLength: 0)
                        Text("量程 \(Int(TokenRateScaleSettings.clamped(fullScale).rounded())) tok/s")
                            .monospacedDigit()
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.82))

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(AppTheme.insetBackground.opacity(0.82))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [AppTheme.accentCyan, AppTheme.accentBlue],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(8, proxy.size.width * fillFraction))
                        }
                    }
                    .frame(height: 9)
                }
            }

            RateFullScaleSlider(value: $fullScale)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: LiveRatePanelLayout.contentHeight, maxHeight: LiveRatePanelLayout.contentHeight, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(AppTheme.solidControlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(AppTheme.border.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct RateFullScaleSlider: View {
    @Binding var value: Double

    var body: some View {
        AlignedSettingSliderRow(
            title: "满格",
            systemImage: "speedometer",
            value: $value,
            range: TokenRateScaleSettings.range,
            step: 10,
            displayValue: TokenRateScaleSettings.displayValue(value)
        )
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.calloutOptionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border.opacity(0.48), lineWidth: 1)
        )
    }
}

private struct AlignedSettingSliderRow: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    let displayValue: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 42, alignment: .leading)

            Slider(value: $value, in: range, step: step)
                .frame(maxWidth: .infinity)

            Text(displayValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 44, alignment: .trailing)
        }
        .frame(height: 22)
    }
}

struct LiveRateControls: View {
    @Binding var floatingPanelEnabled: Bool
    @Binding var statusBarPanelEnabled: Bool
    @Binding var preciseTokenCountingEnabled: Bool
    @Binding var floatingPanelOpacity: Double
    @Binding var floatingPanelScale: Double
    @Binding var floatingPanelGradientStartHex: String
    @Binding var floatingPanelGradientEndHex: String
    @Binding var floatingPanelGradientDirection: String
    @Binding var floatingPanelGradientStyle: String
    @Binding var floatingPanelUnreadEffect: String
    @Binding var showingPaletteMenu: Bool
    @Binding var showingUnreadEffectMenu: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                DisplaySurfaceToggleButton(
                    title: "悬浮窗",
                    systemImage: "rectangle.on.rectangle",
                    isOn: $floatingPanelEnabled
                )
                .frame(maxWidth: .infinity, minHeight: 24)

                DisplaySurfaceToggleButton(
                    title: "状态栏",
                    systemImage: "menubar.rectangle",
                    isOn: $statusBarPanelEnabled
                )
                .frame(maxWidth: .infinity, minHeight: 24)

                DisplaySurfaceToggleButton(
                    title: "精确 token 统计",
                    systemImage: "number",
                    isOn: $preciseTokenCountingEnabled
                )
                .frame(maxWidth: .infinity, minHeight: 24)
            }

            FloatingPanelAppearanceSettings(
                floatingPanelOpacity: $floatingPanelOpacity,
                floatingPanelScale: $floatingPanelScale,
                startHex: $floatingPanelGradientStartHex,
                endHex: $floatingPanelGradientEndHex,
                directionRaw: $floatingPanelGradientDirection,
                styleRaw: $floatingPanelGradientStyle,
                unreadEffectRaw: $floatingPanelUnreadEffect,
                isPaletteMenuPresented: $showingPaletteMenu,
                isUnreadEffectMenuPresented: $showingUnreadEffectMenu
            )
        }
        .controlSize(.small)
        .font(.system(size: 11, weight: .medium))
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: LiveRatePanelLayout.contentHeight, maxHeight: LiveRatePanelLayout.contentHeight, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.solidControlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.border.opacity(0.48), lineWidth: 1)
        )
    }
}

struct FloatingPanelAppearanceSettings: View {
    @Binding var floatingPanelOpacity: Double
    @Binding var floatingPanelScale: Double
    @Binding var startHex: String
    @Binding var endHex: String
    @Binding var directionRaw: String
    @Binding var styleRaw: String
    @Binding var unreadEffectRaw: String
    @Binding var isPaletteMenuPresented: Bool
    @Binding var isUnreadEffectMenuPresented: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            VStack(spacing: 4) {
                FloatingPanelPaletteControl(
                    startHex: $startHex,
                    endHex: $endHex,
                    directionRaw: $directionRaw,
                    styleRaw: $styleRaw,
                    isPresented: $isPaletteMenuPresented,
                    willOpen: {
                        isUnreadEffectMenuPresented = false
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)

                FloatingUnreadEffectPicker(
                    selection: normalizedUnreadEffectBinding,
                    isPresented: $isUnreadEffectMenuPresented,
                    willOpen: {
                        isPaletteMenuPresented = false
                    }
                )
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
            }
            .frame(width: 76, alignment: .leading)
            .zIndex(2)

            VStack(spacing: 0) {
                CompactFloatingSlider(
                    title: "透明度",
                    systemImage: "circle.lefthalf.filled",
                    value: $floatingPanelOpacity,
                    range: 0.45...0.98,
                    displayValue: "\(Int((floatingPanelOpacity * 100).rounded()))%",
                    showsBackground: false
                )

                AppearanceSliderDivider()

                CompactFloatingSlider(
                    title: "大小",
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    value: $floatingPanelScale,
                    range: FloatingTokenPanelMetrics.scaleRange,
                    displayValue: "\(Int((floatingPanelScale * 100).rounded()))%",
                    showsBackground: false
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .zIndex(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 56)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.solidControlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.border.opacity(0.56), lineWidth: 1)
        )
        .zIndex(isUnreadEffectMenuPresented ? 50 : 0)
    }

    private var normalizedUnreadEffectBinding: Binding<String> {
        Binding(
            get: {
                FloatingPanelUnreadEffect(rawValue: unreadEffectRaw)?.rawValue
                    ?? FloatingPanelAppearance.defaultUnreadEffect
            },
            set: { unreadEffectRaw = $0 }
        )
    }

}

private struct FloatingAppearanceMiniButtonLabel: View {
    let title: String
    let systemImage: String
    var showsChevron = false
    var isAccent = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))

            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.72))
                } else {
                    Color.clear
                }
            }
            .frame(width: 8, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(isAccent ? AppTheme.accentBlue : .primary)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.calloutOptionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isAccent ? AppTheme.accentBlue.opacity(0.18) : AppTheme.border.opacity(0.74), lineWidth: 1)
        )
    }
}

private struct FloatingUnreadEffectPicker: View {
    @Binding var selection: String
    @Binding var isPresented: Bool
    let willOpen: () -> Void

    var body: some View {
        Button {
            if !isPresented {
                willOpen()
            }
            isPresented.toggle()
        } label: {
            FloatingAppearanceMiniButtonLabel(
                title: "提醒",
                systemImage: "bell.badge",
                showsChevron: true,
                isAccent: false
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .anchorPreference(key: FloatingUnreadEffectButtonBoundsKey.self, value: .bounds) { anchor in
            anchor
        }
        .zIndex(isPresented ? 20 : 0)
        .help("选择未读时悬浮窗背景动效")
    }
}

struct FloatingUnreadEffectMenu: View {
    @Binding var selection: String
    let closeAction: () -> Void

    var body: some View {
        SettingsCalloutContainer(
            title: "提醒样式",
            subtitle: nil,
            systemImage: "bell.badge",
            closeAction: closeAction
        ) {
            Text("有完成的会话还没点开时，悬浮窗用选中的样式提醒。")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            SettingsCalloutSection("样式") {
                VStack(spacing: 5) {
                    unreadEffectOption(.off)
                    unreadEffectOption(.ripple)
                    unreadEffectOption(.shimmer)
                }
                .padding(6)
            }
        }
    }

    private func unreadEffectOption(_ effect: FloatingPanelUnreadEffect) -> some View {
        let isSelected = selection == effect.rawValue
        return Button {
            selection = effect.rawValue
            triggerUnreadEffectPreview(effect)
            closeAction()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: unreadEffectIcon(effect))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(isSelected ? AppTheme.accentBlue : .secondary)
                    .frame(width: 15)

                VStack(alignment: .leading, spacing: 0) {
                    Text(unreadEffectTitle(effect))
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(unreadEffectSubtitle(effect))
                        .font(.system(size: 8.8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.accentBlue : .secondary.opacity(0.45))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AppTheme.selectedControlBackground : AppTheme.calloutOptionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? AppTheme.accentBlue.opacity(0.55) : AppTheme.border.opacity(0.50), lineWidth: 1)
        )
    }

    private func unreadEffectTitle(_ effect: FloatingPanelUnreadEffect) -> String {
        switch effect {
        case .off:
            return "关"
        case .ripple:
            return "涟漪"
        case .shimmer:
            return "扫光"
        }
    }

    private func unreadEffectSubtitle(_ effect: FloatingPanelUnreadEffect) -> String {
        switch effect {
        case .off:
            return "不显示动效"
        case .ripple:
            return "圆形水波"
        case .shimmer:
            return "柔和光带"
        }
    }

    private func unreadEffectIcon(_ effect: FloatingPanelUnreadEffect) -> String {
        switch effect {
        case .off:
            return "bell.slash"
        case .ripple:
            return "dot.radiowaves.left.and.right"
        case .shimmer:
            return "sparkles"
        }
    }

    private func triggerUnreadEffectPreview(_ effect: FloatingPanelUnreadEffect) {
        guard effect != .off else {
            UserDefaults.standard.set(0.0, forKey: FloatingPanelAppearance.unreadPreviewUntilKey)
            return
        }
        let duration: TimeInterval = 3.2
        let previewUntil = Date.timeIntervalSinceReferenceDate + duration
        UserDefaults.standard.set(previewUntil, forKey: FloatingPanelAppearance.unreadPreviewUntilKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) {
            let currentPreviewUntil = UserDefaults.standard.double(forKey: FloatingPanelAppearance.unreadPreviewUntilKey)
            if currentPreviewUntil <= previewUntil {
                UserDefaults.standard.set(0.0, forKey: FloatingPanelAppearance.unreadPreviewUntilKey)
            }
        }
    }
}

private struct LiveRateResetButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("重置整体速率", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.raisedBackground.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border.opacity(0.72), lineWidth: 1)
        )
        .help("重置全会话实时速率窗口")
    }
}

private struct AppearanceSliderDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.border.opacity(0.45))
            .frame(height: 1)
            .padding(.leading, 52)
            .padding(.trailing, 40)
    }
}

struct FloatingPanelPaletteControl: View {
    @Binding var startHex: String
    @Binding var endHex: String
    @Binding var directionRaw: String
    @Binding var styleRaw: String
    @Binding var isPresented: Bool
    var isVertical = false
    let willOpen: () -> Void

    var body: some View {
        Button {
            if !isPresented {
                willOpen()
            }
            isPresented.toggle()
        } label: {
            FloatingAppearanceMiniButtonLabel(
                title: isVertical ? "调色" : "调色盘",
                systemImage: "paintpalette",
                showsChevron: true,
                isAccent: false
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .anchorPreference(key: FloatingPanelPaletteButtonBoundsKey.self, value: .bounds) { anchor in
            anchor
        }
        .zIndex(isPresented ? 22 : 0)
        .help("调整悬浮窗背景渐变")
    }
}

struct FloatingPanelPaletteMenu: View {
    @Binding var startHex: String
    @Binding var endHex: String
    @Binding var directionRaw: String
    @Binding var styleRaw: String
    let closeAction: () -> Void
    @State private var scheduledClose: DispatchWorkItem?

    var body: some View {
        SettingsCalloutContainer(
            title: "悬浮窗样式",
            subtitle: nil,
            systemImage: "paintpalette",
            closeAction: closePaletteNow
        ) {
            SettingsCalloutSection("颜色") {
                VStack(spacing: 0) {
                    FloatingStyleControlRow(title: "起始色", systemImage: "circle.fill") {
                        ColorPicker("", selection: colorBinding($startHex), supportsOpacity: false)
                            .labelsHidden()
                    }

                    FloatingStyleDivider()

                    FloatingStyleControlRow(title: "结束色", systemImage: "circle.lefthalf.filled") {
                        ColorPicker("", selection: colorBinding($endHex), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }

            SettingsCalloutSection("渐变") {
                VStack(spacing: 0) {
                    FloatingStyleControlRow(title: "方向", systemImage: "arrow.up.right") {
                        Picker("", selection: normalizedDirectionBinding) {
                            ForEach(FloatingPanelGradientDirection.allCases) { direction in
                                Text(direction.label).tag(direction.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 150, alignment: .trailing)
                    }

                    FloatingStyleDivider()

                    FloatingStyleControlRow(title: "类型", systemImage: "swirl.circle.righthalf.filled") {
                        Picker("", selection: normalizedStyleBinding) {
                            ForEach(FloatingPanelGradientStyle.allCases) { style in
                                Text(style.label).tag(style.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 168)
                    }
                }
            }

            Button {
                startHex = FloatingPanelAppearance.defaultStartHex
                endHex = FloatingPanelAppearance.defaultEndHex
                directionRaw = FloatingPanelAppearance.defaultDirection
                styleRaw = FloatingPanelAppearance.defaultStyle
                closePaletteSoon()
            } label: {
                Label("恢复默认", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.58), lineWidth: 1)
            )
        }
        .frame(width: 338, alignment: .leading)
        .onChange(of: startHex) { _, _ in
            schedulePaletteClose(after: 0.85)
        }
        .onChange(of: endHex) { _, _ in
            schedulePaletteClose(after: 0.85)
        }
        .onChange(of: directionRaw) { _, _ in
            closePaletteSoon()
        }
        .onChange(of: styleRaw) { _, _ in
            closePaletteSoon()
        }
        .onDisappear {
            scheduledClose?.cancel()
            scheduledClose = nil
            NSColorPanel.shared.close()
        }
    }

    private var normalizedDirectionBinding: Binding<String> {
        Binding(
            get: {
                FloatingPanelGradientDirection(rawValue: directionRaw)?.rawValue
                    ?? FloatingPanelAppearance.defaultDirection
            },
            set: { directionRaw = $0 }
        )
    }

    private var normalizedStyleBinding: Binding<String> {
        Binding(
            get: {
                FloatingPanelGradientStyle(rawValue: styleRaw)?.rawValue
                    ?? FloatingPanelAppearance.defaultStyle
            },
            set: { styleRaw = $0 }
        )
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: {
                Color(floatingPanelHex: hex.wrappedValue)
                    ?? Color(floatingPanelHex: FloatingPanelAppearance.defaultStartHex)
                    ?? AppTheme.panelBackgroundAlt
            },
            set: { newValue in
                if let nextHex = newValue.floatingPanelHexString() {
                    hex.wrappedValue = nextHex
                }
            }
        )
    }

    private func schedulePaletteClose(after delay: TimeInterval) {
        scheduledClose?.cancel()
        let work = DispatchWorkItem {
            closePaletteNow()
        }
        scheduledClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closePaletteSoon() {
        schedulePaletteClose(after: 0.12)
    }

    private func closePaletteNow() {
        scheduledClose?.cancel()
        scheduledClose = nil
        NSColorPanel.shared.close()
        closeAction()
    }
}

private struct FloatingStyleControlRow<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 15)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            content
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
    }
}

private struct FloatingStyleDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.border.opacity(0.58))
            .frame(height: 1)
            .padding(.leading, 35)
    }
}

struct DisplaySurfaceToggleButton: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? AppTheme.accentBlue.opacity(0.14) : AppTheme.calloutOptionBackground)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isOn ? AppTheme.accentBlue.opacity(0.24) : AppTheme.border.opacity(0.82), lineWidth: 1)

                Label(title, systemImage: isOn ? "checkmark.circle.fill" : systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .foregroundStyle(isOn ? AppTheme.accentBlue : .secondary)
        .help(isOn ? "关闭\(title)" : "开启\(title)")
    }
}

struct CompactFloatingSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    let displayValue: String
    var showsBackground = true

    var body: some View {
        AlignedSettingSliderRow(
            title: title,
            systemImage: systemImage,
            value: $value,
            range: range,
            step: step,
            displayValue: displayValue
        )
        .padding(.horizontal, showsBackground ? 6 : 2)
        .padding(.vertical, showsBackground ? 4 : 0)
        .background(
            Group {
                if showsBackground {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.calloutOptionBackground)
                }
            }
        )
    }
}

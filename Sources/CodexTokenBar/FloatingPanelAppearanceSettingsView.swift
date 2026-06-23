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
    @AppStorage(FloatingPanelAppearance.textWhiteOverrideKey) private var floatingPanelTextWhiteOverride = FloatingPanelAppearance.defaultTextWhiteOverride

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
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

                    AppearanceSliderDivider()

                    CompactFloatingSlider(
                        title: "字体",
                        systemImage: "textformat",
                        value: $floatingPanelTextWhiteOverride,
                        range: 0...1,
                        displayValue: "\(Int((floatingPanelTextWhiteOverride * 100).rounded()))%",
                        showsBackground: false
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .zIndex(1)
            }
            .frame(height: 78)

            FloatingPanelContentSettings()
                .frame(height: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 107)
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

struct FloatingPanelContentSettings: View {
    @AppStorage(FloatingPanelContentVisibility.rateAndBarKey) private var showRateAndBar = FloatingPanelContentVisibility.default.showRateAndBar
    @AppStorage(FloatingPanelContentVisibility.usageStatusKey) private var showUsageStatus = FloatingPanelContentVisibility.default.showUsageStatus
    @AppStorage(FloatingPanelContentVisibility.metricsKey) private var showMetrics = FloatingPanelContentVisibility.default.showMetrics
    @AppStorage(FloatingPanelContentVisibility.quotaKey) private var showQuota = FloatingPanelContentVisibility.default.showQuota
    @AppStorage(FloatingPanelContentVisibility.radarKey) private var showRadar = FloatingPanelContentVisibility.default.showRadar

    var body: some View {
        HStack(spacing: 5) {
            DisplaySurfaceToggleButton(
                title: "速率",
                systemImage: "speedometer",
                isOn: $showRateAndBar
            )

            DisplaySurfaceToggleButton(
                title: "余量",
                systemImage: "sparkles",
                isOn: $showUsageStatus
            )

            DisplaySurfaceToggleButton(
                title: "总今次",
                systemImage: "number",
                isOn: $showMetrics
            )

            DisplaySurfaceToggleButton(
                title: "5h/7d",
                systemImage: "chart.bar.fill",
                isOn: $showQuota
            )

            DisplaySurfaceToggleButton(
                title: "Radar",
                systemImage: "dot.radiowaves.left.and.right",
                isOn: $showRadar
            )
        }
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
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
        .accessibilityLabel("提醒样式")
        .accessibilityValue(selectionTitle)
        .accessibilityHint("选择有未读会话时悬浮窗的提醒动画")
    }

    private var selectionTitle: String {
        switch FloatingPanelUnreadEffect(rawValue: selection) ?? .ripple {
        case .off:
            return "关"
        case .ripple:
            return "涟漪"
        case .shimmer:
            return "扫光"
        }
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
        .accessibilityLabel("调色盘")
        .accessibilityHint("调整悬浮窗背景渐变颜色、方向和类型")
    }
}

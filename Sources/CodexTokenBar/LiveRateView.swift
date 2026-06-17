import AppKit
import SwiftUI

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

import AppKit
import SwiftUI

private enum LiveRatePanelLayout {
    static let contentHeight: CGFloat = 158
    static let contentSpacing: CGFloat = 12
}

struct LiveRateView: View {
    let monitor: LiveRateMonitor
    @Binding var floatingPanelEnabled: Bool
    @Binding var statusBarPanelEnabled: Bool
    @Binding var liveRateMonitoringEnabled: Bool
    @Binding var floatingPanelShowRateAndBar: Bool
    @Binding var tokenRateFullScale: Double
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LiveRateHeader(monitor: monitor, onReset: monitor.reset)

            GeometryReader { proxy in
                let columnWidth = max(0, (proxy.size.width - LiveRatePanelLayout.contentSpacing) / 2)

                HStack(alignment: .top, spacing: LiveRatePanelLayout.contentSpacing) {
                    LiveRateInstrumentReader(
                        monitor: monitor,
                        fullScale: $tokenRateFullScale,
                        isMonitoringEnabled: $liveRateMonitoringEnabled,
                        floatingPanelShowRateAndBar: $floatingPanelShowRateAndBar
                    )
                        .frame(width: columnWidth, height: LiveRatePanelLayout.contentHeight)

                    LiveRateControls(
                        floatingPanelEnabled: $floatingPanelEnabled,
                        statusBarPanelEnabled: $statusBarPanelEnabled,
                        onOpenSettings: onOpenSettings
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
        .onAppear {
            syncMonitoringEnabled(liveRateMonitoringEnabled)
        }
        .onChange(of: liveRateMonitoringEnabled) {
            syncMonitoringEnabled(liveRateMonitoringEnabled)
        }
    }

    private func syncMonitoringEnabled(_ enabled: Bool) {
        monitor.setMonitoringEnabled(enabled)
        floatingPanelShowRateAndBar = enabled
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
    @Binding var isMonitoringEnabled: Bool
    @Binding var floatingPanelShowRateAndBar: Bool

    var body: some View {
        LiveRateInstrument(
            snapshot: monitor.totalSnapshot,
            fullScale: $fullScale,
            isMonitoringEnabled: $isMonitoringEnabled,
            floatingPanelShowRateAndBar: $floatingPanelShowRateAndBar
        )
    }
}

struct LiveRateInstrument: View {
    let snapshot: LiveRateSnapshot
    @Binding var fullScale: Double
    @Binding var isMonitoringEnabled: Bool
    @Binding var floatingPanelShowRateAndBar: Bool

    private var fillFraction: CGFloat {
        let scale = TokenRateScaleSettings.clamped(fullScale)
        return CGFloat(min(max(snapshot.rollingTokensPerSecond, 0), scale) / scale)
    }

    private var syncedMonitoringBinding: Binding<Bool> {
        Binding(
            get: { isMonitoringEnabled },
            set: { enabled in
                isMonitoringEnabled = enabled
                floatingPanelShowRateAndBar = enabled
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("实时速率", systemImage: "speedometer")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon)
                Text(isMonitoringEnabled ? "估算运行中" : "已关闭")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isMonitoringEnabled ? AppTheme.accentBlue : .secondary)
                Spacer(minLength: 0)
                LiveRatePowerToggle(isOn: syncedMonitoringBinding)
            }

            ZStack {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .lastTextBaseline, spacing: 7) {
                                Text(snapshot.rollingTokensPerSecondText)
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
                                Text("含输出与工具输入流 · 部分流式可能延迟")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary.opacity(0.72))
                                    .lineLimit(1)
                                    .help("部分 Codex 流式事件可能不会实时落入本地日志，速度显示可能会有延迟。")
                                Spacer(minLength: 0)
                                Text("量程 \(Int(TokenRateScaleSettings.clamped(fullScale).rounded())) tok/s")
                                    .monospacedDigit()
                            }
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.82))

                            GeometryReader { proxy in
                                let minimumFillFraction = 8 / max(proxy.size.width, 1)
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(AppTheme.insetBackground.opacity(0.82))
                                    SmoothRateFillBar(
                                        fraction: Double(fillFraction),
                                        minimumFraction: Double(minimumFillFraction)
                                    )
                                }
                            }
                            .frame(height: 9)
                        }
                    }

                    Text("官方为避免高频日志写入损耗硬盘，砍掉了很多流式输出日志；大部分速率只是估算，只用于判断 Codex 是否正在干活，不代表真实速率。")
                        .font(.system(size: 8.4, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.78))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    RateFullScaleSlider(value: $fullScale)
                }
                .opacity(isMonitoringEnabled ? 1 : 0.24)
                .saturation(isMonitoringEnabled ? 1 : 0.25)
                .allowsHitTesting(isMonitoringEnabled)

                if !isMonitoringEnabled {
                    LiveRateDisabledOverlay()
                }
            }
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

private struct LiveRatePowerToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(isOn ? "关闭" : "开启")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(isOn ? .secondary : AppTheme.accentBlue)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                Capsule()
                    .fill(isOn ? AppTheme.raisedBackground : AppTheme.accentBlue.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(isOn ? AppTheme.border : AppTheme.accentBlue.opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "关闭实时速率" : "开启实时速率")
        .accessibilityValue(isOn ? "已开启" : "已关闭")
    }
}

private struct LiveRateDisabledOverlay: View {
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "power.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            Text("实时速率已关闭")
                .font(.system(size: 12, weight: .bold))
            Text("监控和主界面速率显示已暂停")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.border.opacity(0.50), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("实时速率已关闭")
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
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label("显示面", systemImage: "rectangle.3.group")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("常用开关留在这里，其他选项集中到总体设置。")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                DisplaySurfaceToggleButton(
                    title: "悬浮窗",
                    systemImage: "rectangle.on.rectangle",
                    isOn: $floatingPanelEnabled
                )
                .frame(maxWidth: .infinity, minHeight: 34)

                DisplaySurfaceToggleButton(
                    title: "状态栏（实验）",
                    systemImage: "menubar.rectangle",
                    isOn: $statusBarPanelEnabled
                )
                .frame(maxWidth: .infinity, minHeight: 34)

                Button(action: onOpenSettings) {
                    Label("总体设置", systemImage: "gearshape")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accentBlue)
                .background(AppTheme.accentBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(AppTheme.accentBlue.opacity(0.26), lineWidth: 1))
            }

            Text("悬浮窗外观、额度配色、未读提醒、信息顺序、精确统计和界面大小都已移入总体设置。")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

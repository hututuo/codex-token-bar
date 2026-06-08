import SwiftUI

struct LiveRateView: View {
    @ObservedObject var monitor: LiveRateMonitor
    @Binding var tokenDisplayMode: TokenDisplayMode
    @Binding var preciseTokenCountingEnabled: Bool

    private var primarySnapshot: LiveRateSnapshot {
        monitor.totalSnapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("全会话实时速度")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()

                Picker("显示模式", selection: $tokenDisplayMode) {
                    ForEach(TokenDisplayMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 238)

                Menu {
                    ForEach(monitor.threadOptions) { option in
                        Button {
                            monitor.selectThread(option.id)
                        } label: {
                            if option.id == monitor.selectedThreadID {
                                Label(option.displayTitle, systemImage: "checkmark")
                            } else {
                                Text(option.displayTitle)
                            }
                        }
                    }
                } label: {
                    Label("查看单会话", systemImage: "sidebar.leading")
                }
                .buttonStyle(.bordered)
                .font(.system(size: 13, weight: .medium))

                Toggle(isOn: $preciseTokenCountingEnabled) {
                    Label("精准", systemImage: "number")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .font(.system(size: 13, weight: .medium))
                .help("开启后使用 o200k_base 精确统计流式输出 token；关闭后使用轻量估算。")

                Button {
                    monitor.reset()
                } label: {
                    Label("重置", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .font(.system(size: 13, weight: .medium))
            }

            HStack(alignment: .center, spacing: 14) {
                LiveRateGauge(value: primarySnapshot.rollingTokensPerSecond)
                    .frame(width: 154, height: 92)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        LiveMetricCell(
                            value: String(format: "%.1f", primarySnapshot.rollingTokensPerSecond),
                            label: "全会话 tok/s"
                        )
                        LiveMetricCell(
                            value: "\(primarySnapshot.breakdown.modelGenerated)",
                            label: "模型生成"
                        )
                        LiveMetricCell(
                            value: "\(primarySnapshot.outputTokens)",
                            label: "综合 token"
                        )
                    }

                    HStack(spacing: 8) {
                        LivePill(systemImage: "sum", text: primarySnapshot.scopeLabel)
                        LivePill(systemImage: "point.3.connected.trianglepath.dotted", text: primarySnapshot.interfaceLabel)
                        LivePill(systemImage: tokenDisplayMode.systemImage, text: tokenDisplayMode.label)
                    }

                    LiveBreakdownRow(breakdown: primarySnapshot.breakdown)

                    LiveSelectedThreadRow(snapshot: monitor.snapshot)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("全会话输出汇总")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(primarySnapshot.status) · \(primarySnapshot.sourceLabel)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(18)
        .frame(maxWidth: 980)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow, radius: 18, y: 10)
    }
}

struct LiveSelectedThreadRow: View {
    let snapshot: LiveRateSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Label("选中会话", systemImage: "sidebar.leading")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Text(String(format: "%.1f tok/s", snapshot.rollingTokensPerSecond))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: 86, alignment: .leading)

            Text("\(snapshot.outputTokens) 综合")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .frame(width: 96, alignment: .leading)

            Text("\(snapshot.breakdown.modelGenerated) 模型")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .frame(width: 86, alignment: .leading)

            Text(snapshot.status)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.insetBackground)
        )
    }
}

struct LiveBreakdownRow: View {
    let breakdown: LiveTokenBreakdown

    var body: some View {
        HStack(spacing: 8) {
            LiveBreakdownChip(label: "可见", value: breakdown.visibleText)
            LiveBreakdownChip(label: "工具参数", value: breakdown.toolArguments)
            LiveBreakdownChip(label: "编辑输入", value: breakdown.patchInput)
            LiveBreakdownChip(label: "实际改动", value: breakdown.patchApplied)
            LiveBreakdownChip(label: "工具输出", value: breakdown.toolOutput)
            LiveBreakdownChip(label: "reasoning", value: breakdown.reasoning)
            if breakdown.exactModelOutput > 0 {
                LiveBreakdownChip(label: "精确输出", value: breakdown.exactModelOutput)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LiveBreakdownChip: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppTheme.raisedBackground)
        )
    }
}

struct LiveRateGauge: View {
    let value: Double

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.insetBackground)

            GeometryReader { proxy in
                let capped = min(max(value, 0), 120)
                let width = max(6, proxy.size.width * capped / 120)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.accentCyan, AppTheme.accentBlue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f", value))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("tokens / second")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

struct LiveMetricCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 112, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.raisedBackground)
        )
    }
}

struct LivePill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(AppTheme.raisedBackground)
            )
            .lineLimit(1)
    }
}

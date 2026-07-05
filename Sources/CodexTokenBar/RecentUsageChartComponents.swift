import SwiftUI

struct RecentChartRangeSelector: View {
    @Binding var selection: RecentChartRange

    var body: some View {
        HStack(spacing: 3) {
            ForEach(RecentChartRange.allCases) { range in
                Button {
                    selection = range
                } label: {
                    Text(range.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selection == range ? AppTheme.accentBlue : .secondary)
                        .frame(width: 34, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selection == range ? AppTheme.accentBlue.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("曲线范围 \(range.title)")
                .accessibilityValue(selection == range ? "已选择" : "未选择")
            }
        }
        .padding(3)
        .background(AppTheme.raisedBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) 图例")
        .accessibilityValue(value)
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
        .accessibilityLabel("显示 \(title) 曲线")
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityHint("切换这条曲线是否显示")
    }
}

struct RecentChartQuotaEstimateModelSelector: View {
    @Binding var selectedModel: OfficialAPIPriceModel

    var body: some View {
        HStack(spacing: 5) {
            Text(RecentChartQuotaEstimateAffordancePresentation.modelOption(for: selectedModel, selectedModel: selectedModel).groupLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(OfficialAPIPriceModel.allCases) { model in
                let option = RecentChartQuotaEstimateAffordancePresentation.modelOption(
                    for: model,
                    selectedModel: selectedModel
                )
                Button {
                    selectedModel = model
                } label: {
                    Text(option.shortTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selectedModel == model ? AppTheme.accentBlue : .secondary)
                        .frame(width: 34, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedModel == model ? AppTheme.accentBlue.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.accessibilityLabel)
                .accessibilityValue(option.accessibilityValue)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(AppTheme.raisedBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

struct RecentChartQuotaEstimateOverlay: View {
    let selection: QuotaConsumptionSelection
    let onClose: () -> Void

    var body: some View {
        let presentation = QuotaConsumptionEstimatorOverlayPresentation(selection: selection)

        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.costTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(presentation.costText)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.accentBlue)
                    Text(presentation.timeRangeText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(presentation.cacheHitText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppTheme.accentCyan)
                }

                HStack(spacing: 7) {
                    Text(presentation.estimateTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    QuotaEstimateChip(presentation: presentation.fiveHourChip, color: .purple)
                    QuotaEstimateChip(presentation: presentation.sevenDayChip, color: .green)
                }

                HStack(spacing: 6) {
                    Text(presentation.ratioTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(presentation.budgetRatioText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(presentation.showsRatioWarning ? .orange : .primary)
                    Text(presentation.ratioHelpText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let ratioWarningText = presentation.ratioWarningText {
                        Text(ratioWarningText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }

                if let ratioWarningDetailText = presentation.ratioWarningDetailText {
                    Text(ratioWarningDetailText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.closeAccessibilityLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 410, alignment: .leading)
        .background(AppTheme.hoverBubble.opacity(0.96), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.borderStrong, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }
}

private struct QuotaEstimateChip: View {
    let presentation: QuotaConsumptionEstimatePresentation
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(presentation.title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            Text(presentation.detail)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 7)
        .frame(height: 21)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        )
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.detail)
    }
}

extension View {
    func chartBubblePlacement(tokenX: CGFloat, plot: CGRect) -> some View {
        modifier(ChartBubblePlacementModifier(tokenX: tokenX, plot: plot))
    }
}

struct ChartBubblePlacementModifier: ViewModifier {
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
    let bucketInterval: TimeInterval
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
            if isHovering {
                Text(RecentChartQuotaEstimateAffordancePresentation.hoverInstruction)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.accentBlue)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isHovering ? "曲线当前点" : "曲线最新点")
        .accessibilityValue(accessibilitySummary)
    }

    private var average: Int {
        bin.calls > 0 ? bin.tokens / bin.calls : 0
    }

    private var accessibilitySummary: String {
        var parts = [
            timeRange,
            "\(bin.tokens.abbreviatedTokens) token",
            "\(bin.calls) 次请求",
            "平均 \(average.abbreviatedTokens)"
        ]
        if let cacheBreakdown, cacheBreakdown.calls > 0 {
            parts.append("缓存命中率 \(cacheBreakdown.cacheHitRate.percentString)")
            parts.append("命中 \(cacheBreakdown.cachedInputTokens.abbreviatedTokens)")
        }
        if fiveHourRemaining != nil || sevenDayRemaining != nil {
            parts.append("5 小时额度 \(percentText(fiveHourRemaining))")
            parts.append("7 天额度 \(percentText(sevenDayRemaining))")
        }
        if isHovering {
            parts.append(RecentChartQuotaEstimateAffordancePresentation.hoverAccessibilityPrompt)
        }
        return parts.joined(separator: "；")
    }

    private var timeRange: String {
        let end = bin.start.addingTimeInterval(bucketInterval)
        if bucketInterval <= 60 * 60,
           Calendar.current.isDate(bin.start, inSameDayAs: end) {
            return "\(DateFormatter.hourMinute.string(from: bin.start)) - \(DateFormatter.hourMinute.string(from: end))"
        }
        return "\(DateFormatter.monthDayHourMinute.string(from: bin.start)) - \(DateFormatter.monthDayHourMinute.string(from: end))"
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }
}

struct ChartTimeMarkers: View {
    let bins: [BinUsage]
    let markerIndices: [Int]
    let range: RecentChartRange
    let plot: CGRect

    var body: some View {
        ForEach(markerIndices, id: \.self) { index in
            if let bin = bins[safe: index] {
                Text(label(for: bin.start))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .position(x: xPosition(for: index), y: plot.maxY + 20)
            }
        }
    }

    private func xPosition(for index: Int) -> CGFloat {
        plot.minX + CGFloat(index) * plot.width / CGFloat(max(bins.count - 1, 1))
    }

    private func label(for date: Date) -> String {
        switch range {
        case .twentyFourHours:
            return DateFormatter.hourMinute.string(from: date)
        case .sevenDays, .thirtyDays:
            return DateFormatter.monthDay.string(from: date)
        }
    }
}

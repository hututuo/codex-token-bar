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
            Text("官方 API")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(OfficialAPIPriceModel.allCases) { model in
                Button {
                    selectedModel = model
                } label: {
                    Text(model.shortTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selectedModel == model ? AppTheme.accentBlue : .secondary)
                        .frame(width: 34, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedModel == model ? AppTheme.accentBlue.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("官方 API 定价 \(model.title)")
                .accessibilityValue(selectedModel == model ? "已选择" : "未选择")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("本段消耗")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(selection.breakdown.costText(selection.priceCard))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.accentBlue)
                Text(selection.timeRangeText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("命中 \(selection.breakdown.cacheHitRate.percentString)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.accentCyan)
            }

            HStack(spacing: 7) {
                Text("反推总额度")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                QuotaEstimateChip(title: "5h", estimate: selection.fiveHour, color: .purple)
                QuotaEstimateChip(title: "7d", estimate: selection.sevenDay, color: .green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 380, alignment: .leading)
        .background(AppTheme.hoverBubble.opacity(0.96), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.borderStrong, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("额度估算")
        .accessibilityValue("本段消耗 \(selection.breakdown.costText(selection.priceCard))，5 小时 \(selection.fiveHour.accessibilityText)，7 天 \(selection.sevenDay.accessibilityText)")
    }
}

private struct QuotaEstimateChip: View {
    let title: String
    let estimate: QuotaConsumptionEstimate
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            Text(detail)
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
        .accessibilityLabel("\(title) 额度估算")
        .accessibilityValue(detail)
    }

    private var detail: String {
        switch estimate.confidence {
        case .measured:
            return "\(estimate.budgetText) · 降 \(estimate.quotaDropPercent.oneDecimalPercent)"
        case .insufficientQuotaMovement:
            return "下降太小"
        case .noTokenUsage:
            return "无 token"
        }
    }
}

extension View {
    func chartBubblePlacement(tokenX: CGFloat, plot: CGRect) -> some View {
        modifier(ChartBubblePlacementModifier(tokenX: tokenX, plot: plot))
    }
}

private extension OfficialAPIPriceModel {
    var shortTitle: String {
        switch self {
        case .gpt55: "5.5"
        case .gpt54: "5.4"
        case .gpt54Mini: "mini"
        }
    }
}

private extension QuotaConsumptionSelection {
    var timeRangeText: String {
        "\(DateFormatter.hourMinute.string(from: startDate))-\(DateFormatter.hourMinute.string(from: endDate))"
    }
}

private extension QuotaConsumptionEstimate {
    var accessibilityText: String {
        switch confidence {
        case .measured:
            return "反推总额度 \(budgetText)，下降 \(quotaDropPercent.oneDecimalPercent)"
        case .insufficientQuotaMovement:
            return "额度下降太小，不能反推"
        case .noTokenUsage:
            return "没有 token 用量"
        }
    }

    var budgetText: String {
        guard let impliedWindowBudgetUSD else { return "--" }
        return "$\(Self.moneyString(impliedWindowBudgetUSD))"
    }

    static func moneyString(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f", value)
        }
        if value >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }
}

private extension TokenCacheBreakdown {
    func costText(_ priceCard: QuotaConsumptionPriceCard) -> String {
        "$\(QuotaConsumptionEstimate.moneyString(priceCard.costUSD(for: self)))"
    }
}

private extension Double {
    var oneDecimalPercent: String {
        if rounded() == self {
            return "\(Int(self))%"
        }
        return String(format: "%.1f%%", self)
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

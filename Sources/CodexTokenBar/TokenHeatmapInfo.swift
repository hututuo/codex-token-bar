import SwiftUI

struct HeatmapUsageSummary {
    let title: String
    let tokens: Int
    let calls: Int
    let iconName: String
    let cacheBreakdown: TokenCacheBreakdown?
    let isCacheRate: Bool
    let quotaRemainingPercent: Double?
    let isQuotaRemaining: Bool

    init(
        title: String,
        tokens: Int,
        calls: Int,
        iconName: String,
        cacheBreakdown: TokenCacheBreakdown? = nil,
        isCacheRate: Bool = false,
        quotaRemainingPercent: Double? = nil,
        isQuotaRemaining: Bool = false
    ) {
        self.title = title
        self.tokens = tokens
        self.calls = calls
        self.iconName = iconName
        self.cacheBreakdown = cacheBreakdown
        self.isCacheRate = isCacheRate
        self.quotaRemainingPercent = quotaRemainingPercent
        self.isQuotaRemaining = isQuotaRemaining
    }

    var average: Int {
        calls > 0 ? tokens / calls : 0
    }
}

struct HeatmapRangeSummary {
    let title: String
    let dayCount: Int
    let tokens: Int
    let calls: Int
    let cacheBreakdown: TokenCacheBreakdown?
    let quotaAverageRemainingPercent: Double?

    var average: Int {
        calls > 0 ? tokens / calls : 0
    }

    var compactTitle: String {
        title
            .replacingOccurrences(of: "年", with: ".")
            .replacingOccurrences(of: "月", with: ".")
            .replacingOccurrences(of: "日", with: "")
            .replacingOccurrences(of: " - ", with: "-")
    }
}

struct HeatmapHoverInfo: View {
    let summary: HeatmapUsageSummary?
    let rangeSummary: HeatmapRangeSummary?
    let hasRangeStart: Bool

    var body: some View {
        GeometryReader { proxy in
            let leftWidth = max(300, proxy.size.width * 0.43)
            HStack(spacing: 14) {
                singleDayContent
                    .frame(width: leftWidth, alignment: .leading)

                Rectangle()
                    .fill(AppTheme.border)
                    .frame(width: 1, height: 22)

                rangeContent
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .layoutPriority(1)
            }
        }
        .frame(height: 20)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.insetBackground)
        )
    }

    @ViewBuilder
    private var singleDayContent: some View {
        HStack(spacing: 12) {
            if let summary {
                Image(systemName: summary.iconName)
                    .foregroundStyle(AppTheme.accentBlue)
                Text(summary.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if summary.isCacheRate, let breakdown = summary.cacheBreakdown {
                    Text(breakdown.cacheHitRate.percentString)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                    Text("命中 \(breakdown.cachedInputTokens.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("未命中 \(breakdown.uncachedInputTokens.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("\(breakdown.calls) calls")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else if summary.isQuotaRemaining {
                    Text(summary.quotaRemainingPercent.map { "\(Int($0.rounded()))% 7d 剩余" } ?? "暂无额度记录")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(summary.quotaRemainingPercent.map { AppTheme.quotaRemainingColor(percent: $0) } ?? .secondary)
                    Text("\(summary.calls) samples")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(summary.tokens.abbreviatedTokens) tokens")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                    Text("\(summary.calls) calls")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("avg \(summary.average.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "cursorarrow.rays")
                    .foregroundStyle(Color.secondary)
                Text("悬停查看单日")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var rangeContent: some View {
        HStack(spacing: 12) {
            if let rangeSummary {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(AppTheme.accentBlue)
                Text("总计")
                    .font(.system(size: 13, weight: .semibold))
                Text(rangeSummary.compactTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(2)
                Text("\(rangeSummary.dayCount) 天")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)

                if let breakdown = rangeSummary.cacheBreakdown {
                    Text(breakdown.cacheHitRate.percentString)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                    Text("命中 \(breakdown.cachedInputTokens.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("未命中 \(breakdown.uncachedInputTokens.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("\(breakdown.calls) calls")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else if let quotaAverage = rangeSummary.quotaAverageRemainingPercent {
                    Text("\(Int(quotaAverage.rounded()))% 7d 平均剩余")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.quotaRemainingColor(percent: quotaAverage))
                    Text("\(rangeSummary.calls) samples")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(rangeSummary.tokens.abbreviatedTokens) tokens")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                    Text("\(rangeSummary.calls) calls")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("avg \(rangeSummary.average.abbreviatedTokens)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else if hasRangeStart {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(AppTheme.accentBlue)
                Text("已选起点，再点一个日期")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "hand.tap")
                    .foregroundStyle(.secondary)
                Text("点击开始和结束日期，可显示范围总计")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

struct MonthLabels: View {
    let markers: [HeatmapMonthMarker]
    let cellSize: CGFloat
    let gap: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(markers) { marker in
                Text(marker.label)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: width(for: marker), alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func width(for marker: HeatmapMonthMarker) -> CGFloat {
        CGFloat(max(2, marker.nextColumn - marker.column)) * (cellSize + gap)
    }
}

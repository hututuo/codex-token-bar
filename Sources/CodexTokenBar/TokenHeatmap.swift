import SwiftUI

struct HeatmapMonthMarker: Identifiable {
    let label: String
    let column: Int
    let nextColumn: Int

    var id: String {
        "\(label)-\(column)"
    }
}

struct HeatmapPreparedData {
    let summaries: [HeatmapUsageSummary]
    let maxTokens: Int
    let maxModelCostUSD: Double
    let columns: [[Int]]
    let monthMarkers: [HeatmapMonthMarker]

    static let empty = HeatmapPreparedData(
        summaries: [],
        maxTokens: 1,
        maxModelCostUSD: 0,
        columns: [],
        monthMarkers: []
    )
}

struct TokenHeatmap: View {
    let dailyUsage: [DayUsage]
    let cacheDaily: [TokenCacheBucket]
    let dailyModelBreakdowns: [ModelTokenBucket]
    let attributionEvents: [TokenCacheAttributionEvent]
    let quotaDaily: [QuotaHistoryDailyBucket]
    let fallbackModel: OfficialAPIPriceModel
    let mode: ActivityMode
    @State private var hoveredIndex: Int?
    @State private var rangeStartIndex: Int?
    @State private var rangeEndIndex: Int?
    @State private var preparedData: HeatmapPreparedData

    private let rows = 7
    private let gap: CGFloat = 4
    private let trailingInset: CGFloat = 9

    init(
        dailyUsage: [DayUsage],
        cacheDaily: [TokenCacheBucket],
        dailyModelBreakdowns: [ModelTokenBucket] = [],
        attributionEvents: [TokenCacheAttributionEvent] = [],
        quotaDaily: [QuotaHistoryDailyBucket],
        fallbackModel: OfficialAPIPriceModel = .gpt56Sol,
        mode: ActivityMode
    ) {
        self.dailyUsage = dailyUsage
        self.cacheDaily = cacheDaily
        self.dailyModelBreakdowns = dailyModelBreakdowns
        self.attributionEvents = attributionEvents
        self.quotaDaily = quotaDaily
        self.fallbackModel = fallbackModel
        self.mode = mode
        _preparedData = State(initialValue: .empty)
    }

    var body: some View {
        GeometryReader { proxy in
            let summaries = preparedData.summaries
            let columns = preparedData.columns
            let selectedIndex = hoveredIndex ?? summaries.indices.last
            let cellSize = adaptiveCellSize(containerWidth: proxy.size.width, columnCount: columns.count)
            let gridWidth = gridWidth(columnCount: columns.count, cellSize: cellSize)
            let gridHeight = gridHeight(cellSize: cellSize)
            let rangeSelection = normalizedRangeSelection(dayCount: summaries.count)
            let rangeSummary = rangeSelection.flatMap { makeRangeSummary(range: $0) }

            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(columns.indices, id: \.self) { columnIndex in
                            VStack(spacing: gap) {
                                ForEach(0..<rows, id: \.self) { rowIndex in
                                    if let dayIndex = columns[columnIndex][safe: rowIndex],
                                       let summary = summaries[safe: dayIndex] {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(fillStyle(for: summary, preparedData: preparedData))
                                            .frame(width: cellSize, height: cellSize)
                                    } else {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color.clear)
                                            .frame(width: cellSize, height: cellSize)
                                    }
                                }
                            }
                        }
                    }

                    if let rangeSelection {
                        ForEach(rangeSelection.lowerBound...rangeSelection.upperBound, id: \.self) { index in
                            let isEndpoint = index == rangeSelection.lowerBound || index == rangeSelection.upperBound
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(AppTheme.accentBlue.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(AppTheme.accentBlue.opacity(isEndpoint ? 0.98 : 0.50), lineWidth: isEndpoint ? 2.0 : 1.1)
                                )
                                .frame(width: cellSize, height: cellSize)
                                .offset(
                                    x: CGFloat(index / rows) * (cellSize + gap),
                                    y: CGFloat(index % rows) * (cellSize + gap)
                                )
                                .allowsHitTesting(false)
                        }
                    }

                    if let selectedIndex,
                       summaries.indices.contains(selectedIndex) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(AppTheme.accentBlue, lineWidth: 1.9)
                            .frame(width: cellSize, height: cellSize)
                            .offset(
                                x: CGFloat(selectedIndex / rows) * (cellSize + gap),
                                y: CGFloat(selectedIndex % rows) * (cellSize + gap)
                            )
                            .allowsHitTesting(false)
                    }

                    HoverTrackingArea(
                        onMove: { location in
                            let nextIndex = nearestDayIndex(
                                at: location,
                                columnCount: columns.count,
                                dayCount: summaries.count,
                                cellSize: cellSize
                            )
                            if hoveredIndex != nextIndex {
                                hoveredIndex = nextIndex
                            }
                        },
                        onClick: { location in
                            guard let clickedIndex = nearestDayIndex(
                                at: location,
                                columnCount: columns.count,
                                dayCount: summaries.count,
                                cellSize: cellSize
                            ) else { return }
                            updateRangeSelection(clickedIndex)
                        },
                        onExit: {
                            if hoveredIndex != nil {
                                hoveredIndex = nil
                            }
                        }
                    )
                    .frame(width: gridWidth, height: gridHeight)
                }
                .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

                MonthLabels(markers: preparedData.monthMarkers, cellSize: cellSize, gap: gap)
                HeatmapHoverInfo(
                    summary: hoveredIndex.flatMap { summaries[safe: $0] } ?? summaries.last,
                    rangeSummary: rangeSummary,
                    hasRangeStart: rangeStartIndex != nil,
                    fallbackModel: fallbackModel
                )
            }
        }
        .frame(height: 180)
        .onAppear(perform: refreshPreparedData)
        .onChange(of: dailyUsage) { _, _ in
            clearRangeSelection()
            refreshPreparedData()
        }
        .onChange(of: cacheDaily) { _, _ in
            clearRangeSelection()
            refreshPreparedData()
        }
        .onChange(of: dailyModelBreakdowns) { _, _ in
            clearRangeSelection()
            refreshPreparedData()
        }
        .onChange(of: attributionEvents) { _, _ in
            clearRangeSelection()
            refreshPreparedData()
        }
        .onChange(of: quotaDaily) { _, _ in
            clearRangeSelection()
            refreshPreparedData()
        }
        .onChange(of: fallbackModel) { _, _ in
            refreshPreparedData()
        }
        .onChange(of: mode) { _, _ in
            hoveredIndex = nil
            clearRangeSelection()
            refreshPreparedData()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token 活动热力图")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("点击开始和结束日期，可以显示范围总计")
    }

    private var accessibilitySummary: String {
        var parts = [
            "模式 \(mode.rawValue)",
            "\(preparedData.summaries.count) 个日期"
        ]
        if let latest = preparedData.summaries.last {
            parts.append("最近 \(summaryAccessibilityText(latest))")
        }
        if let range = normalizedRangeSelection(dayCount: preparedData.summaries.count),
           let rangeSummary = makeRangeSummary(range: range) {
            parts.append("范围 \(rangeAccessibilityText(rangeSummary))")
        } else if rangeStartIndex != nil {
            parts.append("已选择起点，再选择结束日期")
        }
        return parts.joined(separator: "；")
    }

    private func summaryAccessibilityText(_ summary: HeatmapUsageSummary) -> String {
        if summary.isCacheRate {
            guard let breakdown = summary.cacheBreakdown, breakdown.calls > 0 else {
                return "\(summary.title)，暂无缓存命中数据"
            }
            return "\(summary.title)，命中率 \(breakdown.cacheHitRate.percentString)，命中 \(breakdown.cachedInputTokens.abbreviatedTokens)，未命中 \(breakdown.uncachedInputTokens.abbreviatedTokens)，\(breakdown.calls) 次调用"
        }
        if summary.isQuotaRemaining {
            guard let percent = summary.quotaRemainingPercent else {
                return "\(summary.title)，暂无额度记录"
            }
            return "\(summary.title)，7 天额度剩余 \(Int(percent.rounded()))%，\(summary.calls) 个采样"
        }
        if summary.isModelShare {
            let models = ModelUsagePresentation.compactText(from: summary.modelBreakdowns) ?? "暂无模型明细"
            return "\(summary.title)，\(summary.tokens.abbreviatedTokens) token，模型占比 \(models)"
        }
        if summary.isModelCost {
            guard let cost = summary.modelCostUSD else {
                return "\(summary.title)，模型明细待读取"
            }
            let detail = modelCostAccessibilityText(summary.modelBreakdowns)
            return "\(summary.title)，模型费用 \(cost.quotaEstimatorMoneyText)，\(detail)"
        }
        return "\(summary.title)，\(summary.tokens.abbreviatedTokens) token，\(summary.calls) 次调用，平均 \(summary.average.abbreviatedTokens)"
    }

    private func rangeAccessibilityText(_ rangeSummary: HeatmapRangeSummary) -> String {
        if let breakdown = rangeSummary.cacheBreakdown {
            return "\(rangeSummary.title)，\(rangeSummary.dayCount) 天，命中率 \(breakdown.cacheHitRate.percentString)，命中 \(breakdown.cachedInputTokens.abbreviatedTokens)，未命中 \(breakdown.uncachedInputTokens.abbreviatedTokens)，\(breakdown.calls) 次调用"
        }
        if let quotaAverage = rangeSummary.quotaAverageRemainingPercent {
            return "\(rangeSummary.title)，\(rangeSummary.dayCount) 天，7 天额度平均剩余 \(Int(quotaAverage.rounded()))%，\(rangeSummary.calls) 个采样"
        }
        if rangeSummary.isModelCost {
            guard let cost = rangeSummary.modelCostUSD else {
                return "\(rangeSummary.title)，\(rangeSummary.dayCount) 天，模型明细待读取"
            }
            return "\(rangeSummary.title)，\(rangeSummary.dayCount) 天，模型费用 \(cost.quotaEstimatorMoneyText)，\(modelCostAccessibilityText(rangeSummary.modelBreakdowns))"
        }
        if !rangeSummary.modelBreakdowns.isEmpty {
            let models = ModelUsagePresentation.compactText(from: rangeSummary.modelBreakdowns) ?? "暂无模型明细"
            return "\(rangeSummary.title)，\(rangeSummary.dayCount) 天，\(rangeSummary.tokens.abbreviatedTokens) token，模型占比 \(models)"
        }
        return "\(rangeSummary.title)，\(rangeSummary.dayCount) 天，\(rangeSummary.tokens.abbreviatedTokens) token，\(rangeSummary.calls) 次调用，平均 \(rangeSummary.average.abbreviatedTokens)"
    }

    private func adaptiveCellSize(containerWidth: CGFloat, columnCount: Int) -> CGFloat {
        guard columnCount > 0 else { return 12 }
        let targetWidth = max(0, containerWidth - trailingInset)
        let availableForCells = targetWidth - CGFloat(columnCount - 1) * gap
        return max(10, availableForCells / CGFloat(columnCount))
    }

    private func gridHeight(cellSize: CGFloat) -> CGFloat {
        CGFloat(rows) * cellSize + CGFloat(rows - 1) * gap
    }

    private func gridWidth(columnCount: Int, cellSize: CGFloat) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        return CGFloat(columnCount) * cellSize + CGFloat(columnCount - 1) * gap
    }

    private func nearestDayIndex(at location: CGPoint, columnCount: Int, dayCount: Int, cellSize: CGFloat) -> Int? {
        guard dayCount > 0, columnCount > 0 else { return nil }
        let pitch = cellSize + gap
        let rawColumn = Int(((location.x - cellSize / 2) / pitch).rounded())
        let rawRow = Int(((location.y - cellSize / 2) / pitch).rounded())
        let column = min(max(rawColumn, 0), columnCount - 1)
        let row = min(max(rawRow, 0), rows - 1)
        let center = CGPoint(
            x: CGFloat(column) * pitch + cellSize / 2,
            y: CGFloat(row) * pitch + cellSize / 2
        )
        let distance = hypot(location.x - center.x, location.y - center.y)
        guard distance <= cellSize else { return nil }

        let dayIndex = column * rows + row
        guard dayIndex < dayCount else { return nil }
        return dayIndex
    }

    private func color(for summary: HeatmapUsageSummary, maxTokens: Int) -> Color {
        if summary.isCacheRate {
            guard summary.calls > 0, let cacheBreakdown = summary.cacheBreakdown else {
                return AppTheme.emptyCell
            }
            return AppTheme.cacheHitColor(rate: cacheBreakdown.cacheHitRate)
        }

        if summary.isQuotaRemaining {
            guard let percent = summary.quotaRemainingPercent else {
                return AppTheme.emptyCell
            }
            return AppTheme.quotaRemainingColor(percent: percent)
        }

        if summary.isModelShare {
            guard summary.tokens > 0 else { return AppTheme.emptyCell }
            let ratio = min(1.0, Double(summary.tokens) / Double(max(maxTokens, 1)))
            return (ModelUsagePresentation.dominantColor(from: summary.modelBreakdowns) ?? AppTheme.emptyCell)
                .opacity(0.24 + ratio * 0.76)
        }

        let value = summary.tokens
        guard value > 0 else { return AppTheme.emptyCell }
        let ratio = min(1.0, Double(value) / Double(max(maxTokens, 1)))
        return AppTheme.heatmapColor(ratio: ratio)
    }

    private func fillStyle(
        for summary: HeatmapUsageSummary,
        preparedData: HeatmapPreparedData
    ) -> AnyShapeStyle {
        guard summary.isModelCost else {
            return AnyShapeStyle(color(for: summary, maxTokens: preparedData.maxTokens))
        }
        guard summary.modelCostUSD != nil else {
            return AnyShapeStyle(AppTheme.emptyCell)
        }
        let items = FloatingTodayModelUsagePresentation.items(
            from: summary.modelBreakdowns,
            fallbackModel: fallbackModel
        )
        let paid = items.filter { ($0.costUSD ?? 0) > 0 }
        guard !paid.isEmpty else {
            if let independent = items.first(where: \.usesIndependentQuota) {
                return AnyShapeStyle(independent.color.opacity(summary.tokens > 0 ? 0.46 : 0))
            }
            return AnyShapeStyle(AppTheme.emptyCell)
        }
        let total = paid.reduce(0) { $0 + ($1.costUSD ?? 0) }
        guard total > 0 else { return AnyShapeStyle(AppTheme.emptyCell) }
        let intensity = min(1, total / max(preparedData.maxModelCostUSD, 0.000_001))
        let opacity = 0.30 + intensity * 0.70
        var cursor = 0.0
        var stops: [Gradient.Stop] = []
        for item in paid {
            let color = item.color.opacity(opacity)
            let next = min(1, cursor + (item.costUSD ?? 0) / total)
            stops.append(Gradient.Stop(color: color, location: cursor))
            stops.append(Gradient.Stop(color: color, location: next))
            cursor = next
        }
        return AnyShapeStyle(
            LinearGradient(
                gradient: Gradient(stops: stops),
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func refreshPreparedData() {
        preparedData = Self.prepare(
            dailyUsage: dailyUsage,
            cacheDaily: cacheDaily,
            dailyModelBreakdowns: dailyModelBreakdowns,
            attributionEvents: attributionEvents,
            quotaDaily: quotaDaily,
            fallbackModel: fallbackModel,
            mode: mode
        )
    }

    private func updateRangeSelection(_ index: Int) {
        if rangeStartIndex == nil || rangeEndIndex != nil {
            rangeStartIndex = index
            rangeEndIndex = nil
        } else {
            rangeEndIndex = index
        }
    }

    private func clearRangeSelection() {
        rangeStartIndex = nil
        rangeEndIndex = nil
    }

    private func normalizedRangeSelection(dayCount: Int) -> ClosedRange<Int>? {
        guard let start = rangeStartIndex, dayCount > 0 else { return nil }
        let clampedStart = min(max(start, 0), dayCount - 1)
        let clampedEnd = min(max(rangeEndIndex ?? start, 0), dayCount - 1)
        return min(clampedStart, clampedEnd)...max(clampedStart, clampedEnd)
    }

    private func makeRangeSummary(range: ClosedRange<Int>) -> HeatmapRangeSummary? {
        guard !dailyUsage.isEmpty,
              let firstDay = dailyUsage[safe: range.lowerBound],
              let lastDay = dailyUsage[safe: range.upperBound] else {
            return nil
        }

        let days = range.compactMap { dailyUsage[safe: $0] }
        let title = rangeTitle(first: firstDay.date, last: lastDay.date)

        if mode == .cacheHitRate {
            let calendar = Calendar.current
            let cacheByDay = Dictionary(uniqueKeysWithValues: cacheDaily.map { bucket in
                (calendar.startOfDay(for: bucket.start), bucket.breakdown)
            })
            let breakdown = days.compactMap { day in
                cacheByDay[calendar.startOfDay(for: day.date)]
            }.combined
            return HeatmapRangeSummary(
                title: title,
                dayCount: days.count,
                tokens: breakdown.totalTokens,
                calls: breakdown.calls,
                cacheBreakdown: breakdown,
                quotaAverageRemainingPercent: nil
            )
        }

        if mode == .quotaRemaining {
            let calendar = Calendar.current
            let quotaByDay = Dictionary(uniqueKeysWithValues: quotaDaily.map { bucket in
                (calendar.startOfDay(for: bucket.date), bucket)
            })
            let values = days.compactMap { day in
                quotaByDay[calendar.startOfDay(for: day.date)]?.sevenDayRemainingPercent
            }
            return HeatmapRangeSummary(
                title: title,
                dayCount: days.count,
                tokens: 0,
                calls: values.count,
                cacheBreakdown: nil,
                quotaAverageRemainingPercent: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            )
        }

        if mode == .modelShare || mode == .modelCost {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: firstDay.date)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay.date)) ?? lastDay.date
            let modelBucketsByDay = Dictionary(uniqueKeysWithValues: dailyModelBreakdowns.map { bucket in
                (calendar.startOfDay(for: bucket.start), bucket.modelBreakdowns)
            })
            let rows = mode == .modelCost
                ? days.flatMap { day in
                    modelBucketsByDay[calendar.startOfDay(for: day.date)] ?? []
                }
                : ModelUsagePresentation.rows(from: attributionEvents.filter {
                    $0.start >= start && $0.start < end
                })
            let hasMissingModelDetail = mode == .modelCost && days.contains { day in
                day.tokens > 0 && modelBucketsByDay[calendar.startOfDay(for: day.date)] == nil
            }
            let cost = mode == .modelCost && !hasMissingModelDetail
                ? FloatingTodayModelUsagePresentation.items(
                    from: rows,
                    fallbackModel: fallbackModel
                ).compactMap(\.costUSD).reduce(0, +)
                : nil
            return HeatmapRangeSummary(
                title: title,
                dayCount: days.count,
                tokens: days.reduce(0) { $0 + $1.tokens },
                calls: days.reduce(0) { $0 + $1.calls },
                cacheBreakdown: nil,
                quotaAverageRemainingPercent: nil,
                modelBreakdowns: rows,
                modelCostUSD: cost,
                isModelCost: mode == .modelCost
            )
        }

        let tokenTotal = days.reduce(0) { $0 + $1.tokens }
        let callTotal = days.reduce(0) { $0 + $1.calls }
        return HeatmapRangeSummary(
            title: title,
            dayCount: days.count,
            tokens: tokenTotal,
            calls: callTotal,
            cacheBreakdown: nil,
            quotaAverageRemainingPercent: nil
        )
    }

    private func modelCostAccessibilityText(_ rows: [ModelTokenBreakdown]) -> String {
        let items = FloatingTodayModelUsagePresentation.items(
            from: rows,
            fallbackModel: fallbackModel
        )
        guard !items.isEmpty else { return "暂无模型明细" }
        return items.map { item in
            "\(item.label) \(item.valueText(for: .cost))"
        }.joined(separator: "，")
    }

    private func rangeTitle(first: Date, last: Date) -> String {
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return DateFormatter.fullDay.string(from: first)
        }
        return "\(DateFormatter.fullDay.string(from: first)) - \(DateFormatter.fullDay.string(from: last))"
    }

}

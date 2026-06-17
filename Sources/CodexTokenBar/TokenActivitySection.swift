import SwiftUI

struct ActivitySection: View {
    let dailyUsage: [DayUsage]
    let cacheDaily: [TokenCacheBucket]
    let quotaDaily: [QuotaHistoryDailyBucket]
    @Binding var selectedMode: ActivityMode

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Token 活动")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                ActivityModeSelector(selectedMode: $selectedMode)
            }

            TokenHeatmap(dailyUsage: dailyUsage, cacheDaily: cacheDaily, quotaDaily: quotaDaily, mode: selectedMode)
        }
        .frame(maxWidth: 980)
    }
}

struct ActivityModeSelector: View {
    @Binding var selectedMode: ActivityMode

    private let regularModes: [ActivityMode] = [.daily, .weekly, .cumulative]
    private let specialModes: [ActivityMode] = [.cacheHitRate, .quotaRemaining]

    var body: some View {
        HStack(spacing: 4) {
            Text("模式")
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            HStack(spacing: 2) {
                ForEach(regularModes) { mode in
                    modeButton(mode, width: 42)
                }

                HStack(spacing: 2) {
                    ForEach(specialModes) { mode in
                        modeButton(mode, width: 42, groupedSpecial: true)
                    }
                }
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.accentBlue.opacity(0.26), lineWidth: 1)
                )
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.raisedBackground)
            )
        }
    }

    private func modeButton(_ mode: ActivityMode, width: CGFloat, groupedSpecial: Bool = false) -> some View {
        Button {
            selectedMode = mode
        } label: {
            Text(mode.rawValue)
                .font(.system(size: groupedSpecial ? 12 : 13, weight: selectedMode == mode ? .semibold : .medium))
                .foregroundStyle(labelColor(for: mode))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: width, height: 25)
                .background(background(for: mode))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Token 活动模式 \(mode.rawValue)")
        .accessibilityValue(selectedMode == mode ? "已选择" : "未选择")
        .accessibilityHint("切换 Token 活动显示模式")
    }

    private func labelColor(for mode: ActivityMode) -> Color {
        return .primary
    }

    @ViewBuilder
    private func background(for mode: ActivityMode) -> some View {
        if selectedMode == mode {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppTheme.accentBlue.opacity(mode.isSpecial ? 0.13 : 0.18))
        } else {
            Color.clear
        }
    }
}

private struct HeatmapMonthMarker: Identifiable {
    let label: String
    let column: Int
    let nextColumn: Int

    var id: String {
        "\(label)-\(column)"
    }
}

private struct HeatmapPreparedData {
    let summaries: [HeatmapUsageSummary]
    let maxTokens: Int
    let columns: [[Int]]
    let monthMarkers: [HeatmapMonthMarker]

    static let empty = HeatmapPreparedData(summaries: [], maxTokens: 1, columns: [], monthMarkers: [])
}

struct TokenHeatmap: View {
    let dailyUsage: [DayUsage]
    let cacheDaily: [TokenCacheBucket]
    let quotaDaily: [QuotaHistoryDailyBucket]
    let mode: ActivityMode
    @State private var hoveredIndex: Int?
    @State private var rangeStartIndex: Int?
    @State private var rangeEndIndex: Int?
    @State private var preparedData: HeatmapPreparedData

    private let rows = 7
    private let gap: CGFloat = 4
    private let trailingInset: CGFloat = 9

    init(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket], quotaDaily: [QuotaHistoryDailyBucket], mode: ActivityMode) {
        self.dailyUsage = dailyUsage
        self.cacheDaily = cacheDaily
        self.quotaDaily = quotaDaily
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
                                            .fill(color(for: summary, maxTokens: preparedData.maxTokens))
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
                    hasRangeStart: rangeStartIndex != nil
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
        .onChange(of: quotaDaily) { _, _ in
            clearRangeSelection()
            refreshPreparedData()
        }
        .onChange(of: mode) { _, _ in
            hoveredIndex = nil
            clearRangeSelection()
            refreshPreparedData()
        }
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

        let value = summary.tokens
        guard value > 0 else { return AppTheme.emptyCell }
        let ratio = min(1.0, Double(value) / Double(max(maxTokens, 1)))
        return AppTheme.heatmapColor(ratio: ratio)
    }

    private func refreshPreparedData() {
        preparedData = Self.prepare(dailyUsage: dailyUsage, cacheDaily: cacheDaily, quotaDaily: quotaDaily, mode: mode)
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

    private func rangeTitle(first: Date, last: Date) -> String {
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return DateFormatter.fullDay.string(from: first)
        }
        return "\(DateFormatter.fullDay.string(from: first)) - \(DateFormatter.fullDay.string(from: last))"
    }

    private static func prepare(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket], quotaDaily: [QuotaHistoryDailyBucket], mode: ActivityMode) -> HeatmapPreparedData {
        let summaries = makeSummaries(dailyUsage: dailyUsage, cacheDaily: cacheDaily, quotaDaily: quotaDaily, mode: mode)
        let columns = makeColumnIndices(dayCount: summaries.count)
        return HeatmapPreparedData(
            summaries: summaries,
            maxTokens: max(summaries.map(\.tokens).max() ?? 1, 1),
            columns: columns,
            monthMarkers: monthMarkers(dailyUsage: dailyUsage, endColumn: max(columns.count, 1))
        )
    }

    private static func makeColumnIndices(dayCount: Int) -> [[Int]] {
        stride(from: 0, to: dayCount, by: 7).map { start in
            Array(start..<min(start + 7, dayCount))
        }
    }

    private static func makeSummaries(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket], quotaDaily: [QuotaHistoryDailyBucket], mode: ActivityMode) -> [HeatmapUsageSummary] {
        switch mode {
        case .daily:
            return dailyUsage.map { day in
                HeatmapUsageSummary(
                    title: DateFormatter.fullDay.string(from: day.date),
                    tokens: day.tokens,
                    calls: day.calls,
                    iconName: "calendar"
                )
            }
        case .weekly:
            return weeklySummaries(dailyUsage: dailyUsage)
        case .cumulative:
            var runningTokens = 0
            var runningCalls = 0
            return dailyUsage.map { day in
                runningTokens += day.tokens
                runningCalls += day.calls
                return HeatmapUsageSummary(
                    title: "截至 \(DateFormatter.fullDay.string(from: day.date))",
                    tokens: runningTokens,
                    calls: runningCalls,
                    iconName: "sum"
                )
            }
        case .cacheHitRate:
            return cacheHitRateSummaries(dailyUsage: dailyUsage, cacheDaily: cacheDaily)
        case .quotaRemaining:
            return quotaRemainingSummaries(dailyUsage: dailyUsage, quotaDaily: quotaDaily)
        }
    }

    private static func quotaRemainingSummaries(dailyUsage: [DayUsage], quotaDaily: [QuotaHistoryDailyBucket]) -> [HeatmapUsageSummary] {
        let calendar = Calendar.current
        let quotaByDay = Dictionary(uniqueKeysWithValues: quotaDaily.map { bucket in
            (calendar.startOfDay(for: bucket.date), bucket)
        })

        return dailyUsage.map { day in
            let date = calendar.startOfDay(for: day.date)
            let bucket = quotaByDay[date]
            return HeatmapUsageSummary(
                title: DateFormatter.fullDay.string(from: day.date),
                tokens: Int((bucket?.sevenDayRemainingPercent ?? 0).rounded()),
                calls: bucket?.sampleCount ?? 0,
                iconName: "gauge.with.dots.needle.67percent",
                quotaRemainingPercent: bucket?.sevenDayRemainingPercent,
                isQuotaRemaining: true
            )
        }
    }

    private static func cacheHitRateSummaries(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket]) -> [HeatmapUsageSummary] {
        let calendar = Calendar.current
        let cacheByDay = Dictionary(uniqueKeysWithValues: cacheDaily.map { bucket in
            (calendar.startOfDay(for: bucket.start), bucket.breakdown)
        })

        return dailyUsage.map { day in
            let date = calendar.startOfDay(for: day.date)
            let breakdown = cacheByDay[date]
            return HeatmapUsageSummary(
                title: DateFormatter.fullDay.string(from: day.date),
                tokens: breakdown?.totalTokens ?? 0,
                calls: breakdown?.calls ?? 0,
                iconName: "bolt.horizontal.circle",
                cacheBreakdown: breakdown,
                isCacheRate: true
            )
        }
    }

    private static func weeklySummaries(dailyUsage: [DayUsage]) -> [HeatmapUsageSummary] {
        let calendar = Calendar.current
        var weekTotals: [String: (tokens: Int, calls: Int, first: Date, last: Date)] = [:]

        for day in dailyUsage {
            let key = "\(calendar.component(.yearForWeekOfYear, from: day.date))-\(calendar.component(.weekOfYear, from: day.date))"
            if let current = weekTotals[key] {
                weekTotals[key] = (
                    current.tokens + day.tokens,
                    current.calls + day.calls,
                    min(current.first, day.date),
                    max(current.last, day.date)
                )
            } else {
                weekTotals[key] = (day.tokens, day.calls, day.date, day.date)
            }
        }

        return dailyUsage.map { day in
            let key = "\(calendar.component(.yearForWeekOfYear, from: day.date))-\(calendar.component(.weekOfYear, from: day.date))"
            let total = weekTotals[key] ?? (day.tokens, day.calls, day.date, day.date)
            return HeatmapUsageSummary(
                title: "\(DateFormatter.monthDay.string(from: total.first)) - \(DateFormatter.monthDay.string(from: total.last))",
                tokens: total.tokens,
                calls: total.calls,
                iconName: "calendar.badge.clock"
            )
        }
    }

    private static func monthMarkers(dailyUsage: [DayUsage], endColumn: Int) -> [HeatmapMonthMarker] {
        guard !dailyUsage.isEmpty else { return [] }

        var markers: [HeatmapMonthMarker] = []
        var previousMonth = -1
        let calendar = Calendar.current

        for (index, day) in dailyUsage.enumerated() {
            let month = calendar.component(.month, from: day.date)
            guard month != previousMonth else { continue }

            previousMonth = month
            let column = index / 7
            let nextColumn = nextMonthColumn(after: index, dailyUsage: dailyUsage) ?? endColumn
            markers.append(HeatmapMonthMarker(label: "\(month)月", column: column, nextColumn: nextColumn))
        }

        return markers
    }

    private static func nextMonthColumn(after index: Int, dailyUsage: [DayUsage]) -> Int? {
        guard index < dailyUsage.count else { return nil }
        let calendar = Calendar.current
        let month = calendar.component(.month, from: dailyUsage[index].date)
        for next in (index + 1)..<dailyUsage.count {
            let nextMonth = calendar.component(.month, from: dailyUsage[next].date)
            if nextMonth != month {
                return next / 7
            }
        }
        return nil
    }

}

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

private struct MonthLabels: View {
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

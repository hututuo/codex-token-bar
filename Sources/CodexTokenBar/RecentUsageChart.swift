import SwiftUI

enum RecentChartRange: String, CaseIterable, Identifiable {
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twentyFourHours: "24 小时窗口"
        case .sevenDays: "7 天窗口"
        case .thirtyDays: "30 天窗口"
        }
    }

    var label: String {
        switch self {
        case .twentyFourHours: "24h"
        case .sevenDays: "7d"
        case .thirtyDays: "30d"
        }
    }

    var subtitle: String {
        switch self {
        case .twentyFourHours: "5 分钟粒度 · 横向滚动查看 30 天内历史"
        case .sevenDays: "1 小时粒度 · 横向滚动查看历史"
        case .thirtyDays: "3 小时粒度 · 横向滚动查看历史"
        }
    }

    var bucketInterval: TimeInterval {
        switch self {
        case .twentyFourHours: 5 * 60
        case .sevenDays: 60 * 60
        case .thirtyDays: 3 * 60 * 60
        }
    }
}

enum RecentChartScrollMetrics {
    static let trailingAnchorID = "recent-chart-trailing-edge"

    static func contentWidth(
        range: RecentChartRange,
        bins: [BinUsage],
        bucketInterval: TimeInterval,
        viewportWidth: CGFloat
    ) -> CGFloat {
        guard let first = bins.first,
              let last = bins.last,
              viewportWidth > 0 else {
            return viewportWidth
        }

        let viewportDuration = windowDuration(for: range)
        let contentDuration = max(
            last.start.addingTimeInterval(bucketInterval).timeIntervalSince(first.start),
            viewportDuration
        )
        return max(viewportWidth, viewportWidth * CGFloat(contentDuration / viewportDuration))
    }

    static func windowDuration(for range: RecentChartRange) -> TimeInterval {
        switch range {
        case .twentyFourHours:
            return 24 * 60 * 60
        case .sevenDays:
            return 7 * 24 * 60 * 60
        case .thirtyDays:
            return 30 * 24 * 60 * 60
        }
    }
}

struct RecentChartPreparedData {
    let range: RecentChartRange
    let bins: [BinUsage]
    let bucketInterval: TimeInterval
    let maxTokens: Int
    let maxCalls: Int
    let tokenTotal: Int
    let callTotal: Int
    let recentCacheBreakdown: TokenCacheBreakdown
    let cacheBreakdowns: [TokenCacheBreakdown]
    let carriedCacheHitRates: [Double]
    let fiveHourRemainingPercents: [Double?]
    let sevenDayRemainingPercents: [Double?]
    let latestFiveHourRemaining: Double?
    let latestSevenDayRemaining: Double?
    let hasCacheCalls: Bool
    let hasFiveHourQuota: Bool
    let hasSevenDayQuota: Bool
    let markerIndices: [Int]

    static let empty = RecentChartPreparedData(
        range: .twentyFourHours,
        bins: [],
        bucketInterval: RecentChartRange.twentyFourHours.bucketInterval,
        maxTokens: 1,
        maxCalls: 1,
        tokenTotal: 0,
        callTotal: 0,
        recentCacheBreakdown: .empty,
        cacheBreakdowns: [],
        carriedCacheHitRates: [],
        fiveHourRemainingPercents: [],
        sevenDayRemainingPercents: [],
        latestFiveHourRemaining: nil,
        latestSevenDayRemaining: nil,
        hasCacheCalls: false,
        hasFiveHourQuota: false,
        hasSevenDayQuota: false,
        markerIndices: []
    )
}

private struct RecentChartPlotData {
    let tokenPoints: [CGPoint]
    let callPoints: [CGPoint]
    let cachePoints: [CGPoint]
    let fiveHourQuotaPoints: [CGPoint?]
    let sevenDayQuotaPoints: [CGPoint?]

    init(bins: [BinUsage], prepared: RecentChartPreparedData, plot: CGRect, step: CGFloat) {
        tokenPoints = bins.indices.map { index in
            let x = plot.minX + CGFloat(index) * step
            let y = plot.maxY - CGFloat(bins[index].tokens) / CGFloat(prepared.maxTokens) * plot.height
            return CGPoint(x: x, y: y)
        }
        callPoints = bins.indices.map { index in
            let x = plot.minX + CGFloat(index) * step
            let y = plot.maxY - CGFloat(bins[index].calls) / CGFloat(prepared.maxCalls) * plot.height
            return CGPoint(x: x, y: y)
        }
        cachePoints = bins.indices.map { index in
            let x = plot.minX + CGFloat(index) * step
            let rate = prepared.carriedCacheHitRates[safe: index] ?? 0
            let y = plot.maxY - CGFloat(rate) * plot.height
            return CGPoint(x: x, y: y)
        }
        fiveHourQuotaPoints = bins.indices.map { index in
            guard let value = prepared.fiveHourRemainingPercents[safe: index],
                  let percent = value else { return nil }
            let x = plot.minX + CGFloat(index) * step
            let y = plot.maxY - CGFloat(max(0, min(100, percent)) / 100.0) * plot.height
            return CGPoint(x: x, y: y)
        }
        sevenDayQuotaPoints = bins.indices.map { index in
            guard let value = prepared.sevenDayRemainingPercents[safe: index],
                  let percent = value else { return nil }
            let x = plot.minX + CGFloat(index) * step
            let y = plot.maxY - CGFloat(max(0, min(100, percent)) / 100.0) * plot.height
            return CGPoint(x: x, y: y)
        }
    }
}

let recentChartHoverBubbleVerticalOffset: CGFloat = 50

struct RecentUsageChart: View {
    let bins: [BinUsage]
    let hourlyBins: [BinUsage]
    let cacheRecentBins: [TokenCacheBucket]
    let cacheHourlyBins: [TokenCacheBucket]
    let quotaRecentBins: [QuotaHistoryRecentBucket]
    let quotaHourlyBins: [QuotaHistoryRecentBucket]
    private static let dataLineWidth: CGFloat = 1.55
    private static let hoverRingLineWidth: CGFloat = 1.55
    @AppStorage("recentChartRange") private var selectedRangeRaw = RecentChartRange.twentyFourHours.rawValue
    @AppStorage("recentChartShowTokens") private var showTokens = true
    @AppStorage("recentChartShowCalls") private var showCalls = true
    @AppStorage("recentChartShowCacheHitRate") private var showCacheHitRate = true
    @AppStorage("recentChartShowFiveHourQuota") private var showFiveHourQuota = true
    @AppStorage("recentChartShowSevenDayQuota") private var showSevenDayQuota = true
    @AppStorage("recentChartQuotaEstimateModel") private var quotaEstimateModelRaw = OfficialAPIPriceModel.gpt55.rawValue
    @State private var hoveredIndex: Int?
    @State private var consumptionSelectionState = RecentChartConsumptionSelectionState()
    @State var preparedData: RecentChartPreparedData

    init(
        bins: [BinUsage],
        hourlyBins: [BinUsage],
        cacheRecentBins: [TokenCacheBucket],
        cacheHourlyBins: [TokenCacheBucket],
        quotaRecentBins: [QuotaHistoryRecentBucket],
        quotaHourlyBins: [QuotaHistoryRecentBucket]
    ) {
        self.bins = bins
        self.hourlyBins = hourlyBins
        self.cacheRecentBins = cacheRecentBins
        self.cacheHourlyBins = cacheHourlyBins
        self.quotaRecentBins = quotaRecentBins
        self.quotaHourlyBins = quotaHourlyBins
        _preparedData = State(initialValue: .empty)
    }

    private var selectedRange: RecentChartRange {
        RecentChartRange(rawValue: selectedRangeRaw) ?? .twentyFourHours
    }

    private var selectedRangeBinding: Binding<RecentChartRange> {
        Binding(
            get: { selectedRange },
            set: { range in
                selectedRangeRaw = range.rawValue
                hoveredIndex = nil
            }
        )
    }

    private var chartHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(selectedRange.title)
                        .font(.system(size: 19, weight: .semibold))
                    Label(RecentChartQuotaEstimateAffordancePresentation.headerLabel, systemImage: "cursorarrow.click.2")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(AppTheme.accentBlue.opacity(0.10), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(AppTheme.accentBlue.opacity(0.28), lineWidth: 1)
                        )
                        .help(RecentChartQuotaEstimateAffordancePresentation.headerHelp)
                }
                Text(selectedRange.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(RecentChartQuotaEstimateAffordancePresentation.inlineInstruction)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.accentBlue.opacity(0.82))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 8) {
                    RecentChartQuotaEstimateModelSelector(selectedModel: selectedQuotaEstimateModelBinding)
                    RecentChartRangeSelector(selection: selectedRangeBinding)
                }

                HStack(spacing: 14) {
                    ChartLegend(color: .blue, label: "Token", value: preparedData.tokenTotal.abbreviatedTokens)
                    ChartLegend(color: .orange, label: "调用", value: "\(preparedData.callTotal)")
                    ChartLegend(color: AppTheme.accentCyan, label: "命中率", value: preparedData.recentCacheBreakdown.cacheHitRate.percentString)
                    ChartLegend(color: .purple, label: "5h", value: Self.percentText(preparedData.latestFiveHourRemaining))
                    ChartLegend(color: .green, label: "7d", value: Self.percentText(preparedData.latestSevenDayRemaining))
                }

                HStack(spacing: 5) {
                    ChartLineToggle(title: "Token", color: .blue, isOn: $showTokens)
                    ChartLineToggle(title: "调用", color: .orange, isOn: $showCalls)
                    ChartLineToggle(title: "命中率", color: AppTheme.accentCyan, isOn: $showCacheHitRate)
                    ChartLineToggle(title: "5h", color: .purple, isOn: $showFiveHourQuota)
                    ChartLineToggle(title: "7d", color: .green, isOn: $showSevenDayQuota)
                }
            }
        }
    }

    private var chartPlot: some View {
        GeometryReader { proxy in
            let contentWidth = RecentChartScrollMetrics.contentWidth(
                range: selectedRange,
                bins: preparedData.bins,
                bucketInterval: preparedData.bucketInterval,
                viewportWidth: proxy.size.width
            )

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: contentWidth > proxy.size.width + 1) {
                    HStack(spacing: 0) {
                        chartPlotCanvas(width: contentWidth, height: proxy.size.height)
                            .frame(width: contentWidth, height: proxy.size.height)

                        Color.clear
                            .frame(width: 1, height: 1)
                            .id(RecentChartScrollMetrics.trailingAnchorID)
                    }
                }
                .scrollClipDisabled()
                .onAppear {
                    scrollChartToLatestIfNeeded(scrollProxy)
                }
                .onChange(of: selectedRangeRaw) { _, _ in
                    scrollChartToLatestIfNeeded(scrollProxy)
                }
                .onChange(of: preparedData.bins.count) { _, _ in
                    scrollChartToLatestIfNeeded(scrollProxy)
                }
            }
        }
        .frame(height: 185)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(selectedRange.title) 曲线图")
        .accessibilityValue(accessibilitySummary)
    }

    @ViewBuilder
    private func chartPlotCanvas(width: CGFloat, height: CGFloat) -> some View {
        let plot = CGRect(x: 0, y: 18, width: width, height: max(height - 42, 1))
        let chartBins = preparedData.bins
        let step = plot.width / CGFloat(max(chartBins.count - 1, 1))
        let activeIndex = hoveredIndex.flatMap { chartBins.indices.contains($0) ? $0 : nil }
        let consumptionSelection = activeConsumptionSelection
        let plotData = RecentChartPlotData(bins: chartBins, prepared: preparedData, plot: plot, step: step)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.accentBlue.opacity(0.10), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: plot.width, height: plot.height)
                .offset(x: plot.minX, y: plot.minY)

            if let consumptionSelection {
                let lowerX = plot.minX + CGFloat(consumptionSelection.startIndex) * step
                let upperX = plot.minX + CGFloat(consumptionSelection.endIndex) * step
                Rectangle()
                    .fill(AppTheme.accentBlue.opacity(0.10))
                    .frame(width: max(abs(upperX - lowerX), 2), height: plot.height)
                    .position(x: (lowerX + upperX) / 2, y: plot.midY)

                Path { path in
                    path.move(to: CGPoint(x: lowerX, y: plot.minY))
                    path.addLine(to: CGPoint(x: lowerX, y: plot.maxY))
                }
                .stroke(AppTheme.accentBlue.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [4, 5]))

                RecentChartQuotaEstimateOverlay(
                    selection: consumptionSelection,
                    onClose: {
                        consumptionSelectionState.reset()
                    }
                )
                    .position(x: plot.minX + 205, y: plot.minY - 58)
                    .zIndex(12)
            }

            ForEach(0..<4, id: \.self) { line in
                let y = plot.minY + CGFloat(line) * plot.height / 3
                Path { path in
                    path.move(to: CGPoint(x: plot.minX, y: y))
                    path.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
                .stroke(AppTheme.grid, style: StrokeStyle(lineWidth: 1, dash: [4, 8]))
            }

            if showTokens {
                tokenAreaPath(points: plotData.tokenPoints, plot: plot)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.accentBlue.opacity(0.22), AppTheme.accentBlue.opacity(0.055), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                linePath(points: plotData.tokenPoints)
                    .stroke(AppTheme.accentBlue, style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round))
            }

            if showCalls {
                linePath(points: plotData.callPoints)
                    .stroke(AppTheme.accentOrange, style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round))
            }

            if showCacheHitRate && preparedData.hasCacheCalls {
                linePath(points: plotData.cachePoints)
                    .stroke(AppTheme.accentCyan, style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round, dash: [5, 5]))
            }

            if showFiveHourQuota && preparedData.hasFiveHourQuota {
                optionalLinePath(points: plotData.fiveHourQuotaPoints)
                    .stroke(.purple.opacity(0.92), style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round, dash: [3, 6]))
            }

            if showSevenDayQuota && preparedData.hasSevenDayQuota {
                optionalLinePath(points: plotData.sevenDayQuotaPoints)
                    .stroke(.green.opacity(0.88), style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round, dash: [7, 5]))
            }

            if let activeIndex {
                let tokenPoint = plotData.tokenPoints[safe: activeIndex] ?? .zero
                let callPoint = plotData.callPoints[safe: activeIndex] ?? .zero
                let cachePoint = plotData.cachePoints[safe: activeIndex] ?? .zero
                let fiveHourPoint = plotData.fiveHourQuotaPoints[safe: activeIndex] ?? nil
                let sevenDayPoint = plotData.sevenDayQuotaPoints[safe: activeIndex] ?? nil

                Path { path in
                    path.move(to: CGPoint(x: tokenPoint.x, y: plot.minY))
                    path.addLine(to: CGPoint(x: tokenPoint.x, y: plot.maxY))
                }
                .stroke(AppTheme.accentBlue.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))

                if showTokens {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(AppTheme.accentBlue, lineWidth: Self.hoverRingLineWidth))
                        .position(tokenPoint)
                }

                if showCalls {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(AppTheme.accentOrange, lineWidth: Self.hoverRingLineWidth))
                        .position(callPoint)
                }

                if showCacheHitRate && preparedData.cacheBreakdowns[safe: activeIndex]?.calls ?? 0 > 0 {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(AppTheme.accentCyan, lineWidth: Self.hoverRingLineWidth))
                        .position(cachePoint)
                }

                if showFiveHourQuota, let fiveHourPoint {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.purple, lineWidth: Self.hoverRingLineWidth))
                        .position(fiveHourPoint)
                }

                if showSevenDayQuota, let sevenDayPoint {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.green, lineWidth: Self.hoverRingLineWidth))
                        .position(sevenDayPoint)
                }

                ChartHoverBubble(
                    bin: chartBins[activeIndex],
                    cacheBreakdown: preparedData.cacheBreakdowns[safe: activeIndex],
                    fiveHourRemaining: preparedData.fiveHourRemainingPercents[safe: activeIndex] ?? nil,
                    sevenDayRemaining: preparedData.sevenDayRemainingPercents[safe: activeIndex] ?? nil,
                    bucketInterval: preparedData.bucketInterval,
                    isHovering: true
                )
                    .chartBubblePlacement(tokenX: tokenPoint.x, plot: plot)
                    .zIndex(10)
            }

            HoverTrackingArea(
                onMove: { location in
                    let plotLocation = CGPoint(
                        x: location.x + plot.minX,
                        y: location.y + plot.minY
                    )
                    hoveredIndex = hoverIndex(at: plotLocation, in: plot, step: step)
                },
                onClick: { location in
                    let plotLocation = CGPoint(
                        x: location.x + plot.minX,
                        y: location.y + plot.minY
                    )
                    guard let clickedIndex = hoverIndex(at: plotLocation, in: plot, step: step),
                          preparedData.bins.indices.contains(clickedIndex) else { return }
                    hoveredIndex = clickedIndex
                    consumptionSelectionState.click(index: clickedIndex, validCount: preparedData.bins.count)
                },
                onExit: {
                    hoveredIndex = nil
                }
            )
            .frame(width: plot.width, height: plot.height)
            .position(x: plot.midX, y: plot.midY)

            ChartTimeMarkers(
                bins: chartBins,
                markerIndices: preparedData.markerIndices,
                range: preparedData.range,
                plot: plot
            )
        }
        .frame(width: width, height: height)
    }

    private func scrollChartToLatestIfNeeded(_ proxy: ScrollViewProxy) {
        guard preparedData.bins.count > 1 else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(RecentChartScrollMetrics.trailingAnchorID, anchor: .trailing)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            chartHeader
            chartPlot
        }
        .frame(maxWidth: 980)
        .onAppear(perform: refreshPreparedData)
        .onChange(of: bins) { _, _ in
            clampConsumptionSelection()
            refreshPreparedData()
        }
        .onChange(of: hourlyBins) { _, _ in
            refreshPreparedData()
        }
        .onChange(of: cacheRecentBins) { _, _ in
            refreshPreparedData()
        }
        .onChange(of: cacheHourlyBins) { _, _ in
            refreshPreparedData()
        }
        .onChange(of: quotaRecentBins) { _, _ in
            refreshPreparedData()
        }
        .onChange(of: quotaHourlyBins) { _, _ in
            refreshPreparedData()
        }
        .onChange(of: selectedRangeRaw) { _, _ in
            hoveredIndex = nil
            consumptionSelectionState.reset()
            refreshPreparedData()
        }
    }


    private var accessibilitySummary: String {
        var visibleSeries: [String] = []
        if showTokens { visibleSeries.append("Token") }
        if showCalls { visibleSeries.append("调用") }
        if showCacheHitRate, preparedData.hasCacheCalls { visibleSeries.append("命中率") }
        if showFiveHourQuota, preparedData.hasFiveHourQuota { visibleSeries.append("5 小时额度") }
        if showSevenDayQuota, preparedData.hasSevenDayQuota { visibleSeries.append("7 天额度") }

        return [
            "\(preparedData.bins.count) 个时间点",
            "Token 总量 \(preparedData.tokenTotal.abbreviatedTokens)",
            "调用 \(preparedData.callTotal) 次",
            "缓存命中率 \(preparedData.recentCacheBreakdown.cacheHitRate.percentString)",
            "5 小时额度 \(Self.percentText(preparedData.latestFiveHourRemaining))",
            "7 天额度 \(Self.percentText(preparedData.latestSevenDayRemaining))",
            "已显示 \(visibleSeries.isEmpty ? "无曲线" : visibleSeries.joined(separator: "、"))"
        ].joined(separator: "；")
    }

    private func refreshPreparedData() {
        refreshPreparedData(range: selectedRange)
    }

    private func refreshPreparedData(range: RecentChartRange) {
        preparedData = Self.prepare(
            range: range,
            recentBins: bins,
            hourlyBins: hourlyBins,
            cacheRecentBins: cacheRecentBins,
            cacheHourlyBins: cacheHourlyBins,
            quotaRecentBins: quotaRecentBins,
            quotaHourlyBins: quotaHourlyBins
        )
        clampConsumptionSelection()
    }

    private var selectedQuotaEstimateModel: OfficialAPIPriceModel {
        OfficialAPIPriceModel(rawValue: quotaEstimateModelRaw) ?? .gpt55
    }

    private var selectedQuotaEstimateModelBinding: Binding<OfficialAPIPriceModel> {
        Binding(
            get: { selectedQuotaEstimateModel },
            set: { quotaEstimateModelRaw = $0.rawValue }
        )
    }

    private var activeConsumptionSelection: QuotaConsumptionSelection? {
        guard let startIndex = consumptionSelectionState.startIndex,
              !preparedData.bins.isEmpty else { return nil }
        let fallbackEnd = preparedData.bins.index(before: preparedData.bins.endIndex)
        let validHover = hoveredIndex.flatMap { preparedData.bins.indices.contains($0) ? $0 : nil }
        let endIndex = consumptionSelectionState.activeEndIndex(
            hoveredIndex: validHover,
            fallbackEndIndex: fallbackEnd
        ) ?? fallbackEnd
        return preparedData.quotaConsumptionSelection(
            startIndex: startIndex,
            endIndex: endIndex,
            priceCard: .officialAPI(selectedQuotaEstimateModel)
        )
    }

    private func clampConsumptionSelection() {
        consumptionSelectionState.clamp(validCount: preparedData.bins.count)
    }
}

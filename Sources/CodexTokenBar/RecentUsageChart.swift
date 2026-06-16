import SwiftUI

private enum RecentChartRange: String, CaseIterable, Identifiable {
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twentyFourHours: "最近 24 小时"
        case .sevenDays: "最近 7 天"
        case .thirtyDays: "最近 30 天"
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
        case .twentyFourHours: "5 分钟粒度 · 5 分钟自动刷新"
        case .sevenDays: "1 小时粒度 · 5 分钟自动刷新"
        case .thirtyDays: "6 小时粒度 · 5 分钟自动刷新"
        }
    }

    var bucketInterval: TimeInterval {
        switch self {
        case .twentyFourHours: 5 * 60
        case .sevenDays: 60 * 60
        case .thirtyDays: 6 * 60 * 60
        }
    }
}

private struct RecentChartPreparedData {
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

private let recentChartHoverBubbleVerticalOffset: CGFloat = 50

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
    @State private var hoveredIndex: Int?
    @State private var preparedData: RecentChartPreparedData

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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedRange.title)
                        .font(.system(size: 19, weight: .semibold))
                    Text(selectedRange.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 7) {
                    RecentChartRangeSelector(selection: selectedRangeBinding)

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

            GeometryReader { proxy in
                let plot = CGRect(x: 0, y: 18, width: proxy.size.width, height: proxy.size.height - 42)
                let chartBins = preparedData.bins
                let step = plot.width / CGFloat(max(chartBins.count - 1, 1))
                let activeIndex = hoveredIndex.flatMap { chartBins.indices.contains($0) ? $0 : nil }
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
            }
            .frame(height: 185)
        }
        .frame(maxWidth: 980)
        .onAppear(perform: refreshPreparedData)
        .onChange(of: bins) { _, _ in
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
            refreshPreparedData()
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        Path { path in
            appendSmoothPolyline(points, to: &path)
        }
    }

    private func tokenAreaPath(points: [CGPoint], plot: CGRect) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: plot.maxY))
        path.addLine(to: first)
        appendSmoothPolyline(points, to: &path, moveToStart: false)
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.addLine(to: CGPoint(x: last.x, y: plot.maxY))
        path.closeSubpath()
        return path
    }

    private func optionalLinePath(points: [CGPoint?]) -> Path {
        var path = Path()
        var segment: [CGPoint] = []

        for point in points {
            guard let point else {
                if !segment.isEmpty {
                    appendSmoothPolyline(segment, to: &path)
                    segment.removeAll(keepingCapacity: true)
                }
                continue
            }
            segment.append(point)
        }

        if !segment.isEmpty {
            appendSmoothPolyline(segment, to: &path)
        }
        return path
    }

    private func appendSmoothPolyline(_ points: [CGPoint], to path: inout Path, moveToStart: Bool = true) {
        guard let first = points.first else { return }
        if moveToStart {
            path.move(to: first)
        }

        guard points.count > 2 else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return
        }

        guard let slopes = monotoneSlopes(for: points) else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return
        }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let dx = end.x - start.x
            guard dx > .ulpOfOne else {
                path.addLine(to: end)
                continue
            }

            let controlDistance = dx / 3
            path.addCurve(
                to: end,
                control1: CGPoint(
                    x: start.x + controlDistance,
                    y: start.y + slopes[index] * controlDistance
                ),
                control2: CGPoint(
                    x: end.x - controlDistance,
                    y: end.y - slopes[index + 1] * controlDistance
                )
            )
        }
    }

    private func monotoneSlopes(for points: [CGPoint]) -> [CGFloat]? {
        guard points.count > 2 else { return nil }

        // Shape-preserving slopes keep smoothing from inventing peaks between adjacent bins.
        var intervals: [CGFloat] = []
        var deltas: [CGFloat] = []
        for index in 0..<(points.count - 1) {
            let dx = points[index + 1].x - points[index].x
            guard dx > .ulpOfOne else { return nil }
            intervals.append(dx)
            deltas.append((points[index + 1].y - points[index].y) / dx)
        }

        var slopes = Array(repeating: CGFloat.zero, count: points.count)
        slopes[0] = endpointSlope(
            edgeInterval: intervals[0],
            neighborInterval: intervals[1],
            edgeDelta: deltas[0],
            neighborDelta: deltas[1]
        )
        slopes[points.count - 1] = endpointSlope(
            edgeInterval: intervals[intervals.count - 1],
            neighborInterval: intervals[intervals.count - 2],
            edgeDelta: deltas[deltas.count - 1],
            neighborDelta: deltas[deltas.count - 2]
        )

        for index in 1..<(points.count - 1) {
            let left = deltas[index - 1]
            let right = deltas[index]
            guard left != 0, right != 0, (left > 0) == (right > 0) else {
                slopes[index] = 0
                continue
            }

            let leftInterval = intervals[index - 1]
            let rightInterval = intervals[index]
            let leftWeight = 2 * rightInterval + leftInterval
            let rightWeight = rightInterval + 2 * leftInterval
            slopes[index] = (leftWeight + rightWeight) / (leftWeight / left + rightWeight / right)
        }

        for index in 0..<deltas.count {
            let delta = deltas[index]
            guard delta != 0 else {
                slopes[index] = 0
                slopes[index + 1] = 0
                continue
            }

            let alpha = slopes[index] / delta
            let beta = slopes[index + 1] / delta
            if alpha < 0 || beta < 0 {
                if alpha < 0 { slopes[index] = 0 }
                if beta < 0 { slopes[index + 1] = 0 }
                continue
            }

            let magnitude = alpha * alpha + beta * beta
            if magnitude > 9 {
                let scale = 3 / magnitude.squareRoot()
                slopes[index] = scale * alpha * delta
                slopes[index + 1] = scale * beta * delta
            }
        }

        return slopes
    }

    private func endpointSlope(
        edgeInterval: CGFloat,
        neighborInterval: CGFloat,
        edgeDelta: CGFloat,
        neighborDelta: CGFloat
    ) -> CGFloat {
        guard edgeDelta != 0 else { return 0 }

        let slope = ((2 * edgeInterval + neighborInterval) * edgeDelta - edgeInterval * neighborDelta) / (edgeInterval + neighborInterval)
        if (slope > 0) != (edgeDelta > 0) {
            return 0
        }
        if (edgeDelta > 0) != (neighborDelta > 0), abs(slope) > abs(3 * edgeDelta) {
            return 3 * edgeDelta
        }
        return slope
    }

    private func hoverIndex(at location: CGPoint, in plot: CGRect, step: CGFloat) -> Int? {
        guard plot.contains(location), !preparedData.bins.isEmpty else { return nil }
        let rawIndex = Int(round((location.x - plot.minX) / max(step, 1)))
        return min(max(rawIndex, preparedData.bins.startIndex), preparedData.bins.index(before: preparedData.bins.endIndex))
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
    }

    private static func prepare(
        range: RecentChartRange,
        recentBins: [BinUsage],
        hourlyBins: [BinUsage],
        cacheRecentBins: [TokenCacheBucket],
        cacheHourlyBins: [TokenCacheBucket],
        quotaRecentBins: [QuotaHistoryRecentBucket],
        quotaHourlyBins: [QuotaHistoryRecentBucket]
    ) -> RecentChartPreparedData {
        let bins = usageBins(for: range, recentBins: recentBins, hourlyBins: hourlyBins)
        let cacheBreakdowns = cacheBreakdowns(
            for: range,
            bins: bins,
            cacheRecentBins: cacheRecentBins,
            cacheHourlyBins: cacheHourlyBins
        )
        let carriedRates = carriedCacheHitRates(cacheBreakdowns: cacheBreakdowns)
        let quotaBuckets = quotaBuckets(
            for: range,
            bins: bins,
            quotaRecentBins: quotaRecentBins,
            quotaHourlyBins: quotaHourlyBins
        )
        let fiveHourRemaining = quotaBuckets.map { $0?.fiveHourRemainingPercent }
        let sevenDayRemaining = quotaBuckets.map { $0?.sevenDayRemainingPercent }
        let last = bins.count - 1
        let markerIndices: [Int] = bins.count > 1
            ? [0, last / 4, last / 2, (last * 3) / 4, last].reduce(into: [Int]()) { result, index in
                if !result.contains(index) {
                    result.append(index)
                }
            }
            : []

        return RecentChartPreparedData(
            range: range,
            bins: bins,
            bucketInterval: range.bucketInterval,
            maxTokens: max(bins.map(\.tokens).max() ?? 1, 1),
            maxCalls: max(bins.map(\.calls).max() ?? 1, 1),
            tokenTotal: bins.reduce(0) { $0 + $1.tokens },
            callTotal: bins.reduce(0) { $0 + $1.calls },
            recentCacheBreakdown: cacheBreakdowns.combined,
            cacheBreakdowns: cacheBreakdowns,
            carriedCacheHitRates: carriedRates,
            fiveHourRemainingPercents: fiveHourRemaining,
            sevenDayRemainingPercents: sevenDayRemaining,
            latestFiveHourRemaining: fiveHourRemaining.reversed().compactMap { $0 }.first,
            latestSevenDayRemaining: sevenDayRemaining.reversed().compactMap { $0 }.first,
            hasCacheCalls: cacheBreakdowns.contains { $0.calls > 0 },
            hasFiveHourQuota: fiveHourRemaining.contains { $0 != nil },
            hasSevenDayQuota: sevenDayRemaining.contains { $0 != nil },
            markerIndices: markerIndices
        )
    }

    private static func usageBins(for range: RecentChartRange, recentBins: [BinUsage], hourlyBins: [BinUsage]) -> [BinUsage] {
        switch range {
        case .twentyFourHours:
            return recentBins
        case .sevenDays:
            return Array(hourlyBins.suffix(7 * 24))
        case .thirtyDays:
            return aggregateUsage(Array(hourlyBins.suffix(30 * 24)), groupSize: 6)
        }
    }

    private static func aggregateUsage(_ bins: [BinUsage], groupSize: Int) -> [BinUsage] {
        guard groupSize > 1 else { return bins }
        var result: [BinUsage] = []
        var index = 0
        while index < bins.count {
            let end = min(index + groupSize, bins.count)
            let group = bins[index..<end]
            if let start = group.first?.start {
                result.append(
                    BinUsage(
                        start: start,
                        tokens: group.reduce(0) { $0 + $1.tokens },
                        calls: group.reduce(0) { $0 + $1.calls }
                    )
                )
            }
            index = end
        }
        return result
    }

    private static func cacheBreakdowns(
        for range: RecentChartRange,
        bins: [BinUsage],
        cacheRecentBins: [TokenCacheBucket],
        cacheHourlyBins: [TokenCacheBucket]
    ) -> [TokenCacheBreakdown] {
        switch range {
        case .twentyFourHours:
            let cacheByBin = cacheMap(cacheRecentBins, interval: 5 * 60)
            return bins.map { bin in cacheByBin[timeBinKey(bin.start, interval: 5 * 60)] ?? .empty }
        case .sevenDays:
            let cacheByHour = cacheMap(cacheHourlyBins, interval: 60 * 60)
            return bins.map { bin in cacheByHour[timeBinKey(bin.start, interval: 60 * 60)] ?? .empty }
        case .thirtyDays:
            let cacheByHour = cacheMap(cacheHourlyBins, interval: 60 * 60)
            return bins.map { bin in
                (0..<6).map { offset in
                    let date = bin.start.addingTimeInterval(Double(offset) * 60 * 60)
                    return cacheByHour[timeBinKey(date, interval: 60 * 60)] ?? .empty
                }.combined
            }
        }
    }

    private static func cacheMap(_ buckets: [TokenCacheBucket], interval: TimeInterval) -> [Int: TokenCacheBreakdown] {
        buckets.reduce(into: [Int: TokenCacheBreakdown]()) { result, bucket in
            let key = timeBinKey(bucket.start, interval: interval)
            if let current = result[key] {
                result[key] = [current, bucket.breakdown].combined
            } else {
                result[key] = bucket.breakdown
            }
        }
    }

    private static func quotaBuckets(
        for range: RecentChartRange,
        bins: [BinUsage],
        quotaRecentBins: [QuotaHistoryRecentBucket],
        quotaHourlyBins: [QuotaHistoryRecentBucket]
    ) -> [QuotaHistoryRecentBucket?] {
        switch range {
        case .twentyFourHours:
            let quotaByBin = quotaMap(quotaRecentBins, interval: 5 * 60)
            return bins.map { bin in quotaByBin[timeBinKey(bin.start, interval: 5 * 60)] }
        case .sevenDays:
            let quotaByHour = quotaMap(quotaHourlyBins, interval: 60 * 60)
            return bins.map { bin in quotaByHour[timeBinKey(bin.start, interval: 60 * 60)] }
        case .thirtyDays:
            let quotaByHour = quotaMap(quotaHourlyBins, interval: 60 * 60)
            return bins.map { bin in
                let buckets = (0..<6).compactMap { offset in
                    let date = bin.start.addingTimeInterval(Double(offset) * 60 * 60)
                    return quotaByHour[timeBinKey(date, interval: 60 * 60)]
                }
                return averagedQuotaBucket(start: bin.start, buckets: buckets)
            }
        }
    }

    private static func quotaMap(_ buckets: [QuotaHistoryRecentBucket], interval: TimeInterval) -> [Int: QuotaHistoryRecentBucket] {
        Dictionary(uniqueKeysWithValues: buckets.map { bucket in
            (timeBinKey(bucket.start, interval: interval), bucket)
        })
    }

    private static func averagedQuotaBucket(start: Date, buckets: [QuotaHistoryRecentBucket]) -> QuotaHistoryRecentBucket? {
        let fiveHourValues = buckets.compactMap(\.fiveHourRemainingPercent)
        let sevenDayValues = buckets.compactMap(\.sevenDayRemainingPercent)
        let fiveHour = average(fiveHourValues)
        let sevenDay = average(sevenDayValues)
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return QuotaHistoryRecentBucket(
            start: start,
            fiveHourRemainingPercent: fiveHour,
            sevenDayRemainingPercent: sevenDay
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func timeBinKey(_ date: Date, interval: TimeInterval) -> Int {
        Int(floor(date.timeIntervalSince1970 / interval))
    }

    private static func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    private static func carriedCacheHitRates(cacheBreakdowns: [TokenCacheBreakdown]) -> [Double] {
        var carriedRate = cacheBreakdowns.first(where: { $0.calls > 0 })?.cacheHitRate ?? 0
        return cacheBreakdowns.map { breakdown in
            if breakdown.calls > 0 {
                carriedRate = breakdown.cacheHitRate
                return breakdown.cacheHitRate
            }
            return carriedRate
        }
    }
}

private struct RecentChartRangeSelector: View {
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
    }
}

private extension View {
    func chartBubblePlacement(tokenX: CGFloat, plot: CGRect) -> some View {
        modifier(ChartBubblePlacementModifier(tokenX: tokenX, plot: plot))
    }
}

private struct ChartBubblePlacementModifier: ViewModifier {
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
    }

    private var average: Int {
        bin.calls > 0 ? bin.tokens / bin.calls : 0
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

private struct ChartTimeMarkers: View {
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

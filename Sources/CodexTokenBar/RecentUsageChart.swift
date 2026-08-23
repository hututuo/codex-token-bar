import AppKit
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
        case .sevenDays: "1 小时粒度 · 横向滚动查看 30 天内历史"
        case .thirtyDays: "6 小时粒度"
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

struct RecentChartGeometry: Equatable {
    let canvasHeight: CGFloat
    let plotTop: CGFloat
    let plotHeight: CGFloat
    let timeMarkerOffset: CGFloat
}

extension RecentChartRange {
    var chartGeometry: RecentChartGeometry {
        RecentChartGeometry(
            canvasHeight: 278,
            plotTop: 27,
            plotHeight: 215,
            timeMarkerOffset: 30
        )
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

    static func windowCount(
        range: RecentChartRange,
        bins: [BinUsage],
        bucketInterval: TimeInterval
    ) -> Int {
        guard let first = bins.first,
              let last = bins.last else {
            return 1
        }

        let viewportDuration = windowDuration(for: range)
        let contentDuration = max(
            last.start.addingTimeInterval(bucketInterval).timeIntervalSince(first.start),
            viewportDuration
        )
        return max(1, Int(ceil(contentDuration / viewportDuration)))
    }

    static func anchorID(for index: Int) -> String {
        "recent-chart-window-\(index)"
    }

    static func shiftedWindowIndex(
        current: Int,
        direction: RecentChartScrollDirection,
        windowCount: Int
    ) -> Int {
        let upperBound = max(windowCount - 1, 0)
        return min(max(current + direction.delta, 0), upperBound)
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

enum RecentChartAutoScrollPolicy {
    static func shouldFollowLatest(
        previousBins: [BinUsage],
        updatedBins: [BinUsage],
        wasAtLatest: Bool?
    ) -> Bool {
        guard wasAtLatest != false else { return false }
        guard previousBins.count == updatedBins.count else { return true }
        return zip(previousBins, updatedBins).contains { previous, updated in
            previous.start != updated.start
        }
    }
}

struct RecentChartScrollPresentation: Equatable {
    static let endpointEpsilon: CGFloat = 0.25

    let contentOffset: CGFloat
    let maxOffset: CGFloat
    let viewportWidth: CGFloat
    let currentWindowIndex: Int
    let windowCount: Int
    let isAtOldest: Bool
    let isAtLatest: Bool

    init(
        contentOffset: CGFloat,
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        windowCount: Int,
        epsilon: CGFloat = endpointEpsilon
    ) {
        let safeViewportWidth = max(viewportWidth, 0)
        let safeContentWidth = max(contentWidth, 0)
        let safeWindowCount = max(windowCount, 1)
        let maximum = max(safeContentWidth - safeViewportWidth, 0)
        let clampedOffset = min(max(contentOffset, 0), maximum)
        let safeEpsilon = max(epsilon, 0)
        let upperWindowIndex = safeWindowCount - 1

        self.contentOffset = clampedOffset
        maxOffset = maximum
        self.viewportWidth = safeViewportWidth
        self.windowCount = safeWindowCount
        isAtOldest = clampedOffset <= safeEpsilon
        isAtLatest = maximum - clampedOffset <= safeEpsilon

        if safeViewportWidth > 0 {
            currentWindowIndex = min(
                max(Int(floor((clampedOffset + safeEpsilon) / safeViewportWidth)), 0),
                upperWindowIndex
            )
        } else {
            currentWindowIndex = 0
        }
    }

    func targetWindowIndex(for direction: RecentChartScrollDirection) -> Int {
        RecentChartScrollMetrics.shiftedWindowIndex(
            current: currentWindowIndex,
            direction: direction,
            windowCount: windowCount
        )
    }

    var edgeFadeState: RecentChartEdgeFadeState {
        RecentChartEdgeFadeState(
            showsLeft: windowCount > 1 && !isAtOldest,
            showsRight: windowCount > 1 && !isAtLatest
        )
    }
}

@MainActor
final class RecentChartScrollOffsetObserver: NSObject {
    private var observation: NSObjectProtocol?
    private(set) weak var scrollView: NSScrollView?
    var onOffsetChange: ((CGFloat) -> Void)?

    func attach(to scrollView: NSScrollView) {
        // SwiftUI calls updateNSView while evaluating the view graph. Reporting the same
        // scroll view synchronously from that callback mutates @State during the update and
        // can create an endless redraw loop on a large dashboard snapshot.
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        observation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reportCurrentOffset()
            }
        }
        DispatchQueue.main.async { [weak self, weak scrollView] in
            guard let self, self.scrollView === scrollView else { return }
            self.reportCurrentOffset()
        }
    }

    func detach() {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
        }
        observation = nil
        scrollView = nil
    }

    func reportCurrentOffset() {
        guard let scrollView else { return }
        onOffsetChange?(scrollView.contentView.bounds.origin.x)
    }
}

struct RecentChartScrollOffsetReader: NSViewRepresentable {
    let onOffsetChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObservationView {
        let view = ObservationView()
        view.observer.onOffsetChange = onOffsetChange
        return view
    }

    func updateNSView(_ nsView: ObservationView, context: Context) {
        nsView.observer.onOffsetChange = onOffsetChange
        nsView.attachToEnclosingScrollView()
    }

    static func dismantleNSView(_ nsView: ObservationView, coordinator: Void) {
        nsView.observer.detach()
    }

    final class ObservationView: NSView {
        let observer = RecentChartScrollOffsetObserver()

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attachToEnclosingScrollView()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachToEnclosingScrollView()
        }

        func attachToEnclosingScrollView() {
            guard let enclosingScrollView else { return }
            observer.attach(to: enclosingScrollView)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

enum RecentChartScrollDirection {
    case backward
    case forward

    var delta: Int {
        switch self {
        case .backward: -1
        case .forward: 1
        }
    }

    var systemImage: String {
        switch self {
        case .backward: "chevron.left"
        case .forward: "chevron.right"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .backward: "上一时间窗口"
        case .forward: "下一时间窗口"
        }
    }

    func accessibilityButton(isEnabled: Bool) -> RecentChartAccessibilityButtonPresentation {
        RecentChartAccessibilityButtonPresentation(
            label: accessibilityLabel,
            value: nil,
            isEnabled: isEnabled
        )
    }
}

struct RecentChartEdgeFadeState: Equatable {
    let showsLeft: Bool
    let showsRight: Bool

    init(showsLeft: Bool, showsRight: Bool) {
        self.showsLeft = showsLeft
        self.showsRight = showsRight
    }

    init(currentWindowIndex: Int, windowCount: Int) {
        let upperBound = max(windowCount - 1, 0)
        let clampedIndex = min(max(currentWindowIndex, 0), upperBound)
        showsLeft = windowCount > 1 && clampedIndex > 0
        showsRight = windowCount > 1 && clampedIndex < upperBound
    }
}

struct RecentChartPreparationInput: Equatable {
    let bins: [BinUsage]
    let hourlyBins: [BinUsage]
    let cacheRecentBins: [TokenCacheBucket]
    let cacheHourlyBins: [TokenCacheBucket]
    let attributionEvents: [TokenCacheAttributionEvent]
    let quotaRecentBins: [QuotaHistoryRecentBucket]
    let quotaHourlyBins: [QuotaHistoryRecentBucket]
}

struct RecentChartPreparedData: Equatable {
    let range: RecentChartRange
    let bins: [BinUsage]
    let bucketInterval: TimeInterval
    let maxTokens: Int
    let maxCalls: Int
    let tokenTotal: Int
    let callTotal: Int
    let recentCacheBreakdown: TokenCacheBreakdown
    let cacheBreakdowns: [TokenCacheBreakdown]
    let modelBreakdowns: [[ModelTokenBreakdown]]
    let observedCacheHitRates: [Double?]
    let fiveHourRemainingPercents: [Double?]
    let sevenDayRemainingPercents: [Double?]
    let fiveHourQuotaObservations: [QuotaHistoryObservation]
    let sevenDayQuotaObservations: [QuotaHistoryObservation]
    let quotaObservationProvenanceAvailable: Bool
    let latestFiveHourRemaining: Double?
    let latestSevenDayRemaining: Double?
    let hasCacheCalls: Bool
    let hasFiveHourQuota: Bool
    let hasSevenDayQuota: Bool
    let markerIndices: [Int]

    init(
        range: RecentChartRange,
        bins: [BinUsage],
        bucketInterval: TimeInterval,
        maxTokens: Int,
        maxCalls: Int,
        tokenTotal: Int,
        callTotal: Int,
        recentCacheBreakdown: TokenCacheBreakdown,
        cacheBreakdowns: [TokenCacheBreakdown],
        modelBreakdowns: [[ModelTokenBreakdown]] = [],
        observedCacheHitRates: [Double?],
        fiveHourRemainingPercents: [Double?],
        sevenDayRemainingPercents: [Double?],
        fiveHourQuotaObservations: [QuotaHistoryObservation] = [],
        sevenDayQuotaObservations: [QuotaHistoryObservation] = [],
        quotaObservationProvenanceAvailable: Bool = false,
        latestFiveHourRemaining: Double?,
        latestSevenDayRemaining: Double?,
        hasCacheCalls: Bool,
        hasFiveHourQuota: Bool,
        hasSevenDayQuota: Bool,
        markerIndices: [Int]
    ) {
        self.range = range
        self.bins = bins
        self.bucketInterval = bucketInterval
        self.maxTokens = maxTokens
        self.maxCalls = maxCalls
        self.tokenTotal = tokenTotal
        self.callTotal = callTotal
        self.recentCacheBreakdown = recentCacheBreakdown
        self.cacheBreakdowns = cacheBreakdowns
        self.modelBreakdowns = modelBreakdowns
        self.observedCacheHitRates = observedCacheHitRates
        self.fiveHourRemainingPercents = fiveHourRemainingPercents
        self.sevenDayRemainingPercents = sevenDayRemainingPercents
        self.fiveHourQuotaObservations = Self.normalizedQuotaObservations(
            fiveHourQuotaObservations
        )
        self.sevenDayQuotaObservations = Self.normalizedQuotaObservations(
            sevenDayQuotaObservations
        )
        self.quotaObservationProvenanceAvailable = quotaObservationProvenanceAvailable
        self.latestFiveHourRemaining = latestFiveHourRemaining
        self.latestSevenDayRemaining = latestSevenDayRemaining
        self.hasCacheCalls = hasCacheCalls
        self.hasFiveHourQuota = hasFiveHourQuota
        self.hasSevenDayQuota = hasSevenDayQuota
        self.markerIndices = markerIndices
    }

    private static func normalizedQuotaObservations(
        _ observations: [QuotaHistoryObservation]
    ) -> [QuotaHistoryObservation] {
        let ordered = observations.sorted { lhs, rhs in
            if lhs.observedAt != rhs.observedAt {
                return lhs.observedAt < rhs.observedAt
            }
            return lhs.remainingPercent < rhs.remainingPercent
        }
        var result: [QuotaHistoryObservation] = []
        result.reserveCapacity(ordered.count)
        for observation in ordered {
            if result.last?.observedAt == observation.observedAt {
                result[result.count - 1] = observation
            } else {
                result.append(observation)
            }
        }
        return result
    }

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
        modelBreakdowns: [],
        observedCacheHitRates: [],
        fiveHourRemainingPercents: [],
        sevenDayRemainingPercents: [],
        quotaObservationProvenanceAvailable: true,
        latestFiveHourRemaining: nil,
        latestSevenDayRemaining: nil,
        hasCacheCalls: false,
        hasFiveHourQuota: false,
        hasSevenDayQuota: false,
        markerIndices: []
    )
}

struct RecentChartWindowSummary: Equatable {
    let startIndex: Int
    let endIndex: Int
    let tokenTotal: Int
    let callTotal: Int
    let recentCacheBreakdown: TokenCacheBreakdown
    let latestFiveHourRemaining: Double?
    let latestSevenDayRemaining: Double?
    let hasCacheCalls: Bool

    static let empty = RecentChartWindowSummary(
        startIndex: 0,
        endIndex: -1,
        tokenTotal: 0,
        callTotal: 0,
        recentCacheBreakdown: .empty,
        latestFiveHourRemaining: nil,
        latestSevenDayRemaining: nil,
        hasCacheCalls: false
    )
}

extension RecentChartPreparedData {
    /// Summarize only the time window represented by the current chart viewport.
    /// The prepared bins intentionally retain older history so the plot can be
    /// paged; that history must not inflate the headline values in the header.
    func visibleWindowSummary(
        for presentation: RecentChartScrollPresentation?
    ) -> RecentChartWindowSummary {
        guard !bins.isEmpty else { return .empty }

        let windowBucketCount = max(
            1,
            Int((RecentChartScrollMetrics.windowDuration(for: range) / bucketInterval).rounded())
        )
        let lastIndex = bins.count - 1
        let startIndex: Int
        if let presentation {
            if presentation.isAtLatest {
                startIndex = max(lastIndex - windowBucketCount + 1, 0)
            } else if presentation.isAtOldest {
                startIndex = 0
            } else {
                let contentWidth = max(
                    presentation.maxOffset + presentation.viewportWidth,
                    presentation.viewportWidth
                )
                let step = contentWidth / CGFloat(max(bins.count - 1, 1))
                startIndex = step > 0
                    ? Int((presentation.contentOffset / step).rounded())
                    : max(lastIndex - windowBucketCount + 1, 0)
            }
        } else {
            startIndex = max(lastIndex - windowBucketCount + 1, 0)
        }

        let clampedStartIndex = min(max(startIndex, 0), lastIndex)
        let endIndex = min(clampedStartIndex + windowBucketCount - 1, lastIndex)
        let indices = clampedStartIndex...endIndex
        let cacheBreakdown = indices
            .compactMap { cacheBreakdowns[safe: $0] }
            .combined

        return RecentChartWindowSummary(
            startIndex: clampedStartIndex,
            endIndex: endIndex,
            tokenTotal: indices.reduce(0) { $0 + bins[$1].tokens },
            callTotal: indices.reduce(0) { $0 + bins[$1].calls },
            recentCacheBreakdown: cacheBreakdown,
            latestFiveHourRemaining: indices.reversed().compactMap {
                fiveHourRemainingPercents[safe: $0] ?? nil
            }.first,
            latestSevenDayRemaining: indices.reversed().compactMap {
                sevenDayRemainingPercents[safe: $0] ?? nil
            }.first,
            hasCacheCalls: cacheBreakdown.calls > 0
        )
    }
}

struct RecentChartPlotData: Equatable {
    let renderStartIndex: Int
    let renderEndIndex: Int
    let tokenPoints: [CGPoint]
    let callPoints: [CGPoint]
    let cachePoints: [CGPoint?]
    let costPoints: [CGPoint?]
    let bucketCostsUSD: [Double]
    let fiveHourQuotaPoints: [CGPoint?]
    let sevenDayQuotaPoints: [CGPoint?]

    init(
        bins: [BinUsage],
        prepared: RecentChartPreparedData,
        plot: CGRect,
        step: CGFloat,
        bucketCostsUSD: [Double],
        fixedScales: RecentChartFixedScaleMap,
        renderRange: ClosedRange<Int>?,
        scaleRange: ClosedRange<Int>?
    ) {
        let calculatedBucketCostsUSD = bins.indices.map { index in
            guard let cost = bucketCostsUSD[safe: index], cost.isFinite else { return 0.0 }
            return max(cost, 0)
        }
        self.bucketCostsUSD = calculatedBucketCostsUSD
        let scaleIndices: [Int]
        if let scaleRange, !bins.isEmpty {
            let lowerBound = min(max(scaleRange.lowerBound, bins.startIndex), bins.index(before: bins.endIndex))
            let upperBound = min(max(scaleRange.upperBound, lowerBound), bins.index(before: bins.endIndex))
            scaleIndices = Array(lowerBound...upperBound)
        } else {
            scaleIndices = Array(bins.indices)
        }
        let scaleMap = RecentChartScaleMap(
            tokenValues: scaleIndices.map { bins[$0].tokens },
            costValues: scaleIndices.map { calculatedBucketCostsUSD[$0] },
            fixed: fixedScales
        )
        let renderIndices: [Int]
        if let renderRange, !bins.isEmpty {
            let lowerBound = min(max(renderRange.lowerBound, bins.startIndex), bins.index(before: bins.endIndex))
            let upperBound = min(max(renderRange.upperBound, lowerBound), bins.index(before: bins.endIndex))
            renderIndices = Array(lowerBound...upperBound)
        } else {
            renderIndices = Array(bins.indices)
        }
        renderStartIndex = renderIndices.first ?? 0
        renderEndIndex = renderIndices.last ?? -1
        tokenPoints = renderIndices.map { index in
            let x = plot.minX + CGFloat(index) * step
            let y = plot.minY + scaleMap.y(
                for: Double(bins[index].tokens),
                series: .tokens,
                plotHeight: plot.height
            )
            return CGPoint(x: x, y: y)
        }
        callPoints = renderIndices.map { index in
            let x = plot.minX + CGFloat(index) * step
            let y = plot.minY + scaleMap.y(
                for: Double(bins[index].calls),
                series: .calls,
                plotHeight: plot.height
            )
            return CGPoint(x: x, y: y)
        }
        cachePoints = renderIndices.map { index in
            let x = plot.minX + CGFloat(index) * step
            guard let rate = prepared.observedCacheHitRates[safe: index] ?? nil else { return nil }
            let y = plot.minY + scaleMap.y(
                for: rate,
                series: .cacheHitRate,
                plotHeight: plot.height
            )
            return CGPoint(x: x, y: y)
        }
        costPoints = renderIndices.map { index in
            guard let cost = calculatedBucketCostsUSD[safe: index],
                  RecentChartScaleMap.isRenderableCost(cost) else { return nil }
            return CGPoint(
                x: plot.minX + CGFloat(index) * step,
                y: plot.minY + scaleMap.y(
                    for: cost,
                    series: .cost,
                    plotHeight: plot.height
                )
            )
        }
        fiveHourQuotaPoints = renderIndices.map { index in
            guard let value = prepared.fiveHourRemainingPercents[safe: index],
                  let percent = value else { return nil }
            let x = plot.minX + CGFloat(index) * step
            let y = plot.minY + scaleMap.y(
                for: percent,
                series: .quota,
                plotHeight: plot.height
            )
            return CGPoint(x: x, y: y)
        }
        sevenDayQuotaPoints = renderIndices.map { index in
            guard let value = prepared.sevenDayRemainingPercents[safe: index],
                  let percent = value else { return nil }
            let x = plot.minX + CGFloat(index) * step
            let y = plot.minY + scaleMap.y(
                for: percent,
                series: .quota,
                plotHeight: plot.height
            )
            return CGPoint(x: x, y: y)
        }
    }

    func tokenPoint(at globalIndex: Int) -> CGPoint? {
        localIndex(for: globalIndex).flatMap { tokenPoints[safe: $0] }
    }

    func callPoint(at globalIndex: Int) -> CGPoint? {
        localIndex(for: globalIndex).flatMap { callPoints[safe: $0] }
    }

    func cachePoint(at globalIndex: Int) -> CGPoint? {
        guard let index = localIndex(for: globalIndex) else { return nil }
        return cachePoints[safe: index] ?? nil
    }

    func costPoint(at globalIndex: Int) -> CGPoint? {
        guard let index = localIndex(for: globalIndex) else { return nil }
        return costPoints[safe: index] ?? nil
    }

    func fiveHourQuotaPoint(at globalIndex: Int) -> CGPoint? {
        guard let index = localIndex(for: globalIndex) else { return nil }
        return fiveHourQuotaPoints[safe: index] ?? nil
    }

    func sevenDayQuotaPoint(at globalIndex: Int) -> CGPoint? {
        guard let index = localIndex(for: globalIndex) else { return nil }
        return sevenDayQuotaPoints[safe: index] ?? nil
    }

    private func localIndex(for globalIndex: Int) -> Int? {
        guard globalIndex >= renderStartIndex, globalIndex <= renderEndIndex else { return nil }
        return globalIndex - renderStartIndex
    }
}

private struct RecentChartRenderCacheKey: Equatable {
    let generation: Int
    let width: CGFloat
    let height: CGFloat
    let scaleStartIndex: Int
    let scaleEndIndex: Int
    let renderStartIndex: Int
    let renderEndIndex: Int
}

private struct RecentChartRenderFrame {
    let plotData: RecentChartPlotData
    let renderPlot: CGRect
    let tokenArea: Path
    let tokenLine: Path
    let callLine: Path
    let cachePoints: Path
    let costPoints: Path
    let fiveHourQuotaLine: Path
    let sevenDayQuotaLine: Path
}

@MainActor
private final class RecentChartRenderFrameCache {
    private var key: RecentChartRenderCacheKey?
    private var frame: RecentChartRenderFrame?

    func value(
        for key: RecentChartRenderCacheKey,
        build: () -> RecentChartRenderFrame
    ) -> RecentChartRenderFrame {
        if self.key == key, let frame {
            return frame
        }
        let updated = build()
        self.key = key
        frame = updated
        return updated
    }
}

let recentChartHoverBubbleVerticalOffset: CGFloat = 74

struct RecentChartQuotaSeriesVisibility: Equatable {
    let showsFiveHour: Bool
    let showsSevenDay: Bool
    let drawsFiveHour: Bool
    let drawsSevenDay: Bool

    init(
        currentFiveHourPresent: Bool,
        currentSevenDayPresent: Bool,
        historyHasFiveHour: Bool,
        historyHasSevenDay: Bool
    ) {
        showsFiveHour = currentFiveHourPresent
        showsSevenDay = currentSevenDayPresent
        drawsFiveHour = currentFiveHourPresent && historyHasFiveHour
        drawsSevenDay = currentSevenDayPresent && historyHasSevenDay
    }

    var accessibilityLabels: [String] {
        [
            showsFiveHour ? "5 小时额度" : nil,
            showsSevenDay ? "7 天额度" : nil,
        ].compactMap { $0 }
    }
}

struct RecentChartQuotaEstimateVisibility: Equatable {
    let showsFiveHour: Bool
    let showsSevenDay: Bool

    init(historyHasFiveHour: Bool, historyHasSevenDay: Bool) {
        showsFiveHour = historyHasFiveHour
        showsSevenDay = historyHasSevenDay
    }
}

struct RecentChartSelectionIndices: Equatable {
    let startIndex: Int
    let endIndex: Int?

    var isFixed: Bool { endIndex != nil }
}

/// Tracks preview-card dismissal independently from the selected range. A
/// close action hides only the card that was closed for the current user
/// interaction generation; it never clears the two-click selection state.
struct RecentChartPreviewVisibilityState: Equatable {
    private(set) var interactionGeneration = 0
    private(set) var topDismissedGeneration: Int?
    private(set) var selectionDismissedGeneration: Int?

    var showsTopPreview: Bool {
        topDismissedGeneration != interactionGeneration
    }

    var showsSelectionSummary: Bool {
        selectionDismissedGeneration != interactionGeneration
    }

    mutating func beginInteraction() {
        interactionGeneration &+= 1
    }

    mutating func beginHoverInteraction(selectionIsFixed: Bool) {
        guard !selectionIsFixed else { return }
        beginInteraction()
    }

    mutating func dismissTopPreview() {
        topDismissedGeneration = interactionGeneration
    }

    mutating func dismissSelectionSummary() {
        selectionDismissedGeneration = interactionGeneration
    }
}

enum RecentChartAccessibilityCursorDirection {
    case previous
    case next
}

struct RecentChartAccessibilityCursorState: Equatable {
    private(set) var index: Int?

    func resolvedIndex(validCount: Int) -> Int? {
        guard validCount > 0 else { return nil }
        return min(max(index ?? validCount - 1, 0), validCount - 1)
    }

    @discardableResult
    mutating func move(
        _ direction: RecentChartAccessibilityCursorDirection,
        validCount: Int
    ) -> Int? {
        guard let current = resolvedIndex(validCount: validCount) else {
            index = nil
            return nil
        }
        switch direction {
        case .previous:
            index = max(current - 1, 0)
        case .next:
            index = min(current + 1, validCount - 1)
        }
        return index
    }

    mutating func select(index: Int, validCount: Int) {
        guard validCount > 0, (0..<validCount).contains(index) else { return }
        self.index = index
    }

    mutating func clamp(validCount: Int) {
        guard validCount > 0 else {
            index = nil
            return
        }
        if let index {
            self.index = min(max(index, 0), validCount - 1)
        }
    }

    mutating func reset() {
        index = nil
    }
}

struct RecentChartSelectionTimeAnchor: Equatable {
    let startDate: Date
    let endDate: Date?
    let bucketInterval: TimeInterval
    let bucketCount: Int?

    init(startDate: Date, bucketInterval: TimeInterval) {
        self.startDate = startDate
        endDate = nil
        self.bucketInterval = bucketInterval
        bucketCount = nil
    }

    init(selection: QuotaConsumptionSelection, bucketInterval: TimeInterval) {
        self.init(
            startDate: selection.startDate,
            endDate: selection.endDate,
            bucketInterval: bucketInterval,
            bucketCount: selection.bucketCount
        )
    }

    init(
        startDate: Date,
        endDate: Date,
        bucketInterval: TimeInterval,
        bucketCount: Int
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.bucketInterval = bucketInterval
        self.bucketCount = bucketCount
    }

    func relocatedIndices(
        in bins: [BinUsage],
        bucketInterval updatedBucketInterval: TimeInterval
    ) -> RecentChartSelectionIndices? {
        guard !bins.isEmpty,
              bucketInterval.isFinite,
              updatedBucketInterval.isFinite,
              bucketInterval > 0,
              Self.matches(bucketInterval, updatedBucketInterval),
              let startIndex = Self.index(of: startDate, in: bins) else { return nil }

        guard let endDate else {
            return RecentChartSelectionIndices(startIndex: startIndex, endIndex: nil)
        }

        let endBucketStart = endDate.addingTimeInterval(-bucketInterval)
        guard let endIndex = Self.index(of: endBucketStart, in: bins) else { return nil }
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        let selectedBins = bins[lower...upper]
        guard let bucketCount,
              upper - lower + 1 == bucketCount,
              zip(selectedBins, selectedBins.dropFirst()).allSatisfy({ pair in
                  Self.matches(
                      pair.1.start.timeIntervalSince(pair.0.start),
                      bucketInterval
                  )
              }) else { return nil }

        return RecentChartSelectionIndices(startIndex: lower, endIndex: upper)
    }

    private static func index(of date: Date, in bins: [BinUsage]) -> Int? {
        bins.firstIndex { matches($0.start.timeIntervalSince(date), 0) }
    }

    private static func matches(_ lhs: TimeInterval, _ rhs: TimeInterval) -> Bool {
        abs(lhs - rhs) < 0.5
    }
}

enum RecentChartSelectionInvalidationPresentation {
    static let message = "历史数据已刷新，原选区时间已失效，请重新选择。"
}

struct RecentUsageChart: View, Equatable {
    let bins: [BinUsage]
    let hourlyBins: [BinUsage]
    let cacheRecentBins: [TokenCacheBucket]
    let cacheHourlyBins: [TokenCacheBucket]
    let attributionEvents: [TokenCacheAttributionEvent]
    let attributionEventsComplete: Bool
    let quotaRecentBins: [QuotaHistoryRecentBucket]
    let quotaHourlyBins: [QuotaHistoryRecentBucket]
    let currentFiveHourQuotaPresent: Bool
    let currentSevenDayQuotaPresent: Bool
    let sharedAccountAttributionContext: QuotaSelectionAttributionContext?
    private static let dataLineWidth: CGFloat = 1.55
    private static let hoverRingLineWidth: CGFloat = 1.55
    @AppStorage("recentChartRange") private var selectedRangeRaw = RecentChartRange.twentyFourHours.rawValue
    @AppStorage("recentChartShowTokens") private var showTokens = true
    @AppStorage("recentChartShowCalls") private var showCalls = true
    @AppStorage("recentChartShowCacheHitRate") private var showCacheHitRate = true
    @AppStorage("recentChartShowCost") private var showCost = true
    @AppStorage("recentChartShowFiveHourQuota") private var showFiveHourQuota = true
    @AppStorage("recentChartShowSevenDayQuota") private var showSevenDayQuota = true
    @AppStorage(SharedAccountUsageAttributionSettings.priceModelKey) private var quotaEstimateModelRaw = OfficialAPIPriceModel.gpt56Sol.rawValue
    @State private var hoveredIndex: Int?
    @State private var consumptionSelectionState = RecentChartConsumptionSelectionState()
    @State private var consumptionSelectionTimeAnchor: RecentChartSelectionTimeAnchor?
    @State private var consumptionSelectionInvalidationMessage: String?
    @State private var previewVisibility = RecentChartPreviewVisibilityState()
    @State private var accessibilityCursorState = RecentChartAccessibilityCursorState()
    @State private var scrollPresentation: RecentChartScrollPresentation?
    @State private var cachedBucketCostsUSD: [Double]
    @State private var cachedFixedScales: RecentChartFixedScaleMap
    @State private var renderGeneration: Int
    @State private var renderFrameCache: RecentChartRenderFrameCache
    @State var preparedData: RecentChartPreparedData

    init(
        bins: [BinUsage],
        hourlyBins: [BinUsage],
        cacheRecentBins: [TokenCacheBucket],
        cacheHourlyBins: [TokenCacheBucket],
        attributionEvents: [TokenCacheAttributionEvent] = [],
        attributionEventsComplete: Bool = true,
        quotaRecentBins: [QuotaHistoryRecentBucket],
        quotaHourlyBins: [QuotaHistoryRecentBucket],
        currentFiveHourQuotaPresent: Bool = true,
        currentSevenDayQuotaPresent: Bool = true,
        sharedAccountAttributionContext: QuotaSelectionAttributionContext? = nil
    ) {
        self.bins = bins
        self.hourlyBins = hourlyBins
        self.cacheRecentBins = cacheRecentBins
        self.cacheHourlyBins = cacheHourlyBins
        self.attributionEvents = attributionEvents
        self.attributionEventsComplete = attributionEventsComplete
        self.quotaRecentBins = quotaRecentBins
        self.quotaHourlyBins = quotaHourlyBins
        self.currentFiveHourQuotaPresent = currentFiveHourQuotaPresent
        self.currentSevenDayQuotaPresent = currentSevenDayQuotaPresent
        self.sharedAccountAttributionContext = sharedAccountAttributionContext
        _cachedBucketCostsUSD = State(initialValue: [])
        _cachedFixedScales = State(initialValue: .empty)
        _renderGeneration = State(initialValue: 0)
        _renderFrameCache = State(initialValue: RecentChartRenderFrameCache())
        _preparedData = State(initialValue: .empty)
    }

    nonisolated static func == (lhs: RecentUsageChart, rhs: RecentUsageChart) -> Bool {
        lhs.bins == rhs.bins
            && lhs.hourlyBins == rhs.hourlyBins
            && lhs.cacheRecentBins == rhs.cacheRecentBins
            && lhs.cacheHourlyBins == rhs.cacheHourlyBins
            && lhs.attributionEvents == rhs.attributionEvents
            && lhs.attributionEventsComplete == rhs.attributionEventsComplete
            && lhs.quotaRecentBins == rhs.quotaRecentBins
            && lhs.quotaHourlyBins == rhs.quotaHourlyBins
            && lhs.currentFiveHourQuotaPresent == rhs.currentFiveHourQuotaPresent
            && lhs.currentSevenDayQuotaPresent == rhs.currentSevenDayQuotaPresent
            && lhs.sharedAccountAttributionContext == rhs.sharedAccountAttributionContext
    }

    private var quotaSeriesVisibility: RecentChartQuotaSeriesVisibility {
        RecentChartQuotaSeriesVisibility(
            currentFiveHourPresent: currentFiveHourQuotaPresent,
            currentSevenDayPresent: currentSevenDayQuotaPresent,
            historyHasFiveHour: preparedData.hasFiveHourQuota,
            historyHasSevenDay: preparedData.hasSevenDayQuota
        )
    }

    private var quotaEstimateVisibility: RecentChartQuotaEstimateVisibility {
        RecentChartQuotaEstimateVisibility(
            historyHasFiveHour: preparedData.hasFiveHourQuota,
            historyHasSevenDay: preparedData.hasSevenDayQuota
        )
    }

    private var selectedRange: RecentChartRange {
        RecentChartRange(rawValue: selectedRangeRaw) ?? .twentyFourHours
    }

    private var selectedRangeBinding: Binding<RecentChartRange> {
        Binding(
            get: { selectedRange },
            set: { range in
                selectedRangeRaw = range.rawValue
                scrollPresentation = nil
                clearConsumptionSelection()
            }
        )
    }

    private var visibleWindowSummary: RecentChartWindowSummary {
        preparedData.visibleWindowSummary(for: scrollPresentation)
    }

    private var visibleWindowCostUSD: Double {
        let summary = visibleWindowSummary
        guard summary.endIndex >= summary.startIndex else { return 0 }
        return (summary.startIndex...summary.endIndex).reduce(0) { total, index in
            total + (cachedBucketCostsUSD[safe: index] ?? 0)
        }
    }

    private var preparationInput: RecentChartPreparationInput {
        RecentChartPreparationInput(
            bins: bins,
            hourlyBins: hourlyBins,
            cacheRecentBins: cacheRecentBins,
            cacheHourlyBins: cacheHourlyBins,
            attributionEvents: attributionEvents,
            quotaRecentBins: quotaRecentBins,
            quotaHourlyBins: quotaHourlyBins
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
                    RecentChartRangeSelector(selection: selectedRangeBinding)
                }

                HStack(spacing: 14) {
                    ChartLegend(color: .blue, label: "Token", value: visibleWindowSummary.tokenTotal.abbreviatedTokens)
                    ChartLegend(color: .orange, label: "调用", value: "\(visibleWindowSummary.callTotal)")
                    ChartLegend(color: AppTheme.accentCyan, label: "命中率", value: visibleWindowSummary.recentCacheBreakdown.cacheHitRate.percentString)
                    ChartLegend(color: AppTheme.accentAmber, label: "金额", value: visibleWindowCostUSD.quotaEstimatorMoneyText)
                    if quotaSeriesVisibility.showsFiveHour {
                        ChartLegend(color: .purple, label: "5h", value: Self.percentText(visibleWindowSummary.latestFiveHourRemaining))
                    }
                    if quotaSeriesVisibility.showsSevenDay {
                        ChartLegend(color: .green, label: "7d", value: Self.percentText(visibleWindowSummary.latestSevenDayRemaining))
                    }
                }

                HStack(spacing: 5) {
                    ChartLineToggle(title: "Token", color: .blue, isOn: $showTokens)
                    ChartLineToggle(title: "调用", color: .orange, isOn: $showCalls)
                    ChartLineToggle(title: "命中率", color: AppTheme.accentCyan, isOn: $showCacheHitRate)
                    ChartLineToggle(title: "金额", color: AppTheme.accentAmber, isOn: $showCost)
                    if quotaSeriesVisibility.showsFiveHour {
                        ChartLineToggle(title: "5h", color: .purple, isOn: $showFiveHourQuota)
                    }
                    if quotaSeriesVisibility.showsSevenDay {
                        ChartLineToggle(title: "7d", color: .green, isOn: $showSevenDayQuota)
                    }
                }
            }
        }
    }

    private func chartPlot(
        consumptionSelection: QuotaConsumptionSelection?
    ) -> some View {
        GeometryReader { proxy in
            let buttonWidth: CGFloat = 28
            let viewportWidth = max(proxy.size.width, 1)
            let contentWidth = RecentChartScrollMetrics.contentWidth(
                range: selectedRange,
                bins: preparedData.bins,
                bucketInterval: preparedData.bucketInterval,
                viewportWidth: viewportWidth
            )
            let windowCount = RecentChartScrollMetrics.windowCount(
                range: selectedRange,
                bins: preparedData.bins,
                bucketInterval: preparedData.bucketInterval
            )
            let presentation = scrollPresentation ?? RecentChartScrollPresentation(
                contentOffset: max(contentWidth - viewportWidth, 0),
                viewportWidth: viewportWidth,
                contentWidth: contentWidth,
                windowCount: windowCount
            )

            ScrollViewReader { scrollProxy in
                ZStack {
                    ZStack {
                        ScrollView(.horizontal, showsIndicators: contentWidth > viewportWidth + 1) {
                            HStack(spacing: 0) {
                                ZStack(alignment: .topLeading) {
                                    chartPlotCanvas(
                                        width: contentWidth,
                                        height: proxy.size.height,
                                        consumptionSelection: consumptionSelection
                                    )
                                        .frame(width: contentWidth, height: proxy.size.height)

                                    RecentChartScrollOffsetReader { contentOffset in
                                        updateScrollPresentation(
                                            contentOffset: contentOffset,
                                            viewportWidth: viewportWidth,
                                            contentWidth: contentWidth,
                                            windowCount: windowCount
                                        )
                                    }
                                    .frame(width: 1, height: 1)

                                    chartScrollAnchors(
                                        windowCount: windowCount,
                                        viewportWidth: viewportWidth,
                                        contentWidth: contentWidth
                                    )
                                }
                                .frame(width: contentWidth, height: proxy.size.height)

                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .id(RecentChartScrollMetrics.trailingAnchorID)
                            }
                        }
                        .scrollClipDisabled()
                        .mask(chartViewportMask)
                        .overlay(alignment: .topLeading) {
                            chartHoverBubbleOverlay(
                                viewportWidth: viewportWidth,
                                height: proxy.size.height,
                                contentWidth: contentWidth,
                                contentOffset: presentation.contentOffset,
                                consumptionSelection: consumptionSelection
                            )
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(selectedRange.title) 曲线图")
                        .accessibilityValue(chartInteractionAccessibilityValue)
                        .accessibilityHint("调整时间点后，执行设置选区点；第一次设起点，第二次固定终点。")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment:
                                moveAccessibilityCursor(.next)
                            case .decrement:
                                moveAccessibilityCursor(.previous)
                            @unknown default:
                                break
                            }
                        }
                        .accessibilityAction(named: Text("设置选区点")) {
                            selectAccessibilityCursor()
                        }
                        .accessibilityAction(named: Text("清除选区")) {
                            clearConsumptionSelection()
                        }
                        .focusable()
                        .onMoveCommand { direction in
                            switch direction {
                            case .left, .up:
                                moveAccessibilityCursor(.previous)
                            case .right, .down:
                                moveAccessibilityCursor(.next)
                            default:
                                break
                            }
                        }
                        .onKeyPress(.space) {
                            selectAccessibilityCursor()
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            guard consumptionSelectionState.startIndex != nil || hoveredIndex != nil else {
                                return .ignored
                            }
                            dismissTopPreview()
                            dismissSelectionSummary()
                            return .handled
                        }

                        RecentChartEdgeFadeOverlay(
                            state: presentation.edgeFadeState
                        )
                    }
                    .frame(width: viewportWidth, height: proxy.size.height)

                    HStack {
                        RecentChartScrollButton(
                            direction: .backward,
                            isDisabled: windowCount <= 1 || presentation.isAtOldest,
                            action: {
                                scrollChart(
                                    by: .backward,
                                    presentation: presentation,
                                    proxy: scrollProxy
                                )
                            }
                        )
                        .frame(width: buttonWidth, height: proxy.size.height)
                        .offset(x: -buttonWidth - 6)

                        Spacer(minLength: 0)

                        RecentChartScrollButton(
                            direction: .forward,
                            isDisabled: windowCount <= 1 || presentation.isAtLatest,
                            action: {
                                scrollChart(
                                    by: .forward,
                                    presentation: presentation,
                                    proxy: scrollProxy
                                )
                            }
                        )
                        .frame(width: buttonWidth, height: proxy.size.height)
                        .offset(x: buttonWidth + 6)
                    }

                }
                .onAppear {
                    scrollChartToLatest(scrollProxy)
                }
                .onChange(of: selectedRangeRaw) { _, _ in
                    scrollChartToLatest(scrollProxy)
                }
                .onChange(of: preparedData.bins) { previousBins, updatedBins in
                    guard RecentChartAutoScrollPolicy.shouldFollowLatest(
                        previousBins: previousBins,
                        updatedBins: updatedBins,
                        wasAtLatest: scrollPresentation?.isAtLatest
                    ) else { return }
                    scrollChartToLatest(scrollProxy)
                }
            }
        }
        .frame(height: selectedRange.chartGeometry.canvasHeight)
    }

    private var chartViewportMask: some View {
        Rectangle()
            .padding(.vertical, -90)
    }

    @ViewBuilder
    private func chartScrollAnchors(windowCount: Int, viewportWidth: CGFloat, contentWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<max(windowCount, 1), id: \.self) { index in
                Color.clear
                    .frame(
                        width: scrollAnchorWidth(
                            index: index,
                            windowCount: windowCount,
                            viewportWidth: viewportWidth,
                            contentWidth: contentWidth
                        ),
                        height: 1
                    )
                    .id(RecentChartScrollMetrics.anchorID(for: index))
            }
        }
        .frame(width: contentWidth, height: 1, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func scrollAnchorWidth(
        index: Int,
        windowCount: Int,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> CGFloat {
        guard windowCount > 1 else { return max(contentWidth, 1) }
        if index >= windowCount - 1 {
            return max(contentWidth - viewportWidth * CGFloat(index), 1)
        }
        return max(viewportWidth, 1)
    }

    @ViewBuilder
    private func chartPlotCanvas(
        width: CGFloat,
        height: CGFloat,
        consumptionSelection: QuotaConsumptionSelection?
    ) -> some View {
        let geometry = selectedRange.chartGeometry
        let plot = CGRect(
            x: 0,
            y: geometry.plotTop,
            width: width,
            height: max(geometry.plotHeight, 1)
        )
        let chartBins = preparedData.bins
        let step = plot.width / CGFloat(max(chartBins.count - 1, 1))
        let scaleWindow = visibleWindowSummary
        let renderRange: ClosedRange<Int>? = scaleWindow.endIndex >= scaleWindow.startIndex
            ? max(scaleWindow.startIndex - 2, 0)...min(scaleWindow.endIndex + 2, max(chartBins.count - 1, 0))
            : nil
        let activeIndex = consumptionSelectionState.fixedEndIndex.flatMap {
            chartBins.indices.contains($0) ? $0 : nil
        } ?? hoveredIndex.flatMap { chartBins.indices.contains($0) ? $0 : nil }
        let renderKey = RecentChartRenderCacheKey(
            generation: renderGeneration,
            width: width,
            height: height,
            scaleStartIndex: scaleWindow.startIndex,
            scaleEndIndex: scaleWindow.endIndex,
            renderStartIndex: renderRange?.lowerBound ?? 0,
            renderEndIndex: renderRange?.upperBound ?? max(chartBins.count - 1, -1)
        )
        let renderFrame = renderFrameCache.value(for: renderKey) {
            let plotData = RecentChartPlotData(
                bins: chartBins,
                prepared: preparedData,
                plot: plot,
                step: step,
                bucketCostsUSD: cachedBucketCostsUSD,
                fixedScales: cachedFixedScales,
                renderRange: renderRange,
                scaleRange: scaleWindow.endIndex >= scaleWindow.startIndex
                    ? scaleWindow.startIndex...scaleWindow.endIndex
                    : nil
            )
            let renderPlot: CGRect
            if chartBins.isEmpty {
                renderPlot = plot
            } else {
                let renderLeft = plot.minX + CGFloat(plotData.renderStartIndex) * step
                let renderRight = plot.minX + CGFloat(max(plotData.renderEndIndex, plotData.renderStartIndex)) * step
                renderPlot = CGRect(
                    x: max(plot.minX, renderLeft),
                    y: plot.minY,
                    width: max(min(plot.maxX, renderRight) - max(plot.minX, renderLeft), 1),
                    height: plot.height
                )
            }
            return RecentChartRenderFrame(
                plotData: plotData,
                renderPlot: renderPlot,
                tokenArea: tokenAreaPath(points: plotData.tokenPoints, plot: renderPlot),
                tokenLine: linePath(points: plotData.tokenPoints),
                callLine: linePath(points: plotData.callPoints),
                cachePoints: observedOptionalPointPath(points: plotData.cachePoints),
                costPoints: observedOptionalPointPath(points: plotData.costPoints),
                fiveHourQuotaLine: optionalLinePath(points: plotData.fiveHourQuotaPoints),
                sevenDayQuotaLine: optionalLinePath(points: plotData.sevenDayQuotaPoints)
            )
        }
        let plotData = renderFrame.plotData
        let renderPlot = renderFrame.renderPlot

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.accentBlue.opacity(0.10), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: renderPlot.width, height: renderPlot.height)
                .offset(x: renderPlot.minX, y: renderPlot.minY)

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
                    path.move(to: CGPoint(x: upperX, y: plot.minY))
                    path.addLine(to: CGPoint(x: upperX, y: plot.maxY))
                }
                .stroke(AppTheme.accentBlue.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [4, 5]))

            }

            ForEach(0..<4, id: \.self) { line in
                let y = plot.minY + CGFloat(line) * plot.height / 3
                Path { path in
                    path.move(to: CGPoint(x: renderPlot.minX, y: y))
                    path.addLine(to: CGPoint(x: renderPlot.maxX, y: y))
                }
                .stroke(AppTheme.grid, style: StrokeStyle(lineWidth: 1, dash: [4, 8]))
            }

            if showTokens {
                renderFrame.tokenArea
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.accentBlue.opacity(0.22), AppTheme.accentBlue.opacity(0.055), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                renderFrame.tokenLine
                    .stroke(AppTheme.accentBlue, style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round))

            }

            if showCalls {
                renderFrame.callLine
                    .stroke(AppTheme.accentOrange, style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round))
            }

            if showCacheHitRate && preparedData.hasCacheCalls {
                renderFrame.cachePoints
                    .fill(AppTheme.accentCyan)
            }

            if showCost && plotData.costPoints.contains(where: { $0 != nil }) {
                renderFrame.costPoints
                .fill(AppTheme.accentAmber)
            }

            if showFiveHourQuota && quotaSeriesVisibility.drawsFiveHour {
                renderFrame.fiveHourQuotaLine
                    .stroke(.purple.opacity(0.92), style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round, dash: [3, 6]))
            }

            if showSevenDayQuota && quotaSeriesVisibility.drawsSevenDay {
                renderFrame.sevenDayQuotaLine
                    .stroke(.green.opacity(0.88), style: StrokeStyle(lineWidth: Self.dataLineWidth, lineCap: .round, lineJoin: .round, dash: [7, 5]))
            }

            if let activeIndex {
                let tokenPoint = plotData.tokenPoint(at: activeIndex)
                let callPoint = plotData.callPoint(at: activeIndex)
                let cachePoint = plotData.cachePoint(at: activeIndex)
                let costPoint = plotData.costPoint(at: activeIndex)
                let fiveHourPoint = plotData.fiveHourQuotaPoint(at: activeIndex)
                let sevenDayPoint = plotData.sevenDayQuotaPoint(at: activeIndex)

                if let tokenPoint {
                    Path { path in
                        path.move(to: CGPoint(x: tokenPoint.x, y: plot.minY))
                        path.addLine(to: CGPoint(x: tokenPoint.x, y: plot.maxY))
                    }
                    .stroke(AppTheme.accentBlue.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                }

                if showTokens, let tokenPoint {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(AppTheme.accentBlue, lineWidth: Self.hoverRingLineWidth))
                        .position(tokenPoint)
                }

                if showCalls, let callPoint {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(AppTheme.accentOrange, lineWidth: Self.hoverRingLineWidth))
                        .position(callPoint)
                }

                if showCacheHitRate,
                   preparedData.cacheBreakdowns[safe: activeIndex]?.calls ?? 0 > 0,
                   let cachePoint {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(AppTheme.accentCyan, lineWidth: Self.hoverRingLineWidth))
                        .position(cachePoint)
                }

                if showCost, let costPoint {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(AppTheme.accentAmber, lineWidth: Self.hoverRingLineWidth))
                        .position(costPoint)
                }

                if showFiveHourQuota, quotaSeriesVisibility.drawsFiveHour, let fiveHourPoint {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.purple, lineWidth: Self.hoverRingLineWidth))
                        .position(fiveHourPoint)
                }

                if showSevenDayQuota, quotaSeriesVisibility.drawsSevenDay, let sevenDayPoint {
                    Circle()
                        .fill(AppTheme.pageBackground)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.green, lineWidth: Self.hoverRingLineWidth))
                        .position(sevenDayPoint)
                }
            }

            HoverTrackingArea(
                onMove: { location in
                    let plotLocation = CGPoint(
                        x: location.x + plot.minX,
                        y: location.y + plot.minY
                    )
                    updateHoveredIndex(
                        hoverIndex(at: plotLocation, in: plot, step: step)
                    )
                },
                onClick: { location in
                    let plotLocation = CGPoint(
                        x: location.x + plot.minX,
                        y: location.y + plot.minY
                    )
                    guard let clickedIndex = hoverIndex(at: plotLocation, in: plot, step: step),
                          preparedData.bins.indices.contains(clickedIndex) else { return }
                    updateConsumptionSelection(forClickedIndex: clickedIndex)
                },
                onExit: {
                    updateHoveredIndex(nil)
                }
            )
            .frame(width: plot.width, height: plot.height)
            .position(x: plot.midX, y: plot.midY)

            ChartTimeMarkers(
                bins: chartBins,
                markerIndices: preparedData.markerIndices.filter {
                    $0 >= plotData.renderStartIndex && $0 <= plotData.renderEndIndex
                },
                range: preparedData.range,
                plot: plot,
                markerOffset: geometry.timeMarkerOffset
            )
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func chartHoverBubbleOverlay(
        viewportWidth: CGFloat,
        height: CGFloat,
        contentWidth: CGFloat,
        contentOffset: CGFloat,
        consumptionSelection: QuotaConsumptionSelection?
    ) -> some View {
        let chartBins = preparedData.bins
        let geometry = selectedRange.chartGeometry
        let liveHoverIndex = hoveredIndex.flatMap { chartBins.indices.contains($0) ? $0 : nil }
        let fixedEndIndex = consumptionSelectionState.fixedEndIndex.flatMap {
            chartBins.indices.contains($0) ? $0 : nil
        }
        let activeIndex = fixedEndIndex ?? liveHoverIndex

        if previewVisibility.showsTopPreview, let activeIndex {
            let contentPlot = CGRect(
                x: 0,
                y: geometry.plotTop,
                width: contentWidth,
                height: max(geometry.plotHeight, 1)
            )
            let viewportPlot = CGRect(
                x: 0,
                y: geometry.plotTop,
                width: viewportWidth,
                height: max(geometry.plotHeight, 1)
            )
            let step = contentPlot.width / CGFloat(max(chartBins.count - 1, 1))
            let viewportTokenX = contentPlot.minX + CGFloat(activeIndex) * step - contentOffset

            Group {
                if fixedEndIndex != nil, let selection = consumptionSelection {
                    ChartSelectionSummaryBubble(
                        selection: selection,
                        onClose: dismissTopPreview
                    )
                } else {
                    ChartHoverBubble(
                        bin: chartBins[activeIndex],
                        cacheBreakdown: preparedData.cacheBreakdowns[safe: activeIndex],
                        modelBreakdowns: preparedData.modelBreakdowns[safe: activeIndex] ?? [],
                        costUSD: bucketCostUSD(at: activeIndex),
                        fiveHourRemaining: quotaSeriesVisibility.showsFiveHour
                            ? preparedData.fiveHourRemainingPercents[safe: activeIndex] ?? nil
                            : nil,
                        sevenDayRemaining: quotaSeriesVisibility.showsSevenDay
                            ? preparedData.sevenDayRemainingPercents[safe: activeIndex] ?? nil
                            : nil,
                        bucketInterval: preparedData.bucketInterval,
                        isHovering: true,
                        onClose: dismissTopPreview
                    )
                }
            }
            .chartBubblePlacement(tokenX: viewportTokenX, plot: viewportPlot)
            .zIndex(10)
        }
    }

    private func scrollChart(
        by direction: RecentChartScrollDirection,
        presentation: RecentChartScrollPresentation,
        proxy: ScrollViewProxy
    ) {
        guard presentation.windowCount > 1 else { return }
        let target = presentation.targetWindowIndex(for: direction)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                if target >= presentation.windowCount - 1 {
                    proxy.scrollTo(RecentChartScrollMetrics.trailingAnchorID, anchor: .trailing)
                } else {
                    proxy.scrollTo(RecentChartScrollMetrics.anchorID(for: target), anchor: .leading)
                }
            }
        }
    }

    private func scrollChartToLatest(_ proxy: ScrollViewProxy) {
        guard preparedData.bins.count > 1 else { return }
        scrollPresentation = nil
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(RecentChartScrollMetrics.trailingAnchorID, anchor: .trailing)
            }
        }
    }

    private func updateScrollPresentation(
        contentOffset: CGFloat,
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        windowCount: Int
    ) {
        let maxOffset = max(contentWidth - viewportWidth, 0)
        let clampedOffset = min(max(contentOffset, 0), maxOffset)
        let step = contentWidth / CGFloat(max(preparedData.bins.count - 1, 1))
        let bucketAlignedOffset: CGFloat
        if clampedOffset <= 0.5 {
            bucketAlignedOffset = 0
        } else if maxOffset - clampedOffset <= 0.5 {
            bucketAlignedOffset = maxOffset
        } else if step > 0 {
            bucketAlignedOffset = min(max((clampedOffset / step).rounded() * step, 0), maxOffset)
        } else {
            bucketAlignedOffset = clampedOffset
        }
        let updated = RecentChartScrollPresentation(
            contentOffset: bucketAlignedOffset,
            viewportWidth: viewportWidth,
            contentWidth: contentWidth,
            windowCount: windowCount
        )
        guard scrollPresentation != updated else { return }
        scrollPresentation = updated
    }

    @ViewBuilder
    private func consumptionSelectionSummary(
        selection consumptionSelection: QuotaConsumptionSelection?,
        attribution: QuotaSelectionAttributionResult?
    ) -> some View {
        if previewVisibility.showsSelectionSummary, let consumptionSelection {
            RecentChartQuotaEstimateOverlay(
                selection: consumptionSelection,
                attribution: attribution,
                isSelectionFixed: consumptionSelectionState.fixedEndIndex != nil,
                showsFiveHourQuota: quotaEstimateVisibility.showsFiveHour,
                showsSevenDayQuota: quotaEstimateVisibility.showsSevenDay,
                currentFiveHourQuotaPresent: currentFiveHourQuotaPresent,
                currentSevenDayQuotaPresent: currentSevenDayQuotaPresent,
                attributionEventsComplete: attributionEventsComplete,
                onClose: dismissSelectionSummary
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let consumptionSelectionInvalidationMessage {
            RecentChartSelectionInvalidationBanner(
                message: consumptionSelectionInvalidationMessage
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        let consumptionSelection = activeConsumptionSelection
        let selectionAttribution = activeSelectionAttribution(
            for: consumptionSelection
        )
        VStack(alignment: .leading, spacing: 18) {
            chartHeader
            chartPlot(consumptionSelection: consumptionSelection)
            consumptionSelectionSummary(
                selection: consumptionSelection,
                attribution: selectionAttribution
            )
        }
        .frame(maxWidth: 980)
        .onAppear(perform: refreshPreparedData)
        .onChange(of: preparationInput) { _, _ in
            refreshPreparedData()
        }
        .onChange(of: selectedRangeRaw) { _, _ in
            clearConsumptionSelection()
            accessibilityCursorState.reset()
            refreshPreparedData()
        }
        .onChange(of: quotaEstimateModelRaw) { _, _ in
            refreshBucketCosts()
        }
    }


    private var accessibilitySummary: String {
        let windowSummary = visibleWindowSummary
        var visibleSeries: [String] = []
        if showTokens { visibleSeries.append("Token") }
        if showCalls { visibleSeries.append("调用") }
        if showCacheHitRate, windowSummary.hasCacheCalls { visibleSeries.append("命中率") }
        if showCost, !preparedData.bins.isEmpty { visibleSeries.append("每桶金额") }
        if showFiveHourQuota, quotaSeriesVisibility.drawsFiveHour { visibleSeries.append("5 小时额度") }
        if showSevenDayQuota, quotaSeriesVisibility.drawsSevenDay { visibleSeries.append("7 天额度") }

        var parts = [
            "\(preparedData.bins.count) 个时间点",
            "当前窗口 Token 总量 \(windowSummary.tokenTotal.abbreviatedTokens)",
            "当前窗口调用 \(windowSummary.callTotal) 次",
            "当前窗口缓存命中率 \(windowSummary.recentCacheBreakdown.cacheHitRate.percentString)",
        ]
        if quotaSeriesVisibility.showsFiveHour {
            parts.append("5 小时额度 \(Self.percentText(windowSummary.latestFiveHourRemaining))")
        }
        if quotaSeriesVisibility.showsSevenDay {
            parts.append("7 天额度 \(Self.percentText(windowSummary.latestSevenDayRemaining))")
        }
        parts.append("已显示 \(visibleSeries.isEmpty ? "无曲线" : visibleSeries.joined(separator: "、"))")
        return parts.joined(separator: "；")
    }

    private var chartInteractionAccessibilityValue: String {
        var value = accessibilitySummary
        if let index = accessibilityCursorState.resolvedIndex(validCount: preparedData.bins.count),
           let bin = preparedData.bins[safe: index] {
            value += "；当前时间点 \(DateFormatter.monthDayHourMinute.string(from: bin.start))，Token \(bin.tokens.abbreviatedTokens)，调用 \(bin.calls) 次"
        }
        if consumptionSelectionState.fixedEndIndex != nil {
            value += "；选区已固定"
        } else if consumptionSelectionState.startIndex != nil {
            value += "；已设置起点，等待终点"
        } else {
            value += "；尚未设置选区"
        }
        return value
    }

    private func refreshPreparedData() {
        refreshPreparedData(range: selectedRange)
    }

    private func refreshPreparedData(range: RecentChartRange) {
        let updatedData = Self.prepare(
            range: range,
            recentBins: bins,
            hourlyBins: hourlyBins,
            cacheRecentBins: cacheRecentBins,
            cacheHourlyBins: cacheHourlyBins,
            attributionEvents: attributionEvents,
            quotaRecentBins: quotaRecentBins,
            quotaHourlyBins: quotaHourlyBins
        )
        let updatedBucketCostsUSD = Self.bucketCosts(
            for: updatedData,
            priceModel: selectedQuotaEstimateModel
        )
        let updatedFixedScales = Self.fixedScales(for: updatedData)
        guard updatedData != preparedData else {
            var renderInputsChanged = false
            if updatedBucketCostsUSD != cachedBucketCostsUSD {
                cachedBucketCostsUSD = updatedBucketCostsUSD
                renderInputsChanged = true
            }
            if updatedFixedScales != cachedFixedScales {
                cachedFixedScales = updatedFixedScales
                renderInputsChanged = true
            }
            if renderInputsChanged {
                renderGeneration &+= 1
            }
            return
        }
        preparedData = updatedData
        cachedBucketCostsUSD = updatedBucketCostsUSD
        cachedFixedScales = updatedFixedScales
        renderGeneration &+= 1
        accessibilityCursorState.clamp(validCount: updatedData.bins.count)
        restoreConsumptionSelection(in: updatedData)
    }

    private var selectedQuotaEstimateModel: OfficialAPIPriceModel {
        OfficialAPIPriceModel.storedValue(for: quotaEstimateModelRaw)
    }

    private func refreshBucketCosts() {
        let updated = Self.bucketCosts(
            for: preparedData,
            priceModel: selectedQuotaEstimateModel
        )
        guard updated != cachedBucketCostsUSD else { return }
        cachedBucketCostsUSD = updated
        renderGeneration &+= 1
    }

    private static func fixedScales(
        for prepared: RecentChartPreparedData
    ) -> RecentChartFixedScaleMap {
        RecentChartFixedScaleMap(
            callValues: prepared.bins.map(\.calls)
        )
    }

    private static func bucketCosts(
        for prepared: RecentChartPreparedData,
        priceModel: OfficialAPIPriceModel
    ) -> [Double] {
        prepared.bins.indices.map { index in
            let fallbackBreakdown = prepared.cacheBreakdowns[safe: index] ?? .empty
            let estimate = ModelAwareAPIPriceEstimator.estimate(
                modelBreakdowns: prepared.modelBreakdowns[safe: index] ?? [],
                fallbackBreakdown: fallbackBreakdown,
                fallbackModel: priceModel,
                rates: { $0.currentPriceRates }
            )
            return estimate.costUSD.isFinite ? max(estimate.costUSD, 0) : 0
        }
    }

    private func bucketCostUSD(at index: Int) -> Double {
        if let cachedCost = cachedBucketCostsUSD[safe: index] {
            return cachedCost
        }
        let fallbackBreakdown = preparedData.cacheBreakdowns[safe: index] ?? .empty
        let estimate = ModelAwareAPIPriceEstimator.estimate(
            modelBreakdowns: preparedData.modelBreakdowns[safe: index] ?? [],
            fallbackBreakdown: fallbackBreakdown,
            fallbackModel: selectedQuotaEstimateModel,
            rates: { $0.currentPriceRates }
        )
        return estimate.costUSD.isFinite ? max(estimate.costUSD, 0) : 0
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
            priceCard: .officialAPI(selectedQuotaEstimateModel),
            attributionEvents: attributionEvents
        )
    }

    private func activeSelectionAttribution(
        for selection: QuotaConsumptionSelection?
    ) -> QuotaSelectionAttributionResult? {
        guard attributionEventsComplete,
              consumptionSelectionState.fixedEndIndex != nil,
              let selection,
              let sharedAccountAttributionContext else { return nil }
        return QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: sharedAccountAttributionContext
        )
    }

    private func updateConsumptionSelection(forClickedIndex clickedIndex: Int) {
        guard preparedData.bins.indices.contains(clickedIndex),
              let clickedDate = preparedData.bins[safe: clickedIndex]?.start else { return }

        previewVisibility.beginInteraction()
        hoveredIndex = clickedIndex
        consumptionSelectionInvalidationMessage = nil
        accessibilityCursorState.select(
            index: clickedIndex,
            validCount: preparedData.bins.count
        )
        consumptionSelectionState.click(
            index: clickedIndex,
            validCount: preparedData.bins.count
        )

        if let startIndex = consumptionSelectionState.startIndex,
           let fixedEndIndex = consumptionSelectionState.fixedEndIndex,
           let selection = preparedData.quotaConsumptionSelection(
               startIndex: startIndex,
               endIndex: fixedEndIndex,
               priceCard: .officialAPI(selectedQuotaEstimateModel),
               attributionEvents: attributionEvents
           ) {
            consumptionSelectionTimeAnchor = RecentChartSelectionTimeAnchor(
                selection: selection,
                bucketInterval: preparedData.bucketInterval
            )
        } else {
            consumptionSelectionTimeAnchor = RecentChartSelectionTimeAnchor(
                startDate: clickedDate,
                bucketInterval: preparedData.bucketInterval
            )
        }
    }

    private func restoreConsumptionSelection(in updatedData: RecentChartPreparedData) {
        guard let anchor = consumptionSelectionTimeAnchor else {
            consumptionSelectionState.clamp(validCount: updatedData.bins.count)
            return
        }
        guard let relocated = anchor.relocatedIndices(
            in: updatedData.bins,
            bucketInterval: updatedData.bucketInterval
        ) else {
            hoveredIndex = nil
            consumptionSelectionState.reset()
            consumptionSelectionTimeAnchor = nil
            consumptionSelectionInvalidationMessage = RecentChartSelectionInvalidationPresentation.message
            return
        }

        var relocatedState = RecentChartConsumptionSelectionState()
        relocatedState.click(
            index: relocated.startIndex,
            validCount: updatedData.bins.count
        )
        if let endIndex = relocated.endIndex {
            relocatedState.click(index: endIndex, validCount: updatedData.bins.count)
        }
        hoveredIndex = nil
        consumptionSelectionState = relocatedState
        consumptionSelectionInvalidationMessage = nil
    }

    private func clearConsumptionSelection() {
        hoveredIndex = nil
        consumptionSelectionState.reset()
        consumptionSelectionTimeAnchor = nil
        consumptionSelectionInvalidationMessage = nil
    }

    private func updateHoveredIndex(_ index: Int?) {
        guard hoveredIndex != index else { return }
        hoveredIndex = index
        if index != nil {
            previewVisibility.beginHoverInteraction(
                selectionIsFixed: consumptionSelectionState.fixedEndIndex != nil
            )
        }
    }

    private func dismissTopPreview() {
        previewVisibility.dismissTopPreview()
    }

    private func dismissSelectionSummary() {
        previewVisibility.dismissSelectionSummary()
    }

    private func moveAccessibilityCursor(
        _ direction: RecentChartAccessibilityCursorDirection
    ) {
        guard let index = accessibilityCursorState.move(
            direction,
            validCount: preparedData.bins.count
        ) else { return }
        updateHoveredIndex(index)
    }

    private func selectAccessibilityCursor() {
        guard let index = accessibilityCursorState.resolvedIndex(
            validCount: preparedData.bins.count
        ) else { return }
        accessibilityCursorState.select(index: index, validCount: preparedData.bins.count)
        updateConsumptionSelection(forClickedIndex: index)
    }
}

private struct RecentChartScrollButton: View {
    let direction: RecentChartScrollDirection
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(direction.accessibilityLabel, systemImage: direction.systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDisabled ? .secondary.opacity(0.45) : AppTheme.accentBlue)
                .frame(width: 24, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isDisabled ? AppTheme.solidControlBackground.opacity(0.55) : AppTheme.accentBlue.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isDisabled ? AppTheme.border.opacity(0.45) : AppTheme.accentBlue.opacity(0.28), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityRepresentation {
            RecentChartAccessibilityButtonRepresentation(
                presentation: direction.accessibilityButton(isEnabled: !isDisabled),
                action: action
            )
        }
    }
}

private struct RecentChartEdgeFadeOverlay: View {
    let state: RecentChartEdgeFadeState

    var body: some View {
        ZStack {
            if state.showsLeft {
                edgeFade(start: AppTheme.pageBackground.opacity(0.96), end: .clear)
                    .frame(width: 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if state.showsRight {
                edgeFade(start: .clear, end: AppTheme.pageBackground.opacity(0.96))
                    .frame(width: 26)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .allowsHitTesting(false)
    }

    private func edgeFade(start: Color, end: Color) -> some View {
        LinearGradient(
            colors: [start, end],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

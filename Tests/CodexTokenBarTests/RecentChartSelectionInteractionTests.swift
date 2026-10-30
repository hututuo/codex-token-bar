import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class RecentChartSelectionInteractionTests: XCTestCase {
    func testRevealingTopPreviewDoesNotChangeSelectionOrLowerCardDismissal() {
        var preview = RecentChartPreviewVisibilityState()
        preview.beginInteraction()
        preview.dismissTopPreview()
        preview.dismissSelectionSummary()
        let generation = preview.interactionGeneration
        preview.revealTopPreview()
        XCTAssertTrue(preview.showsTopPreview)
        XCTAssertFalse(preview.showsSelectionSummary)
        XCTAssertEqual(preview.interactionGeneration, generation)
    }

    func testGuideCursorFollowsEveryActualPolylineVertexAndIntermediateSegment() {
        for point in RecentChartGuideGeometry.curve { XCTAssertEqual(RecentChartGuideGeometry.point(at: point.x), point) }
        XCTAssertEqual(RecentChartGuideGeometry.point(at: 80), CGPoint(x: 80, y: 61.5))
        XCTAssertEqual(RecentChartGuideGeometry.point(at: 95).y, 49)
        XCTAssertEqual(RecentChartGuideGeometry.point(at: -10), RecentChartGuideGeometry.curve.first)
        XCTAssertEqual(RecentChartGuideGeometry.point(at: 500), RecentChartGuideGeometry.curve.last)
    }

    @MainActor
    func testGuideClickFeedbackPreview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CODEX_CHART_GUIDE_PREVIEW"] else {
            throw XCTSkip("Opt-in production guide screenshots")
        }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let steps: [RecentChartGuideStep] = [.hoverStart, .pressStart, .releaseStart, .moveRange, .hoverEnd, .pressEnd, .releaseEnd, .result]
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
                Text("正式引导组件 · 点击起点 / 点击终点").font(.system(size: 15, weight: .semibold))
                ForEach(0..<4) { row in
                    HStack(spacing: 20) {
                        ForEach(0..<2) { column in
                            RecentChartGuideDemo(step: steps[row * 2 + column]).frame(width: 220, height: 108)
                        }
                    }
                }
            }.padding(20).frame(width: 500, height: 550, alignment: .topLeading)
                .background(AppTheme.pageBackground).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 550), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("guide-click-phases-\(name).png"))
            window.orderOut(nil)
        }
    }

    func testSevenDayFineSeriesHitTestingUsesTheDrawnSubpixelSpacing() {
        let count = 30 * 24 * 12
        let width: CGFloat = 980 * 30 / 7
        let step = width / CGFloat(count - 1)
        let plot = CGRect(x: 0, y: 27, width: width, height: 215)
        XCTAssertLessThan(step, 1)
        // Both endpoints are in the trailing seven-day viewport. A one-pixel
        // denominator incorrectly resolves them to offscreen, older history.
        for index in [count - 2_000, count - 1_000, count - 1] {
            let x = min(CGFloat(index) * step, width - 0.000_001)
            XCTAssertEqual(RecentChartHitTesting.index(
                at: CGPoint(x: x, y: 100), in: plot, step: step, pointCount: count
            ), index)
        }
        XCTAssertNil(RecentChartHitTesting.index(
            at: CGPoint(x: 10, y: 10), in: plot, step: step, pointCount: count
        ))
        XCTAssertNil(RecentChartHitTesting.index(
            at: CGPoint(x: 10, y: 100), in: plot, step: 0, pointCount: count
        ))
    }

    func testUnifiedScaleMapUsesExplicitPerSeriesVisualRanges() {
        let scaleMap = RecentChartScaleMap(
            tokenValues: [50, 100],
            callValues: [5, 10],
            costs: [5, 17.5, 30, 0]
        )

        XCTAssertEqual(scaleMap.heightFraction(for: 100, series: .tokens), 0.65, accuracy: 0.000_001)
        XCTAssertEqual(scaleMap.heightFraction(for: 10, series: .calls), 1, accuracy: 0.000_001)
        XCTAssertEqual(scaleMap.heightFraction(for: 1, series: .cacheHitRate), 1, accuracy: 0.000_001)
        XCTAssertEqual(scaleMap.heightFraction(for: 100, series: .quota), 1, accuracy: 0.000_001)
        XCTAssertEqual(scaleMap.heightFraction(for: 5, series: .cost), 1.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(scaleMap.heightFraction(for: 17.5, series: .cost), 7.0 / 12.0, accuracy: 0.000_001)
        XCTAssertEqual(scaleMap.heightFraction(for: 30, series: .cost), 1, accuracy: 0.000_001)
    }

    func testTokenAndCostScaleDomainsFollowTheVisibleWindow() {
        let fixed = RecentChartFixedScaleMap(callValues: [1, 2, 4, 8])
        let firstWindow = RecentChartScaleMap(
            tokenValues: [50, 100],
            costValues: [1, 2],
            fixed: fixed
        )
        let secondWindow = RecentChartScaleMap(
            tokenValues: [200, 400],
            costValues: [4, 8],
            fixed: fixed
        )

        XCTAssertEqual(firstWindow.heightFraction(for: 100, series: .tokens), 0.65, accuracy: 0.000_001)
        XCTAssertEqual(secondWindow.heightFraction(for: 400, series: .tokens), 0.65, accuracy: 0.000_001)
        XCTAssertEqual(firstWindow.heightFraction(for: 8, series: .calls), 1, accuracy: 0.000_001)
        XCTAssertEqual(secondWindow.heightFraction(for: 8, series: .calls), 1, accuracy: 0.000_001)
        XCTAssertEqual(firstWindow.heightFraction(for: 1, series: .cost), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(firstWindow.heightFraction(for: 2, series: .cost), 1, accuracy: 0.000_001)
        XCTAssertEqual(secondWindow.heightFraction(for: 4, series: .cost), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(secondWindow.heightFraction(for: 8, series: .cost), 1, accuracy: 0.000_001)
    }

    @MainActor
    func testPlotDataBuildsOnlyTheRequestedRenderWindowWithGlobalCoordinates() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let bins = (0..<100).map { index in
            BinUsage(
                start: start.addingTimeInterval(Double(index) * 5 * 60),
                tokens: index + 1,
                calls: index % 7
            )
        }
        let prepared = RecentUsageChart.prepare(
            range: .twentyFourHours,
            recentBins: bins,
            hourlyBins: [],
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )
        let plot = CGRect(x: 0, y: 27, width: 990, height: 215)
        let step = plot.width / CGFloat(bins.count - 1)
        let fixed = RecentChartFixedScaleMap(callValues: bins.map(\.calls))
        let plotData = RecentChartPlotData(
            bins: bins,
            prepared: prepared,
            plot: plot,
            step: step,
            bucketCostsUSD: Array(repeating: 0, count: bins.count),
            fixedScales: fixed,
            renderRange: 18...32,
            scaleRange: 20...30
        )

        XCTAssertEqual(plotData.renderStartIndex, 18)
        XCTAssertEqual(plotData.renderEndIndex, 32)
        XCTAssertEqual(plotData.tokenPoints.count, 15)
        XCTAssertEqual(plotData.callPoints.count, 15)
        XCTAssertEqual(try XCTUnwrap(plotData.tokenPoints.first).x, 18 * step, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(plotData.tokenPoints.last).x, 32 * step, accuracy: 0.000_001)
        XCTAssertNotNil(plotData.tokenPoint(at: 20))
        XCTAssertNil(plotData.tokenPoint(at: 17))
        XCTAssertNil(plotData.tokenPoint(at: 33))
    }

    @MainActor
    func testHeadlineTotalsUseTheSelectedWindowInsteadOfRetainedHistory() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let recentBins = (0..<(30 * 24 * 12)).map { index in
            BinUsage(
                start: base.addingTimeInterval(Double(index) * RecentChartRange.twentyFourHours.bucketInterval),
                tokens: index + 1,
                calls: 1
            )
        }
        let hourlyBins = (0..<(365 * 24)).map { index in
            BinUsage(
                start: base.addingTimeInterval(Double(index) * RecentChartRange.sevenDays.bucketInterval),
                tokens: 10_000 + index,
                calls: 2
            )
        }

        func prepared(_ range: RecentChartRange) -> RecentChartPreparedData {
            RecentUsageChart.prepare(
                range: range,
                recentBins: recentBins,
                hourlyBins: hourlyBins,
                cacheRecentBins: [],
                cacheHourlyBins: [],
                quotaRecentBins: [],
                quotaHourlyBins: []
            )
        }

        let twentyFourHourData = prepared(.twentyFourHours)
        let twentyFourHourSummary = twentyFourHourData.visibleWindowSummary(for: nil)
        XCTAssertEqual(twentyFourHourData.bins.count, 30 * 24 * 12)
        XCTAssertEqual(twentyFourHourSummary.endIndex, twentyFourHourData.bins.count - 1)
        XCTAssertEqual(twentyFourHourSummary.endIndex - twentyFourHourSummary.startIndex + 1, 24 * 12)
        XCTAssertEqual(
            twentyFourHourSummary.tokenTotal,
            recentBins.suffix(24 * 12).reduce(0) { $0 + $1.tokens }
        )
        XCTAssertEqual(twentyFourHourSummary.callTotal, 24 * 12)
        let middlePresentation = RecentChartScrollPresentation(
            contentOffset: 10 * 980,
            viewportWidth: 980,
            contentWidth: RecentChartScrollMetrics.contentWidth(
                range: .twentyFourHours,
                bins: twentyFourHourData.bins,
                bucketInterval: twentyFourHourData.bucketInterval,
                viewportWidth: 980
            ),
            windowCount: RecentChartScrollMetrics.windowCount(
                range: .twentyFourHours,
                bins: twentyFourHourData.bins,
                bucketInterval: twentyFourHourData.bucketInterval
            )
        )
        let middleSummary = twentyFourHourData.visibleWindowSummary(for: middlePresentation)
        XCTAssertEqual(middleSummary.endIndex - middleSummary.startIndex + 1, 24 * 12)
        XCTAssertLessThan(middleSummary.endIndex, twentyFourHourSummary.startIndex)

        let sevenDayData = prepared(.sevenDays)
        let sevenDaySummary = sevenDayData.visibleWindowSummary(for: nil)
        XCTAssertEqual(sevenDayData.bins.count, 30 * 24)
        XCTAssertEqual(sevenDaySummary.endIndex - sevenDaySummary.startIndex + 1, 7 * 24)
        XCTAssertEqual(
            sevenDaySummary.tokenTotal,
            hourlyBins.suffix(7 * 24).reduce(0) { $0 + $1.tokens }
        )
        XCTAssertEqual(sevenDaySummary.callTotal, 7 * 24 * 2)

        let thirtyDayData = prepared(.thirtyDays)
        let thirtyDaySummary = thirtyDayData.visibleWindowSummary(for: nil)
        XCTAssertEqual(thirtyDayData.bins.count, 30 * 4)
        XCTAssertEqual(thirtyDaySummary.endIndex - thirtyDaySummary.startIndex + 1, 30 * 4)
        XCTAssertTrue(thirtyDayData.bins.allSatisfy {
            Int64($0.start.timeIntervalSince1970.rounded()) % Int64(6 * 60 * 60) == 0
        })
        let thirtyDayStart = try XCTUnwrap(thirtyDayData.bins.first?.start)
        let thirtyDayEnd = try XCTUnwrap(thirtyDayData.bins.last?.start)
            .addingTimeInterval(RecentChartRange.thirtyDays.bucketInterval)
        let expectedThirtyDayHourlyBins = hourlyBins.filter {
            $0.start >= thirtyDayStart && $0.start < thirtyDayEnd
        }
        XCTAssertEqual(
            thirtyDaySummary.tokenTotal,
            expectedThirtyDayHourlyBins.reduce(0) { $0 + $1.tokens }
        )
        XCTAssertEqual(
            thirtyDaySummary.callTotal,
            expectedThirtyDayHourlyBins.reduce(0) { $0 + $1.calls }
        )
    }

    @MainActor
    func testThirtyDayBucketsUseStableEpochAlignedSixHourBoundaries() {
        let oneHour = TimeInterval(60 * 60)
        let base = Date(timeIntervalSince1970: oneHour)
        let hourlyBins = (0..<(30 * 24)).map { index in
            BinUsage(
                start: base.addingTimeInterval(Double(index) * oneHour),
                tokens: index + 1,
                calls: 1
            )
        }

        let prepared = RecentUsageChart.prepare(
            range: .thirtyDays,
            recentBins: [],
            hourlyBins: hourlyBins,
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )

        XCTAssertEqual(prepared.bins.count, 30 * 4)
        XCTAssertTrue(prepared.bins.allSatisfy {
            Int64($0.start.timeIntervalSince1970.rounded()) % Int64(6 * 60 * 60) == 0
        })
        XCTAssertTrue(zip(prepared.bins, prepared.bins.dropFirst()).allSatisfy { pair in
            pair.1.start.timeIntervalSince(pair.0.start) == 6 * 60 * 60
        })
        XCTAssertEqual(prepared.bins.last?.start.timeIntervalSince1970, 30 * 24 * oneHour)
        XCTAssertEqual(prepared.bins.last?.tokens, hourlyBins.last?.tokens)
    }

    func testHoverBubbleClearsThePlotByAnExtraVerticalGutter() {
        XCTAssertEqual(recentChartHoverBubbleVerticalOffset, 74)
        XCTAssertEqual(recentChartHoverBubblePlotClearance, 10)
        XCTAssertEqual(recentChartHoverBubbleTopReveal, 220)
    }

    @MainActor
    func testTimeMarkersUseThreeHourCadenceForTheTwentyFourHourRange() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let recentBins = (0..<72).map { index in
            BinUsage(
                start: base.addingTimeInterval(Double(index) * RecentChartRange.twentyFourHours.bucketInterval),
                tokens: index + 1,
                calls: 1
            )
        }

        let prepared = RecentUsageChart.prepare(
            range: .twentyFourHours,
            recentBins: recentBins,
            hourlyBins: [],
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )

        XCTAssertEqual(RecentChartRange.twentyFourHours.timeMarkerInterval, 3 * 60 * 60)
        XCTAssertEqual(prepared.markerIndices, [0, 36, 71])
    }

    func testAccessibilityCursorMovesSelectsClampsAndResets() {
        var cursor = RecentChartAccessibilityCursorState()

        XCTAssertEqual(cursor.resolvedIndex(validCount: 5), 4)
        XCTAssertEqual(cursor.move(.previous, validCount: 5), 3)
        XCTAssertEqual(cursor.move(.next, validCount: 5), 4)
        XCTAssertEqual(cursor.move(.next, validCount: 5), 4)

        cursor.select(index: 1, validCount: 5)
        XCTAssertEqual(cursor.index, 1)
        cursor.clamp(validCount: 1)
        XCTAssertEqual(cursor.index, 0)
        cursor.reset()
        XCTAssertNil(cursor.index)
        XCTAssertNil(cursor.resolvedIndex(validCount: 0))
    }

    func testPreviewCloseIsGenerationScopedAndDoesNotClearSelectionState() {
        var preview = RecentChartPreviewVisibilityState()
        var selection = RecentChartConsumptionSelectionState()

        selection.click(index: 2, validCount: 8)
        preview.beginInteraction()
        preview.dismissTopPreview()

        XCTAssertFalse(preview.showsTopPreview)
        XCTAssertTrue(preview.showsSelectionSummary)
        XCTAssertEqual(selection.startIndex, 2)
        XCTAssertNil(selection.fixedEndIndex)

        // The next distinct interaction reopens both cards. The selected
        // range remains owned by the two-click state rather than dismissal.
        preview.beginInteraction()
        XCTAssertTrue(preview.showsTopPreview)
        XCTAssertTrue(preview.showsSelectionSummary)
        XCTAssertEqual(selection.startIndex, 2)

        selection.click(index: 5, validCount: 8)
        preview.dismissSelectionSummary()
        XCTAssertFalse(preview.showsSelectionSummary)
        XCTAssertEqual(selection.fixedEndIndex, 5)
    }

    func testPreviewCardsExposeCloseActionsForPointAndFixedSelection() throws {
        let componentSource = try String(
            contentsOfFile: "Sources/CodexTokenBar/RecentUsageChartComponents.swift",
            encoding: .utf8
        )
        let chartSource = try String(
            contentsOfFile: "Sources/CodexTokenBar/RecentUsageChart.swift",
            encoding: .utf8
        )
        XCTAssertTrue(componentSource.contains("关闭当前点预览"))
        XCTAssertTrue(componentSource.contains("关闭选中区间预览"))
        XCTAssertTrue(componentSource.contains(".allowsHitTesting(true)"))
        XCTAssertTrue(chartSource.contains(".onKeyPress(.escape)"))
        XCTAssertTrue(
            chartSource.contains("RecentChartOutsideClickMonitor(onOutsideClick: resetChartInteractionIfNeeded)"),
            "the production chart must connect its full section bounds to outside-click reset"
        )
    }

    @MainActor
    func testOutsideClickMonitorIgnoresChartBoundsAndReportsBlankSpace() {
        var outsideClickCount = 0
        let monitorView = RecentChartOutsideClickMonitor.MonitoringView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100)
        )
        monitorView.onOutsideClick = { outsideClickCount += 1 }

        monitorView.observeLocalClick(NSPoint(x: 100, y: 50))
        XCTAssertEqual(outsideClickCount, 0)
        monitorView.observeLocalClick(NSPoint(x: 100, y: 101))
        XCTAssertEqual(outsideClickCount, 1)
    }

    func testFixedSelectionHoverDoesNotReopenDismissedTopPreview() {
        var preview = RecentChartPreviewVisibilityState()
        var selection = RecentChartConsumptionSelectionState()

        selection.click(index: 2, validCount: 8)
        preview.beginInteraction()
        selection.click(index: 5, validCount: 8)
        preview.beginInteraction()
        preview.dismissTopPreview()
        XCTAssertFalse(preview.showsTopPreview)

        preview.beginHoverInteraction(selectionIsFixed: selection.fixedEndIndex != nil)
        XCTAssertFalse(
            preview.showsTopPreview,
            "hovering a fixed selection must not reopen a card explicitly closed by the user"
        )

        selection.click(index: 6, validCount: 8)
        preview.beginInteraction()
        XCTAssertTrue(preview.showsTopPreview, "a new click starts a new interaction generation")
        XCTAssertEqual(selection.startIndex, 6, "a third in-plot click starts the next range")
        XCTAssertNil(selection.fixedEndIndex)

        var openHoverPreview = RecentChartPreviewVisibilityState()
        openHoverPreview.beginInteraction()
        openHoverPreview.dismissTopPreview()
        openHoverPreview.beginHoverInteraction(selectionIsFixed: false)
        XCTAssertTrue(openHoverPreview.showsTopPreview, "ordinary hover changes should reopen the point preview")
    }

    func testProductionChartComputesSelectionOncePerBodyEvaluation() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexTokenBar/RecentUsageChart.swift",
            encoding: .utf8
        )
        XCTAssertEqual(
            source.components(separatedBy: "activeConsumptionSelection").count - 1,
            2,
            "selection should appear only at its declaration and the single body-level evaluation"
        )
        XCTAssertTrue(source.contains("let liveHoverIndex = hoveredIndex"))
        XCTAssertTrue(source.contains("hoveredIndexSnapshot: liveHoverIndex"))
        XCTAssertTrue(source.contains("activeSelectionAttribution(\n            for: consumptionSelection"))
        XCTAssertTrue(source.contains("cachedFixedConsumptionSelection"))
        XCTAssertTrue(source.contains("rebuildFixedConsumptionSelectionCache()"))
        XCTAssertFalse(
            source.contains("guard selectedRange == .twentyFourHours"),
            "shared-account attribution must not be restricted to 24h"
        )
        XCTAssertTrue(
            source.contains("consumptionSelectionState.fixedEndIndex != nil"),
            "shared-account attribution must wait for the second click that fixes the range"
        )
    }

    func testFixedTimeAnchorRelocatesAfterBinsArePrepended() throws {
        let interval: TimeInterval = 5 * 60
        let base = Date(timeIntervalSince1970: 12_000)
        let anchor = RecentChartSelectionTimeAnchor(
            startDate: base.addingTimeInterval(interval),
            endDate: base.addingTimeInterval(interval * 4),
            bucketInterval: interval,
            bucketCount: 3
        )
        let refreshedBins = bins(
            startingAt: base.addingTimeInterval(-interval),
            count: 7,
            interval: interval
        )

        let relocated = try XCTUnwrap(
            anchor.relocatedIndices(in: refreshedBins, bucketInterval: interval)
        )

        XCTAssertEqual(relocated, RecentChartSelectionIndices(startIndex: 2, endIndex: 4))
        XCTAssertTrue(relocated.isFixed)
    }

    func testFixedTimeAnchorFailsClosedWhenAnInteriorBucketDisappears() {
        let interval: TimeInterval = 5 * 60
        let base = Date(timeIntervalSince1970: 18_000)
        let anchor = RecentChartSelectionTimeAnchor(
            startDate: base,
            endDate: base.addingTimeInterval(interval * 3),
            bucketInterval: interval,
            bucketCount: 3
        )
        let incompleteBins = [0, 2, 3].map { offset in
            BinUsage(
                start: base.addingTimeInterval(Double(offset) * interval),
                tokens: 1,
                calls: 1
            )
        }

        XCTAssertNil(anchor.relocatedIndices(in: incompleteBins, bucketInterval: interval))
        XCTAssertEqual(
            RecentChartSelectionInvalidationPresentation.message,
            "历史数据已刷新，原选区时间已失效，请重新选择。"
        )
    }

    func testPreviewTimeAnchorRelocatesItsStartWithoutInventingAnEnd() throws {
        let interval: TimeInterval = 5 * 60
        let base = Date(timeIntervalSince1970: 24_000)
        let anchor = RecentChartSelectionTimeAnchor(
            startDate: base.addingTimeInterval(interval * 2),
            bucketInterval: interval
        )
        let refreshedBins = bins(
            startingAt: base.addingTimeInterval(-interval),
            count: 6,
            interval: interval
        )

        let relocated = try XCTUnwrap(
            anchor.relocatedIndices(in: refreshedBins, bucketInterval: interval)
        )

        XCTAssertEqual(relocated, RecentChartSelectionIndices(startIndex: 3, endIndex: nil))
        XCTAssertFalse(relocated.isFixed)
    }

    @MainActor
    func testProductionChartKeepsSecondClickAndSummaryButtonsReachable() throws {
        let defaultsSuite = "RecentChartSelectionInteractionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.set(
            RecentChartRange.twentyFourHours.rawValue,
            forKey: "recentChartRange"
        )
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let input = makeRecentChartInteractionPreparationInput()
        let chart = RecentUsageChart(
            bins: input.bins,
            hourlyBins: input.hourlyBins,
            cacheRecentBins: input.cacheRecentBins,
            cacheHourlyBins: input.cacheHourlyBins,
            quotaRecentBins: input.quotaRecentBins,
            quotaHourlyBins: input.quotaHourlyBins
        )
        .defaultAppStorage(defaults)
        let hostingView = NSHostingView(
            rootView: chart.frame(maxHeight: .infinity, alignment: .topLeading)
        )
        // Leave enough vertical room for the fixed selection summary. A
        // 520-point host is shorter than the rendered summary state and causes
        // AppKit to center an otherwise stable chart by a few points.
        hostingView.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        // Preparation now runs off the main thread. Wait for the production
        // plot, so a click cannot accidentally exercise its loading state.
        let preparationDeadline = Date().addingTimeInterval(2)
        while firstRecentChartTrackingView(in: hostingView) == nil, Date() < preparationDeadline {
            runRecentChartMainLoop()
            hostingView.layoutSubtreeIfNeeded()
        }
        let initialFittingHeight = hostingView.fittingSize.height

        var trackingView = try XCTUnwrap(firstRecentChartTrackingView(in: hostingView))
        let initialTrackingFrame = trackingView.convert(trackingView.bounds, to: hostingView)
        try clickRecentChart(
            trackingView,
            window: window,
            localPoint: NSPoint(x: 110, y: trackingView.bounds.midY)
        )
        runRecentChartMainLoop()
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, initialFittingHeight + 100)

        trackingView = try XCTUnwrap(firstRecentChartTrackingView(in: hostingView))
        let updatedTrackingFrame = trackingView.convert(trackingView.bounds, to: hostingView)
        XCTAssertEqual(updatedTrackingFrame.minY, initialTrackingFrame.minY, accuracy: 0.5)
        XCTAssertEqual(updatedTrackingFrame.height, initialTrackingFrame.height, accuracy: 0.5)
        try clickRecentChart(
            trackingView,
            window: window,
            localPoint: NSPoint(x: 410, y: trackingView.bounds.midY)
        )
        runRecentChartMainLoop()
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.height, initialFittingHeight + 100)
    }

    @MainActor
    func testProductionCacheToggleRepaintsPlotWithoutNewUsageData() throws {
        let defaults = UserDefaults.standard
        let key = RecentChartSeriesVisibility.cacheHitRateDefaultsKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let suiteName = "RecentChartToggle-\(UUID().uuidString)"
        let isolated = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        isolated.set(RecentChartRange.twentyFourHours.rawValue, forKey: "recentChartRange")
        defer { isolated.removePersistentDomain(forName: suiteName) }
        let input = makeRecentChartInteractionPreparationInput()
        let host = NSHostingView(rootView: RecentUsageChart(
            bins: input.bins, hourlyBins: input.hourlyBins,
            cacheRecentBins: input.cacheRecentBins, cacheHourlyBins: input.cacheHourlyBins,
            quotaRecentBins: [], quotaHourlyBins: [],
            currentFiveHourQuotaPresent: false, currentSevenDayQuotaPresent: false
        ).defaultAppStorage(isolated).frame(maxHeight: .infinity, alignment: .topLeading).background(AppTheme.pageBackground))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(3)
        while firstRecentChartTrackingView(in: host) == nil, Date() < deadline {
            runRecentChartMainLoop()
            host.layoutSubtreeIfNeeded()
        }
        runRecentChartMainLoop()
        host.layoutSubtreeIfNeeded()
        func cyanPlotPixels() throws -> Int {
            let tracker = try XCTUnwrap(firstRecentChartTrackingView(in: host))
            let rect = tracker.convert(tracker.bounds, to: host)
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let scale = CGFloat(image.pixelsHigh) / host.bounds.height
            let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
            let rows = max(Int(top * scale), 0)..<min(Int((top + rect.height) * scale), image.pixelsHigh)
            var count = 0
            for y in rows {
                for x in 0..<image.pixelsWide {
                    guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.alphaComponent > 0.9, c.greenComponent > 0.7, c.blueComponent > 0.85,
                       c.redComponent < 0.55, c.greenComponent - c.redComponent > 0.25, c.blueComponent - c.greenComponent < 0.20 { count += 1 }
                }
            }
            return count
        }
        if let folder = ProcessInfo.processInfo.environment["CODEX_CHART_TOGGLE_PREVIEW"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("toggle-fixture-before.png"))
        }
        let before = try cyanPlotPixels()
        XCTAssertGreaterThan(before, 20, "Fixture must render actual cache observations")
        // Four production toggles, with cache immediately before the rightmost cost toggle.
        try clickRecentChartWindow(window, at: NSPoint(x: 895, y: host.bounds.height - 65))
        runRecentChartMainLoop()
        host.layoutSubtreeIfNeeded()
        let persistDeadline = Date().addingTimeInterval(0.3)
        while defaults.object(forKey: key) as? Bool != false, Date() < persistDeadline { runRecentChartMainLoop() }
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false, "The real toggle must switch off")
        let after = try cyanPlotPixels()
        XCTAssertLessThan(after, before / 4, "Cache points must disappear immediately, without a scanner refresh")
        try clickRecentChartWindow(window, at: NSPoint(x: 895, y: host.bounds.height - 65))
        runRecentChartMainLoop()
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try cyanPlotPixels(), before * 3 / 4, "Re-enabling must restore observations")
    }

    @MainActor
    func testProductionSummaryCardReceivesRealDetailAndCloseClicks() throws {
        let breakdown = TokenCacheBreakdown(
            inputTokens: 240_000,
            cachedInputTokens: 80_000,
            outputTokens: 40_000,
            reasoningOutputTokens: 0,
            totalTokens: 280_000,
            calls: 3
        )
        let priceCard = QuotaConsumptionPriceCard.officialAPI(.gpt56Sol)
        let selection = QuotaConsumptionSelection(
            startIndex: 0,
            endIndex: 2,
            bucketCount: 3,
            startDate: Date(timeIntervalSince1970: 30_000),
            endDate: Date(timeIntervalSince1970: 30_900),
            priceCard: priceCard,
            breakdown: breakdown,
            fiveHour: QuotaConsumptionEstimator.estimate(
                breakdown: breakdown,
                quotaDropPercent: 10,
                priceCard: priceCard
            ),
            sevenDay: QuotaConsumptionEstimator.estimate(
                breakdown: breakdown,
                quotaDropPercent: 1.6,
                priceCard: priceCard
            )
        )
        var didClose = false
        let card = RecentChartQuotaEstimateOverlay(
            selection: selection,
            attribution: nil,
            isSelectionFixed: true,
            showsFiveHourQuota: true,
            showsSevenDayQuota: true,
            currentFiveHourQuotaPresent: true,
            currentSevenDayQuotaPresent: true,
            onClose: { didClose = true }
        )
        let hostingView = NSHostingView(rootView: card)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: fittingSize.width,
            height: fittingSize.height
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        runRecentChartMainLoop()

        let windowsBeforeDetail = Set(NSApp.windows.map(ObjectIdentifier.init))
        try clickRecentChartWindow(
            window,
            at: NSPoint(x: fittingSize.width - 50, y: 23)
        )
        runRecentChartMainLoop()
        let detailWindow = (window.childWindows ?? []).first
            ?? NSApp.windows.first { candidate in
                candidate !== window && !windowsBeforeDetail.contains(ObjectIdentifier(candidate))
            }
        let openedDetailWindow = try XCTUnwrap(detailWindow)
        XCTAssertGreaterThanOrEqual(openedDetailWindow.frame.width, 600)
        XCTAssertGreaterThanOrEqual(openedDetailWindow.frame.height, 400)
        let detailBounds = try XCTUnwrap(openedDetailWindow.contentView).bounds
        try clickRecentChartWindow(
            openedDetailWindow,
            at: NSPoint(x: detailBounds.maxX - 32, y: detailBounds.maxY - 31)
        )
        // Sheet dismissal is asynchronous and can animate longer than the
        // ordinary 60ms layout tick on a hosted Mac. Keep the real mouse click
        // and the final visibility assertion, but wait for its completion.
        let closeDeadline = Date().addingTimeInterval(2)
        while openedDetailWindow.isVisible && Date() < closeDeadline {
            runRecentChartMainLoop()
        }
        XCTAssertFalse(openedDetailWindow.isVisible)

        try clickRecentChartWindow(
            window,
            at: NSPoint(x: fittingSize.width - 26, y: fittingSize.height - 23)
        )
        runRecentChartMainLoop()
        XCTAssertTrue(didClose)

        XCTAssertEqual(fittingSize.width, 460, accuracy: 0.5)
    }

    private func bins(
        startingAt start: Date,
        count: Int,
        interval: TimeInterval
    ) -> [BinUsage] {
        (0..<count).map { index in
            BinUsage(
                start: start.addingTimeInterval(Double(index) * interval),
                tokens: (index + 1) * 1_000,
                calls: index + 1
            )
        }
    }
}

// Shared with the preparation-store regression so the real-click fixture must
// remain valid when the production store prewarms every range, including 30d.
func makeRecentChartInteractionPreparationInput() -> RecentChartPreparationInput {
    let interval = RecentChartRange.twentyFourHours.bucketInterval
    let base = Date(timeIntervalSince1970: 30_000)
    let usageBins = (0..<12).map { index in
        BinUsage(
            start: base.addingTimeInterval(Double(index) * interval),
            tokens: (index + 1) * 1_000,
            calls: index + 1
        )
    }
    let cacheBins = usageBins.map { bin in
        TokenCacheBucket(
            start: bin.start,
            breakdown: TokenCacheBreakdown(
                inputTokens: 24_000,
                cachedInputTokens: 8_000,
                outputTokens: 4_000,
                reasoningOutputTokens: 0,
                totalTokens: 28_000,
                calls: 1
            )
        )
    }
    let resetDate = base.addingTimeInterval(7 * 24 * 60 * 60)
    let quotaBins = usageBins.enumerated().map { index, bin in
        let fiveHourRemaining = 100 - Double(index) * 3
        let sevenDayRemaining = 100 - Double(index) * 0.3
        let observedAt = bin.start.addingTimeInterval(interval / 2)
        return QuotaHistoryRecentBucket(
            start: bin.start,
            fiveHourRemainingPercent: fiveHourRemaining,
            sevenDayRemainingPercent: sevenDayRemaining,
            fiveHourObservations: [
                QuotaHistoryObservation(
                    observedAt: observedAt,
                    remainingPercent: fiveHourRemaining,
                    resetsAt: resetDate
                )
            ],
            sevenDayObservations: [
                QuotaHistoryObservation(
                    observedAt: observedAt,
                    remainingPercent: sevenDayRemaining,
                    resetsAt: resetDate
                )
            ]
        )
    }
    // Hourly inputs represent one bucket per hour. Passing five-minute quota
    // bins here aliases eight distinct samples to hour key 8 during 30d prewarm.
    let hourInterval = RecentChartRange.sevenDays.bucketInterval
    let indicesByHour = Dictionary(grouping: usageBins.indices) { index in
        Int(floor(usageBins[index].start.timeIntervalSince1970 / hourInterval))
    }
    let hours = indicesByHour.keys.sorted()
    let hourlyBins = hours.map { hour in
        let indices = indicesByHour[hour] ?? []
        return BinUsage(
            start: Date(timeIntervalSince1970: Double(hour) * hourInterval),
            tokens: indices.reduce(0) { $0 + usageBins[$1].tokens },
            calls: indices.reduce(0) { $0 + usageBins[$1].calls }
        )
    }
    let hourlyCacheBins = hours.map { hour in
        TokenCacheBucket(
            start: Date(timeIntervalSince1970: Double(hour) * hourInterval),
            breakdown: (indicesByHour[hour] ?? []).map { cacheBins[$0].breakdown }.combined
        )
    }
    let hourlyQuotaBins = hours.map { hour in
        let indices = indicesByHour[hour] ?? []
        let last = indices.last.map { quotaBins[$0] }
        // Remaining quota is an end-of-bucket state, not an additive counter.
        // Keep every observed sample for the selection's consumption estimate.
        return QuotaHistoryRecentBucket(
            start: Date(timeIntervalSince1970: Double(hour) * hourInterval),
            fiveHourRemainingPercent: last?.fiveHourRemainingPercent,
            sevenDayRemainingPercent: last?.sevenDayRemainingPercent,
            fiveHourObservations: indices.flatMap { quotaBins[$0].fiveHourObservations },
            sevenDayObservations: indices.flatMap { quotaBins[$0].sevenDayObservations }
        )
    }
    return RecentChartPreparationInput(
        bins: usageBins,
        hourlyBins: hourlyBins,
        cacheRecentBins: cacheBins,
        cacheHourlyBins: hourlyCacheBins,
        attributionEvents: [],
        quotaRecentBins: quotaBins,
        quotaHourlyBins: hourlyQuotaBins
    )
}

@MainActor
private func firstRecentChartTrackingView(in root: NSView) -> HoverTrackingArea.TrackingView? {
    if let trackingView = root as? HoverTrackingArea.TrackingView {
        return trackingView
    }
    for subview in root.subviews {
        if let trackingView = firstRecentChartTrackingView(in: subview) {
            return trackingView
        }
    }
    return nil
}

@MainActor
private func clickRecentChart(
    _ trackingView: HoverTrackingArea.TrackingView,
    window: NSWindow,
    localPoint: NSPoint
) throws {
    let windowPoint = trackingView.convert(localPoint, to: nil)
    XCTAssertTrue(window.contentView?.hitTest(windowPoint) === trackingView)
    let timestamp = ProcessInfo.processInfo.systemUptime
    let mouseDown = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )
    let mouseUp = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
    )
    window.sendEvent(mouseDown)
    window.sendEvent(mouseUp)
}

@MainActor
private func clickRecentChartWindow(_ window: NSWindow, at windowPoint: NSPoint) throws {
    XCTAssertNotNil(window.contentView?.hitTest(windowPoint))
    let timestamp = ProcessInfo.processInfo.systemUptime
    let mouseDown = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )
    let mouseUp = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
    )
    window.sendEvent(mouseDown)
    window.sendEvent(mouseUp)
}

@MainActor
private func runRecentChartMainLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.06))
}

import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class RecentChartSelectionInteractionTests: XCTestCase {
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
        XCTAssertTrue(source.contains("chartPlot(consumptionSelection: consumptionSelection)"))
        XCTAssertTrue(source.contains("activeSelectionAttribution(\n            for: consumptionSelection"))
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

        let interval = RecentChartRange.twentyFourHours.bucketInterval
        let base = Date(timeIntervalSince1970: 30_000)
        let usageBins = bins(startingAt: base, count: 12, interval: interval)
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
        let chart = RecentUsageChart(
            bins: usageBins,
            hourlyBins: usageBins,
            cacheRecentBins: cacheBins,
            cacheHourlyBins: cacheBins,
            quotaRecentBins: quotaBins,
            quotaHourlyBins: quotaBins
        )
        .defaultAppStorage(defaults)
        let hostingView = NSHostingView(
            rootView: chart.frame(maxHeight: .infinity, alignment: .topLeading)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 980, height: 520)
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
        runRecentChartMainLoop()
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

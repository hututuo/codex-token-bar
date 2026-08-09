import XCTest
@testable import CodexTokenBar

final class CodexRadarViewPlacementTests: XCTestCase {
    func testDashboardPlacesRadarStripAboveLiveRateView() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let source = try String(contentsOf: dashboardView, encoding: .utf8)

        let radarRange = try XCTUnwrap(source.range(of: "CodexRadarStrip("))
        let liveRateRange = try XCTUnwrap(source.range(of: "LiveRateView("))

        XCTAssertLessThan(radarRange.lowerBound, liveRateRange.lowerBound)
    }

    func testRadarDetailRefreshAlsoRetriesCrowdRadar() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let source = try String(contentsOf: dashboardView, encoding: .utf8)
        let overlayStart = try XCTUnwrap(source.range(of: "private var radarDetailOverlayCard"))
        let overlayEnd = try XCTUnwrap(source.range(of: "private func presentExportResult", range: overlayStart.upperBound..<source.endIndex))
        let overlaySource = String(source[overlayStart.lowerBound..<overlayEnd.lowerBound])

        XCTAssertTrue(overlaySource.contains("radarStore.refreshDetail()"))
        XCTAssertTrue(overlaySource.contains("radarStore.refresh()"))
        XCTAssertTrue(overlaySource.contains("radarStore.isDetailRefreshing || radarStore.isRefreshing"))
    }

    func testRadarStoreDefaultsToTenMinuteRefresh() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let storeFile = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarStore.swift")
        let source = try String(contentsOf: storeFile, encoding: .utf8)

        XCTAssertTrue(source.contains("refreshInterval: TimeInterval = 600"))
    }

    func testSharedAccountRefreshSignatureIncludesRadarSourceKind() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let source = try String(contentsOf: dashboardView, encoding: .utf8)

        XCTAssertTrue(source.contains("radar?.sourceKind ?? \"\""))
    }

    func testRadarStripBalancesOfficialAndCrowdRadarsInMiddleColumns() {
        let widths = CodexRadarStrip.columnWidths(totalWidth: 800)
        let evenColumnWidth = 800 / 4.0

        XCTAssertLessThan(widths.window, widths.officialRadar)
        XCTAssertLessThan(widths.window, evenColumnWidth)
        XCTAssertEqual(widths.officialRadar, widths.crowdRadar, accuracy: 0.01)
        XCTAssertGreaterThan(widths.officialRadar, evenColumnWidth)
        XCTAssertGreaterThan(widths.quota, widths.window)
        XCTAssertEqual(widths.window + widths.officialRadar + widths.crowdRadar + widths.quota, 800, accuracy: 0.01)
    }

    func testRadarDetailUsesSeparatedPanelsAndFramedTables() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let radarView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarView.swift")
        let source = try String(contentsOf: radarView, encoding: .utf8)

        XCTAssertTrue(source.contains("CodexRadarDetailSubsection("))
        XCTAssertTrue(source.contains("private struct CodexRadarDetailSubsection"))
        XCTAssertTrue(source.contains("private struct CodexRadarTableContainer"))
        XCTAssertTrue(source.contains("CodexRadarTableContainer"))
    }

    func testRadarActionUsesUrgentAccentInDetailAndCompactSurfaces() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let radarView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarView.swift")
        let compactSurface = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")
        let radarSource = try String(contentsOf: radarView, encoding: .utf8)
        let compactSource = try String(contentsOf: compactSurface, encoding: .utf8)

        XCTAssertTrue(radarSource.contains("valueColors: [\"建议动作\": AppTheme.radarActionColor(snapshot.recommendedAction)]"))
        XCTAssertTrue(compactSource.contains("let actionPrimaryColor = AppTheme.radarActionRole(snapshot?.recommendedAction) == .red"))
        XCTAssertTrue(compactSource.contains(".foregroundStyle(actionPrimaryColor)"))
    }

    func testRadarDetailChartsUseAxesAndSelectableModelSeries() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let radarView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarView.swift")
        let source = try String(contentsOf: radarView, encoding: .utf8)

        XCTAssertTrue(source.contains("CodexRadarSeriesLineChart("))
        XCTAssertTrue(source.contains("ChartLineToggle("))
        XCTAssertTrue(source.contains("xAxisTitle:"))
        XCTAssertTrue(source.contains("yAxisTitle:"))
        XCTAssertTrue(source.contains("selectedModelSeriesIDs"))
    }

    func testRadarDetailChartsShowAllDatesAndHoverDetails() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let radarView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarView.swift")
        let source = try String(contentsOf: radarView, encoding: .utf8)

        XCTAssertTrue(source.contains("@State private var hoveredChartIndex"))
        XCTAssertTrue(source.contains("allXMarkerIndices"))
        XCTAssertTrue(source.contains("CodexRadarChartHoverBubble"))
        XCTAssertTrue(source.contains("HoverTrackingArea("))
    }

    func testQuotaChartHasWindowAndTierSelectors() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let radarView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarView.swift")
        let source = try String(contentsOf: radarView, encoding: .utf8)

        XCTAssertTrue(source.contains("selectedQuotaWindow"))
        XCTAssertTrue(source.contains("selectedQuotaTierIDs"))
        XCTAssertTrue(source.contains("CodexRadarQuotaWindowSelector"))
        XCTAssertTrue(source.contains("quotaRadar.resolvedWindow(selectedQuotaWindow)"))
        XCTAssertTrue(source.contains("quotaRadar.chartSeries(for: activeQuotaWindow)"))
        XCTAssertTrue(source.contains("windows: quotaRadar.availableWindows"))
    }

    func testQuotaWindowSelectorUsesFullSegmentHitTargets() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let radarView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarView.swift")
        let source = try String(contentsOf: radarView, encoding: .utf8)

        XCTAssertTrue(source.contains(".frame(width: 46, height: 26)"))
        XCTAssertTrue(source.contains(".contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))"))
    }

    func testRadarStripShowsTwoMiddleRadarsAndSourceCredit() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let radarView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarView.swift")
        let source = try String(contentsOf: radarView, encoding: .utf8)

        XCTAssertTrue(source.contains("snapshot?.modelIQ.primaryModelPoint"))
        XCTAssertTrue(source.contains("snapshot?.modelIQ.secondaryModelRows ?? []"))
        XCTAssertTrue(source.contains("CodexRadarHeaderSourceCredit(snapshot: snapshot)"))
        XCTAssertTrue(source.contains("private struct CodexRadarHeaderSourceCredit"))
        XCTAssertTrue(source.contains("CodexCrowdRadarBlock("))
        XCTAssertTrue(source.contains("staleDataDisplayed: crowdStaleDataDisplayed"))
        XCTAssertTrue(source.contains("private struct CodexCrowdRadarBlock"))
        XCTAssertTrue(source.contains("\"官方雷达\""))
        XCTAssertTrue(source.contains("\"众测雷达\""))
        XCTAssertTrue(source.contains("Codex 雷达  codexradar.com"))

        let window = try XCTUnwrap(source.range(of: "CodexRadarWindowBlock(snapshot: snapshot)"))
        let official = try XCTUnwrap(source.range(of: "CodexRadarModelIQBlock(snapshot: snapshot)"))
        let crowd = try XCTUnwrap(source.range(of: "CodexCrowdRadarBlock("))
        let quota = try XCTUnwrap(source.range(of: "CodexRadarQuotaBlock(snapshot: snapshot)"))
        XCTAssertLessThan(window.lowerBound, official.lowerBound)
        XCTAssertLessThan(official.lowerBound, crowd.lowerBound)
        XCTAssertLessThan(crowd.lowerBound, quota.lowerBound)
    }

    func testRadarDetailKeepsEnvironmentPressureAfterSummaryReplacement() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let radarView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarView.swift")
        let source = try String(contentsOf: radarView, encoding: .utf8)

        XCTAssertTrue(source.contains("CodexRadarEnvironmentDetail(snapshot: snapshot, feedItems: feedItems)"))
        XCTAssertTrue(source.contains("private struct CodexRadarEnvironmentDetail"))
        XCTAssertTrue(source.contains("\"环境压力与资讯\""))
        XCTAssertFalse(source.contains("private struct CodexRadarEnvironmentBlock"))
        XCTAssertTrue(source.contains("众测刷新失败，显示上次排行"))
    }

    func testRadarStripBalancesAccentColorAcrossEverySummaryColumn() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let radarView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarView.swift")
        let source = try String(contentsOf: radarView, encoding: .utf8)

        XCTAssertTrue(source.contains(".foregroundStyle(primaryAccent ?? .secondary)"))
        XCTAssertTrue(source.contains("accent: AppTheme.accentCyan"))
        XCTAssertTrue(source.contains("let bestAccent = best.map { accent(for: $0) }"))
        XCTAssertTrue(
            source.contains(
                """
                AppTheme.radarScoreColor(
                            passed: model.scorePassed,
                            tasks: model.scoreSamples,
                            score: model.iq
                        )
                """
            )
        )
        XCTAssertTrue(source.contains("Text(title)\n                .foregroundStyle(accent ?? .secondary)"))
    }
}

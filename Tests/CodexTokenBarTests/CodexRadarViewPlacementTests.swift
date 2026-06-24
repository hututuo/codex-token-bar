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
        XCTAssertTrue(source.contains("@StateObject private var radarStore = CodexRadarStore()"))
        XCTAssertTrue(source.contains("showingCodexRadarDetails"))
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

    func testRadarStripMovesModelIQLeftOfEvenColumns() {
        let widths = CodexRadarStrip.columnWidths(totalWidth: 800)
        let evenColumnWidth = 800 / 4.0

        XCTAssertLessThan(widths.window, widths.modelIQ)
        XCTAssertLessThan(widths.window, evenColumnWidth)
        XCTAssertLessThan(widths.window + 1, evenColumnWidth + 1)
        XCTAssertGreaterThan(widths.modelIQ, evenColumnWidth)
        XCTAssertEqual(widths.window + widths.modelIQ + widths.quota + widths.environment, 800, accuracy: 0.01)
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
        XCTAssertTrue(source.contains("quotaRadar.chartSeries(for: selectedQuotaWindow)"))
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

    func testRadarStripShowsSecondaryModelsAndSourceCredit() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let radarView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarView.swift")
        let source = try String(contentsOf: radarView, encoding: .utf8)

        XCTAssertTrue(source.contains("snapshot?.modelIQ.primaryModelRow.point"))
        XCTAssertTrue(source.contains("snapshot?.modelIQ.secondaryModelRows ?? []"))
        XCTAssertTrue(source.contains("CodexRadarHeaderSourceCredit(snapshot: snapshot)"))
        XCTAssertTrue(source.contains("private struct CodexRadarHeaderSourceCredit"))
        XCTAssertTrue(source.contains("CodexRadarEnvironmentBlock(snapshot: snapshot)"))
        XCTAssertTrue(source.contains("private struct CodexRadarEnvironmentBlock"))
        XCTAssertTrue(source.contains("Codex 雷达  codexradar.com"))
    }
}

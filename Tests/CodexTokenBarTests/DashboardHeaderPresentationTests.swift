import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class DashboardHeaderPresentationTests: XCTestCase {
    func testMarkAllReadRemainsVisibleWithIdleToneAtZeroUnread() {
        let presentation = DashboardMarkAllReadPresentation(unreadCount: 0, isBusy: false)

        XCTAssertEqual(presentation.tone, .idle)
        XCTAssertTrue(presentation.isEnabled)
        XCTAssertEqual(presentation.accessibilityLabel, "全部已读")
        XCTAssertEqual(presentation.accessibilityValue, "当前没有未读会话，可重新建立已读基线")
    }

    func testMarkAllReadUsesActiveToneWithUnreadAndDisablesOnlyWhileBusy() {
        let active = DashboardMarkAllReadPresentation(unreadCount: 2, isBusy: false)
        let busy = DashboardMarkAllReadPresentation(unreadCount: 2, isBusy: true)

        XCTAssertEqual(active.tone, .active)
        XCTAssertTrue(active.isEnabled)
        XCTAssertEqual(active.accessibilityValue, "2 个未读会话")
        XCTAssertFalse(busy.isEnabled)
        XCTAssertEqual(busy.accessibilityHint, "正在更新已读基线")
    }

    func testDashboardModeDoesNotExposeLocalUnreadAcknowledgementWhileExportProducesNone() {
        XCTAssertTrue(DashboardHeaderPresentationMode.dashboard.showsActions)
        XCTAssertEqual(
            DashboardHeaderPresentationMode.dashboard.actions(unreadCount: 0),
            [
                .refresh,
                .changeDirectory,
                .providerRepair,
                .sessionManagement,
                .sessionEnhancements,
                .autoResume,
            ]
        )
        XCTAssertFalse(DashboardHeaderPresentationMode.export.showsActions)
        XCTAssertTrue(DashboardHeaderPresentationMode.export.actions(unreadCount: 3).isEmpty)
    }

    func testMarkAllReadControllerCoalescesBusyClicksAndCanTriggerAgainAfterCompletion() {
        var controller = DashboardMarkAllReadController()
        var calls = 0

        XCTAssertTrue(controller.trigger { calls += 1 })
        XCTAssertFalse(controller.trigger { calls += 1 })
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(controller.isBusy)

        controller.complete()
        XCTAssertTrue(controller.trigger { calls += 1 })
        XCTAssertEqual(calls, 2)
    }

    func testHeaderLayoutReservesReadableWidthForCommonAutomaticSource() {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let originWidth = ("自动发现" as NSString).size(withAttributes: [.font: font]).width
        let pathWidth = ("~/.codex" as NSString).size(withAttributes: [.font: font]).width
        let requiredWidth = DashboardHeaderContextLayout.badgeHorizontalPadding * 2
            + DashboardHeaderContextLayout.iconWidth
            + DashboardHeaderContextLayout.badgeSpacing * 2
            + ceil(originWidth)
            + ceil(pathWidth)

        XCTAssertGreaterThanOrEqual(DashboardHeaderContextLayout.dataSourceWidth, requiredWidth)
        XCTAssertEqual(DashboardHeaderContextLayout.contextRowCount, 2)
    }

    func testHeaderFreshnessSeparatesSyncFailureAndSuccessfulTimestamp() {
        let generatedAt = Date(timeIntervalSince1970: 1_720_000_000)

        let syncing = DashboardHeaderFreshnessPresentation(
            status: "读取完成",
            isRefreshing: true,
            generatedAt: generatedAt
        )
        XCTAssertEqual(syncing.text, "正在同步")
        XCTAssertFalse(syncing.needsAttention)

        let failed = DashboardHeaderFreshnessPresentation(
            status: "额度读取失败，继续显示旧数据",
            isRefreshing: false,
            generatedAt: generatedAt
        )
        XCTAssertEqual(failed.text, "额度读取失败，继续显示旧数据")
        XCTAssertTrue(failed.needsAttention)

        let current = DashboardHeaderFreshnessPresentation(
            status: "读取完成",
            isRefreshing: false,
            generatedAt: generatedAt
        )
        XCTAssertTrue(current.text.hasPrefix("更新于 "))
        XCTAssertFalse(current.needsAttention)
    }

    func testHeaderExposesIndependentSessionEnhancementAndAutoResumeEntries() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let headerFile = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardHeaderView.swift")
        let source = try String(contentsOf: headerFile, encoding: .utf8)

        XCTAssertTrue(source.contains("sparkles.rectangle.stack"))
        XCTAssertTrue(source.contains("title: \"自动续跑\""))
        XCTAssertFalse(source.contains("systemImage: \"trash\""))
    }

    func testHeaderExposesSharedRunningThreadSummaryInContextRail() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let headerFile = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardHeaderView.swift")
        let dashboardFile = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let headerSource = try String(contentsOf: headerFile, encoding: .utf8)
        let dashboardSource = try String(contentsOf: dashboardFile, encoding: .utf8)

        XCTAssertTrue(headerSource.contains("let runningThreadSummary: RunningThreadSummary"))
        XCTAssertTrue(headerSource.contains("Text(runningThreadPresentation.displayText)"))
        XCTAssertTrue(headerSource.contains(".accessibilityLabel(\"运行线程\")"))
        XCTAssertTrue(
            dashboardSource.contains(
                "runningThreadSummary: taskCompletionMonitor.runningThreadSummary"
            )
        )
    }

    func testSecondaryModelCostCardsNeverReplaceModelDetailsWithEllipsis() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let headerFile = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardHeaderView.swift")
        let source = try String(contentsOf: headerFile, encoding: .utf8)
        let rowStart = try XCTUnwrap(source.range(of: "struct DashboardModelCostRow"))
        let rowEnd = try XCTUnwrap(
            source.range(of: "private struct DashboardPrimaryModelCostCard", range: rowStart.upperBound..<source.endIndex)
        )
        let rowSource = String(source[rowStart.lowerBound..<rowEnd.lowerBound])
        let start = try XCTUnwrap(source.range(of: "private struct DashboardSecondaryModelCostChip"))
        let end = try XCTUnwrap(
            source.range(of: "struct StatCell", range: start.upperBound..<source.endIndex)
        )
        let chipSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(rowSource.contains("LazyVGrid("))
        XCTAssertTrue(rowSource.contains(".layoutPriority(1)"))
        XCTAssertTrue(chipSource.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(chipSource.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(chipSource.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(chipSource.contains(".lineLimit(1)"))
    }

    func testModelCostRowDoesNotRemoveTheOverviewRowsTopInset() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let headerFile = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardHeaderView.swift")
        let source = try String(contentsOf: headerFile, encoding: .utf8)
        let stripStart = try XCTUnwrap(source.range(of: "struct StatStrip: View"))
        let stripEnd = try XCTUnwrap(
            source.range(of: "enum DashboardModelCostScope", range: stripStart.upperBound..<source.endIndex)
        )
        let stripSource = String(source[stripStart.lowerBound..<stripEnd.lowerBound])

        XCTAssertTrue(stripSource.contains(".padding(.vertical, 7)"))
        XCTAssertFalse(stripSource.contains(".padding(.bottom, 7)"))
    }

    @MainActor
    func testHostedAutomaticSourceBadgeKeepsStableSingleLineFrame() {
        let hostingView = NSHostingView(
            rootView: DataSourceBadge(path: "~/.codex", origin: "自动发现")
        )
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            hostingView.fittingSize.width,
            DashboardHeaderContextLayout.dataSourceWidth,
            accuracy: 0.5
        )
        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, 28)
    }
}

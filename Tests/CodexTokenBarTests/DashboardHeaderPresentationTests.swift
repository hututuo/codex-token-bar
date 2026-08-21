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

    func testHeaderFreshnessKeepsDataAndChartTimesWithoutCheckTimestamp() {
        let dataUpdatedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let checkedAt = dataUpdatedAt.addingTimeInterval(90)

        let current = DashboardHeaderFreshnessPresentation(
            status: "读取完成",
            isRefreshing: false,
            generatedAt: checkedAt,
            lastCheckedAt: checkedAt,
            dataUpdatedAt: dataUpdatedAt,
            aggregateCoveredAt: dataUpdatedAt
        )

        XCTAssertTrue(current.text.contains("数据更新于"))
        XCTAssertTrue(current.text.contains("图表至"))
        XCTAssertFalse(current.text.contains("检查于"))
        XCTAssertFalse(current.needsAttention)
    }

    func testHeaderFreshnessDoesNotCallMetadataCheckADataUpdate() {
        let checkedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let metadataOnly = DashboardHeaderFreshnessPresentation(
            status: "读取完成",
            isRefreshing: false,
            generatedAt: checkedAt,
            lastCheckedAt: checkedAt,
            dataUpdatedAt: nil
        )

        XCTAssertTrue(metadataOnly.text.hasPrefix("摘要于 "))
        XCTAssertFalse(metadataOnly.text.contains("数据更新于"))
    }

    func testPreciseProgressPresentationKeepsBackendFactsAndSeparatesStages() {
        let migration = DashboardHeaderProgressPresentation(
            progress: PreciseIndexProgress(
                phase: .migrating,
                message: "正在升级索引字段",
                completed: 2,
                total: 4
            )
        )
        XCTAssertEqual(migration.stage, .structureUpgrade)
        XCTAssertEqual(migration.countText, "2/4")
        XCTAssertTrue(migration.showsProgress)
        XCTAssertTrue(migration.showsReassurance)
        XCTAssertTrue(migration.text.contains("正在升级索引字段"))

        let attributionLedger = DashboardHeaderProgressPresentation(
            progress: PreciseIndexProgress(
                phase: .migrating,
                message: "正在回填归因账本",
                completed: 1,
                total: 4
            )
        )
        XCTAssertEqual(attributionLedger.stage, .structureUpgrade)

        let modelBackfill = DashboardHeaderProgressPresentation(
            progress: PreciseIndexProgress(
                phase: .migrating,
                message: "backfill historical model + reasoning",
                completed: 3,
                total: 8
            )
        )
        XCTAssertEqual(modelBackfill.stage, .historyModelBackfill)
        XCTAssertEqual(modelBackfill.countText, "3/8")

        let routineScan = DashboardHeaderProgressPresentation(
            progress: PreciseIndexProgress(
                phase: .scanning,
                message: "正在扫描精确历史",
                completed: 5,
                total: 12
            )
        )
        XCTAssertEqual(routineScan.stage, .scanning)
        XCTAssertFalse(routineScan.text.contains("索引升级"))
        XCTAssertFalse(routineScan.text.contains("历史模型补全"))

        let reconciliation = DashboardHeaderProgressPresentation(
            progress: PreciseIndexProgress(
                phase: .waiting,
                message: "等待单文件 reconciliation",
                completed: 0,
                total: nil
            )
        )
        XCTAssertEqual(reconciliation.stage, .reconciliation)
        XCTAssertTrue(reconciliation.showsProgress)

        let publishing = DashboardHeaderProgressPresentation(
            progress: PreciseIndexProgress(
                phase: .publishing,
                message: "正在发布精确索引",
                completed: 1,
                total: 1
            )
        )
        XCTAssertEqual(publishing.stage, .publishing)
        XCTAssertEqual(publishing.countText, "1/1")

        let complete = DashboardHeaderProgressPresentation(
            progress: PreciseIndexProgress(
                phase: .complete,
                message: "精确统计已更新",
                completed: 1,
                total: 1
            )
        )
        XCTAssertEqual(complete.text, "本地统计")
        XCTAssertFalse(complete.showsReassurance)
        XCTAssertFalse(complete.needsAttention)
        XCTAssertTrue(complete.isReady)

        let failed = DashboardHeaderProgressPresentation(
            progress: PreciseIndexProgress(
                phase: .failed,
                message: "保留上次可信数据",
                completed: 1,
                total: 4
            )
        )
        XCTAssertTrue(failed.text.contains("失败"))
        XCTAssertTrue(failed.needsAttention)
        XCTAssertFalse(failed.isReady)
        XCTAssertEqual(failed.countText, "1/4")
    }

    func testHeaderFreshnessReturnsToUpdatedTimestampAfterCompleteProgress() {
        let generatedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let idle = DashboardHeaderFreshnessPresentation(
            status: "读取完成",
            isRefreshing: false,
            generatedAt: generatedAt,
            progress: .idle
        )
        XCTAssertTrue(idle.text.hasPrefix("更新于 "))

        let complete = DashboardHeaderFreshnessPresentation(
            status: "读取完成",
            isRefreshing: false,
            generatedAt: generatedAt,
            progress: PreciseIndexProgress(
                phase: .complete,
                message: "精确统计已更新",
                completed: 1,
                total: 1
            )
        )
        XCTAssertTrue(complete.text.hasPrefix("更新于 "))
    }

    func testFailedModelBackfillKeepsTheLastRealProgressCount() {
        let previous = PreciseIndexProgress(
            phase: .backfillingModel,
            message: "正在补全历史模型信息 3/8",
            completed: 3,
            total: 8
        )
        let failed = PreciseIndexProgress(
            phase: .failed,
            message: "精确统计失败，保留上次可信数据",
            completed: 0,
            total: nil
        ).preservingMigrationContext(from: previous)

        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.completed, 3)
        XCTAssertEqual(failed.total, 8)
        XCTAssertTrue(failed.message.contains("索引升级失败"))
        XCTAssertTrue(failed.message.contains("原始数据不会丢失"))
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
        XCTAssertTrue(rowSource.contains("DashboardModelCostScopePicker(scope: $scope)"))
        XCTAssertFalse(rowSource.contains("pickerStyle(.segmented)"))
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

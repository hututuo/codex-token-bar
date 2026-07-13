import XCTest
@testable import CodexTokenBar

final class CodexRadarPresentationStateTests: XCTestCase {
    func testStaleSnapshotPresentationShowsStripBadgeAndDetailWarning() throws {
        let snapshot = try makeSnapshot()
        let state = CodexRadarPresentationState(
            snapshot: snapshot,
            status: "Codex 雷达读取失败：Codex Radar HTTP 500",
            diagnostics: [
                CodexRadarDiagnostic(
                    source: .current,
                    category: .httpServer,
                    severity: .error,
                    message: "Codex 雷达服务器暂时不可用"
                ),
                .staleCachedData(source: .current)
            ],
            staleDataDisplayed: true
        )

        XCTAssertEqual(state.stripStatusText, "Codex 雷达服务器暂时不可用")
        XCTAssertEqual(state.statusBadge?.title, "旧")
        XCTAssertEqual(state.statusBadge?.accessibilityText, "当前显示上次成功读取的 Codex 雷达")
        XCTAssertEqual(state.detailWarning?.title, "显示上次成功读取的雷达")
        XCTAssertEqual(state.detailWarning?.message, "Codex 雷达服务器暂时不可用")
        XCTAssertEqual(state.compactMarkerText, "旧")
        XCTAssertEqual(state.compactAccessibilityText, "当前显示上次成功读取的 Codex 雷达")
    }

    func testFeedPartialFailurePresentationShowsRSSWarningWithoutRootStale() throws {
        let snapshot = try makeSnapshot()
        let state = CodexRadarPresentationState(
            snapshot: snapshot,
            status: "Codex 雷达 · 更新于 03:00:00",
            diagnostics: [
                .rssFailure(
                    underlying: CodexRadarDiagnostic(
                        source: .rss,
                        category: .parseFailure,
                        severity: .error,
                        message: "Codex 雷达响应格式异常"
                    )
                )
            ],
            feedStaleDataDisplayed: true
        )

        XCTAssertTrue(state.stripStatusText.hasPrefix("RSS 读取失败 · "))
        XCTAssertEqual(state.statusBadge?.title, "RSS")
        XCTAssertEqual(state.detailWarning?.title, "RSS 历史暂未更新")
        XCTAssertEqual(state.detailWarning?.message, "Codex 雷达 RSS 读取失败")
        XCTAssertEqual(state.compactMarkerText, "RSS")
        XCTAssertFalse(state.staleDataDisplayed)
    }

    func testNilSnapshotRootFailureUsesErrorEmptyStateInsteadOfLoadingOnly() {
        let state = CodexRadarPresentationState(
            snapshot: nil,
            status: "Codex 雷达读取失败：网络请求失败",
            diagnostics: [
                CodexRadarDiagnostic(
                    source: .current,
                    category: .networkFetch,
                    severity: .error,
                    message: "Codex 雷达网络请求失败"
                )
            ]
        )

        XCTAssertEqual(state.statusBadge?.title, "失败")
        XCTAssertEqual(state.emptyState?.title, "Codex 雷达读取失败")
        XCTAssertEqual(state.emptyState?.message, "Codex 雷达网络请求失败")
        XCTAssertEqual(state.compactAccessibilityText, "Codex 雷达读取失败")
    }

    func testFloatingPresentationIncludesDegradedRadarAccessibilityWithoutInventingData() {
        let tokenSnapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "输出中",
            rate: 12.3,
            consumedTokens: 123_456,
            todayTokens: 7_890,
            todayRequests: 42,
            quota: .empty,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let failedRadar = CodexRadarPresentationState(
            snapshot: nil,
            diagnostics: [
                CodexRadarDiagnostic(
                    source: .current,
                    category: .networkFetch,
                    severity: .error,
                    message: "Codex 雷达网络请求失败"
                )
            ]
        )

        let model = FloatingPanelPresentationModel(
            snapshot: tokenSnapshot,
            visibility: FloatingPanelContentVisibility(
                showRateAndBar: false,
                showUsageStatus: false,
                showMetrics: false,
                showQuota: false,
                showRadar: true
            ),
            radarPresentation: failedRadar
        )

        XCTAssertTrue(model.accessibilityParts.contains("Codex 雷达读取失败"))
        XCTAssertFalse(model.accessibilityParts.contains { $0.contains("雷达建议") })
        XCTAssertFalse(model.accessibilityParts.contains { $0.contains("IQ") })
    }

    func testHappyPathPresentationKeepsExistingStripAndFloatingText() throws {
        let snapshot = try makeSnapshot()
        let state = CodexRadarPresentationState(snapshot: snapshot)

        XCTAssertEqual(state.statusBadge, nil)
        XCTAssertEqual(state.detailWarning, nil)
        XCTAssertEqual(state.emptyState, nil)
        XCTAssertTrue(state.stripStatusText.hasPrefix("10分钟刷新 · "))

        let tokenSnapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "输出中",
            rate: 12.3,
            consumedTokens: 123_456,
            todayTokens: 7_890,
            todayRequests: 42,
            quota: .empty,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let model = FloatingPanelPresentationModel(
            snapshot: tokenSnapshot,
            visibility: FloatingPanelContentVisibility(
                showRateAndBar: false,
                showUsageStatus: false,
                showMetrics: false,
                showQuota: false,
                showRadar: true
            ),
            radarPresentation: state
        )

        XCTAssertTrue(model.accessibilityParts.contains("雷达建议 \(CodexRadarPresentationText.action(snapshot.recommendedAction))"))
        XCTAssertTrue(model.accessibilityParts.contains(snapshot.modelIQ.primaryModelRow.point.scoreDisplayText))
        XCTAssertNil(state.compactMarkerText)
    }

    func testFloatingPresentationUsesPublicSummaryFieldsWithoutAdvancedRadarSections() throws {
        let snapshot = try JSONDecoder.codexRadar.decode(
            CodexRadarSnapshot.self,
            from: Data(CodexRadarModelsTests.publicSummaryJSON.utf8)
        )
        let tokenSnapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "输出中",
            rate: 12.3,
            consumedTokens: 123_456,
            todayTokens: 7_890,
            todayRequests: 42,
            quota: .empty,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let model = FloatingPanelPresentationModel(
            snapshot: tokenSnapshot,
            visibility: FloatingPanelContentVisibility(
                showRateAndBar: false,
                showUsageStatus: false,
                showMetrics: false,
                showQuota: false,
                showRadar: true
            ),
            radarPresentation: CodexRadarPresentationState(snapshot: snapshot)
        )

        XCTAssertTrue(model.accessibilityParts.contains("雷达建议 等待"))
        XCTAssertTrue(model.accessibilityParts.contains("IQ 100"))
        XCTAssertFalse(model.accessibilityParts.contains { $0.contains("环境压力") })
        XCTAssertFalse(model.accessibilityParts.contains { $0.contains("recent") })
    }

    private func makeSnapshot() throws -> CodexRadarSnapshot {
        try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: Data(CodexRadarModelsTests.sampleJSON.utf8))
    }
}

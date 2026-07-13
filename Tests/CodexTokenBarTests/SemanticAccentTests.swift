import XCTest
@testable import CodexTokenBar

final class SemanticAccentTests: XCTestCase {
    func testMetricColorsMoveContinuouslyFromRedThroughAmberAndGreenToBlue() {
        XCTAssertEqual(AppTheme.semanticMetricRGB(percent: 0), .init(red: 202, green: 60, blue: 73))
        XCTAssertEqual(AppTheme.semanticMetricRGB(percent: 35), .init(red: 204, green: 139, blue: 38))
        XCTAssertEqual(AppTheme.semanticMetricRGB(percent: 70), .init(red: 31, green: 158, blue: 94))
        XCTAssertEqual(AppTheme.semanticMetricRGB(percent: 100), .init(red: 20, green: 105, blue: 204))
        XCTAssertEqual(AppTheme.semanticMetricRGB(percent: 52.5), .init(red: 118, green: 149, blue: 66))
    }

    func testMetricColorsClampInvalidAndOutOfRangeValues() {
        XCTAssertEqual(AppTheme.semanticMetricRGB(percent: .nan), AppTheme.semanticMetricRGB(percent: 0))
        XCTAssertEqual(AppTheme.semanticMetricRGB(percent: -20), AppTheme.semanticMetricRGB(percent: 0))
        XCTAssertEqual(AppTheme.semanticMetricRGB(percent: 140), AppTheme.semanticMetricRGB(percent: 100))
    }

    func testRadarScorePrefersExecutedTaskRatioAndFallsBackToNormalizedIQ() {
        XCTAssertEqual(AppTheme.radarScorePercent(passed: 8, tasks: 10, score: 25), 80)
        XCTAssertEqual(AppTheme.radarScorePercent(passed: 0, tasks: 0, score: 150), 100)
        XCTAssertEqual(AppTheme.radarScorePercent(passed: 0, tasks: 0, score: 75), 50)
        XCTAssertEqual(AppTheme.radarScoreRGB(passed: 10, tasks: 10, score: 150), .init(red: 31, green: 158, blue: 94))
    }

    func testActionsAndPaceUseRestrainedFixedAccentRoles() {
        XCTAssertEqual(AppTheme.radarActionRole("wait"), .amber)
        XCTAssertEqual(AppTheme.radarActionRole("run"), .green)
        XCTAssertEqual(AppTheme.radarActionRole("closed"), .red)
        XCTAssertEqual(AppTheme.radarActionRole("unknown"), .blue)
        XCTAssertEqual(AppTheme.quotaPaceRole("用得太快，先省着"), .red)
        XCTAssertEqual(AppTheme.quotaPaceRole("最后几小时，别梭哈"), .red)
        XCTAssertEqual(AppTheme.quotaPaceRole("节奏很好"), .green)
        XCTAssertEqual(AppTheme.quotaPaceRole("余量很足，使劲蹬"), .blue)
    }
}

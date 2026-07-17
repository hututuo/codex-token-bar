import XCTest
@testable import CodexTokenBar

final class CodexCrowdRadarTests: XCTestCase {
    func testBestModelUsesPassRateAndConvertsToIQ() {
        let snapshot = CodexCrowdRadarSnapshot(
            generatedAt: "2026-07-16T00:00:00Z",
            taskCount: 112,
            cellCount: 1_904,
            contributorCount: 130,
            pendingGrades: 1,
            errorGrades: 7,
            models: [
                CodexCrowdRadarModel(model: "gpt-5.6-sol", effort: "max", graded: 79, passed: 53, passRate: 0.675, cells: 77),
                CodexCrowdRadarModel(model: "gpt-5.6-luna", effort: "high", graded: 61, passed: 43, passRate: 0.705, cells: 60),
                CodexCrowdRadarModel(model: "gpt-5.6-terra", effort: "ultra", graded: 45, passed: 36, passRate: 0.795, cells: 44)
            ]
        )
        XCTAssertEqual(snapshot.rankedModels.map(\.label), ["Terra ultra", "Luna high", "Sol max"])
        XCTAssertEqual(snapshot.bestModel?.label, "Terra ultra")
        XCTAssertEqual(snapshot.bestModel?.iq ?? 0, 119.25, accuracy: 0.001)
    }
}

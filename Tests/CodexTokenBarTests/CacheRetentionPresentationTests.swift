import XCTest
@testable import CodexTokenBar

final class CacheRetentionPresentationTests: XCTestCase {
    func testCoverageCopyDoesNotTreatHighSampleQuantileAsRecommendation() {
        func point(_ id: String, gap: Int64, cached: Int64) -> CacheRetentionPoint {
            .init(id: id, sourceKey: "source", sessionKey: "session", model: "model",
                  gapMicroseconds: gap, startedAtMicroseconds: 0, previousInput: 100,
                  previousCached: 90, input: 100, cached: cached)
        }
        let high = (0..<20).map { point("high-\($0)", gap: Int64($0) * 60_000_000, cached: 90) }
        let low = (0..<100).map { point("low-\($0)", gap: 60_000_000, cached: 0) }
        let all = high + low
        let result = CacheRetentionAnalysis.calculate(all)
        XCTAssertEqual(result.p95Microseconds, 18 * 60_000_000)
        XCTAssertEqual(result.p95CoverageCount, 19)
        // A 95% coverage of the high samples coexists with only 19/119
        // high samples before that line. These describe different populations.
        let inside = all.filter { $0.gapMicroseconds <= result.p95Microseconds! }
        XCTAssertEqual(inside.count, 119)
        XCTAssertEqual(inside.filter(\.highReuse).count, 19)
        let text = CacheRetentionCopy.coverage(result)
        XCTAssertTrue(text.contains("过去高命中的续问"))
        XCTAssertTrue(text.contains("95%"))
        XCTAssertFalse(text.contains("建议"))
        XCTAssertFalse(text.contains("推荐"))
    }
}

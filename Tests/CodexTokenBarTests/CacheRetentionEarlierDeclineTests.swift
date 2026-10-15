import XCTest
@testable import CodexTokenBar

final class CacheRetentionEarlierDeclineTests: XCTestCase {
    func testSupportedNinePointEarlierDropIsNotHiddenByAnArbitraryTenPointThreshold() {
        let points = group(gap: 1, high: 900) + group(gap: 20, high: 810) + group(gap: 60, high: 200)
        let result = CacheRetentionAnalysis.calculate(points)
        XCTAssertEqual(result.dropMicroseconds, 40 * 60_000_000)
        XCTAssertEqual(result.earlierDecline?.microseconds, 10.5 * 60_000_000)
        XCTAssertEqual(result.earlierDecline?.count, 2_000)
        XCTAssertEqual(result.earlierDecline?.segments.map(\.highCount), [900, 810])
        XCTAssertTrue(CacheRetentionCopy.recommendation(result).contains("10.5 分钟"))
    }

    func testOnlyOneSupportedDropNeverFallsBackToP95ForTheEarlierLine() {
        let result = CacheRetentionAnalysis.calculate(group(gap: 1, high: 1_000) + group(gap: 60, high: 200))
        XCTAssertNotNil(result.dropMicroseconds)
        XCTAssertNotNil(result.p95Microseconds)
        XCTAssertNil(result.earlierDecline)
        XCTAssertFalse(CacheRetentionCopy.recommendation(result).contains("建议尽量"))
    }

    func testEarlierFitCannotUseObservationsBeyondTheMainBoundaryAndScalesWithTime() {
        let points = group(gap: 1, high: 900) + group(gap: 20, high: 810) + group(gap: 60, high: 200)
        let result = CacheRetentionAnalysis.calculate(points)
        let doubled = points.map { p in
            CacheRetentionPoint(id: p.id, sourceKey: p.sourceKey, sessionKey: p.sessionKey, model: p.model,
                gapMicroseconds: p.gapMicroseconds * 2, startedAtMicroseconds: p.startedAtMicroseconds,
                previousInput: p.previousInput, previousCached: p.previousCached, input: p.input, cached: p.cached)
        }
        let scaled = CacheRetentionAnalysis.calculate(doubled)
        XCTAssertEqual(scaled.earlierDecline?.microseconds, result.earlierDecline!.microseconds * 2)
        XCTAssertEqual(scaled.dropMicroseconds, result.dropMicroseconds! * 2)
        XCTAssertLessThan(result.earlierDecline!.rightMicroseconds, result.dropRightMicroseconds!)
    }

    private func group(gap: Int64, high: Int) -> [CacheRetentionPoint] {
        (0..<1_000).map { index in
            .init(id: "\(gap)-\(index)", sourceKey: "source", sessionKey: "session", model: "model",
                gapMicroseconds: gap * 60_000_000, startedAtMicroseconds: 0,
                previousInput: 100, previousCached: 90, input: 100, cached: index < high ? 90 : 0)
        }
    }
}

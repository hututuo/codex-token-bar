import XCTest
@testable import CodexTokenBar

final class QuotaPeriodBoundaryPolicyTests: XCTestCase {
    func testEveryCompleteBucketIsIncludedAtEveryResetSecond() {
        let base: TimeInterval = 1_800_000_000
        for offset in 0..<300 {
            let start = Date(timeIntervalSince1970: base + Double(offset))
            let end = start.addingTimeInterval(604_800)
            let first = base + (offset == 0 ? 0 : 300)
            let lastEnd = base + 604_800
            XCTAssertEqual(QuotaPeriodBoundaryPolicy.firstCompleteBucketStart(after: start).timeIntervalSince1970, first)
            XCTAssertEqual(QuotaPeriodBoundaryPolicy.lastCompleteBucketEnd(before: end).timeIntervalSince1970, lastEnd)
            XCTAssertTrue(QuotaPeriodBoundaryPolicy.contains(bucketStart: Date(timeIntervalSince1970: first), periodStart: start, periodEnd: end))
            XCTAssertTrue(QuotaPeriodBoundaryPolicy.contains(bucketStart: Date(timeIntervalSince1970: lastEnd - 300), periodStart: start, periodEnd: end))
            XCTAssertFalse(QuotaPeriodBoundaryPolicy.contains(bucketStart: Date(timeIntervalSince1970: first - 300), periodStart: start, periodEnd: end))
            XCTAssertFalse(QuotaPeriodBoundaryPolicy.contains(bucketStart: Date(timeIntervalSince1970: lastEnd), periodStart: start, periodEnd: end))
        }
    }
}

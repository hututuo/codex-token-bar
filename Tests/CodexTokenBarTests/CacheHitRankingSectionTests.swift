import Foundation
import XCTest
@testable import CodexTokenBar

final class CacheHitRankingSectionTests: XCTestCase {
    func testLatestSortOrdersDatedItemsNewestFirst() {
        let older = sortValue(id: "older", date: Date(timeIntervalSince1970: 1_000), input: 2_000, cached: 1_500)
        let newer = sortValue(id: "newer", date: Date(timeIntervalSince1970: 2_000), input: 2_000, cached: 100)
        let unknown = sortValue(id: "unknown", date: nil, input: 2_000, cached: 0)

        let sorted = [older, unknown, newer].sorted(by: CacheRankingSortOrder.latest.sortsBefore)

        XCTAssertEqual(sorted.map(\.id), ["newer", "older", "unknown"])
    }

    func testLowHitSortStillPrioritizesLowestHitRate() {
        let lowHit = sortValue(id: "low", date: Date(timeIntervalSince1970: 1_000), input: 2_000, cached: 100)
        let highHit = sortValue(id: "high", date: Date(timeIntervalSince1970: 3_000), input: 2_000, cached: 1_500)
        let sameRateMoreMisses = sortValue(id: "more-misses", date: Date(timeIntervalSince1970: 2_000), input: 4_000, cached: 200)

        let sorted = [highHit, lowHit, sameRateMoreMisses].sorted(by: CacheRankingSortOrder.lowHit.sortsBefore)

        XCTAssertEqual(sorted.map(\.id), ["more-misses", "low", "high"])
    }

    private func sortValue(id: String, date: Date?, input: Int, cached: Int) -> CacheRankingSortValue {
        CacheRankingSortValue(
            id: id,
            sortDate: date,
            breakdown: TokenCacheBreakdown(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: input,
                calls: 1
            )
        )
    }
}

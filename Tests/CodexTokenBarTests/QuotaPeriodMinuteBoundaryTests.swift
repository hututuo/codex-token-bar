import XCTest
@testable import CodexTokenBar

final class QuotaPeriodMinuteBoundaryTests: XCTestCase {
    private func detailedEvent(at timestamp: TimeInterval) -> TokenCacheAttributionEvent {
        let minutes = (0..<5).map { index in
            TokenCacheBucket(
                start: Date(timeIntervalSince1970: timestamp + Double(index * 60)),
                breakdown: TokenCacheBreakdown(
                    inputTokens: (index + 1) * 100, cachedInputTokens: (index + 1) * 20,
                    outputTokens: index + 1, reasoningOutputTokens: 0,
                    totalTokens: (index + 1) * 101, calls: 1
                )
            )
        }
        return TokenCacheAttributionEvent(
            id: String(timestamp), start: Date(timeIntervalSince1970: timestamp),
            model: "gpt-6-astra", breakdown: minutes.map(\.breakdown).combined,
            minuteBuckets: minutes
        )
    }

    func testEveryResetSecondRetainsAllClearMinutesAtBothEdges() {
        let base: TimeInterval = 1_800_000_000
        let leading = detailedEvent(at: base)
        let trailing = detailedEvent(at: base + 604_800)
        for offset in 0..<300 {
            let start = Date(timeIntervalSince1970: base + Double(offset))
            let end = start.addingTimeInterval(604_800)
            let partition = QuotaPeriodBoundaryPolicy.partition(
                events: [leading, trailing], periodStart: start, periodEnd: end
            )
            let first = Int(ceil(Double(offset) / 60))
            let last = offset / 60
            let expectedLeading = (first..<5).reduce(0) { $0 + ($1 + 1) * 101 }
            let expectedTrailing = (0..<last).reduce(0) { $0 + ($1 + 1) * 101 }
            XCTAssertEqual(partition.events.map(\.breakdown).combined.totalTokens,
                           expectedLeading + expectedTrailing, "offset \(offset)")
            let ambiguous = offset % 60 == 0 ? 0 : (last + 1) * 101
            XCTAssertEqual(partition.boundary.leading.totalTokens, ambiguous)
            XCTAssertEqual(partition.boundary.trailing.totalTokens, ambiguous)
        }
    }

    func testOldSnapshotAndInvalidMinuteDetailRetainCoarseBoundary() throws {
        let detailed = detailedEvent(at: 1_800_000_000)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(detailed)) as? [String: Any])
        json.removeValue(forKey: "minuteBuckets")
        let old = try JSONDecoder().decode(TokenCacheAttributionEvent.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.minuteBuckets)
        let invalid = TokenCacheAttributionEvent(
            id: detailed.id, start: detailed.start, model: detailed.model,
            breakdown: detailed.breakdown, minuteBuckets: Array(detailed.minuteBuckets!.dropFirst())
        )
        for event in [old, invalid] {
            let result = QuotaPeriodBoundaryPolicy.partition(
                events: [event], periodStart: event.start.addingTimeInterval(88),
                periodEnd: event.start.addingTimeInterval(604_888)
            )
            XCTAssertTrue(result.events.isEmpty)
            XCTAssertEqual(result.boundary.leading, event.breakdown)
        }
    }
}

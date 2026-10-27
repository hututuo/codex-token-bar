import XCTest
@testable import CodexTokenBar

final class FloatingModelUsageCacheTests: XCTestCase {
    func testReusesOnlyExactInputsIncludingDatedPricesAndPresentationOptions() {
        let cache = FloatingModelUsageCache()
        var computations = 0
        let usage = TokenCacheBreakdown(inputTokens: 100, cachedInputTokens: 50,
            outputTokens: 20, reasoningOutputTokens: 0, totalTokens: 120, calls: 1)
        func key(date: Double = 1_792_000_000, model: String = "gpt-6.1-sol", placeholders: Bool = false,
                 merge: Bool = false, fallback: OfficialAPIPriceModel = .gpt56Sol) -> FloatingModelUsageCache.Key {
            .init(rows: [.init(model: model, breakdown: usage,
                pricePeriods: [.init(model: model, start: Date(timeIntervalSince1970: date), breakdown: usage)])],
                fallbackModel: fallback, showPlaceholders: placeholders, mergeAutoReview: merge)
        }
        func read(_ key: FloatingModelUsageCache.Key) -> [FloatingTodayModelUsageItem] {
            cache.value(for: key) {
                computations += 1
                return FloatingTodayModelUsagePresentation.makeItems(from: key.rows, fallbackModel: key.fallbackModel,
                    showPlaceholders: key.showPlaceholders, mergeAutoReview: key.mergeAutoReview)
            }
        }
        let baseline = read(key())
        for _ in 0..<20 { XCTAssertEqual(read(key()), baseline) }
        XCTAssertEqual(computations, 1)
        let old = read(key(date: 1_700_000_000))
        XCTAssertNotEqual(old.first?.costUSD, baseline.first?.costUSD, "A changed price epoch must not reuse current pricing")
        _ = read(key(model: "gpt-6-luna"))
        _ = read(key(placeholders: true))
        _ = read(key(merge: true))
        _ = read(key(fallback: .gpt56Luna))
        XCTAssertEqual(computations, 6)
    }

    func testEvictsOlderSnapshotsAndChangedBreakdownCannotReuseOldItems() {
        let cache = FloatingModelUsageCache(capacity: 2)
        var computations = 0
        func read(_ tokens: Int) {
            let usage = TokenCacheBreakdown(inputTokens: tokens, cachedInputTokens: 0, outputTokens: 0,
                reasoningOutputTokens: 0, totalTokens: tokens, calls: 1)
            let key = FloatingModelUsageCache.Key(rows: [.init(model: "gpt-6-luna", breakdown: usage)],
                fallbackModel: .gpt56Sol, showPlaceholders: false, mergeAutoReview: false)
            _ = cache.value(for: key) { computations += 1; return [] }
        }
        read(1); read(2); read(1); read(3)
        XCTAssertEqual(computations, 3)
        read(2)
        XCTAssertEqual(computations, 4, "Least recently used input must be evicted")
    }
}

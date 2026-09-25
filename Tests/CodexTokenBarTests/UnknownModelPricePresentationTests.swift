import XCTest
@testable import CodexTokenBar

final class UnknownModelPricePresentationTests: XCTestCase {
    func testUnknownPriceStaysOnItsOwnRowAndPreservesKnownSubtotal() throws {
        for model: String? in [nil, "", "  ", "future-model"] {
            let items = FloatingTodayModelUsagePresentation.items(
                from: [row("gpt-6-astra"), row(model)], fallbackModel: .gpt56Sol
            )
            let unknown = try XCTUnwrap(items.first { $0.costUSD == nil })
            XCTAssertEqual(unknown.tokens, 1_000_000)
            XCTAssertEqual(unknown.share, 0.5)
            XCTAssertEqual(unknown.valueText(for: .cost), "价格未知")
            XCTAssertEqual(FloatingTodayModelUsagePresentation.knownCostUSD(in: items), 10)
            let overflow = try XCTUnwrap(FloatingTodayModelUsagePresentation.overflowDetailText(items: [unknown], visibleLimit: 0))
            XCTAssertTrue(overflow.contains("价格未知"))
            XCTAssertFalse(overflow.contains("$"))
        }
    }

    func testAllUnknownUsageDoesNotBecomeZeroThroughPlaceholdersOrSpark() {
        for rows in [[row("future-model")], [row("future-model"), row("gpt-5.3-codex-spark")]] {
            for showPlaceholders in [false, true] {
                let items = FloatingTodayModelUsagePresentation.items(
                    from: rows, fallbackModel: .gpt56Sol, showPlaceholders: showPlaceholders
                )
                XCTAssertNil(FloatingTodayModelUsagePresentation.knownCostUSD(in: items))
            }
        }
        XCTAssertEqual(FloatingTodayModelUsagePresentation.knownCostUSD(in: []), 0)
        let spark = FloatingTodayModelUsagePresentation.items(from: [row("gpt-5.3-codex-spark")], fallbackModel: .gpt56Sol)
        XCTAssertEqual(FloatingTodayModelUsagePresentation.knownCostUSD(in: spark), 0)
    }

    @MainActor
    func testHeatmapKeepsUnknownModelDetailsSeparateFromMissingProjection() throws {
        let day = Calendar.current.startOfDay(for: Date())
        for model: String? in [nil, "future-model"] {
            for mixed in [false, true] {
                let rows = mixed ? [row(model), row("gpt-6-astra")] : [row(model)]
                let prepared = TokenHeatmap.prepare(
                    dailyUsage: [DayUsage(date: day, tokens: rows.count * 1_000_000, calls: rows.count)],
                    cacheDaily: [],
                    dailyModelBreakdowns: [ModelTokenBucket(start: day, modelBreakdowns: rows)],
                    quotaDaily: [], mode: .modelCost
                )
                let summary = try XCTUnwrap(prepared.summaries.first)
                XCTAssertTrue(summary.hasUnknownPrices)
                XCTAssertEqual(summary.modelBreakdowns.count, rows.count)
                if mixed {
                    XCTAssertEqual(summary.modelCostUSD, 10)
                } else {
                    XCTAssertNil(summary.modelCostUSD)
                }
            }
        }
    }

    private func row(_ model: String?) -> ModelTokenBreakdown {
        ModelTokenBreakdown(model: model, breakdown: TokenCacheBreakdown(
            inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0,
            reasoningOutputTokens: 0, totalTokens: 1_000_000, calls: 1
        ))
    }
}

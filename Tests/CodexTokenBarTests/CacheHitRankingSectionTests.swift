import Foundation
import XCTest
@testable import CodexTokenBar

final class CacheHitRankingSectionTests: XCTestCase {
    func testPagingLoadsTenAtATimeAndStopsAtTotal() {
        var paging = CacheRankingPagingState()

        XCTAssertEqual(paging.visibleCount(totalCount: 25), 10)
        XCTAssertTrue(paging.hasMore(totalCount: 25))

        paging.loadMore(totalCount: 25)
        XCTAssertEqual(paging.visibleCount(totalCount: 25), 20)

        paging.loadMore(totalCount: 25)
        XCTAssertEqual(paging.visibleCount(totalCount: 25), 25)
        XCTAssertFalse(paging.hasMore(totalCount: 25))

        paging.loadMore(totalCount: 25)
        XCTAssertEqual(paging.visibleCount(totalCount: 25), 25)

        paging.reset()
        XCTAssertEqual(paging.visibleCount(totalCount: 25), 10)
    }

    func testDashboardKeepsTopTenRankingAndAddsFullDetailOverlay() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift"),
            encoding: .utf8
        )
        let rankingSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/CodexTokenBar/CacheHitRankingSection.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(dashboardSource.contains("@State private var showingCacheHitRankingDetails"))
        XCTAssertTrue(dashboardSource.contains("CacheHitRankingSection("))
        XCTAssertTrue(dashboardSource.contains("CacheHitRankingDetailView("))
        XCTAssertTrue(dashboardSource.contains("showingCacheHitRankingDetails = true"))
        XCTAssertTrue(rankingSource.contains("rankingItems.prefix(10)"))
        XCTAssertTrue(rankingSource.contains("查看完整排行"))
        XCTAssertTrue(rankingSource.contains("搜索会话、问题、回答或上下文"))
        XCTAssertTrue(rankingSource.contains(".help(rankingHoverText)"))
    }

    func testSearchMatchesTitleAnswerAndContextCaseInsensitively() {
        XCTAssertTrue(CacheRankingSearchMatcher.matches(
            query: "ALPHA",
            title: "Alpha session",
            subtitle: "普通回答",
            context: nil
        ))
        XCTAssertTrue(CacheRankingSearchMatcher.matches(
            query: "关键答案",
            title: "普通问题",
            subtitle: "答：关键答案",
            context: nil
        ))
        XCTAssertTrue(CacheRankingSearchMatcher.matches(
            query: "第 12 轮",
            title: "普通问题",
            subtitle: "普通回答",
            context: "项目会话 · 第 12 轮"
        ))
        XCTAssertFalse(CacheRankingSearchMatcher.matches(
            query: "未出现",
            title: "普通问题",
            subtitle: "普通回答",
            context: "项目会话"
        ))
    }

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

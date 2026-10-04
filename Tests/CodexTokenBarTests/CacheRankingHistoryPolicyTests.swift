import Foundation
import XCTest
@testable import CodexTokenBar

final class CacheRankingHistoryPolicyTests: XCTestCase {
    func testReadsExplicitCodexCompressionBooleanWithoutMistakingPromptTextForSettings() {
        XCTAssertTrue(CacheRankingHistoryPolicy.isEnabled(configText: "[features]\nlocal_thread_store_compression = true # enabled\n"))
        XCTAssertTrue(CacheRankingHistoryPolicy.isEnabled(configText: "features.local_thread_store_compression = true\n"))
        XCTAssertTrue(CacheRankingHistoryPolicy.isEnabled(configText: "features = { note = \"a, local_thread_store_compression = false\", local_thread_store_compression = true }\n"))
        XCTAssertFalse(CacheRankingHistoryPolicy.isEnabled(configText: "features = { note = \"a, local_thread_store_compression = true\" }\n"))
        XCTAssertTrue(CacheRankingHistoryPolicy.isEnabled(configText: "[\"features\"]\n'local_thread_store_compression' = true\n"))
        XCTAssertFalse(CacheRankingHistoryPolicy.isEnabled(configText: "[features]\nlocal_thread_store_compression = false\n"))
        XCTAssertFalse(CacheRankingHistoryPolicy.isEnabled(configText: "[profiles.example.features]\nlocal_thread_store_compression = true\n"))
        XCTAssertFalse(CacheRankingHistoryPolicy.isEnabled(configText: "# [features]\n# local_thread_store_compression = true\n"))
        XCTAssertFalse(CacheRankingHistoryPolicy.isEnabled(configText: "instructions = \"\"\"\n[features]\nlocal_thread_store_compression = true\n\"\"\"\n"))
        XCTAssertFalse(CacheRankingHistoryPolicy.isEnabled(configText: "[features]\nlocal_thread_store_compression = \"true\"\n"))
    }

    func testOlderCachedPayloadDecodesWithoutRankingScopeAndNewScopeRoundTrips() throws {
        var usage = TokenCacheUsage(total: .empty, daily: [], hourly: [], recentBins: [], sessions: [], turns: [])
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(usage)) as? [String: Any])
        object.removeValue(forKey: "rankingActiveSince")
        XCTAssertNil(try decoder.decode(TokenCacheUsage.self, from: JSONSerialization.data(withJSONObject: object)).rankingActiveSince)
        usage.rankingActiveSince = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(try decoder.decode(TokenCacheUsage.self, from: encoder.encode(usage)).rankingActiveSince, usage.rankingActiveSince)
    }
}

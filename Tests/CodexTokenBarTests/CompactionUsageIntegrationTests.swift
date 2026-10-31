import Foundation
import XCTest
@testable import CodexTokenBar

final class CompactionUsageIntegrationTests: XCTestCase {
    private let usage: [String:Any] = ["input_tokens":326340,"cached_input_tokens":323968,
        "output_tokens":7768,"reasoning_output_tokens":0,"total_tokens":334108,"cache_write_input_tokens":0]
    private func line(_ type:String,_ payload:[String:Any], ordinal:Int) throws -> String {
        let value:[String:Any] = ["timestamp":"2026-10-13T02:49:26.730Z","ordinal":ordinal,"type":type,"payload":payload]
        return String(data:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!
    }
    private func parse(_ lines:[String]) throws -> [CodexUsageAnalyzer.IndexedTokenEvent] {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("CompactionIntegration-\(UUID())")
        defer { try? FileManager.default.removeItem(at:home) }
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        let file=home.appendingPathComponent("session.jsonl")
        let bytes=Data((lines.joined(separator:"\n")+"\n").utf8)
        try bytes.write(to:file)
        let analyzer=CodexUsageAnalyzer(dataSource:.init(codexHome:home,origin:.userSelected))
        var values:[CodexUsageAnalyzer.IndexedTokenEvent]=[]
        _=try analyzer.parseSessionIntoHistoryIndex(file:file,sessionID:"fixture",endingAt:UInt64(bytes.count),
            insertFingerprint:{ _ in true },emit:{ values.append($0) })
        return values
    }
    private func modern() throws -> String {
        try line("token_usage_record",["response_id":"resp_compact","usage":usage,
            "turn_token_usage":["input_tokens":15000000,"output_tokens":50000],
            "thread_token_usage":["input_tokens":200000000,"output_tokens":1000000]],ordinal:20)
    }
    private func compact(id:String="resp_compact") throws -> String {
        try line("compacted",["compaction_response_id":id],ordinal:21)
    }
    private func legacy(last:[String:Any],total:[String:Any]?=nil) throws -> String {
        var info:[String:Any]=["last_token_usage":last]
        if let total { info["total_token_usage"]=total }
        return try line("event_msg",["type":"token_count","info":info],ordinal:22)
    }
    func testActualCompactionSampleCounts334108NotInherited17032149() throws {
        let inherited:[String:Any] = ["input_tokens":16981291,"cached_input_tokens":16000000,
            "output_tokens":50858,"reasoning_output_tokens":0,"total_tokens":17032149]
        let empty:[String:Any] = ["input_tokens":0,"cached_input_tokens":0,"output_tokens":0,
            "reasoning_output_tokens":0,"total_tokens":46525]
        let result=try parse([modern(),compact(),legacy(last:empty,total:inherited)])
        XCTAssertEqual(result.reduce(0){$0+$1.event.tokens},334108)
        XCTAssertEqual(result.filter{$0.accountingKind == .counted}.count,1)
        XCTAssertEqual(result.first?.event.cachedInputTokens,323968)
    }
    func testMirrorBothArrivalOrdersCountOnce() throws {
        for lines in [try [modern(),compact(),legacy(last:usage,total:usage)],
                      try [modern(),legacy(last:usage,total:usage),compact()]] {
            let result=try parse(lines)
            XCTAssertEqual(result.reduce(0){$0+$1.event.tokens},334108)
            XCTAssertEqual(result.filter{$0.accountingKind == .counted}.count,1)
        }
    }
    func testInlineOnlyCompactionAndFollowingMirrorCountOnce() throws {
        let inline=try line("compacted",["compaction_response_id":"resp_compact",
            "latest_token_usage_record":["response_id":"resp_compact","usage":usage]],ordinal:21)
        let result=try parse([inline,legacy(last:usage,total:usage)])
        XCTAssertEqual(result.reduce(0){$0+$1.event.tokens},334108)
    }
    func testLatestOfDifferentResponseIsUnknownRatherThanInventedUsage() throws {
        let wrong=try line("compacted",["compaction_response_id":"resp_missing",
            "latest_token_usage_record":["response_id":"resp_other","usage":usage]],ordinal:21)
        let result=try parse([wrong])
        XCTAssertEqual(result.count,1)
        XCTAssertEqual(result.first?.accountingKind,.unreportedCompaction)
        XCTAssertEqual(result.first?.event.tokens,0)
    }
    func testMarkerWithoutResponseIDRetainsUnknownUsageEvidence() throws {
        let result=try parse([line("compacted",[:],ordinal:21)])
        XCTAssertEqual(result.count,1)
        XCTAssertEqual(result.first?.accountingKind,.unreportedCompaction)
        XCTAssertEqual(result.first?.event.tokens,0)
    }
    func testSubscriptionPricingRemainsThreeBucketsAndReasoningIsNotChargedTwice() {
        let rates=APIPriceRates(inputUSDPerMillion:2,cachedInputUSDPerMillion:0.1,outputUSDPerMillion:10)
        let sample=TokenCacheBreakdown(inputTokens:326340,cachedInputTokens:323968,
            outputTokens:7768,reasoningOutputTokens:7768,totalTokens:334108,calls:1)
        XCTAssertEqual(rates.costUSD(for:sample),(2372*2+323968*0.1+7768*10)/1000000,accuracy:0.0000001)
    }
    func testUnknownUsageStopsQuotaInversionButKeepsKnownCost() {
        let sample=TokenCacheBreakdown(inputTokens:100,cachedInputTokens:50,outputTokens:10,
            reasoningOutputTokens:4,totalTokens:110,calls:1)
        let value=QuotaConsumptionEstimator.estimate(breakdown:sample,quotaDropPercent:10,
            priceCard:.officialAPI(.gpt56Sol),usageComplete:false)
        XCTAssertEqual(value.confidence,.incompleteUsage)
        XCTAssertNil(value.impliedWindowBudgetUSD)
        XCTAssertGreaterThan(value.selectedCostUSD,0)
    }
}

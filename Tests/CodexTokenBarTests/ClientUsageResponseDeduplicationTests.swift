import CryptoKit
import XCTest
@testable import CodexTokenBar

final class ClientUsageResponseDeduplicationTests: XCTestCase {
    private let boundary = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("response-dedup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixtures() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedFixtures/claude-response-deduplication.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }

    private func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func event(_ row: [Any]) throws -> ClientUsageEvent {
        let client = try XCTUnwrap(UsageClient(rawValue: row[0] as! String))
        let session = row[1] as! String, kind = row[2] as! String
        let identity = kind == "malformed" ? "id:" + String(repeating: "z", count: 64) : kind + ":" + hash(row[3] as! String)
        return ClientUsageEvent(client: client, eventID: "v1:\(hash(session)):\(identity)", sessionID: session,
            model: row[4] as! String, timestamp: Date(timeIntervalSince1970: (row[5] as! NSNumber).doubleValue),
            inputTokens: (row[6] as! NSNumber).int64Value, outputTokens: (row[7] as! NSNumber).int64Value,
            cacheReadTokens: (row[8] as? NSNumber)?.int64Value, cacheWriteTokens: (row[9] as? NSNumber)?.int64Value,
            reasoningTokens: (row[10] as? NSNumber)?.int64Value, quality: kind == "fallback" ? "fallback_identity" : "recorded",
            cacheWrite5mTokens: (row[11] as? NSNumber)?.int64Value, cacheWrite1hTokens: (row[12] as? NSNumber)?.int64Value)
    }

    private func physicalState(_ ledger: MultiClientUsageLedger) throws -> [String] {
        var result = try ledger.database.readRows("SELECT json_array(client,event_id,session_id,model,timestamp,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,payload) FROM client_usage_events ORDER BY client,event_id") { $0.text(0)! }
        result += try ledger.database.readRows("SELECT json_array(revision,client,event_id,captured_at,payload) FROM client_usage_revisions ORDER BY revision") { $0.text(0)! }
        result += try ledger.database.readRows("SELECT json_array(client,source_key,offset,size,modified,identity) FROM client_file_checkpoints ORDER BY client,source_key") { $0.text(0)! }
        result += try ledger.database.readRows("SELECT sql FROM sqlite_master ORDER BY name") { $0.text(0) ?? "" }
        result += try ledger.database.readRows("PRAGMA user_version") { String($0.int(0)!) }
        return result
    }

    func testSharedFixturesConserveEveryConsumerWithoutChangingHistoricalRecords() throws {
        for fixture in try fixtures() {
            let name = fixture["name"] as! String
            let events = try (fixture["observations"] as! [[Any]]).map(event)
            let expected = fixture["expected"] as! [[Any]]
            for reversed in [false, true] {
                let url = try directory().appendingPathComponent("usage.sqlite")
                let writer = try MultiClientUsageLedger(url: url)
                _ = try writer.ingest(reversed ? Array(events.reversed()) : events, client: .claudeDesktop,
                    sourceKey: "fixture", checkpoint: .init(offset: 42, size: 84, modified: 123, identity: "unchanged"))
                let before = try physicalState(writer)
                let reader = try MultiClientUsageLedger(url: url, readOnly: true)
                let actual = try reader.database.readRows(ClientUsageReadModel.query("""
                    SELECT json_array(client,model,timestamp,input_tokens,output_tokens,cache_read_tokens,
                                      cache_write_tokens,reasoning_tokens,cache_write_5m_tokens,cache_write_1h_tokens)
                    FROM effective_client_usage_events ORDER BY client,model,timestamp,event_id
                    """)) { try JSONSerialization.jsonObject(with: Data($0.text(0)!.utf8)) as! [Any] }
                XCTAssertTrue(NSArray(array: actual).isEqual(to: expected.map { Array($0.prefix(10)) }), name)

                let summaries = try reader.summaries()
                let totalInput = expected.reduce(Int64(0)) { $0 + ($1[3] as! NSNumber).int64Value }
                let totalOutput = expected.reduce(Int64(0)) { $0 + ($1[4] as! NSNumber).int64Value }
                let totalCost = expected.compactMap { ($0[10] as? NSNumber)?.int64Value }.reduce(0, +)
                XCTAssertEqual(summaries.reduce(0) { $0 + $1.requests }, expected.count, name)
                XCTAssertEqual(summaries.reduce(0) { $0 + $1.inputTokens }, totalInput, name)
                XCTAssertEqual(summaries.reduce(0) { $0 + $1.outputTokens }, totalOutput, name)
                for summary in summaries {
                    let rows = expected.filter { ($0[0] as! String) == summary.client.rawValue && ($0[1] as! String) == summary.model }
                    let priced = rows.compactMap { ($0[10] as? NSNumber)?.int64Value }
                    XCTAssertEqual(summary.requests, rows.count, name)
                    XCTAssertEqual(summary.unpricedRequests, rows.count - priced.count, name)
                    XCTAssertEqual(summary.cacheReadComplete, rows.allSatisfy { !($0[5] is NSNull) }, name)
                    if priced.isEmpty { XCTAssertNil(summary.apiCostUSD, name) }
                    else { XCTAssertEqual(try XCTUnwrap(summary.apiCostUSD), Double(priced.reduce(0, +)) / 1_000_000, accuracy: 1e-10, name) }
                }
                for (since, until) in [(boundary.addingTimeInterval(-10), boundary), (boundary, boundary.addingTimeInterval(10))] {
                    let count = expected.filter { let t = ($0[2] as! NSNumber).doubleValue; return t >= since.timeIntervalSince1970 && t < until.timeIntervalSince1970 }.count
                    XCTAssertEqual(try reader.summaries(since: since, before: until).reduce(0) { $0 + $1.requests }, count, name)
                }
                let trend = try reader.trendBuckets(now: boundary.addingTimeInterval(10))
                XCTAssertEqual(trend.reduce(0) { $0 + $1.requests }, expected.count, name)
                XCTAssertEqual(trend.reduce(0) { $0 + $1.inputTokens }, totalInput, name)
                XCTAssertEqual(trend.compactMap(\.apiCostMicroUSD).reduce(0, +), totalCost, name)
                XCTAssertEqual(trend.reduce(0) { $0 + $1.unpricedRequests }, summaries.reduce(0) { $0 + $1.unpricedRequests }, name)
                let days = try reader.dailyBuckets(now: boundary.addingTimeInterval(10))
                XCTAssertEqual(days.reduce(0) { $0 + $1.requests }, expected.count, name)
                XCTAssertEqual(days.reduce(0) { $0 + $1.inputTokens }, totalInput, name)
                let rankings = try MultiClientUsageLedger.readOnlyCacheRankingProjection(url: url)
                XCTAssertEqual(rankings.matchingRequestCount, expected.count, name)
                XCTAssertEqual(rankings.requests.reduce(0) { $0 + $1.inputTokens }, totalInput, name)
                XCTAssertEqual(rankings.sessions.reduce(0) { $0 + $1.requests }, expected.count, name)
                XCTAssertEqual(rankings.sessions.reduce(0) { $0 + $1.inputTokens }, totalInput, name)
                for request in rankings.requests {
                    XCTAssertTrue(events.contains { $0.client == request.client && $0.eventID == request.eventID && $0.sessionID == request.sessionID }, name)
                    XCTAssertTrue(rankings.sessions.contains { $0.client == request.client && $0.sessionID == request.sessionID && $0.modelIDs.contains(request.model) }, name)
                }
                XCTAssertEqual(try physicalState(writer), before, "Read projection mutated historical state: \(name)")
            }
        }
    }

    func testFutureCopiedResponseInvalidatesCachesWithoutAddingARequest() throws {
        let fixture = try fixtures()[0]
        let events = try (fixture["observations"] as! [[Any]]).map(event)
        let ledger = try MultiClientUsageLedger(url: directory().appendingPathComponent("usage.sqlite"))
        _ = try ledger.ingest(events)
        XCTAssertEqual(try ledger.summaries().first?.apiCostUSD, 0.247)
        XCTAssertEqual(try ledger.summaries(since: boundary).first?.requests, 1)
        let oldPayloads = try ledger.database.readRows("SELECT payload FROM client_usage_events ORDER BY event_id") { $0.text(0)! }
        var update = events[0]
        update.sessionID = "later-copy"
        update.eventID = "v1:\(hash(update.sessionID)):id:\(hash("message-1"))"
        update.outputTokens = 1_100
        XCTAssertEqual(try ledger.ingest([update]), 1)
        XCTAssertEqual(try ledger.summaries().first?.apiCostUSD, 0.249)
        XCTAssertEqual(try ledger.summaries(since: boundary).first?.requests, 1)
        XCTAssertEqual(try ledger.summaries(since: boundary).first?.outputTokens, 1_100)
        XCTAssertEqual(try ledger.ingest([update]), 0)
        let currentPayloads = try ledger.database.readRows("SELECT payload FROM client_usage_events") { $0.text(0)! }
        XCTAssertTrue(Set(oldPayloads).isSubset(of: Set(currentPayloads)))
        XCTAssertEqual(currentPayloads.count, 3)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0)! }.first, 3)
    }

    func testRealParserCopiesCountOnceAcrossLocalMidnight() throws {
        let midnight = Calendar.current.startOfDay(for: boundary)
        let ledger = try MultiClientUsageLedger(url: directory().appendingPathComponent("usage.sqlite"))
        for (session, time) in [("original", midnight.addingTimeInterval(-1)), ("fork", midnight.addingTimeInterval(1))] {
            let object: [String: Any] = ["type": "assistant", "sessionId": session, "entrypoint": "claude-desktop",
                "timestamp": ISO8601DateFormatter().string(from: time), "message": ["id": "same-provider-message", "model": "claude-opus-5-5",
                    "usage": ["input_tokens": 20000, "output_tokens": 1000, "cache_read_input_tokens": 10000, "cache_creation_input_tokens": 20000]]]
            let events = try MultiClientUsageParsers.parse(data: JSONSerialization.data(withJSONObject: object), client: .claudeDesktop, sessionHint: session)
            XCTAssertEqual(events.count, 1)
            _ = try ledger.ingest(events)
        }
        XCTAssertEqual(try ledger.summaries(before: midnight).count, 0)
        XCTAssertEqual(try ledger.summaries(since: midnight).first?.requests, 1)
        let days = try ledger.dailyBuckets(now: midnight.addingTimeInterval(10))
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.startUnix, Int64(midnight.timeIntervalSince1970))
        XCTAssertEqual(days.first?.inputTokens, 50000)
    }
}

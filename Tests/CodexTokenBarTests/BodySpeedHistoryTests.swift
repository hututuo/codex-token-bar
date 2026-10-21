import Foundation
import XCTest
@testable import CodexTokenBar

final class BodySpeedHistoryTests: XCTestCase {
    func sample(tokens: Int = 500, seconds: Double = 10) -> ObservedSpeedSample {
        .init(id: "body/s/t/i", threadID: "s", turnID: "t", itemID: "i", model: "m", startedAt: 1000,
              endedAt: 1000 + seconds, outputTokens: tokens, outputCharacters: tokens, outputBytes: tokens,
              chunkCount: 0, durationSeconds: seconds, tokensPerSecond: Double(tokens) / seconds,
              confidence: "high", networkWarning: nil, source: "test", measurementKind: "completed_body", tokenizer: "o200k_base")
    }
    func testOldHighConfidenceCannotBypassTimingAndAnomalyRules() {
        XCTAssertEqual(sample(tokens: 64, seconds: 0.001).bodyQuality.reason, "采样时长不超过 0.55 秒")
        XCTAssertTrue(sample(tokens: 50, seconds: 1).bodyQuality.included)
        XCTAssertFalse(sample(tokens: 500, seconds: 500).bodyQuality.included)
        var inconsistent = sample(); inconsistent.durationSeconds = 2
        XCTAssertEqual(inconsistent.bodyQuality.reason, "数量与计时不一致")
        var warned = sample(); warned.networkWarning = "retry"
        XCTAssertFalse(warned.bodyQuality.included)
        XCTAssertTrue(sample(tokens: 100, seconds: 2).bodyQuality.included)
        XCTAssertEqual(sample().bodyQuality.confidence, "high")
    }
    func testBodyQualityUsesOriginalMillisecondBoundaryAndNoTokenMinimum() {
        for start in [1000.0, 1_792_581_316.123] {
            for milliseconds in [549, 550, 551] {
                var row = sample(tokens: 20, seconds: Double(milliseconds) / 1000)
                row.startedAt = start
                row.endedAt = start + row.durationSeconds
                row.confidence = "low"
                XCTAssertEqual(row.bodyQuality.included, milliseconds > 550)
                XCTAssertEqual(row.bodyQuality.confidence, milliseconds > 550 ? "medium" : "low")
            }
        }
        XCTAssertEqual(sample(tokens: 12, seconds: 5).bodyQuality.confidence, "high")
        XCTAssertEqual(sample(tokens: 700, seconds: 1).bodyQuality.reason, "速率异常偏高")
    }
    func testBodyAverageIncludesShortTextDespiteLegacyLowConfidence() {
        var collector = ObservedSpeedCollector()
        var first = sample(tokens: 12, seconds: 0.6); first.confidence = "low"
        var second = sample(tokens: 60, seconds: 1.2); second.id = "second"; second.confidence = "low"
        var excluded = sample(tokens: 20, seconds: 0.55); excluded.id = "boundary"
        collector.samples = [first, second, excluded]
        let summary = collector.completedBodySummaries(now: 1020, windowSeconds: 900).first
        XCTAssertEqual(summary?.sampleCount, 2)
        XCTAssertEqual(summary?.outputTokens, 72)
        XCTAssertEqual(summary?.tokensPerSecond ?? 0, 40, accuracy: 0.0001)
        XCTAssertEqual(summary?.confidence, "medium")
        XCTAssertEqual(collector.samples.count, 3)
    }
    func testBodyAverageOnlyWeightsEligibleBodiesAndPreservesExcludedRecords() {
        var collector = ObservedSpeedCollector()
        var other = sample(tokens: 200, seconds: 5); other.id = "second"
        var old = sample(); old.id = "stream"; old.measurementKind = nil
        var spike = sample(tokens: 1000, seconds: 0.001); spike.id = "spike"
        collector.samples = [sample(), other, old, spike]
        let summary = collector.completedBodySummaries(now: 1020, windowSeconds: 900)
        XCTAssertEqual(summary.first?.tokensPerSecond ?? 0, 700.0 / 15.0, accuracy: 0.0001)
        XCTAssertEqual(summary.first?.sampleCount, 2)
        XCTAssertEqual(collector.samples.count, 4)
    }
    func testLatestSidebarSpeedsUseCompleteHistoryAndExpirePerModel() {
        var collector = ObservedSpeedCollector()
        let now = 4000.0
        func row(_ id: String, _ model: String, _ end: Double, _ seconds: Double = 2) -> ObservedSpeedSample {
            var s = sample(tokens: 100, seconds: seconds)
            s.id = id; s.model = model; s.startedAt = end - seconds; s.endedAt = end
            return s
        }
        collector.samples = (0..<12).map { row("m-\($0)", "model-\($0)", now - 10 - Double($0)) }
        collector.samples += [row("old-sol", "sol", now - 80), row("latest-sol", "sol", now - 20),
            row("short-sol", "sol", now - 1, 0.5), row("expired", "expired", now - 1801),
            row("unknown", " unknown ", now - 1), row("future", "future", now + 1)]
        var warned = row("warned-sol", "sol", now - 2); warned.networkWarning = "retry"
        collector.samples.append(warned)
        let summaries = collector.latestCompletedBodySpeeds(now: now)
        XCTAssertEqual(summaries.count, 13)
        let sol = summaries.first { $0.model == "sol" }
        XCTAssertEqual(sol?.lastMeasuredAt, now - 20)
        XCTAssertEqual(sol?.sampleCount, 1)
        XCTAssertEqual(sol?.tokensPerSecond, 50)
        XCTAssertTrue(collector.latestCompletedBodySpeeds(now: now + 1802).isEmpty)
    }
    func testModelOverviewKeepsOlderModelsAndPrefersCurrentWindow() {
        let old = ModelSpeedSummary(model: "luna", tokensPerSecond: 100, sampleCount: 2, outputTokens: 1000, durationSeconds: 10, lastMeasuredAt: 1000)
        var sol = old; sol.model = "sol"; sol.tokensPerSecond = 40
        var recent = sol; recent.tokensPerSecond = 60; recent.lastMeasuredAt = 2000
        var unknown = old; unknown.model = " unknown "
        let readings = BodySpeedModelReading.combined(recent: [recent], retained: [old, sol, unknown])
        XCTAssertEqual(readings.map(\.id), ["sol", "luna"])
        XCTAssertEqual(readings.first?.summary.tokensPerSecond, 60)
        XCTAssertEqual(readings.first?.historical, false)
        XCTAssertEqual(readings.last?.historical, true)
        var collector = ObservedSpeedCollector()
        var warned = sample(); warned.id = "warned"; warned.networkWarning = "retry"
        collector.samples = [sample(tokens: 100, seconds: 2), warned]
        XCTAssertEqual(collector.completedBodySummaries(now: 1020, windowSeconds: 900).first?.lastMeasuredAt, 1002)
        XCTAssertEqual(sample(tokens: 25, seconds: 0.5).bodyQuality.statusLabel, "时长≤0.55秒")
    }
    func testBodySpeedHistoryWindowCentersWithinChosenDisplay() {
        for area in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                     CGRect(x: -1920, y: 50, width: 1920, height: 1030),
                     CGRect(x: 1440, y: -500, width: 800, height: 600)] {
            let frame = BodySpeedHistoryWindowController.centeredFrame(size: CGSize(width: 960, height: 688), in: area)
            XCTAssertEqual(frame.midX, area.midX, accuracy: 0.001)
            XCTAssertEqual(frame.midY, area.midY, accuracy: 0.001)
            XCTAssertTrue(area.contains(frame))
        }
    }
    func testBodyPairingRetainsCommentaryType() throws {
        let fixture = CompletedBodySpeedTests()
        var assembler = CompletedBodyAssembler()
        _ = assembler.consume(try fixture.context(), thread: "s", now: 1020, tokenizer: { _ in 200 })
        _ = assembler.consume(try fixture.timing(), thread: "s", now: 1020, tokenizer: { _ in 200 })
        let body = try fixture.line("response_item", ["type": "message", "role": "assistant", "id": "i", "phase": "commentary", "content": [["type": "output_text", "text": "hello"]]])
        let result = assembler.consume(body, thread: "s", now: 1020, tokenizer: { _ in 200 })
        XCTAssertEqual(result?.bodyPhase, "commentary")
        XCTAssertEqual(result?.bodyTypeLabel, "中间消息")
    }
    func testRetentionUsesDaysAndNeverDeletesLegacyOrSilentlyKeepsOnlyTenThousandRows() {
        let now = 4_000_000.0
        var collector = ObservedSpeedCollector()
        var expired = sample(); expired.id = "expired"; expired.endedAt = now - 31 * 86400
        var middle = sample(); middle.id = "middle"; middle.endedAt = now - 20 * 86400
        var recent = sample(); recent.id = "recent"; recent.endedAt = now - 86400
        var legacy = expired; legacy.id = "legacy"; legacy.measurementKind = nil
        collector.samples = [expired,middle,recent,legacy]
        collector.pruneCompletedBodies(now: now, retentionDays: 30)
        XCTAssertEqual(Set(collector.samples.map(\.id)), ["middle","recent","legacy"])
        collector.pruneCompletedBodies(now: now, retentionDays: 15)
        XCTAssertEqual(Set(collector.samples.map(\.id)), ["recent","legacy"])
        let rows = (0..<11_000).map { index in var row = recent; row.id = "body-\(index)"; return row }
        collector.addCompletedBodies(rows)
        XCTAssertEqual(collector.samples.count, 11_002)
    }
    func testBackgroundWriterRejectsAnOlderQueuedSnapshot() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = BodySpeedSampleWriter()
        let error = await writer.persist([sample()], to: url, ticket: 2)
        XCTAssertNil(error)
        _ = await writer.persist([], to: url, ticket: 1)
        let kept = try JSONDecoder().decode([ObservedSpeedSample].self, from: Data(contentsOf: url))
        XCTAssertEqual(kept.count, 1)
    }
    func testLocalHistoryPerformanceAudit() throws {
        guard let input = ProcessInfo.processInfo.environment["TOKENBAR_BODY_PERF_INPUT"],
              let output = ProcessInfo.processInfo.environment["TOKENBAR_BODY_PERF_OUTPUT"] else { throw XCTSkip("Opt-in numeric history performance audit") }
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as! [String: Any]
        let rows = try JSONDecoder().decode([ObservedSpeedSample].self, from: JSONSerialization.data(withJSONObject: root["samples"]!))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var collector = ObservedSpeedCollector(storeURL: file)
        collector.samples = rows
        let now = Date().timeIntervalSince1970
        var start = Date()
        for _ in 0..<100 { _ = collector.completedBodySummaries(now: now, windowSeconds: 900) }
        let summaryMS = Date().timeIntervalSince(start) * 10
        start = Date()
        for _ in 0..<100 { collector.addCompletedBodies(Array(rows.prefix(10))) }
        let duplicateMS = Date().timeIntervalSince(start) * 10
        start = Date(); collector.persist()
        let persistenceMS = Date().timeIntervalSince(start) * 1000
        XCTAssertNil(collector.persistenceError)
        XCTAssertEqual(collector.samples.count, rows.count)
        let result: [String: Any] = ["sampleCount": rows.count, "summaryMSPerRefresh": summaryMS,
            "duplicateMergeMSPerPoll": duplicateMS, "persistMSOnNewSamples": persistenceMS,
            "storedBytes": try Data(contentsOf: file).count]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output))
    }

}

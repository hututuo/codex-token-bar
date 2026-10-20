import XCTest
@testable import CodexTokenBar

final class ThroughputTelemetryTests: XCTestCase {
    func testInterruptionClearsOnlyAffectedThreadAndLateUsageDoesNotRevive() {
        var curve = ThroughputCurve()
        for thread in ["a", "b"] {
            curve.consume(.init(kind: "start", timestamp: 100, turnID: "t"), thread: thread, now: 100)
            curve.consume(.init(kind: "usage", timestamp: 101, turnID: "t", output: 500), thread: thread, now: 101)
        }
        curve.tick(now: 104)
        XCTAssertGreaterThan(curve.rate(thread: "a"), 0)
        curve.consume(.init(kind: "abort", timestamp: 104, turnID: "t"), thread: "a", now: 104)
        curve.consume(.init(kind: "usage", timestamp: 105, turnID: "t", output: 900), thread: "a", now: 105)
        curve.tick(now: 105)
        XCTAssertEqual(curve.rate(thread: "a"), 0)
        XCTAssertGreaterThan(curve.rate(thread: "b"), 0)
        curve.consume(.init(kind: "start", timestamp: 106, turnID: "new"), thread: "a", now: 106)
        curve.consume(.init(kind: "usage", timestamp: 107, turnID: "new", output: 500), thread: "a", now: 107)
        curve.tick(now: 109)
        XCTAssertGreaterThan(curve.rate(thread: "a"), 0)
    }
    func testFinishExpiresWithinFiveSecondsAndFreshnessIsBounded() {
        var c = ThroughputCurve()
        c.consume(.init(kind: "usage", timestamp: 100, turnID: "t", output: 100_000), thread: "a", now: 100)
        c.consume(.init(kind: "complete", timestamp: 102, turnID: "t"), thread: "a", now: 102)
        c.tick(now: 107)
        XCTAssertEqual(c.total, 0)
        c.consume(.init(kind: "usage", timestamp: 110, turnID: "b", output: 100_000), thread: "a", now: 110)
        c.tick(now: 130)
        XCTAssertEqual(c.total, 0)
    }
    func testTinyReasoningDurationNeverDividesTokensByEightMilliseconds() {
        var c = ThroughputCurve()
        c.consume(.init(kind: "reasoning", timestamp: 100, turnID: "t", itemID: "i", duration: 0.008), thread: "a", now: 100)
        XCTAssertEqual(c.sessions["a"]!.budget, 0.32, accuracy: 0.0001)
        c.consume(.init(kind: "usage", timestamp: 101, turnID: "t", output: 516, reasoning: 516), thread: "a", now: 101)
        XCTAssertEqual(c.sessions["a"]!.budget + c.sessions["a"]!.queue.reduce(0, +) + c.total, 516, accuracy: 0.001)
        XCTAssertTrue(c.sessions["a"]!.history.isEmpty)
    }
    func testSignedSettlementDoesNotDoubleCountReasoning() {
        var c = ThroughputCurve()
        c.consume(.init(kind: "reasoning", timestamp: 100, turnID: "t", duration: 10), thread: "a", now: 100)
        c.consume(.init(kind: "usage", timestamp: 101, turnID: "t", output: 300, reasoning: 200), thread: "a", now: 101)
        XCTAssertEqual(c.sessions["a"]!.budget + c.sessions["a"]!.queue.reduce(0, +) + c.total, 300, accuracy: 0.001)
    }
    func testObservedCollectorExcludesFirstChunkAndUsesWeightedSummary() {
        var c = ObservedSpeedCollector()
        c.start(thread: "a", item: "i")
        for i in 0..<12 { c.append(thread: "a", turn: "t", item: "i", model: "m", text: String(repeating: "x", count: 100), at: 100 + Double(i)) }
        c.finish(thread: "a", estimator: { $0.count })
        let sample = c.samples[0]
        XCTAssertEqual(sample.outputTokens, 1100)
        XCTAssertEqual(sample.tokensPerSecond, 100)
        XCTAssertEqual(sample.durationSeconds, 11)
        XCTAssertEqual(sample.confidence, "high")
        XCTAssertEqual(c.summaries(now: 112).first?.tokensPerSecond, 100)
        c.append(thread: "a", turn: "bad", item: "i", model: "m", text: "a", at: 200)
        c.append(thread: "a", turn: "bad", item: "i", model: "m", text: "xx", at: 210)
        c.finish(thread: "a", estimator: { $0.count })
        XCTAssertNotNil(c.samples.last?.networkWarning)
        XCTAssertEqual(c.summaries(now: 211).first?.sampleCount, 1)
    }
    func testNumericPersistenceDeduplicatesAndPreservesNoText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("speed.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var c = ObservedSpeedCollector(storeURL: url)
        for i in 0..<4 { c.append(thread: "a", turn: "t", item: "i", model: "m", text: "PRIVATE-BODY", at: Double(100 + i)) }
        c.finish(estimator: { $0.count }); c.persist()
        let restored = ObservedSpeedCollector(storeURL: url)
        XCTAssertEqual(restored.samples.count, 1)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("PRIVATE-BODY"))
    }
    func testFifteenAndThirtyMinuteWindowsUseFullEligibleSamples() {
        var c = ObservedSpeedCollector()
        c.start(thread: "a", item: "i")
        for i in 0..<12 { c.append(thread: "a", turn: "t", item: "i", model: "m", text: String(repeating: "x", count: 100), at: 100 + Double(i)) }
        c.finish(estimator: { $0.count })
        var recent = c.samples[0]
        recent.id = "recent"; recent.startedAt = 2_400; recent.endedAt = 2_411
        var earlier = recent
        earlier.id = "earlier"; earlier.startedAt = 1_500; earlier.endedAt = 1_511
        earlier.outputTokens *= 2; earlier.tokensPerSecond *= 2
        c.samples = [earlier, recent]
        XCTAssertEqual(c.summaries(now: 3_000, windowSeconds: 900).first?.sampleCount, 1)
        XCTAssertEqual(c.summaries(now: 3_000, windowSeconds: 900).first?.tokensPerSecond, 100)
        XCTAssertEqual(c.summaries(now: 3_000, windowSeconds: 1_800).first?.sampleCount, 2)
        XCTAssertEqual(c.summaries(now: 3_000, windowSeconds: 1_800).first?.tokensPerSecond, 150)
    }

    func testCorruptMeasurementStoreIsNeverOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("corrupt-but-preserve".utf8).write(to: url)
        var collector = ObservedSpeedCollector(storeURL: url)
        collector.persist()
        XCTAssertNotNil(collector.persistenceError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "corrupt-but-preserve")
    }
    func testMidStreamCaptureCannotEnterModelAverage() {
        var c = ObservedSpeedCollector()
        for i in 0..<12 { c.append(thread: "a", turn: "t", item: "i", model: "m", text: String(repeating: "x", count: 100), at: 100 + Double(i)) }
        c.finish(estimator: { $0.count })
        XCTAssertEqual(c.samples.first?.confidence, "low")
        XCTAssertTrue(c.summaries(now: 112).isEmpty)
    }

    func testQuantityIsNeverReplayedBeforeItsArrival() {
        var c = ThroughputCurve()
        c.consume(.init(kind: "start", timestamp: 100, turnID: "t"), thread: "a", now: 100)
        c.consume(.init(kind: "reasoning", timestamp: 110, turnID: "t", itemID: "i", duration: 10), thread: "a", now: 110)
        c.tick(now: 110)
        XCTAssertEqual(c.total, 0)
        XCTAssertEqual(c.sessions["a"]!.budget, 400)
        c.tick(now: 111)
        XCTAssertGreaterThan(c.total, 0)
    }

    func testTaskCompleteWithErrorIsFailureAndParserKeepsDuration() {
        let signal = ThroughputSignal.parse(object: ["type": "event_msg"], payload: ["type": "task_complete", "error": ["message": "failed"]], at: 100, turn: "t")
        XCTAssertEqual(signal?.kind, "failure")
        let reasoning = ThroughputSignal.parse(object: ["type": "event_msg"], payload: ["type": "item_completed", "item": ["type": "Reasoning", "id": "i"], "started_at_ms": 1000, "completed_at_ms": 9000], at: 10, turn: "t")
        XCTAssertEqual(reasoning?.duration, 8)
    }
}

final class ObservedStreamContextTests: XCTestCase {
    func testAdjacentTurnPacketsUseTheirTimestampAndModel() {
        var contexts = ObservedStreamContexts()
        contexts.consume(.init(kind: "start", timestamp: 100, turnID: "a"), thread: "thread")
        contexts.consume(.init(kind: "context", timestamp: 100.1, turnID: "a", model: "model-a"), thread: "thread")
        contexts.consume(.init(kind: "complete", timestamp: 105, turnID: "a"), thread: "thread")
        contexts.consume(.init(kind: "start", timestamp: 106, turnID: "b"), thread: "thread")
        contexts.consume(.init(kind: "context", timestamp: 106.1, turnID: "b", model: "model-b"), thread: "thread")
        XCTAssertEqual(contexts.resolve(thread: "thread", at: 103, explicitTurn: nil)?.model, "model-a")
        XCTAssertEqual(contexts.resolve(thread: "thread", at: 107, explicitTurn: nil)?.turn, "b")
        XCTAssertNil(contexts.resolve(thread: "thread", at: 105.5, explicitTurn: nil))
    }
    func testUnassociatedPacketNeverBorrowsAnotherTurnsModel() {
        var contexts = ObservedStreamContexts()
        contexts.consume(.init(kind: "context", timestamp: 100, turnID: "a", model: "model-a"), thread: "thread")
        XCTAssertEqual(contexts.resolve(thread: "thread", at: 103, explicitTurn: "other")?.model, "unknown")
        XCTAssertNil(contexts.resolve(thread: "unknown", at: 103, explicitTurn: nil))
    }
    func testInterruptedAndResumedItemRetainsBothNumericSamples() {
        var c = ObservedSpeedCollector()
        for start in [100.0, 200.0] {
            c.start(thread: "a", item: "item")
            for i in 0..<4 { c.append(thread: "a", turn: "t", item: "item", model: "model", text: "abcdef", at: start + Double(i)) }
            c.finish(thread: "a", turn: "t", estimator: { $0.count })
        }
        XCTAssertEqual(c.samples.count, 2)
        XCTAssertNotEqual(c.samples[0].id, c.samples[1].id)
    }
    func testDisplayPoolsShortSegmentsWhileKeepingStrictSummaryEmpty() {
        var c = ObservedSpeedCollector()
        for (item, duration, count) in [("a", 1.0, 80), ("b", 2.0, 20)] {
            c.start(thread: "thread", item: item)
            c.append(thread: "thread", turn: "turn", item: item, model: "model", text: "x", at: 100)
            c.append(thread: "thread", turn: "turn", item: item, model: "model", text: String(repeating: "x", count: count), at: 100 + duration)
            c.finish(item: item, estimator: { $0.count })
        }
        XCTAssertTrue(c.summaries(now: 104).isEmpty)
        let pooled = c.displaySummaries(now: 104, windowSeconds: 900).first!
        XCTAssertEqual(pooled.tokensPerSecond, 100.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(pooled.outputTokens, 100)
        XCTAssertEqual(pooled.sampleCount, 2)
        XCTAssertEqual(pooled.qualifiedSampleCount, 0)
        XCTAssertEqual(pooled.confidence, "medium")
    }
    func testDisplayUpdatesBeforeFinishAndReplacesLiveEstimateWithoutDoubleCounting() {
        var c = ObservedSpeedCollector()
        c.start(thread: "t", item: "i")
        c.append(thread: "t", turn: "turn", item: "i", model: "m", text: "first", at: 100, estimatedTokens: 500)
        c.append(thread: "t", turn: "turn", item: "i", model: "m", text: "second", at: 102, estimatedTokens: 3)
        XCTAssertTrue(c.samples.isEmpty)
        let live = c.displaySummaries(now: 102, windowSeconds: 900).first!
        XCTAssertEqual(live.outputTokens, 3) // first chunk has no measured generation interval
        XCTAssertEqual(live.activeSampleCount, 1)
        XCTAssertTrue(c.displaySummaries(now: 105, windowSeconds: 900).isEmpty)
        c.finish(estimator: { $0.count })
        let done = c.displaySummaries(now: 105, windowSeconds: 900).first!
        XCTAssertEqual(done.outputTokens, 6)
        XCTAssertEqual(done.sampleCount, 1)
        XCTAssertEqual(done.activeSampleCount, 0)
    }
    func testModelBackfillOnlyChangesUnknownAtExactThreadAndTurn() {
        var c = ObservedSpeedCollector()
        for (thread, turn, model) in [("a", "one", "unknown"), ("a", "two", "known"), ("b", "one", "unknown")] {
            c.start(thread: thread, item: turn)
            c.append(thread: thread, turn: turn, item: turn, model: model, text: "x", at: 100)
            c.append(thread: thread, turn: turn, item: turn, model: model, text: "more", at: 101)
            c.finish(thread: thread, item: turn, estimator: { $0.count })
        }
        let quantities = c.samples.map(\.outputTokens)
        c.resolveModels(["a": ["one": "resolved", "two": "wrong"]])
        XCTAssertEqual(c.samples.map(\.model), ["resolved", "known", "unknown"])
        XCTAssertEqual(c.samples.map(\.outputTokens), quantities)
    }

}

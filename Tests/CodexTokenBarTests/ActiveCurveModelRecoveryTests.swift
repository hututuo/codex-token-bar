import XCTest
@testable import CodexTokenBar

final class ActiveCurveModelRecoveryTests: XCTestCase {
    func testMidTurnStartupResolvesExactModelWithoutReplayingOrChangingAmounts() {
        var curve = ThroughputCurve()
        curve.consume(.init(kind: "usage", timestamp: 100, turnID: "long-turn", output: 1000), thread: "chat", now: 100)
        curve.tick(now: 103)
        XCTAssertEqual(curve.modelRates.first?.model, "unknown")
        XCTAssertEqual(curve.unresolvedModelTurns(now: 103), ["chat": ["long-turn"]])
        let old = curve.sessions["chat"]!, total = curve.total
        XCTAssertFalse(curve.resolveModels(["chat": ["neighbour-turn": "gpt-6-luna"]]))
        XCTAssertTrue(curve.resolveModels(["chat": ["long-turn": "gpt-6.1-sol"]]))
        XCTAssertEqual(curve.modelRates.first?.model, "gpt-6.1-sol")
        XCTAssertEqual(curve.total, total)
        let new = curve.sessions["chat"]!
        XCTAssertEqual(new.budget, old.budget); XCTAssertEqual(new.rate, old.rate)
        XCTAssertEqual(new.queue, old.queue); XCTAssertEqual(new.lastQuantity, old.lastQuantity)
        XCTAssertEqual(new.turn, old.turn); XCTAssertEqual(new.finish, old.finish)
        XCTAssertFalse(curve.resolveModels(["chat": ["long-turn": "gpt-6-astra"]]))
        curve.consume(.init(kind: "abort", timestamp: 104, turnID: "long-turn"), thread: "chat", now: 104)
        curve.resolveModels(["chat": ["long-turn": "gpt-6-luna"]])
        XCTAssertEqual(curve.total, 0); XCTAssertTrue(curve.unresolvedModelTurns(now: 104).isEmpty)
    }

    func testNewTurnDoesNotBorrowPreviousModelsAndCompletedTailCanBeColored() {
        var curve = ThroughputCurve()
        curve.consume(.init(kind: "context", timestamp: 100, turnID: "old", model: "gpt-6-luna"), thread: "chat", now: 100)
        curve.consume(.init(kind: "usage", timestamp: 101, turnID: "new", output: 1000), thread: "chat", now: 101)
        curve.tick(now: 103)
        XCTAssertEqual(curve.modelRates.first?.model, "unknown")
        XCTAssertFalse(curve.resolveModels(["chat": ["old": "gpt-6-luna"]]))
        curve.consume(.init(kind: "complete", timestamp: 103, turnID: "new"), thread: "chat", now: 103)
        XCTAssertEqual(curve.unresolvedModelTurns(now: 104), ["chat": ["new"]])
        let before = curve.total
        XCTAssertTrue(curve.resolveModels(["chat": ["new": "gpt-6.1-sol"]]))
        XCTAssertEqual(curve.total, before)
        curve.tick(now: 108)
        XCTAssertEqual(curve.total, 0)
        XCTAssertTrue(curve.unresolvedModelTurns(now: 108).isEmpty)
    }

    @MainActor
    func testStreamCarriesItsExactContextModelIntoCurve() {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "chat")
        monitor.speedContexts.consume(.init(kind: "context", timestamp: 1, turnID: "turn", model: "gpt-6-luna"), thread: "chat")
        monitor.testProcessPollInputs(streamRows: [.init(id: 1, threadID: "chat", ts: 100, tsNanos: 0,
            target: "codex_api::sse::responses", feedbackLogBody: #"SSE event: {"type":"response.output_text.delta","delta":"test output text","item_id":"body","turn_id":"turn","sequence_number":1}"#)], rolloutReads: [], now: 100)
        XCTAssertEqual(monitor.throughputCurve.sessions["chat"]?.model, "gpt-6-luna")
    }

    func testMetadataLookupFindsContextOutsideStartupTailAndRepairsOnlyExactTurn() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let path = home.appendingPathComponent("sessions/rollout-chat.jsonl")
        let oldContext = #"{"type":"turn_context","payload":{"turn_id":"long-turn","model":"gpt-6.1-sol"}}"# + "\n"
        let padding = String(repeating: #"{"type":"event_msg","payload":{"type":"irrelevant"}}"# + "\n", count: 2000)
        try (oldContext + padding).write(to: path, atomically: true, encoding: .utf8)
        let resolver = ObservedSpeedModelResolver()
        var curve = ThroughputCurve()
        curve.consume(.init(kind: "usage", timestamp: 100, turnID: "long-turn", output: 1000), thread: "chat", now: 100)
        curve.tick(now: 103)
        let total = curve.total
        let lookup = await resolver.resolve(home: home, paths: ["chat": path.path], requested: curve.unresolvedModelTurns(now: 103))
        XCTAssertTrue(curve.resolveModels(lookup))
        XCTAssertEqual(curve.modelRates.first?.model, "gpt-6.1-sol")
        XCTAssertEqual(curve.total, total)
    }
    @MainActor
    func testMonitorBackfillsCurveEvenWhenBodySpeedStoreHasNoSamples() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let path = home.appendingPathComponent("sessions/rollout-chat.jsonl")
        try (#"{"type":"turn_context","payload":{"turn_id":"turn","model":"gpt-6.1-sol"}}"# + "\n").write(to: path, atomically: true, encoding: .utf8)
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.setDataSource(CodexDataSource(codexHome: home, origin: .userSelected))
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "chat", threadOptions: [.init(id: "chat", title: "fixture", updatedAtMS: 0, rolloutPath: path.path)])
        let now = Date().timeIntervalSince1970
        monitor.testRefreshSnapshots(now: now)
        monitor.throughputCurve.consume(.init(kind: "usage", timestamp: now, turnID: "turn", output: 1000), thread: "chat", now: now)
        monitor.testRefreshSnapshots(now: now)
        for _ in 0..<100 {
            if monitor.throughputCurve.sessions["chat"]?.model == "gpt-6.1-sol" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(monitor.throughputCurve.sessions["chat"]?.model, "gpt-6.1-sol")
        XCTAssertTrue(monitor.speedSamples.isEmpty)
        monitor.setDataSource(nil)
    }

    func testLocalMetadataReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TOKENBAR_MODEL_REPLAY_PATH"], let thread = env["TOKENBAR_MODEL_REPLAY_THREAD"],
              let turn = env["TOKENBAR_MODEL_REPLAY_TURN"], let home = env["TOKENBAR_MODEL_REPLAY_HOME"] else {
            throw XCTSkip("Opt-in read-only local model metadata replay")
        }
        var curve = ThroughputCurve()
        curve.consume(.init(kind: "usage", timestamp: 100, turnID: turn, output: 1000), thread: thread, now: 100)
        curve.tick(now: 103)
        let before = curve.total
        let lookup = await ObservedSpeedModelResolver().resolve(home: URL(fileURLWithPath: home), paths: [thread: path], requested: curve.unresolvedModelTurns(now: 103))
        XCTAssertTrue(curve.resolveModels(lookup))
        XCTAssertEqual(curve.total, before)
        XCTAssertNotEqual(curve.modelRates.first?.model, "unknown")
        print("MODEL_RECOVERY_REAL_REPLAY model=\(curve.modelRates.first?.model ?? "missing") before=\(before) after=\(curve.total)")
    }

}

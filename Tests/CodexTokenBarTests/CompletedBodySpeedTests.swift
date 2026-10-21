import XCTest
@testable import CodexTokenBar

final class CompletedBodySpeedTests: XCTestCase {
    let now = 1020.0
    func line(_ type: String, _ p: [String: Any], at: Double = 1010, ordinal: UInt64? = nil) throws -> Data {
        var obj: [String: Any] = ["type": type, "timestamp": Date(timeIntervalSince1970: at).ISO8601Format(), "payload": p]
        if let ordinal { obj["ordinal"] = ordinal }
        return try JSONSerialization.data(withJSONObject: obj)
    }
    func context(_ turn: String = "t", model: String = "m") throws -> Data { try line("turn_context", ["turn_id": turn, "model": model]) }
    func body(_ id: String = "i", turn: String? = nil) throws -> Data {
        var p: [String: Any] = ["type": "message", "role": "assistant", "id": id, "content": [["type": "output_text", "text": "hello world"]]]
        if let turn { p["turn_id"] = turn }
        return try line("response_item", p)
    }
    func timing(_ id: String = "i", turn: String = "t", start: Any = 1_000_000, end: Any = 1_010_000) throws -> Data {
        try line("event_msg", ["type": "item_completed", "turn_id": turn, "item": ["type": "AgentMessage", "id": id], "started_at_ms": start, "completed_at_ms": end])
    }
    func ingest(_ data: Data, _ a: inout CompletedBodyAssembler) -> ObservedSpeedSample? {
        a.consume(data, thread: "s", now: now, tokenizer: { _ in 400 })
    }
    func testJoinsEitherOrderWithExactTurnAndItemAndOwnModel() throws {
        for reversed in [false, true] {
            var a = CompletedBodyAssembler()
            _ = ingest(try context(), &a)
            let parts = reversed ? [try body(), try timing()] : [try timing(), try body()]
            XCTAssertNil(ingest(parts[0], &a))
            let sample = try XCTUnwrap(ingest(parts[1], &a))
            XCTAssertEqual(sample.model, "m"); XCTAssertEqual(sample.turnID, "t")
            XCTAssertEqual(sample.outputTokens, 400); XCTAssertEqual(sample.tokensPerSecond, 40)
            XCTAssertEqual(sample.measurementKind, "completed_body"); XCTAssertEqual(sample.chunkCount, 0)
            XCTAssertTrue(a.pending.isEmpty)
        }
        var a = CompletedBodyAssembler()
        _ = ingest(try context(), &a); _ = ingest(try timing(), &a)
        _ = ingest(try context("other", model: "other-model"), &a)
        XCTAssertNil(ingest(try body("wrong"), &a))
        XCTAssertNil(ingest(try body(), &a)) // explicit turn required if context moved
        XCTAssertEqual(ingest(try body(turn: "t"), &a)?.model, "m")
    }
    func testRejectsInvalidTimeBooleanToolsAndInheritedHistory() throws {
        for (start, end): (Any, Any) in [(1000, 999), (1000, 1000), (true, 1000), (-1, 1000)] {
            var a = CompletedBodyAssembler(); _ = ingest(try context(), &a)
            _ = ingest(try timing(start: start, end: end), &a)
            XCTAssertNil(ingest(try body(), &a))
        }
        var a = CompletedBodyAssembler(); _ = ingest(try context(), &a)
        _ = ingest(try timing(), &a)
        XCTAssertNil(ingest(try line("response_item", ["type": "function_call_output", "id": "i", "output": "hello"]), &a))
        a.configure(metadata: ["id": "child", "forked_from_id": "parent", "timestamp": Date(timeIntervalSince1970: 1015).ISO8601Format()])
        XCTAssertNil(ingest(try body(), &a))
    }
    func testSubagentMetadataMarkersAreRecognized() {
        let markers: [[String: Any]] = [
            ["thread_source": "subagent"],
            ["source": ["subagent": false]],
            ["agent_role": "worker"],
            ["agent_path": "root/worker"]
        ]
        for metadata in markers {
            var assembler = CompletedBodyAssembler()
            assembler.configure(metadata: metadata)
            XCTAssertTrue(assembler.hasFork, "Expected subagent marker: \(metadata)")
        }

        var ordinary = CompletedBodyAssembler()
        ordinary.configure(metadata: ["thread_source": "main", "source": [:], "agent_role": "", "agent_path": ""])
        XCTAssertFalse(ordinary.hasFork)
    }
    func testSubagentMetadataKeepsOnlyOwnPaginatedTurn() throws {
        let child = "0000000f-4240-7000-8000-000000000001"
        let parent = "0000000f-4100-7000-8000-000000000003"
        let own = "0000000f-4300-7000-8000-000000000002"
        var a = CompletedBodyAssembler()
        a.configure(metadata: ["id": child, "thread_source": "subagent", "history_mode": "paginated"])
        _ = ingest(try context(parent), &a)
        _ = ingest(try timing(turn: parent, start: 1_001_000), &a)
        XCTAssertNil(ingest(try body(turn: parent), &a))
        _ = ingest(try context(own), &a)
        _ = ingest(try timing(turn: own, start: 1_001_000), &a)
        XCTAssertEqual(ingest(try body(turn: own), &a)?.turnID, own)
    }
    func testPaginatedForkRejectsRewrittenParentButKeepsNewChildTurn() throws {
        let child = "0000000f-4240-7000-8000-000000000001"
        let own = "0000000f-4300-7000-8000-000000000002"
        let parent = "0000000f-4100-7000-8000-000000000003"
        var a = CompletedBodyAssembler()
        a.configure(metadata: ["id": child, "forked_from_id": "p", "history_mode": "paginated", "subagent_history_start_ordinal": 900])
        _ = ingest(try context(parent), &a)
        _ = ingest(try timing(turn: parent, start: 1_001_000), &a)
        XCTAssertNil(ingest(try body(turn: parent), &a))
        _ = ingest(try context(own), &a)
        _ = ingest(try timing(turn: own, start: 1_001_000), &a)
        XCTAssertEqual(ingest(try body(turn: own), &a)?.turnID, own)
    }
    func testPendingIsBoundedAndCannotCrossThreads() throws {
        var a = CompletedBodyAssembler(); _ = ingest(try context(), &a)
        for i in 0..<200 { _ = ingest(try body("i\(i)"), &a) }
        XCTAssertLessThanOrEqual(a.pending.count, 32)
        var other = CompletedBodyAssembler(); _ = ingest(try context(), &other)
        XCTAssertNil(ingest(try timing("i199"), &other))
    }
    func testBundledO200kWorksWithoutNetworkAndHasNoSixteenKTruncation() throws {
        let encoder = try BodySpeedTokenizer.load()
        XCTAssertEqual(encoder.encodeOrdinary(text: "hello world").count, 2)
        XCTAssertEqual(encoder.encodeOrdinary(text: "你好世界").count, 2)
        XCTAssertEqual(encoder.encodeOrdinary(text: String(repeating: "hello world ", count: 3000)).count, 6001)
    }
    func testLegacyPersistenceAndCanonicalSummaryDoNotDoubleCount() throws {
        var a = CompletedBodyAssembler(); _ = ingest(try context(), &a); _ = ingest(try timing(), &a)
        let fresh = try XCTUnwrap(ingest(try body(), &a))
        var old = fresh; old.id = "legacy"; old.measurementKind = nil; old.tokenizer = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode([old]).write(to: url)
        var c = ObservedSpeedCollector(storeURL: url)
        c.addCompletedBodies([fresh, fresh]); c.persist()
        let restored = ObservedSpeedCollector(storeURL: url)
        XCTAssertEqual(restored.samples.count, 2); XCTAssertEqual(restored.samples.first, old)
        XCTAssertEqual(restored.completedBodySummaries(now: now, windowSeconds: 900).first?.sampleCount, 1)
        XCTAssertEqual(restored.completedBodySummaries(now: now, windowSeconds: 900).first?.tokensPerSecond, 40)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("hello world"))
    }
    func testReaderBackfillPartialAppendAndReplayAreIdempotent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout.jsonl")
        var data = Data()
        for value in [try context(), try timing()] { data.append(value); data.append(10) }
        let b = try body(); data.append(b.prefix(b.count / 2)); try data.write(to: file)
        let option = LiveThreadOption(id: "s", title: "", updatedAtMS: 0, rolloutPath: file.path)
        let reader = CompletedBodySpeedReader()
        let empty = await reader.read(options: [option], now: now)
        XCTAssertNil(empty.error); XCTAssertTrue(empty.samples.isEmpty)
        let h = try FileHandle(forWritingTo: file); try h.seekToEnd(); try h.write(contentsOf: b.suffix(b.count - b.count / 2) + Data([10])); try h.close()
        let result = await reader.read(options: [option], now: now)
        XCTAssertEqual(result.samples[file.path]?.first?.outputTokens, 2)
        let again = await reader.read(options: [option], now: now)
        var collector = ObservedSpeedCollector()
        collector.addCompletedBodies(result.samples[file.path] ?? []); collector.addCompletedBodies(again.samples[file.path] ?? [])
        XCTAssertEqual(collector.samples.count, 1)
    }
    func testSameFileRewriteThatGrowsResetsBodyCursorWithoutDroppingHistory() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        func bytes(_ lines: [Data]) -> Data { lines.reduce(into: Data()) { $0.append($1); $0.append(10) } }
        try bytes([context(), timing(), body()]).write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        let reader = CompletedBodySpeedReader()
        let options = [LiveThreadOption(id: "s", title: "", updatedAtMS: 0, rolloutPath: file.path)]
        let first = await reader.read(options: options, now: now)
        XCTAssertEqual(first.samples[file.path]?.count, 1)
        let newTurn = String(repeating: "new-turn", count: 100)
        try bytes([context(newTurn), timing("j", turn: newTurn), body("j", turn: newTurn)]).write(to: file)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, before)
        let second = await reader.read(options: options, now: now)
        XCTAssertEqual(second.samples[file.path]?.count, 2)
        try FileManager.default.removeItem(at: file)
        let missing = await reader.read(options: options, now: now)
        XCTAssertEqual(missing.samples[file.path]?.count, 2)
    }
    func testReaderDeduplicatesOptionsThatShareOneRolloutPath() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [try context(), try timing(), try body()]
        try lines.reduce(into: Data()) { data, line in data.append(line); data.append(10) }.write(to: file)
        let options = [
            LiveThreadOption(id: "newer", title: "", updatedAtMS: 2, rolloutPath: file.path),
            LiveThreadOption(id: "older", title: "", updatedAtMS: 1, rolloutPath: file.path)
        ]
        let result = await CompletedBodySpeedReader().read(options: options, now: now)
        let samples = try XCTUnwrap(result.samples[file.path])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.threadID, "newer")
    }
    func testLocalProductionReaderAudit() async throws {
        guard let input = ProcessInfo.processInfo.environment["TOKENBAR_BODY_AUDIT_OPTIONS"],
              let output = ProcessInfo.processInfo.environment["TOKENBAR_BODY_AUDIT_OUTPUT"] else { throw XCTSkip("Opt-in real local metadata audit") }
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as! [[String: String]]
        let options = rows.map { LiveThreadOption(id: $0["id"]!, title: "", updatedAtMS: 0, rolloutPath: $0["path"]!) }
        let reader = CompletedBodySpeedReader(), time = Date().timeIntervalSince1970
        let start = Date()
        let result = await reader.read(options: options, now: time)
        XCTAssertNil(result.error)
        var collector = ObservedSpeedCollector(); collector.addCompletedBodies(result.samples.values.flatMap { $0 })
        XCTAssertFalse(collector.samples.isEmpty)
        // Drain bounded bootstrap batches before measuring a genuinely idle incremental poll.
        for _ in 0..<8 { _ = await reader.read(options: options, now: time) }
        let secondStart = Date(); _ = await reader.read(options: options, now: time)
        let metadata: [String: Any] = ["samples": try JSONSerialization.jsonObject(with: JSONEncoder().encode(collector.samples)),
            "bootstrapAndSecondReadSeconds": Date().timeIntervalSince(start), "idleReadSeconds": Date().timeIntervalSince(secondStart),
            "models": collector.completedBodySummaries(now: time, windowSeconds: 1800).map { ["model": $0.model, "tokens": $0.outputTokens, "seconds": $0.durationSeconds, "rate": $0.tokensPerSecond, "count": $0.sampleCount] as [String: Any] }]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}

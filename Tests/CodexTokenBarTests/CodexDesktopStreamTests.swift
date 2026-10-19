import XCTest
@testable import CodexTokenBar

final class CodexDesktopStreamTests: XCTestCase {
    let interests: Set<String> = ["thread"]
    func envelope(_ change: [String: Any], owner: String = "owner", thread: String = "thread", version: Int = 11) -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-state-changed", "sourceClientId": owner, "version": version,
         "params": ["hostId": "local", "conversationId": thread, "change": change]]
    }
    func snapshot(text: String = "old", model: String = "model-a") -> [String: Any] {
        envelope(["type": "snapshot", "revision": 10, "conversationState": ["id": "thread", "turnHistory": ["history": ["entitiesByKey": [
            "entity": ["turnId": "turn-a", "status": "inProgress", "params": ["model": model],
                       "items": [["id": "message", "type": "agentMessage", "text": text], ["id": "tool", "type": "commandExecution", "aggregatedOutput": "tool text"]]]
        ]]]]])
    }
    func patch(_ revision: Int, base: Int? = nil, patches: [[String: Any]] = [], changes: [[String: Any]] = []) -> [String: Any] {
        envelope(["type": "patches", "revision": revision, "baseRevision": base ?? revision - 1,
                  "patches": patches, "acceptedTextChanges": changes])
    }
    func text(_ insert: String, at: Int, item: String = "message", entity: String = "entity") -> [String: Any] {
        ["type": "text", "key": ["hostId": "local", "threadId": "thread", "entityKey": entity, "itemId": item],
         "target": ["field": "text"], "edits": [["at": at, "deleteCount": 0, "insert": insert]]]
    }
    func testSnapshotOnlySeedsLengthsAndFirstLiveDeltaHasExactAttribution() {
        var decoder = DesktopStreamDecoder()
        XCTAssertTrue(decoder.consume(snapshot(), at: 100, interests: interests).isEmpty)
        let events = decoder.consume(patch(11, changes: [text(" next", at: 3)]), at: 101, interests: interests)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .delta)
        XCTAssertEqual(events[0].text, " next")
        XCTAssertEqual(events[0].thread, "thread")
        XCTAssertEqual(events[0].turn, "turn-a")
        XCTAssertEqual(events[0].item, "message")
        XCTAssertEqual(events[0].model, "model-a")
        XCTAssertEqual(events[0].at, 101)
    }
    func testDuplicateIsIgnoredGapAndOwnerSwitchResetAndRequireNewSnapshot() {
        var d = DesktopStreamDecoder()
        _ = d.consume(snapshot(), at: 100, interests: interests)
        let packet = patch(11, changes: [text("x", at: 3)])
        XCTAssertEqual(d.consume(packet, at: 101, interests: interests).count, 1)
        XCTAssertTrue(d.consume(packet, at: 102, interests: interests).isEmpty)
        XCTAssertEqual(d.consume(patch(13), at: 103, interests: interests).first?.kind, .reset)
        XCTAssertEqual(d.resubscribe, "thread")
        XCTAssertTrue(d.consume(patch(14), at: 104, interests: interests).isEmpty)
        _ = d.consume(snapshot(), at: 105, interests: interests)
        var switched = patch(11); switched["sourceClientId"] = "other"
        XCTAssertEqual(d.consume(switched, at: 106, interests: interests).first?.kind, .reset)
    }
    func testUTF16AppendAndNoReplacementsOrToolOutputMeasured() {
        var d = DesktopStreamDecoder()
        _ = d.consume(snapshot(text: "🐈"), at: 100, interests: interests)
        XCTAssertEqual(d.consume(patch(11, changes: [text("a", at: 2)]), at: 101, interests: interests).first?.text, "a")
        XCTAssertTrue(d.consume(patch(12, changes: [text("stdout", at: 0, item: "tool")]), at: 102, interests: interests).isEmpty)
        XCTAssertEqual(d.consume(patch(13, changes: [text("bad", at: 0)]), at: 103, interests: interests).last?.kind, .reset)
        XCTAssertEqual(d.resubscribe, "thread")
    }
    func testFreshItemStartDeltaAndCompletionOrderedAndShortAdjacentTurnsKeepModels() {
        var d = DesktopStreamDecoder()
        _ = d.consume(snapshot(), at: 100, interests: interests)
        let prefix: [Any] = ["turnHistory", "history", "entitiesByKey", "new"]
        let turn: [String: Any] = ["turnId": "turn-b", "status": "inProgress", "params": ["model": "model-b"], "items": []]
        _ = d.consume(patch(11, patches: [["op": "add", "path": prefix, "value": turn]]), at: 101, interests: interests)
        let start = d.consume(patch(12, patches: [["op": "add", "path": prefix + ["items", 0],
            "value": ["id": "new-message", "type": "agentMessage", "text": ""]]]), at: 102, interests: interests)
        XCTAssertEqual(start.first?.kind, .start)
        let final = d.consume(patch(13, patches: [["op": "add", "path": prefix + ["completedItemIds", "new-message"], "value": true]],
            changes: [text("new content", at: 0, item: "new-message", entity: "new")]), at: 103, interests: interests)
        XCTAssertEqual(final.map(\.kind), [.delta, .finish])
        XCTAssertTrue(final.allSatisfy { $0.turn == "turn-b" && $0.model == "model-b" })
    }
    func testProtocolAndThreadFencesAndInterruption() {
        var d = DesktopStreamDecoder()
        var wrong = snapshot(); wrong["version"] = 12
        XCTAssertTrue(d.consume(wrong, at: 100, interests: interests).isEmpty)
        XCTAssertTrue(d.consume(snapshot(), at: 100, interests: []).isEmpty)
        _ = d.consume(snapshot(), at: 100, interests: interests)
        let e = d.consume(patch(11, patches: [["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "entity", "status"], "value": "interrupted"]]), at: 101, interests: interests)
        XCTAssertEqual(e.first?.kind, .interrupted)
        XCTAssertEqual(e.first?.turn, "turn-a")
    }
}

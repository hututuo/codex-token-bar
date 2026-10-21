import XCTest
@testable import CodexTokenBar

final class CodexDesktopStreamTests: XCTestCase {
    func testFollowingStatusRequestReannouncesOnlyInterestedLocalVersionedThread() {
        var request: [String: Any] = ["type": "broadcast", "method": "thread-stream-following-status-requested",
            "sourceClientId": "new-owner", "version": 1, "params": ["hostId": "local", "conversationId": "thread"]]
        XCTAssertEqual(DesktopStreamCoordination.parse(request, interests: interests), .following(thread: "thread", target: "new-owner"))
        XCTAssertNil(DesktopStreamCoordination.parse(request, interests: []))
        request["params"] = ["hostId": "remote", "conversationId": "thread"]
        XCTAssertNil(DesktopStreamCoordination.parse(request, interests: interests))
        request["params"] = ["hostId": "local", "conversationId": "thread"]
        request["version"] = 2
        XCTAssertNil(DesktopStreamCoordination.parse(request, interests: interests))
    }
    func testPeerReconnectAndResetProtocolValidation() {
        var message: [String: Any] = ["type": "broadcast", "method": "client-status-changed", "version": 0,
            "sourceClientId": "peer", "params": ["clientId": "peer", "status": "connected"]]
        XCTAssertEqual(DesktopStreamCoordination.parse(message, interests: interests), .connected("peer"))
        message["params"] = ["clientId": "peer", "status": "disconnected"]
        XCTAssertEqual(DesktopStreamCoordination.parse(message, interests: interests), .disconnected("peer"))
        message["version"] = 1
        XCTAssertNil(DesktopStreamCoordination.parse(message, interests: interests))
        message["method"] = "ipc-connection-reset"
        XCTAssertEqual(DesktopStreamCoordination.parse(message, interests: interests), .reset)
        message["version"] = 2
        XCTAssertNil(DesktopStreamCoordination.parse(message, interests: interests))
    }
    func testMissingBaselineRetryBacksOffAndNeverResnapshotsHealthyOrRemovedThreads() {
        var retry = DesktopStreamFollowRetry()
        retry.sent("missing", at: 100)
        retry.sent("healthy", at: 100)
        retry.sent("removed", at: 100)
        retry.reconcile(interests: ["missing", "healthy"], baselines: ["healthy"])
        XCTAssertTrue(retry.due(at: 109.9).isEmpty)
        XCTAssertEqual(retry.due(at: 110), ["missing"])
        XCTAssertTrue(retry.due(at: 129.9).isEmpty)
        XCTAssertEqual(retry.due(at: 130), ["missing"])
        XCTAssertEqual(retry.due(at: 170), ["missing"])
        XCTAssertTrue(retry.due(at: 229.9).isEmpty)
        XCTAssertEqual(retry.due(at: 230), ["missing"])
        XCTAssertEqual(retry.due(at: 290), ["missing"])
        retry.reconcile(interests: ["missing"], baselines: ["missing"])
        XCTAssertTrue(retry.due(at: 10_000).isEmpty)
    }
    @MainActor func testTransportWithoutBaselineNeverClaimsMeasurementReady() {
        let pending = "Desktop 接口已连接，但未收到会话状态；正在重试订阅，暂不能测速"
        XCTAssertEqual(LiveRateMonitor.desktopMeasurementStatus(connection: pending, lastDelta: 99, now: 100), pending)
    }
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
    let entityPath: [Any] = ["turnHistory", "history", "entitiesByKey", "entity"]
    func testPendingSnapshotHydratesIDStatusModelAndPreservesObservedStart() {
        var d = DesktopStreamDecoder()
        let pending = envelope(["type": "snapshot", "revision": 10, "conversationState": ["id": "thread",
            "turnHistory": ["history": ["entitiesByKey": ["entity": ["turnId": NSNull(), "status": "pending", "items": []]]]]]])
        XCTAssertTrue(d.consume(pending, at: 100, interests: interests).isEmpty)
        XCTAssertTrue(d.consume(patch(11, patches: [["op": "add", "path": entityPath + ["items", 0],
            "value": ["id": "message", "type": "agentMessage", "text": ""]]]), at: 101, interests: interests).isEmpty)
        let events = d.consume(patch(12, patches: [
            ["op": "replace", "path": entityPath + ["turnId"], "value": "real-turn"],
            ["op": "replace", "path": entityPath + ["status"], "value": "inProgress"],
            ["op": "replace", "path": entityPath + ["params", "model"], "value": "real-model"]
        ], changes: [text("first", at: 0)]), at: 102, interests: interests)
        XCTAssertEqual(events.map(\.kind), [.start, .delta])
        XCTAssertTrue(events.allSatisfy { $0.turn == "real-turn" && $0.model == "real-model" })
        XCTAssertEqual(d.consume(patch(13, changes: [text(" second", at: 5)]), at: 103, interests: interests).map(\.kind), [.delta])
    }
    func testPendingEntityAddedAfterSnapshotCanActivate() {
        var d = DesktopStreamDecoder()
        _ = d.consume(snapshot(), at: 100, interests: interests)
        let prefix: [Any] = ["turnHistory", "history", "entitiesByKey", "placeholder"]
        _ = d.consume(patch(11, patches: [["op": "add", "path": prefix,
            "value": ["turnId": NSNull(), "status": "pending", "items": []]]]), at: 101, interests: interests)
        let e = d.consume(patch(12, patches: [
            ["op": "replace", "path": prefix + ["turnId"], "value": "next"],
            ["op": "replace", "path": prefix + ["status"], "value": "inProgress"],
            ["op": "add", "path": prefix + ["items", 0], "value": ["id": "message", "type": "agentMessage", "text": ""]]
        ], changes: [text("x", at: 0, entity: "placeholder")]), at: 102, interests: interests)
        XCTAssertEqual(e.map(\.kind), [.start, .delta])
        XCTAssertEqual(e.last?.turn, "next")
    }
    func testUnknownAcceptedEntityResynchronizesRatherThanSilentlyAdvancing() {
        var d = DesktopStreamDecoder()
        _ = d.consume(snapshot(), at: 100, interests: interests)
        XCTAssertEqual(d.consume(patch(11, changes: [text("lost", at: 0, entity: "missing")]), at: 101, interests: interests).map(\.kind), [.reset])
        XCTAssertEqual(d.resubscribe, "thread")
        XCTAssertNil(d.threads["thread"])
    }
    func testTerminalStatusWithFinalDeltaDeliversDeltaBeforeFinish() {
        var d = DesktopStreamDecoder()
        _ = d.consume(snapshot(), at: 100, interests: interests)
        let events = d.consume(patch(11, patches: [["op": "replace", "path": entityPath + ["status"], "value": "completed"]],
            changes: [text(" last", at: 3)]), at: 101, interests: interests)
        XCTAssertEqual(events.map(\.kind), [.delta, .finish])
        XCTAssertNil(d.resubscribe)
        XCTAssertTrue(d.threads["thread"]!.turns.isEmpty)
    }
    func testRemoveReplacementAndMoveInvalidateExistingSample() {
        for operation in ["remove", "replace", "move"] {
            var d = DesktopStreamDecoder()
            _ = d.consume(snapshot(), at: 100, interests: interests)
            var p: [String: Any] = ["op": operation, "path": entityPath]
            if operation == "replace" { p["value"] = ["turnId": "turn-a", "status": "completed", "items": []] }
            if operation == "move" { p["from"] = ["turnHistory", "history", "entitiesByKey", "other"] }
            XCTAssertEqual(d.consume(patch(11, patches: [p]), at: 101, interests: interests).last?.kind, .reset)
            if operation == "move" { XCTAssertEqual(d.resubscribe, "thread") }
            else { XCTAssertTrue(d.threads["thread"]!.turns.isEmpty) }
        }
    }
    func testProjectionKeepsOnlyMetadataAndAdoptsUTF16OffsetWithoutReplayingHistory() throws {
        var original = snapshot(text: String(repeating: "SECRET BODY", count: 1000))
        let encoded = try JSONSerialization.data(withJSONObject: original)
        let projected = try XCTUnwrap(DesktopSnapshotProjection.project(encoded))
        let compact = try JSONSerialization.data(withJSONObject: projected)
        XCTAssertLessThan(compact.count, 1500)
        XCTAssertFalse(String(decoding: compact, as: UTF8.self).contains("SECRET BODY"))
        var d = DesktopStreamDecoder()
        XCTAssertTrue(d.consume(projected, at: 100, interests: interests).isEmpty)
        XCTAssertEqual(d.consume(patch(11, changes: [text("🐈", at: 20000)]), at: 101, interests: interests).map(\.kind), [.delta])
        XCTAssertEqual(d.consume(patch(12, changes: [text("a", at: 20002)]), at: 102, interests: interests).first?.text, "a")
        XCTAssertEqual(d.consume(patch(13, changes: [text("bad", at: 1)]), at: 103, interests: interests).last?.kind, .reset)
        original["version"] = 12
        XCTAssertNil(DesktopSnapshotProjection.project(try JSONSerialization.data(withJSONObject: original)))
    }
    @MainActor func testMeasurementStatusDoesNotClaimReceptionForever() {
        XCTAssertTrue(LiveRateMonitor.desktopMeasurementStatus(connection: "已连接", lastDelta: nil, now: 100).contains("等待正文增量"))
        XCTAssertTrue(LiveRateMonitor.desktopMeasurementStatus(connection: "已连接", lastDelta: 99, now: 100).contains("最近 2 秒"))
        XCTAssertTrue(LiveRateMonitor.desktopMeasurementStatus(connection: "已连接", lastDelta: 90, now: 100).contains("距上次接收 10 秒"))
        XCTAssertEqual(LiveRateMonitor.desktopMeasurementStatus(connection: "连接断开", lastDelta: 99, now: 100), "连接断开")
    }

}

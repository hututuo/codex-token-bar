import Foundation
import XCTest
@testable import CodexTokenBar

final class ModelTraceTests: XCTestCase {
    func testRealPipeRetainsOptedInNotificationsAndQuotaStillFiltersThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("fake-codex")
        try "#!/bin/sh\nprintf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{}}' '{\"id\":1,\"result\":{}}'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        for retained in [Set<String>(), Set(["turn/completed"])] {
            let transport = FoundationAccountQuotaProcessTransport(launchLeasePool: AccountQuotaProcessLaunchLeasePool(), retainedNotificationMethods: retained)
            let session = try transport.start(codexPath: script.path, dataSource: nil)
            defer { _ = try? session.shutdown() }
            guard case .line(let line) = try session.nextStdoutEvent(timeout: 2),
                  let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return XCTFail("Expected a real pipe message") }
            if retained.isEmpty { XCTAssertEqual(message["id"] as? Int, 1) }
            else { XCTAssertEqual(message["method"] as? String, "turn/completed") }
        }
    }
    func testOptInLiveParallelRun() throws {
        guard ProcessInfo.processInfo.environment["TOKENBAR_MODELTRACE_LIVE"] == "1",
              let home = ProcessInfo.processInfo.environment["TOKENBAR_MODELTRACE_HOME"],
              let output = ProcessInfo.processInfo.environment["TOKENBAR_MODELTRACE_OUTPUT"] else { throw XCTSkip("Opt-in three real low-effort requests") }
        let source = CodexDataSource(codexHome: URL(fileURLWithPath: home), origin: .userSelected)
        let account = try ModelTraceController.scope(source: source)
        let started = Date()
        let result = try ModelTraceProbe().run(source: source, model: ModelTrace.defaultModel, cancel: ModelTraceCancellation(), validate: {
            guard try ModelTraceController.scope(source: source) == account else { throw ModelTrace.fail("账号已改变") }
        }, progress: { attempt, sample in print("ModelTrace live attempt=\(attempt) received=\(sample != nil)") })
        XCTAssertEqual(result.usedOutputs, 3)
        let metadata: [String: Any] = ["model": ModelTrace.defaultModel, "effort": ModelTrace.effort, "requests": 3, "parallel": true,
            "elapsedSeconds": Date().timeIntervalSince(started), "attribution": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
    func testSamePinnedBankAndAllCandidateScoresMatchUpstream() throws {
        let data = try Data(contentsOf: ModelTrace.resource("scoring-fixtures.json"))
        let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for item in cases {
            let outputs = item["outputs"] as! [[Int]]
            let samples = outputs.map { ModelTrace.Sample(expectedCount: $0.count, returnedCount: $0.count, outOfRangeCount: 0, numbers: $0) }
            let result = try ModelTrace.analyze(samples)
            let expected = item["results"] as! [[String: Any]]
            XCTAssertEqual(result.candidates.count, 17)
            XCTAssertEqual(result.bankSha256, "e514c76928ea38d23bc0f14d3935f23c97b1efb6d96b18a19bdc88ad2d830536")
            for row in expected {
                let actual = try XCTUnwrap(result.candidates.first { $0.model == row["model"] as? String })
                XCTAssertEqual(actual.probability, row["probability"] as! Double, accuracy: 1e-9)
                XCTAssertEqual(actual.profileSimilarity, row["profile_similarity"] as! Double, accuracy: 1e-9)
                XCTAssertEqual(actual.score, row["score"] as! Double, accuracy: 1e-9)
            }
        }
    }
    func testMalformedOutputsAndToolsNeverBecomeUsableSamples() throws {
        XCTAssertThrowsError(try ModelTrace.parse("[1,2,3]", expected: 307))
        XCTAssertThrowsError(try ModelTrace.parse("这是答案 " + String(repeating: "1,", count: 300), expected: 307))
        XCTAssertThrowsError(try ModelTrace.parse("[1.5,2]", expected: 307))
        var output = ModelTraceOutput()
        XCTAssertThrowsError(try output.accept(["method": "item/updated", "params": ["threadId": "a", "turnId": "b", "item": ["type": "commandExecution"]]], thread: "a", turn: "b", expected: 307))
    }
    func testDefaultAutoIsOffAndHistoryIsScopedAndIdempotent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ModelTraceHistoryStore(url: folder.appendingPathComponent("modeltrace.sqlite"))
        XCTAssertFalse(try store.autoSettings().enabled)
        XCTAssertEqual(try store.autoSettings().intervalHours, 24)
        var run = ModelTrace.Run(model: ModelTrace.defaultModel)
        try store.save(run, scope: "first")
        run.status = "cancelled"; try store.save(run, scope: "first")
        XCTAssertEqual(try store.history(scope: "first").map(\.status), ["cancelled"])
        XCTAssertTrue(try store.history(scope: "second").isEmpty)
    }
    func testParallelProbeKeepsEarlyCompletionsAndUsesExactlyThreeTurns() throws {
        let fake = FakeSession()
        let executable = try FakeCodexExecutable()
        let fakePath = executable.path
        let source = CodexDataSource(codexHome: URL(fileURLWithPath: NSTemporaryDirectory()), origin: .userSelected)
        let probe = ModelTraceProbe(
            transport: FakeTransport(session: fake),
            codexPathResolver: { fakePath }
        )
        let result = try probe.run(source: source, model: ModelTrace.defaultModel, cancel: ModelTraceCancellation(), validate: {}, progress: { _, _ in })
        XCTAssertEqual(fake.receivedCodexPath, fakePath)
        XCTAssertEqual(result.usedOutputs, 3)
        XCTAssertEqual(fake.turnCount, 3)
        XCTAssertTrue(fake.shutdownCalled)
        XCTAssertTrue(fake.frames.allSatisfy { $0["jsonrpc"] as? String == "2.0" })
        let turns = fake.frames.filter { $0["method"] as? String == "turn/start" }
        XCTAssertTrue(turns.allSatisfy { ($0["params"] as? [String: Any])?["effort"] as? String == "low" })
    }
    func testPreCancelledProbeStartsNoTurnsAndReapsTransport() throws {
        let fake = FakeSession(), cancel = ModelTraceCancellation(); cancel.cancel()
        let executable = try FakeCodexExecutable()
        let fakePath = executable.path
        let source = CodexDataSource(codexHome: URL(fileURLWithPath: NSTemporaryDirectory()), origin: .userSelected)
        let probe = ModelTraceProbe(
            transport: FakeTransport(session: fake),
            codexPathResolver: { fakePath }
        )
        XCTAssertThrowsError(try probe.run(source: source, model: ModelTrace.defaultModel, cancel: cancel, validate: {}, progress: { _, _ in }))
        XCTAssertEqual(fake.receivedCodexPath, fakePath)
        XCTAssertEqual(fake.turnCount, 0); XCTAssertTrue(fake.shutdownCalled)
        XCTAssertTrue(fake.terminationRequested)
    }
}

private final class FakeCodexExecutable {
    let directory: URL
    let path: String

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modeltrace-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex")
        do {
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.path = executable.path
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct FakeTransport: AccountQuotaProcessTransport {
    let session: FakeSession
    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession {
        session.receivedCodexPath = codexPath
        return session
    }
}
private final class FakeSession: AccountQuotaProcessSession, @unchecked Sendable {
    var frames: [[String: Any]] = []
    var queue: [Data] = []
    var receivedCodexPath: String?
    var turnCount = 0
    var shutdownCalled = false
    var terminationRequested = false
    private var threadCount = 0
    func writeStdin(_ data: Data) throws {
        let frame = try JSONSerialization.jsonObject(with: data) as! [String: Any]; frames.append(frame)
        guard let id = frame["id"] as? Int, let method = frame["method"] as? String else { return }
        let params = frame["params"] as? [String: Any] ?? [:]
        var result: [String: Any] = [:]
        if method == "thread/start" {
            threadCount += 1
            result = ["model": ModelTrace.defaultModel, "reasoningEffort": "low", "thread": ["id": "thread-\(threadCount)", "ephemeral": true, "path": NSNull()]]
        } else if method == "turn/start" {
            turnCount += 1
            let thread = params["threadId"] as! String, turn = "turn-\(turnCount)"
            let numbers = (0..<ModelTrace.counts[turnCount - 1]).map { $0 % 355 + 1 }
            let text = String(decoding: try JSONEncoder().encode(numbers), as: UTF8.self)
            // Completion arrives before the turn/start response, while later probes
            // have not been registered. These events must survive RPC setup.
            try enqueue(["method": "item/completed", "params": ["threadId": thread, "turnId": turn, "item": ["type": "agentMessage", "phase": "final_answer", "text": text]]])
            try enqueue(["method": "turn/completed", "params": ["threadId": thread, "turn": ["id": turn, "status": "completed"]]])
            result = ["turn": ["id": turn]]
        }
        try enqueue(["jsonrpc": "2.0", "id": id, "result": result])
    }
    private func enqueue(_ value: [String: Any]) throws { queue.append(try JSONSerialization.data(withJSONObject: value)) }
    func nextStdoutEvent(timeout: TimeInterval) throws -> AccountQuotaStdoutEvent { queue.isEmpty ? .idle : .line(queue.removeFirst()) }
    func stderrTailText() -> String? { nil }
    func requestTermination() { terminationRequested = true }
    func shutdown() throws -> AccountQuotaProcessExit { shutdownCalled = true; return AccountQuotaProcessExit(status: 0, reason: .exit) }
}

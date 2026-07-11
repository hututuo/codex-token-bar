import XCTest
@testable import CodexTokenBar

@MainActor
final class TaskCompletionMonitorTests: XCTestCase {
    func testSameIdentityPathRebindCancelsOldPollAndStartsOneNewPathPoll() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskPathRebind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldHome = parent.appendingPathComponent("old-home", isDirectory: true)
        let newHome = parent.appendingPathComponent("new-home", isDirectory: true)
        try FileManager.default.createDirectory(at: oldHome, withIntermediateDirectories: true)
        let sourceAtOldPath = CodexDataSource(codexHome: oldHome, origin: .userSelected)
        let loader = SuspendedTaskCompletionPollLoader()
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults(), pollLoader: loader)

        monitor.start(dataSource: sourceAtOldPath)
        await waitUntil("old-path task poll") {
            await loader.hasPendingRequest(at: oldHome)
        }
        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["trusted-thread"]))
        let identityGeneration = monitor.sourceIdentityGeneration
        let oldBindingGeneration = monitor.sourceBindingGeneration

        try FileManager.default.moveItem(at: oldHome, to: newHome)
        let sourceAtNewPath = CodexDataSource(codexHome: newHome, origin: .userSelected)
        XCTAssertEqual(sourceAtNewPath.stableIdentityKey, sourceAtOldPath.stableIdentityKey)
        monitor.start(dataSource: sourceAtNewPath)

        XCTAssertEqual(monitor.sourceIdentityGeneration, identityGeneration)
        XCTAssertEqual(monitor.sourceBindingGeneration, oldBindingGeneration + 1)
        XCTAssertEqual(monitor.unreadThreadCount, 1)
        await waitUntil("new-path task poll") {
            await loader.hasPendingRequest(at: newHome)
        }

        await loader.completeRequest(
            at: oldHome,
            output: TaskCompletionPollOutput(
                result: nil,
                unreadThreadRead: .available(["old-path-thread"])
            )
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(monitor.unreadThreadCount, 1)

        await loader.completeRequest(
            at: newHome,
            output: TaskCompletionPollOutput(
                result: nil,
                unreadThreadRead: .available(["trusted-thread", "new-path-thread"])
            )
        )
        await waitUntil("new-path task completion") {
            monitor.unreadThreadCount == 2
        }

        let requestCount = await loader.requestCount()
        monitor.start(dataSource: sourceAtNewPath)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(monitor.sourceBindingGeneration, oldBindingGeneration + 1)
        let samePathRequestCount = await loader.requestCount()
        XCTAssertEqual(samePathRequestCount, requestCount)
    }

    func testNativeUnreadMarkAllReadClearsCurrentThreadsAndKeepsNewThreadActive() {
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())

        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["thread-a"]))
        XCTAssertEqual(monitor.unreadThreadCount, 1)

        monitor.markAllRead()
        XCTAssertEqual(monitor.unreadThreadCount, 0)

        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["thread-a", "thread-b"]))
        XCTAssertEqual(monitor.unreadThreadCount, 1)
    }

    func testFallbackCompletionMarkAllReadClearsOldEventAndKeepsNewEventActive() {
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())
        let first = TaskCompletionEvent(
            id: "event-1",
            threadID: "thread-a",
            title: "First",
            body: "Done"
        )
        let second = TaskCompletionEvent(
            id: "event-2",
            threadID: "thread-b",
            title: "Second",
            body: "Done"
        )

        monitor.applyForTesting(
            result: scanResult(events: [first]),
            unreadThreadRead: .unavailable
        )
        XCTAssertEqual(monitor.unreadThreadCount, 1)

        monitor.markAllRead()
        XCTAssertEqual(monitor.unreadThreadCount, 0)

        monitor.applyForTesting(
            result: scanResult(events: [first, second]),
            unreadThreadRead: .unavailable
        )
        XCTAssertEqual(monitor.unreadThreadCount, 1)
    }

    func testOfficialAuthorityLossExposesFallbackCompletions() {
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())
        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["official-thread"]))
        XCTAssertEqual(monitor.unreadThreadCount, 1)
        XCTAssertEqual(monitor.statusText, "有未读会话")

        let fallbackEvents = [
            TaskCompletionEvent(id: "fallback-1", threadID: "fallback-thread-1", title: "Fallback 1", body: "Done"),
            TaskCompletionEvent(id: "fallback-2", threadID: "fallback-thread-2", title: "Fallback 2", body: "Done")
        ]
        monitor.applyForTesting(
            result: scanResult(events: fallbackEvents),
            unreadThreadRead: .unavailable
        )

        XCTAssertEqual(monitor.unreadThreadCount, 2)
        XCTAssertEqual(monitor.statusText, "有任务完成")
        XCTAssertEqual(monitor.detailText, "Fallback 2")
    }

    func testOfficialAuthorityRecoveryReplacesFallbackCountWithoutRecountingIt() {
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())
        let fallback = TaskCompletionEvent(
            id: "fallback-event",
            threadID: "fallback-thread",
            title: "Fallback",
            body: "Done"
        )
        monitor.applyForTesting(
            result: scanResult(events: [fallback]),
            unreadThreadRead: .unavailable
        )
        XCTAssertEqual(monitor.unreadThreadCount, 1)
        XCTAssertEqual(monitor.statusText, "有任务完成")

        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["official-thread"]))

        XCTAssertEqual(monitor.unreadThreadCount, 1)
        XCTAssertEqual(monitor.statusText, "有未读会话")
        XCTAssertEqual(monitor.detailText, "Codex 有 1 个未读会话")

        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["official-thread"]))
        XCTAssertEqual(monitor.unreadThreadCount, 1)
        XCTAssertEqual(monitor.statusText, "有未读会话")
    }

    func testSharedUnreadCorrectnessSequence() throws {
        let sequence = try unreadCorrectnessSequence()
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())

        for step in sequence.steps {
            let events = step.appendCompletions.map {
                TaskCompletionEvent(
                    id: $0.eventID,
                    threadID: $0.threadID,
                    title: $0.title,
                    body: "Done"
                )
            }
            monitor.applyForTesting(
                result: scanResult(events: events),
                unreadThreadRead: .available(Set(step.nativeThreadIDs))
            )
            if step.action == "markAllRead" {
                monitor.markAllRead()
            }

            XCTAssertEqual(monitor.unreadThreadCount, step.expectedCount, step.name)
            if let expectedLatestTitle = step.expectedLatestTitle {
                XCTAssertEqual(monitor.lastCompletedTitle, expectedLatestTitle, step.name)
            }
        }
    }

    func testLiveLoaderScansCompletionsWhileOfficialUnreadIsAvailable() async throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskCompletionLiveMerge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let threadID = "019eaaaa-0000-0000-0000-0000000000bb"
        let unreadState: [String: Any] = [
            "electron-persisted-atom-state": [
                "unread-thread-ids-by-host-v1": ["local": [threadID]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: unreadState).write(
            to: codexHome.appendingPathComponent(".codex-global-state.json")
        )
        let session = sessions.appendingPathComponent("live.jsonl")
        let lines = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\",\"cwd\":\"/tmp\",\"thread_source\":\"user\",\"source\":\"desktop\"}}",
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-06-24T13:00:00.000Z\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-live\",\"completed_at\":1782306000}}"
        ]
        try lines.joined(separator: "\n").appending("\n").write(
            to: session,
            atomically: true,
            encoding: .utf8
        )
        let source = CodexDataSource(codexHome: codexHome, origin: .userSelected)

        let output = await LiveTaskCompletionPollLoader().load(
            request: TaskCompletionPollRequest(
                dataSource: source,
                previousStates: [:],
                seedMode: false,
                seedCutoff: Date(timeIntervalSince1970: 0)
            )
        )

        guard case let .available(threadIDs) = output.unreadThreadRead else {
            return XCTFail("Expected official unread state")
        }
        XCTAssertEqual(threadIDs, [threadID])
        XCTAssertEqual(output.result?.events.count, 1)
        XCTAssertEqual(output.result?.events.first?.threadID, threadID)
    }

    private func scanResult(events: [TaskCompletionEvent]) -> TaskCompletionScanResult {
        TaskCompletionScanResult(states: [:], events: events, fileCount: 1)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TaskCompletionMonitorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func unreadCorrectnessSequence() throws -> UnreadCorrectnessSequence {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repositoryRoot
            .appendingPathComponent("TestFixtures", isDirectory: true)
            .appendingPathComponent("unread-correctness-sequence.json")
        return try JSONDecoder().decode(UnreadCorrectnessSequence.self, from: Data(contentsOf: fixture))
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

private struct UnreadCorrectnessSequence: Decodable {
    let steps: [UnreadCorrectnessStep]
}

private struct UnreadCorrectnessStep: Decodable {
    let name: String
    let nativeThreadIDs: [String]
    let appendCompletions: [UnreadCorrectnessCompletion]
    let action: String
    let expectedCount: Int
    let expectedLatestTitle: String?
}

private struct UnreadCorrectnessCompletion: Decodable {
    let eventID: String
    let threadID: String
    let turnID: String
    let title: String
}

private actor SuspendedTaskCompletionPollLoader: TaskCompletionPollLoading {
    private var continuations: [String: CheckedContinuation<TaskCompletionPollOutput, Never>] = [:]
    private var count = 0

    func load(request: TaskCompletionPollRequest) async -> TaskCompletionPollOutput {
        count += 1
        return await withCheckedContinuation { continuation in
            continuations[request.dataSource.codexHome.path] = continuation
        }
    }

    func hasPendingRequest(at codexHome: URL) -> Bool {
        continuations[codexHome.path] != nil
    }

    func completeRequest(at codexHome: URL, output: TaskCompletionPollOutput) {
        continuations.removeValue(forKey: codexHome.path)?.resume(returning: output)
    }

    func requestCount() -> Int {
        count
    }
}

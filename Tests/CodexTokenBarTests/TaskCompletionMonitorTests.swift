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

    private func scanResult(events: [TaskCompletionEvent]) -> TaskCompletionScanResult {
        TaskCompletionScanResult(states: [:], events: events, fileCount: 1)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TaskCompletionMonitorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
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

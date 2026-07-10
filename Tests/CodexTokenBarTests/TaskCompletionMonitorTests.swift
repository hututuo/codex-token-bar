import XCTest
@testable import CodexTokenBar

@MainActor
final class TaskCompletionMonitorTests: XCTestCase {
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

    private func scanResult(events: [TaskCompletionEvent]) -> TaskCompletionScanResult {
        TaskCompletionScanResult(states: [:], events: events, fileCount: 1)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TaskCompletionMonitorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

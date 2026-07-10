import XCTest
@testable import CodexTokenBar

final class TaskCompletionReadBaselineTests: XCTestCase {
    func testMarkAllReadClearsCurrentNativeUnreadAndFallbackCompletions() {
        var baseline = TaskCompletionReadBaseline()

        let nativeUnread: Set<String> = ["thread-a", "thread-b"]
        let fallbackEvents = [
            "event-1": "thread-a",
            "event-2": "thread-c"
        ]

        baseline.markAllRead(
            unreadThreadIDs: nativeUnread,
            completedEventIDs: Set(fallbackEvents.keys)
        )

        XCTAssertEqual(baseline.activeUnreadThreadIDs(from: nativeUnread), Set<String>())
        XCTAssertEqual(baseline.activeCompletedTaskThreadIDs(from: fallbackEvents), [String: String]())
    }

    func testNewNativeUnreadAndFallbackCompletionStillAppearAfterMarkAllRead() {
        var baseline = TaskCompletionReadBaseline()

        baseline.markAllRead(
            unreadThreadIDs: ["thread-a"],
            completedEventIDs: ["event-1"]
        )

        XCTAssertEqual(
            baseline.activeUnreadThreadIDs(from: ["thread-a", "thread-b"]),
            ["thread-b"]
        )
        XCTAssertEqual(
            baseline.activeCompletedTaskThreadIDs(from: [
                "event-1": "thread-a",
                "event-2": "thread-a"
            ]),
            ["event-2": "thread-a"]
        )
    }

    func testBaselinePersistsByCodexHomePath() {
        let suiteName = "TaskCompletionReadBaselineTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        var baseline = TaskCompletionReadBaseline()
        baseline.markAllRead(unreadThreadIDs: ["thread-a"], completedEventIDs: ["event-1"])

        TaskCompletionReadBaselineStore.save(
            baseline,
            codexHomePath: "/tmp/codex-a",
            defaults: defaults
        )

        var loaded = TaskCompletionReadBaselineStore.load(
            codexHomePath: "/tmp/codex-a",
            defaults: defaults
        )
        XCTAssertEqual(loaded.activeUnreadThreadIDs(from: ["thread-a"]), Set<String>())
        XCTAssertEqual(
            loaded.activeCompletedTaskThreadIDs(from: ["event-1": "thread-a"]),
            [String: String]()
        )

        var otherHome = TaskCompletionReadBaselineStore.load(
            codexHomePath: "/tmp/codex-b",
            defaults: defaults
        )
        XCTAssertEqual(otherHome.activeUnreadThreadIDs(from: ["thread-a"]), ["thread-a"])
    }
}

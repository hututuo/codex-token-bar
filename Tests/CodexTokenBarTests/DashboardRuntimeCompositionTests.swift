import XCTest
@testable import CodexTokenBar

final class DashboardRuntimeCompositionTests: XCTestCase {
    func testDashboardSceneInjectsAppScopedRuntimeInsteadOfCreatingOwners() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexTokenBarApp.swift"),
            encoding: .utf8
        )
        let dashboardSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("@StateObject private var dashboardRuntime: DashboardRuntime"))
        XCTAssertTrue(appSource.contains("runtime: dashboardRuntime"))
        XCTAssertTrue(dashboardSource.contains("let composition = runtime.composition"))
        XCTAssertFalse(dashboardSource.contains("@StateObject private var store"))
        XCTAssertFalse(dashboardSource.contains("TaskCompletionMonitor()"))
        XCTAssertFalse(dashboardSource.contains("LiveRateMonitor()"))
    }

    @MainActor
    func testTwoDashboardCompositionsShareEveryLongLivedOwner() {
        let runtime = DashboardRuntime()

        let first = runtime.composition
        let second = runtime.composition

        XCTAssertEqual(ObjectIdentifier(first.usageStore), ObjectIdentifier(second.usageStore))
        XCTAssertEqual(ObjectIdentifier(first.quotaStore), ObjectIdentifier(second.quotaStore))
        XCTAssertEqual(ObjectIdentifier(first.quotaHistoryStore), ObjectIdentifier(second.quotaHistoryStore))
        XCTAssertEqual(ObjectIdentifier(first.radarStore), ObjectIdentifier(second.radarStore))
        XCTAssertEqual(ObjectIdentifier(first.providerSyncStore), ObjectIdentifier(second.providerSyncStore))
        XCTAssertEqual(ObjectIdentifier(first.taskCompletionMonitor), ObjectIdentifier(second.taskCompletionMonitor))
        XCTAssertEqual(ObjectIdentifier(first.liveMonitor), ObjectIdentifier(second.liveMonitor))
        XCTAssertEqual(
            ObjectIdentifier(first.sourceTransitionCoordinator),
            ObjectIdentifier(second.sourceTransitionCoordinator)
        )
    }

    @MainActor
    func testRuntimeStartsOnceAndOneConsumerCannotStopAnother() {
        var starts = 0
        let runtime = DashboardRuntime(startupAction: { starts += 1 })
        let first = UUID()
        let second = UUID()

        runtime.acquireConsumer(first)
        runtime.acquireConsumer(first)
        runtime.acquireConsumer(second)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(runtime.activeConsumerCount, 2)

        runtime.releaseConsumer(first)
        XCTAssertEqual(runtime.activeConsumerCount, 1)
        XCTAssertTrue(runtime.isStarted)
        XCTAssertEqual(starts, 1)

        runtime.releaseConsumer(second)
        runtime.acquireConsumer(UUID())
        XCTAssertTrue(runtime.isStarted)
        XCTAssertEqual(starts, 1)
    }
}

import XCTest
@testable import CodexTokenBar

final class DashboardRuntimeCompositionTests: XCTestCase {
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

    @MainActor
    func testSideEffectsRunOnceAcrossConsumersAndStopAfterLastRelease() {
        var starts = 0
        var stops = 0
        var wakes = 0
        var binds = 0
        var cadences = 0
        let coordinator = DashboardRuntimeSideEffectCoordinator<Int>(
            onStart: { starts += 1 },
            onStop: { stops += 1 },
            onWake: { wakes += 1 },
            onSurfaceEvent: { binds += 1 },
            onCadenceEvent: { cadences += 1 },
            onConfiguration: { _ in binds += 1 }
        )
        let first = UUID()
        let second = UUID()

        coordinator.acquire(first)
        coordinator.acquire(second)
        XCTAssertEqual(starts, 1)
        coordinator.reportConfiguration(7, for: first)
        coordinator.reportConfiguration(7, for: first)
        XCTAssertEqual(binds, 1)

        coordinator.handleWake()
        coordinator.handleSurfaceEvent()
        coordinator.handleCadenceEvent()
        XCTAssertEqual(wakes, 1)
        XCTAssertEqual(binds, 2)
        XCTAssertEqual(cadences, 1)

        coordinator.release(first)
        coordinator.handleWake()
        XCTAssertEqual(wakes, 2)
        XCTAssertEqual(stops, 0)

        coordinator.release(second)
        coordinator.handleWake()
        coordinator.handleSurfaceEvent()
        XCTAssertEqual(wakes, 2)
        XCTAssertEqual(binds, 2)
        XCTAssertEqual(stops, 1)
    }

    @MainActor
    func testCompactAppOwnerKeepsSingleSideEffectSubscriptionWithoutWindows() {
        var starts = 0
        var stops = 0
        var wakes = 0
        let coordinator = DashboardRuntimeSideEffectCoordinator<Bool>(
            onStart: { starts += 1 },
            onStop: { stops += 1 },
            onWake: { wakes += 1 },
            onSurfaceEvent: {},
            onCadenceEvent: {},
            onConfiguration: { _ in },
            keepsAppOwnerActive: { $0 }
        )
        let consumer = UUID()

        coordinator.acquire(consumer)
        coordinator.reportConfiguration(true, for: consumer)
        coordinator.release(consumer)
        coordinator.handleWake()

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(wakes, 1)
    }
}

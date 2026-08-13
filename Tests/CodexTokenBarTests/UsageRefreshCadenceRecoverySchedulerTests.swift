import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class UsageRefreshCadenceRecoverySchedulerTests: XCTestCase {
    func testScheduledRecoveryRunsAfterInjectedSleep() async {
        let sleeper = ControlledRecoverySleep()
        var task: Task<Void, Never>?
        var recoveryCount = 0

        UsageRefreshCadenceRecoveryScheduler.schedule(
            replacing: &task,
            after: 1.25,
            sleep: sleeper.sleep
        ) {
            recoveryCount += 1
        }

        await sleeper.waitForRequestCount(1)
        let requestedNanoseconds = await sleeper.requestedNanoseconds()
        XCTAssertEqual(requestedNanoseconds, [1_250_000_000])
        XCTAssertEqual(recoveryCount, 0)

        await sleeper.completeAll()
        await waitUntil("scheduled recovery action") {
            recoveryCount == 1
        }

        XCTAssertEqual(recoveryCount, 1)
        UsageRefreshCadenceRecoveryScheduler.cancel(&task)
    }

    func testSchedulingNilDelayCancelsPendingRecovery() async {
        let sleeper = ControlledRecoverySleep()
        var task: Task<Void, Never>?
        var recoveryCount = 0

        UsageRefreshCadenceRecoveryScheduler.schedule(
            replacing: &task,
            after: 2,
            sleep: sleeper.sleep
        ) {
            recoveryCount += 1
        }
        await sleeper.waitForRequestCount(1)

        UsageRefreshCadenceRecoveryScheduler.schedule(
            replacing: &task,
            after: nil,
            sleep: sleeper.sleep
        ) {
            recoveryCount += 1
        }

        await sleeper.completeAll()
        await Task.yield()

        XCTAssertNil(task)
        XCTAssertEqual(recoveryCount, 0)
    }

    func testSchedulingNewRecoveryCancelsPreviousTask() async {
        let sleeper = ControlledRecoverySleep()
        var task: Task<Void, Never>?
        var fired: [String] = []

        UsageRefreshCadenceRecoveryScheduler.schedule(
            replacing: &task,
            after: 3,
            sleep: sleeper.sleep
        ) {
            fired.append("first")
        }
        await sleeper.waitForRequestCount(1)

        UsageRefreshCadenceRecoveryScheduler.schedule(
            replacing: &task,
            after: 4,
            sleep: sleeper.sleep
        ) {
            fired.append("second")
        }
        await sleeper.waitForRequestCount(2)

        await sleeper.completeAll()
        await waitUntil("replacement recovery action") {
            fired == ["second"]
        }

        XCTAssertEqual(fired, ["second"])
        UsageRefreshCadenceRecoveryScheduler.cancel(&task)
    }

    func testThrowingSleepDoesNotRunRecoveryAction() async {
        var task: Task<Void, Never>?
        var recoveryCount = 0

        UsageRefreshCadenceRecoveryScheduler.schedule(
            replacing: &task,
            after: 1,
            sleep: { _ in throw CancellationError() }
        ) {
            recoveryCount += 1
        }

        await Task.yield()
        await Task.yield()
        XCTAssertEqual(recoveryCount, 0)
        UsageRefreshCadenceRecoveryScheduler.cancel(&task)
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 1,
        predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

private actor ControlledRecoverySleep {
    private var requests: [UInt64] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func requestedNanoseconds() -> [UInt64] {
        requests
    }

    func sleep(nanoseconds: UInt64) async throws {
        requests.append(nanoseconds)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForRequestCount(_ count: Int) async {
        while requests.count < count {
            await Task.yield()
        }
    }

    func completeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

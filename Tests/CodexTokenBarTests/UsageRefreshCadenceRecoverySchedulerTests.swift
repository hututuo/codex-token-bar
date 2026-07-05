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
        await Task.yield()

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
        await Task.yield()

        XCTAssertEqual(fired, ["second"])
        UsageRefreshCadenceRecoveryScheduler.cancel(&task)
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

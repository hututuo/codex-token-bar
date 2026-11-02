import XCTest
@testable import CodexTokenBar

@MainActor
final class ApplicationRecoveryOperationGateTests: XCTestCase {
    private actor Attempts {
        enum Interrupted: Error { case fixture }
        private(set) var count = 0
        func run() throws { count += 1; throw Interrupted.fixture }
    }

    func testManualRequestBlocksRetryBeforeSessionObservation() {
        let gate = ApplicationRecoveryOperationGate()
        XCTAssertTrue(gate.beginUpdateRequest())
        XCTAssertFalse(gate.beginMigration())
        XCTAssertFalse(gate.beginUpdateRequest())
        gate.observeUpdateSession(true)
        XCTAssertFalse(gate.beginMigration())
        gate.observeUpdateSession(false)
        gate.updateCycleFinished(failed: false)
        XCTAssertTrue(gate.beginMigration())
        XCTAssertFalse(gate.beginUpdateRequest())
        gate.finishMigration()
        XCTAssertTrue(gate.beginUpdateRequest())
    }

    func testAutomaticSessionBlocksRetryAndCancellationRestoresIt() {
        let gate = ApplicationRecoveryOperationGate()
        gate.observeUpdateSession(true)
        XCTAssertFalse(gate.canBeginMigration)
        gate.observeUpdateSession(false)
        gate.updateCycleFinished(failed: true)
        XCTAssertTrue(gate.canBeginMigration)
        XCTAssertTrue(gate.canRequestUpdate)
    }

    func testInstallerOwnershipOutlivesSuccessfulSessionCompletion() {
        let gate = ApplicationRecoveryOperationGate()
        XCTAssertTrue(gate.beginUpdateRequest())
        gate.observeUpdateSession(true)
        gate.installationWillBegin()
        gate.observeUpdateSession(false)
        gate.updateCycleFinished(failed: false)
        XCTAssertFalse(gate.canBeginMigration)
        XCTAssertFalse(gate.canRequestUpdate)
        gate.finishMigration()
        XCTAssertFalse(gate.canBeginMigration, "An unrelated completion cannot release installer ownership")
        gate.updateCycleFinished(failed: true)
        XCTAssertTrue(gate.canBeginMigration, "A failed/cancelled installer permits recovery again")
    }

    func testRefusedCheckDoesNotLeaveAnUnfinishablePendingRequest() {
        let gate = ApplicationRecoveryOperationGate()
        XCTAssertTrue(gate.beginUpdateRequest())
        gate.updateRequestDidNotStart()
        XCTAssertTrue(gate.canBeginMigration)
    }

    func testInitialBusyUpdateResumesRequestedPreparationAfterCancellation() async {
        let gate = ApplicationRecoveryOperationGate()
        gate.observeUpdateSession(true)
        let attempts = Attempts()
        let startup = ApplicationStartupCoordinator(prepare: { _ in try await attempts.run() },
            activate: { XCTFail("Failed preparation activated business owners"); return nil },
            productionLifecycle: false, operationGate: gate)
        startup.start()
        XCTAssertEqual(startup.phase, .waiting)
        XCTAssertTrue(startup.waitingForSoftwareUpdate)
        let waitingCount = await attempts.count
        XCTAssertEqual(waitingCount, 0)
        gate.observeUpdateSession(false)
        gate.updateCycleFinished(failed: true)
        for _ in 0..<200 {
            if case .failed = startup.phase { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard case .failed = startup.phase else { return XCTFail("Initial preparation never resumed") }
        XCTAssertFalse(startup.waitingForSoftwareUpdate)
        let finalCount = await attempts.count
        XCTAssertEqual(finalCount, 1)
    }

    func testObservingAnUpdateDoesNotStartAnUnrequestedCoordinator() async {
        let gate = ApplicationRecoveryOperationGate()
        let attempts = Attempts()
        let startup = ApplicationStartupCoordinator(prepare: { _ in try await attempts.run() },
            activate: { nil }, productionLifecycle: false, operationGate: gate)
        gate.observeUpdateSession(true)
        gate.observeUpdateSession(false)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(startup.phase, .waiting)
        let count = await attempts.count
        XCTAssertEqual(count, 0)
    }

    func testRetryCannotEscapeUpdateOwnershipThroughCoordinator() async {
        let gate = ApplicationRecoveryOperationGate()
        let attempts = Attempts()
        let startup = ApplicationStartupCoordinator(prepare: { _ in try await attempts.run() },
            activate: { XCTFail("Failed preparation activated business owners"); return nil },
            productionLifecycle: false, operationGate: gate)
        startup.start()
        for _ in 0..<200 {
            if case .failed = startup.phase { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard case .failed = startup.phase else { return XCTFail("Fixture preparation did not fail") }
        XCTAssertFalse(gate.migrationInProgress)
        XCTAssertTrue(gate.beginUpdateRequest())
        startup.retry()
        guard case .failed = startup.phase else { return XCTFail("Blocked retry did not retain the failed screen") }
        let blockedCount = await attempts.count
        XCTAssertEqual(blockedCount, 1, "A pending update must not start a second database operation")
        XCTAssertFalse(gate.migrationInProgress)
        gate.observeUpdateSession(true)
        startup.retry()
        guard case .failed = startup.phase else { return XCTFail("Active update session admitted migration") }
        gate.observeUpdateSession(false)
        gate.updateCycleFinished(failed: true)
        startup.retry()
        XCTAssertEqual(startup.phase, .preparing)
        XCTAssertTrue(gate.migrationInProgress)
        for _ in 0..<200 {
            if case .failed = startup.phase { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(gate.migrationInProgress)
        let resumedCount = await attempts.count
        XCTAssertEqual(resumedCount, 2)
    }
}

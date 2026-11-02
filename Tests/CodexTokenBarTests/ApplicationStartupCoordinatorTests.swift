import XCTest
@testable import CodexTokenBar

@MainActor
final class ApplicationStartupCoordinatorTests: XCTestCase {
    private actor Preparation {
        var started = false
        var continuation: CheckedContinuation<Void, Error>?
        func wait() async throws {
            started = true
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish() { continuation?.resume(); continuation = nil }
    }
    private actor Attempts {
        enum Failure: Error { case interrupted }
        var count = 0
        func run() throws { count += 1; if count == 1 { throw Failure.interrupted } }
    }
    private actor TransientAttempts {
        var count = 0
        let alwaysFails: Bool
        init(alwaysFails: Bool = false) { self.alwaysFails = alwaysFails }
        func run() throws {
            count += 1
            if alwaysFails || count == 1 {
                throw SQLiteDatabaseError(operation: "fixture", code: 5, message: "busy", path: "fixture")
            }
        }
    }
    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Startup state did not progress")
    }
    func testShowsPreparingStateWithoutActivatingOwnersUntilGateFinishes() async {
        let latch = Preparation()
        var activations = 0
        let startup = ApplicationStartupCoordinator(prepare: { progress in
            progress(.init(stage: .importing, completed: 1, total: 2))
            try await latch.wait()
        }, activate: { activations += 1; return nil }, productionLifecycle: false)
        XCTAssertEqual(startup.phase, .waiting)
        XCTAssertEqual(activations, 0)
        startup.start(); startup.start()
        XCTAssertEqual(startup.phase, .preparing)
        XCTAssertEqual(activations, 0)
        for _ in 0..<200 {
            if await latch.started { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let started = await latch.started
        XCTAssertTrue(started)
        await waitFor { startup.progress.stage == .importing }
        XCTAssertEqual(startup.progress.completed, 1)
        XCTAssertEqual(activations, 0)
        await latch.finish()
        await waitFor { startup.phase == .ready }
        startup.start()
        XCTAssertEqual(activations, 1)
    }
    func testFailedPreparationNeverStartsOwnersAndCanRetry() async {
        let attempts = Attempts()
        var activations = 0
        let startup = ApplicationStartupCoordinator(prepare: { _ in try await attempts.run() },
            activate: { activations += 1; return nil }, productionLifecycle: false)
        startup.start()
        await waitFor { if case .failed = startup.phase { return true }; return false }
        XCTAssertEqual(activations, 0)
        startup.retry()
        await waitFor { startup.phase == .ready }
        XCTAssertEqual(activations, 1)
    }

    func testTransientRecoveryRetriesThroughTheSameGateAndActivatesOnlyOnce() async {
        let attempts = TransientAttempts()
        var activations = 0
        let startup = ApplicationStartupCoordinator(prepare: { _ in try await attempts.run() },
            activate: { activations += 1; return nil }, productionLifecycle: false,
            retryDelay: { $0 == 0 ? 0.01 : nil })
        startup.start(); startup.start()
        await waitFor { startup.phase == .ready }
        let count = await attempts.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(activations, 1)
    }

    func testAutomaticRetriesAreBoundedAndNeverRetryUnknownContracts() async {
        XCTAssertEqual((0..<6).compactMap(LocalRecoveryRetryPolicy.delay), [5, 15, 30, 60, 180, 300])
        XCTAssertNil(LocalRecoveryRetryPolicy.delay(6))
        XCTAssertFalse(LocalRecoveryRetryPolicy.canRetry(PublishedBusinessAdmission.Deferred(message: "unknown contract")))
        XCTAssertFalse(LocalRecoveryRetryPolicy.canRetry(BusinessStoreError.proofMismatch))
        let attempts = TransientAttempts(alwaysFails: true)
        let startup = ApplicationStartupCoordinator(prepare: { _ in try await attempts.run() },
            activate: { XCTFail("Failed recovery cannot activate a writer"); return nil }, productionLifecycle: false,
            retryDelay: { $0 < 2 ? 0.01 : nil })
        startup.start()
        for _ in 0..<200 {
            if await attempts.count == 3 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(30))
        let count = await attempts.count
        XCTAssertEqual(count, 3)
        if case .failed = startup.phase {} else { XCTFail("Failure must remain visible after retry budget") }
    }

    func testPublishedRecoveryRetryKeepsOneRuntimeAndShowsRecoveryNotice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("published-startup-\(UUID().uuidString)")
        defer { BusinessSQLiteRoutes.deactivate(); try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let c = BusinessDatabaseMigration.Configuration(container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support, exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("legacy"))
        let quota = support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: quota, bypassBusinessRoutes: true).execute("CREATE TABLE facts(id INTEGER PRIMARY KEY); INSERT INTO facts VALUES(123)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let late = support.appendingPathComponent("body-speed-late.sqlite")
        try SQLiteDatabaseDriver(url: late, bypassBusinessRoutes: true).execute("CREATE TABLE facts(id INTEGER PRIMARY KEY); INSERT INTO facts VALUES(456)")
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 0))
        XCTAssertTrue(BusinessSQLiteRoutes.hasPublishedAdmission)
        let attempts = Attempts()
        var activations = 0
        let startup = ApplicationStartupCoordinator(prepare: { _ in
            do { try await attempts.run() }
            catch { throw PublishedBusinessAdmission.Deferred(message: "fixture pending import") }
        }, activate: { activations += 1; return nil }, productionLifecycle: false)
        startup.start()
        await waitFor { if case .readyWithPendingRecovery = startup.phase { return true }; return false }
        XCTAssertEqual(activations, 1)
        XCTAssertNotNil(startup.recoveryNotice)
        startup.retry(); startup.retry()
        XCTAssertNotNil(startup.recoveryNotice)
        await waitFor { startup.phase == .ready }
        XCTAssertNil(startup.recoveryNotice)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota, readOnly: true).readRows("SELECT id FROM facts") { $0.int(0) }, [123])
    }
}

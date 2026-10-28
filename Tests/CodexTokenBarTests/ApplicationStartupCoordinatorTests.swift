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
}

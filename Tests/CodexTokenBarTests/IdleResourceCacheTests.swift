import Foundation
import XCTest
@testable import CodexTokenBar

final class IdleResourceCacheTests: XCTestCase {
    private final class Resource: @unchecked Sendable {}
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var time: TimeInterval = 0
        var loads = 0
        func advance(_ delta: TimeInterval) { lock.lock(); time += delta; lock.unlock() }
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
        func make() -> Resource { lock.lock(); loads += 1; lock.unlock(); return Resource() }
    }

    func testUnusedCacheDoesNotLoadAndIdleExpiryReleasesItsOwnership() throws {
        let state = State()
        let cache = IdleResourceCache(idleSeconds: 60, automaticallyExpires: false,
                                      now: { state.now() }, make: { state.make() })
        XCTAssertEqual(state.loads, 0)
        var borrowed: Resource? = try cache.get()
        weak var released = borrowed
        XCTAssertTrue(borrowed === (try cache.get()))
        state.advance(59)
        cache.expireIfIdle()
        XCTAssertTrue(borrowed === (try cache.get()))
        state.advance(61)
        cache.expireIfIdle()
        XCTAssertNotNil(released, "An in-flight operation owns its resource through expiry")
        borrowed = nil
        XCTAssertNil(released, "An idle cache must release the last native allocation owner")
        _ = try cache.get()
        XCTAssertEqual(state.loads, 2)
    }

    func testConcurrentBorrowersConstructOnlyOneResource() {
        let state = State()
        let cache = IdleResourceCache(idleSeconds: 60, automaticallyExpires: false,
                                      make: { state.make() })
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do { _ = try cache.get() }
            catch { XCTFail("Concurrent load failed: \(error)") }
        }
        XCTAssertEqual(state.loads, 1)
    }

    func testLongLivedBorrowerPreventsDuplicateConstructionAfterExpiry() throws {
        let state = State()
        let cache = IdleResourceCache(idleSeconds: 60, automaticallyExpires: false,
                                      now: { state.now() }, make: { state.make() })
        let activeCounter = try cache.get()
        state.advance(61)
        cache.expireIfIdle()
        XCTAssertTrue(activeCounter === (try cache.get()),
                      "Optional live counting may still own the tokenizer after body counting idles")
        XCTAssertEqual(state.loads, 1)
    }

    func testFailedLoadCanRetry() throws {
        enum Failure: Error { case unavailable }
        let state = State()
        let cache = IdleResourceCache<Resource>(idleSeconds: 60, automaticallyExpires: false) {
            let resource = state.make()
            if state.loads == 1 { throw Failure.unavailable }
            return resource
        }
        XCTAssertThrowsError(try cache.get())
        XCTAssertNotNil(try cache.get())
        XCTAssertEqual(state.loads, 2)
    }

    func testTimerExpiresWithoutAnotherCaller() async throws {
        let cache = IdleResourceCache<Resource>(idleSeconds: 0.02) { Resource() }
        weak var resource: Resource?
        do { let borrowed = try cache.get(); resource = borrowed }
        for _ in 0..<40 {
            if resource == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(resource, "Expiry must also run while all consumers are idle")
    }
}

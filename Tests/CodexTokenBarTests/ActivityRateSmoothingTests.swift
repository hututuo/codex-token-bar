import XCTest
@testable import CodexTokenBar

final class ActivityRateSmoothingTests: XCTestCase {
    func testSameRiseFallResponseAndTimeBasedGain() {
        XCTAssertEqual(ActivityRateSmoothing.step(previous: 0, target: 100), 28, accuracy: 1e-10)
        let half = ActivityRateSmoothing.step(previous: 0, target: 100, seconds: 0.5)
        XCTAssertEqual(ActivityRateSmoothing.step(previous: half, target: 100, seconds: 0.5), 28, accuracy: 1e-10)
        let falling = ActivityRateSmoothing.step(previous: 100, target: 0, seconds: 0.5)
        XCTAssertEqual(ActivityRateSmoothing.step(previous: falling, target: 0, seconds: 0.5), 82, accuracy: 1e-10)
        XCTAssertEqual(ActivityRateSmoothing.tail(age: 3), 1)
        XCTAssertEqual(ActivityRateSmoothing.tail(age: 4), 0.5)
        XCTAssertEqual(ActivityRateSmoothing.tail(age: 5), 0)
    }
    func testSpikeDecaysButStopAndStaleGapClearImmediately() {
        var smoother = ActivityModelRateSmoother()
        XCTAssertEqual(smoother.update(["opus": 100], at: 100, active: true)["opus"]!, 28, accuracy: 1e-10)
        let falling = smoother.update([:], at: 101, active: true)["opus"]!
        XCTAssertGreaterThan(falling, 0); XCTAssertLessThan(falling, 28)
        XCTAssertTrue(smoother.update(["opus": 100], at: 102, active: false).isEmpty)
        XCTAssertEqual(smoother.update(["opus": 100], at: 103, active: true)["opus"]!, 28, accuracy: 1e-10)
        XCTAssertEqual(smoother.update(["opus": 100], at: 110, active: true)["opus"]!, 28, accuracy: 1e-10)
        XCTAssertTrue(smoother.update([:], at: 115, active: true).isEmpty)
    }
    func testDuplicatePollsDoNotAdvanceAndModelsRemainIndependent() {
        var smoother = ActivityModelRateSmoother()
        let first = smoother.update(["opus": 100, "sonnet": 50, "invalid": .nan], at: 100, active: true)
        XCTAssertEqual(smoother.update(["opus": 999], at: 100, active: true), first)
        XCTAssertEqual(smoother.update([:], at: 99, active: true), first)
        let second = smoother.update(["sonnet": 50], at: 102, active: true)
        XCTAssertLessThan(second["opus"]!, first["opus"]!)
        XCTAssertGreaterThan(second["sonnet"]!, first["sonnet"]!)
        XCTAssertNil(second["invalid"])
        XCTAssertNil(smoother.update(["sonnet": 50], at: 105, active: true)["opus"])
    }
}

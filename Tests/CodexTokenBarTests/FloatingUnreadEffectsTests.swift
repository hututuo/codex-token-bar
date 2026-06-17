import XCTest
@testable import CodexTokenBar

final class FloatingUnreadEffectsTests: XCTestCase {
    func testDefaultRippleSizeKeepsRetinaBackingScaleWithinBudget() throws {
        let frameCount = FloatingUnreadFrameBudget.frameCount(
            cycleDuration: 3.25,
            targetFramesPerSecond: 30
        )

        let scale = try XCTUnwrap(FloatingUnreadFrameBudget.cappedBackingScale(
            size: CGSize(width: 258, height: 88),
            preferredScale: 2,
            frameCount: frameCount
        ))

        XCTAssertEqual(scale, 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            FloatingUnreadFrameBudget.estimatedBytes(size: CGSize(width: 258, height: 88), backingScale: scale, frameCount: frameCount),
            FloatingUnreadFrameBudget.maxFrameSequenceBytes
        )
    }

    func testLargeRippleSizeDownsamplesInsteadOfExceedingFrameBudget() throws {
        let frameCount = FloatingUnreadFrameBudget.frameCount(
            cycleDuration: 3.25,
            targetFramesPerSecond: 30
        )
        let largeSize = CGSize(width: 516, height: 176)

        let scale = try XCTUnwrap(FloatingUnreadFrameBudget.cappedBackingScale(
            size: largeSize,
            preferredScale: 2,
            frameCount: frameCount
        ))

        XCTAssertLessThan(scale, 2)
        XCTAssertGreaterThanOrEqual(scale, 1)
        XCTAssertLessThanOrEqual(
            FloatingUnreadFrameBudget.estimatedBytes(size: largeSize, backingScale: scale, frameCount: frameCount),
            FloatingUnreadFrameBudget.maxFrameSequenceBytes
        )
    }

    func testOversizedUnreadEffectSkipsPrerenderingWhenOneXStillExceedsBudget() {
        let frameCount = FloatingUnreadFrameBudget.frameCount(
            cycleDuration: 3.25,
            targetFramesPerSecond: 30
        )

        let scale = FloatingUnreadFrameBudget.cappedBackingScale(
            size: CGSize(width: 800, height: 400),
            preferredScale: 2,
            frameCount: frameCount
        )

        XCTAssertNil(scale)
    }
}

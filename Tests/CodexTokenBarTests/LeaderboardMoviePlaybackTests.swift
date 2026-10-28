import XCTest
@testable import CodexTokenBar

final class LeaderboardMoviePlaybackTests: XCTestCase {
    func testVisibleMovieAutoplaysAndResumesAfterTemporaryHiding() {
        var state = LeaderboardMoviePlayback()
        XCTAssertFalse(state.shouldPlay(reducedMotion: false, lowPower: false))
        state.visible = true
        XCTAssertTrue(state.shouldPlay(reducedMotion: false, lowPower: false))
        state.visible = false
        XCTAssertFalse(state.shouldPlay(reducedMotion: false, lowPower: false))
        state.visible = true
        XCTAssertTrue(state.shouldPlay(reducedMotion: false, lowPower: false))
    }

    func testManualPauseSurvivesHidingAndPowerChanges() {
        var state = LeaderboardMoviePlayback(visible: true, intent: .pause)
        for visible in [false, true] {
            state.visible = visible
            for reduced in [false, true] {
                for lowPower in [false, true] {
                    XCTAssertFalse(state.shouldPlay(reducedMotion: reduced, lowPower: lowPower))
                }
            }
        }
    }

    func testAutomaticPlaybackHonorsMotionAndPowerButExplicitPlayIsAllowed() {
        var state = LeaderboardMoviePlayback(visible: true)
        XCTAssertFalse(state.shouldPlay(reducedMotion: true, lowPower: false))
        XCTAssertFalse(state.shouldPlay(reducedMotion: false, lowPower: true))
        state.intent = .play
        XCTAssertTrue(state.shouldPlay(reducedMotion: true, lowPower: true))
        state.visible = false
        XCTAssertFalse(state.shouldPlay(reducedMotion: true, lowPower: true))
    }
}

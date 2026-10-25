import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Subset peak tracker")
struct SubsetPeakTrackerTests {
    static let base: Int64 = 1_800_000_000_000
    static let today = base - 3_600_000
    static let tomorrow = today + 86_400_000

    struct Tick {
        var live: Double
        var measured: Double? = 0
        var day: Int64 = SubsetPeakTrackerTests.today
        var at: Int64
    }

    /// Feeds `ticks` and returns which of them fired `newPeak_A`.
    static func run(_ tracker: inout SubsetPeakTracker, _ ticks: [Tick]) -> [Bool] {
        ticks.map { tracker.update(liveOutput: $0.live, measuredPeakOutput: $0.measured, dayStartMs: $0.day, nowMs: $0.at) }
    }

    static func primed(measured: Double = 0, live: Double = 0, at now: Int64 = base) -> SubsetPeakTracker {
        var tracker = SubsetPeakTracker()
        _ = run(&tracker, [Tick(live: live, measured: measured, at: now)])
        return tracker
    }

    @Test func needsTheMinimumAndTheMargin() {
        var below = Self.primed()
        #expect(Self.run(&below, [Tick(live: 19.9, at: Self.base + 500)]) == [false])
        var atMinimum = Self.primed()
        #expect(Self.run(&atMinimum, [Tick(live: 20, at: Self.base + 500)]) == [true])

        var short = Self.primed(measured: 100)
        #expect(Self.run(&short, [Tick(live: 100.9, measured: 100, at: Self.base + 500)]) == [false])
        var enough = Self.primed(measured: 100)
        #expect(Self.run(&enough, [Tick(live: 101, measured: 100, at: Self.base + 500)]) == [true])

        var first = SubsetPeakTracker()
        #expect(Self.run(&first, [Tick(live: 500, at: Self.base)]) == [false], "the first tick has no previous peak")
    }

    @Test func coolsDownForSixtySeconds() {
        var tracker = Self.primed()
        #expect(Self.run(&tracker, [
            Tick(live: 100, at: Self.base + 500),
            Tick(live: 200, at: Self.base + 60_499),
        ]) == [true, false])
        #expect(tracker.peakTodayOutput == 200)
        #expect(Self.run(&tracker, [Tick(live: 300, at: Self.base + 60_500)]) == [true])
    }

    @Test func staysQuietAfterARestart() {
        var tracker = Self.primed(live: 300)
        #expect(tracker.peakTodayOutput == 300)
        tracker.restart(nowMs: Self.base + 1000)
        #expect(tracker.peakTodayOutput == 0, "the observed component is forgotten")
        #expect(Self.run(&tracker, [Tick(live: 10, measured: 50, at: Self.base + 1500)]) == [false])
        #expect(tracker.peakTodayOutput == 50, "rebuilt from the measured peak")
        #expect(Self.run(&tracker, [
            Tick(live: 500, measured: 50, at: Self.base + 2000),
            Tick(live: 1000, measured: 50, at: Self.base + 60_999),
            Tick(live: 1000.5, measured: 50, at: Self.base + 61_000),
            Tick(live: 1002, measured: 50, at: Self.base + 61_500),
        ]) == [false, false, false, true])
    }

    @Test func waitsForTheMeasuredPeak() {
        var tracker = Self.primed(measured: 10)
        #expect(Self.run(&tracker, [Tick(live: 500, measured: nil, at: Self.base + 500)]) == [false])
        #expect(tracker.peakTodayOutput == 500)
        #expect(Self.run(&tracker, [
            Tick(live: 600, measured: 10, at: Self.base + 1000),
            Tick(live: 700, measured: 10, at: Self.base + 1500),
        ]) == [false, true], "the tick after an unknown measured peak never fires")

        var unknown = SubsetPeakTracker()
        let ticks = (0..<4).map { Tick(live: Double($0) * 100, measured: nil, at: Self.base + Int64($0) * 500) }
        #expect(Self.run(&unknown, ticks) == [false, false, false, false])
    }

    @Test func resetsAtTheDayChange() {
        var tracker = Self.primed(live: 500, at: Self.tomorrow - 1000)
        #expect(Self.run(&tracker, [Tick(live: 100, day: Self.tomorrow, at: Self.tomorrow + 500)]) == [false])
        #expect(tracker.peakTodayOutput == 100)
        #expect(Self.run(&tracker, [Tick(live: 150, day: Self.tomorrow, at: Self.tomorrow + 1000)]) == [true])

        var cooling = Self.primed(at: Self.tomorrow - 3000)
        #expect(Self.run(&cooling, [
            Tick(live: 50, at: Self.tomorrow - 2000),
            Tick(live: 10, day: Self.tomorrow, at: Self.tomorrow + 500),
            Tick(live: 300, day: Self.tomorrow, at: Self.tomorrow + 1000),
        ]) == [true, false, false], "the cooldown runs across midnight")
    }

    @Test func peakCombinesMeasuredAndObserved() {
        var tracker = Self.primed(measured: 80, live: 50)
        #expect(tracker.peakTodayOutput == 80)
        _ = Self.run(&tracker, [Tick(live: 120, measured: 80, at: Self.base + 500)])
        #expect(tracker.peakTodayOutput == 120)
        _ = Self.run(&tracker, [Tick(live: 10, measured: 200, at: Self.base + 1000)])
        #expect(tracker.peakTodayOutput == 200)
        _ = Self.run(&tracker, [Tick(live: 10, measured: 90, at: Self.base + 1500)])
        #expect(tracker.peakTodayOutput == 120, "the measured part follows the engine, the observed part stays")
    }
}

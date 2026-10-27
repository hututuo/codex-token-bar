import Foundation

/// The report title tracker (METRICS 11.2, REPORTING 6.4): the speed title level 0–13 of DESIGN 1 from the live value
/// of the General metric and its redline — entered at a threshold, left below 90 % of it, a change held for 0.8 s,
/// idle after 3 s below 0.5 tok/s. The same rule as the app's title tracker, on seconds of any monotonic clock.
public struct ReportTitleTracker: Equatable, Sendable {
    public static let holdSeconds = 0.8
    public static let idleDelaySeconds = 3.0
    public static let exitRatio = 0.9
    public static let firstSpeed = 0.5
    /// Entry thresholds of levels 2–13 as fractions of the redline.
    public static let fractions: [Double] = [0.02, 0.03, 0.04, 0.06, 0.08, 0.12, 0.17, 0.24, 0.34, 0.5, 0.7, 1.0]
    public static let maxLevel = 13

    public private(set) var level = 0
    private var candidate = 0
    private var candidateSince = 0.0
    private var belowSince: Double?

    public init() {}

    public static func enterSpeed(level: Int, redline: Double) -> Double {
        switch level {
        case ...0: 0
        case 1: firstSpeed
        default: fractions[min(level, maxLevel) - 2] * redline
        }
    }

    /// Feeds the live value at `now` (seconds).
    public mutating func update(value: Double, redline: Double, now: Double) {
        let value = value.isFinite ? max(0, value) : 0
        let next = rawLevel(value: value, redline: redline, now: now)
        if next != candidate {
            candidate = next
            candidateSince = now
        }
        if candidate != level, now - candidateSince >= Self.holdSeconds { level = candidate }
    }

    private mutating func rawLevel(value: Double, redline: Double, now: Double) -> Int {
        if value < Self.firstSpeed {
            if belowSince == nil { belowSince = now }
        } else {
            belowSince = nil
        }
        if let belowSince, now - belowSince >= Self.idleDelaySeconds { return 0 }
        var step = candidate == 0 ? (value >= Self.firstSpeed ? 1 : 0) : candidate
        guard step != 0 else { return 0 }
        while step < Self.maxLevel, value >= Self.enterSpeed(level: step + 1, redline: redline) { step += 1 }
        while step > 1, value < Self.enterSpeed(level: step, redline: redline) * Self.exitRatio { step -= 1 }
        return step
    }

    /// `min(1, (v / R)^0.6)` of the unrounded live value (REPORTING 6.4).
    public static func heat(value: Double, redline: Double) -> Double {
        guard value > 0, redline > 0, value.isFinite else { return 0 }
        return min(1, pow(value / redline, 0.6))
    }
}

import Foundation

/// `peakToday_A` and `newPeak_A` of one floating orb that tracks a source subset (METRICS 6.8). The rule is the
/// engine's `newPeak` (METRICS 6.4) on live output, whatever the selected metric.
public struct SubsetPeakTracker: Equatable, Sendable {
    /// Silence after an orb is created or its set changes, so editing an orb never celebrates.
    public static let quietPeriodMs: Int64 = 60_000

    private var dayStartMs: Int64?
    private var measuredPeak = 0.0
    private var observedPeak = 0.0
    /// `peakTodayOutput` after the previous tick; nil when the measured part was not known then.
    private var previousPeak: Double?
    private var lastEmissionMs: Int64?
    private var quietUntilMs: Int64?

    public init() {}

    /// The larger of today's measured peak and the highest live output seen since the last restart or day start.
    public var peakTodayOutput: Double { max(measuredPeak, observedPeak) }

    /// After an orb is created or its set changes: forgets the observed component and stays silent for
    /// `quietPeriodMs` from `nowMs`.
    public mutating func restart(nowMs: Int64) {
        measuredPeak = 0
        observedPeak = 0
        previousPeak = nil
        quietUntilMs = nowMs + Self.quietPeriodMs
    }

    /// One engine tick for this orb; true when `newPeak_A` fires. The live value is compared with the previous
    /// tick's peak, then the peak takes it in. Nothing fires while `measuredPeakOutput` is unknown, on the first tick
    /// after it becomes known, or on the tick that starts a new day (which resets the day's peaks).
    public mutating func update(liveOutput: Double, measuredPeakOutput: Double?, dayStartMs: Int64, nowMs: Int64) -> Bool {
        if self.dayStartMs != dayStartMs {
            self.dayStartMs = dayStartMs
            measuredPeak = 0
            observedPeak = 0
            previousPeak = nil
        }
        var fires = false
        if measuredPeakOutput != nil,
           let previousPeak,
           liveOutput >= SpeedEngine.newPeakMinimum,
           liveOutput >= previousPeak + SpeedEngine.newPeakMargin,
           quietUntilMs.map({ nowMs >= $0 }) ?? true,
           lastEmissionMs.map({ nowMs - $0 >= SpeedEngine.newPeakCooldownMs }) ?? true {
            fires = true
            lastEmissionMs = nowMs
        }
        if let measuredPeakOutput { measuredPeak = measuredPeakOutput }
        observedPeak = max(observedPeak, liveOutput)
        previousPeak = measuredPeakOutput == nil ? nil : peakTodayOutput
        return fires
    }
}

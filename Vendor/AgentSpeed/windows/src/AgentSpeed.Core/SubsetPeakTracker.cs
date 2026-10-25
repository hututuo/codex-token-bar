using AgentSpeed.Core.Engine;

namespace AgentSpeed.Core;

/// <summary>
/// <c>peakToday_A</c> and <c>newPeak_A</c> of one floating orb that tracks a source subset (METRICS 6.8). The rule is
/// the engine's new peak (METRICS 6.4) on live output, whatever the selected metric. Not thread-safe.
/// </summary>
public sealed class SubsetPeakTracker
{
    /// <summary>Silence after an orb is created or its set changes, so editing an orb never celebrates.</summary>
    public const long QuietPeriodMs = 60_000;

    private long? _dayStartMs;
    private double _measuredPeak;
    private double _observedPeak;

    /// <summary><see cref="PeakTodayOutput"/> after the previous tick; null when the measured part was not known then.</summary>
    private double? _previousPeak;
    private long? _lastEmissionMs;
    private long? _quietUntilMs;

    /// <summary>The larger of today's measured peak and the highest live output seen since the last restart or day start.</summary>
    public double PeakTodayOutput => Math.Max(_measuredPeak, _observedPeak);

    /// <summary>
    /// After an orb is created or its set changes: forgets the observed component and stays silent for
    /// <see cref="QuietPeriodMs"/> from <paramref name="nowMs"/>.
    /// </summary>
    public void Restart(long nowMs)
    {
        _measuredPeak = 0;
        _observedPeak = 0;
        _previousPeak = null;
        _quietUntilMs = nowMs + QuietPeriodMs;
    }

    /// <summary>
    /// One engine tick for this orb; true when <c>newPeak_A</c> fires. The live value is compared with the previous
    /// tick's peak, then the peak takes it in. Nothing fires while <paramref name="measuredPeakOutput"/> is unknown, on
    /// the first tick after it becomes known, or on the tick that starts a new day (which resets the day's peaks).
    /// </summary>
    public bool Update(double liveOutput, double? measuredPeakOutput, long dayStartMs, long nowMs)
    {
        if (_dayStartMs != dayStartMs)
        {
            _dayStartMs = dayStartMs;
            _measuredPeak = 0;
            _observedPeak = 0;
            _previousPeak = null;
        }

        var fires = measuredPeakOutput is not null
            && _previousPeak is { } previous
            && liveOutput >= SpeedEngine.PeakMinimum
            && liveOutput >= previous + SpeedEngine.PeakMargin
            && (_quietUntilMs is not { } quietUntil || nowMs >= quietUntil)
            && (_lastEmissionMs is not { } last || nowMs - last >= SpeedEngine.PeakCooldownMs);
        if (fires)
        {
            _lastEmissionMs = nowMs;
        }

        if (measuredPeakOutput is { } measured)
        {
            _measuredPeak = measured;
        }

        _observedPeak = Math.Max(_observedPeak, liveOutput);
        _previousPeak = measuredPeakOutput is null ? null : PeakTodayOutput;
        return fires;
    }
}

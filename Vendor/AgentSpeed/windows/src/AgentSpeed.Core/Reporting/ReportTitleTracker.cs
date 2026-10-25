namespace AgentSpeed.Core.Reporting;

/// <summary>
/// The report title tracker (METRICS 11.2, REPORTING 6.4): the speed title level 0–13 of DESIGN 1 from the live value of the
/// General metric and its redline — entered at a threshold, left below 90 % of it, a change held for 0.8 s, idle after 3 s
/// below 0.5 tok/s. The same rule as the app's title tracker, on seconds of any monotonic clock.
/// </summary>
public sealed class ReportTitleTracker
{
    public const double HoldSeconds = 0.8;
    public const double IdleDelaySeconds = 3.0;
    public const double ExitRatio = 0.9;
    public const double FirstSpeed = 0.5;
    public const int MaxLevel = 13;

    /// <summary>Entry thresholds of levels 2–13 as fractions of the redline.</summary>
    private static readonly double[] Fractions = [0.02, 0.03, 0.04, 0.06, 0.08, 0.12, 0.17, 0.24, 0.34, 0.5, 0.7, 1.0];

    private int _candidate;
    private double _candidateSince;
    private double? _belowSince;

    public int Level { get; private set; }

    public static double EnterSpeed(int level, double redline) => level switch
    {
        <= 0 => 0,
        1 => FirstSpeed,
        _ => Fractions[Math.Min(level, MaxLevel) - 2] * redline,
    };

    /// <summary>Feeds the live value at <paramref name="now"/> (seconds).</summary>
    public void Update(double value, double redline, double now)
    {
        value = double.IsFinite(value) ? Math.Max(0, value) : 0;
        var next = RawLevel(value, redline, now);
        if (next != _candidate)
        {
            _candidate = next;
            _candidateSince = now;
        }

        if (_candidate != Level && now - _candidateSince >= HoldSeconds)
        {
            Level = _candidate;
        }
    }

    /// <summary><c>min(1, (v / R)^0.6)</c> of the unrounded live value (REPORTING 6.4).</summary>
    public static double Heat(double value, double redline) =>
        value > 0 && redline > 0 && double.IsFinite(value) ? Math.Min(1, Math.Pow(value / redline, 0.6)) : 0;

    private int RawLevel(double value, double redline, double now)
    {
        if (value < FirstSpeed)
        {
            _belowSince ??= now;
        }
        else
        {
            _belowSince = null;
        }

        if (_belowSince is { } below && now - below >= IdleDelaySeconds)
        {
            return 0;
        }

        var step = _candidate == 0 ? (value >= FirstSpeed ? 1 : 0) : _candidate;
        if (step == 0)
        {
            return 0;
        }

        while (step < MaxLevel && value >= EnterSpeed(step + 1, redline))
        {
            step++;
        }

        while (step > 1 && value < EnterSpeed(step, redline) * ExitRatio)
        {
            step--;
        }

        return step;
    }
}

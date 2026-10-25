using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Engine;

internal readonly record struct Interval(long StartMs, long EndMs)
{
    public long DurationMs => EndMs - StartMs;
}

/// <summary>Response timing rules (METRICS 3.3).</summary>
internal static class SpeedMath
{
    public const long MaxIntervalMs = 15 * 60_000;
    public const long MinDurationMs = 500;

    /// <summary>The widened speed interval <c>[start', end]</c>, or false when the response never counts as speed.</summary>
    public static bool TryGetSpeedInterval(ParsedResponse response, out Interval interval)
    {
        if (response.StartMs is not { } start || response.EndMs < start || response.EndMs - start > MaxIntervalMs)
        {
            interval = default;
            return false;
        }

        var effectiveStart = response.EndMs - start < MinDurationMs ? response.EndMs - MinDurationMs : start;
        interval = new Interval(effectiveStart, response.EndMs);
        return true;
    }

    public static long Overlap(long a0, long a1, long b0, long b1) => Math.Max(0, Math.Min(a1, b1) - Math.Max(a0, b0));

    public static long FloorDiv(long value, long divisor)
    {
        var quotient = value / divisor;
        return value % divisor != 0 && (value < 0) != (divisor < 0) ? quotient - 1 : quotient;
    }
}

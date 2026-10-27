namespace AgentSpeed.Core;

/// <summary>
/// Unix milliseconds from logs as a <see cref="DateTimeOffset"/>. A corrupt line can carry a time outside the calendar
/// (METRICS 3.6); it clamps to the representable range instead of throwing.
/// </summary>
internal static class UnixTime
{
    private static readonly long MinMs = DateTimeOffset.MinValue.ToUnixTimeMilliseconds();
    private static readonly long MaxMs = DateTimeOffset.MaxValue.ToUnixTimeMilliseconds();

    public static DateTimeOffset FromMs(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(Math.Clamp(ms, MinMs, MaxMs));
}

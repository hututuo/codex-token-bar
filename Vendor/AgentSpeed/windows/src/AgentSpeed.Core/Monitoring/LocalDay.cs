namespace AgentSpeed.Core.Monitoring;

/// <summary>Local midnight for "today" (METRICS 6.6).</summary>
internal static class LocalDay
{
    public static long StartMs(long nowMs, TimeZoneInfo zone)
    {
        var local = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(nowMs), zone);
        var midnight = local.Date;
        var guard = 0;
        while (zone.IsInvalidTime(midnight) && guard++ < 48)
        {
            midnight = midnight.AddMinutes(30);
        }

        var offset = zone.IsAmbiguousTime(midnight)
            ? zone.GetAmbiguousTimeOffsets(midnight).Max()
            : zone.GetUtcOffset(midnight);
        return new DateTimeOffset(midnight, offset).ToUnixTimeMilliseconds();
    }
}

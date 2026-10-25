namespace AgentSpeed.Core.Traffic;

/// <summary>
/// What the views show of traffic (METRICS 10.5, DESIGN 10): a disabled source is still measured and stored, but every view
/// leaves it out, so it shows no traffic anywhere. This computer's values are never filtered.
/// </summary>
public static class TrafficVisibility
{
    /// <summary>
    /// <paramref name="snapshot"/> without the sources outside <paramref name="enabled"/>: their rates, today's bytes and
    /// sparklines, and with them every sum over sources. The machine series, the sampler state and agents are unchanged.
    /// </summary>
    public static TrafficSnapshot Snapshot(TrafficSnapshot snapshot, SourceSet enabled)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!HidesAny(snapshot.Sources.Keys, enabled) && !HidesAny(snapshot.SourceHistory.Keys, enabled))
        {
            return snapshot;
        }

        return snapshot with
        {
            Sources = snapshot.Sources.Where(e => enabled.Contains(e.Key)).ToDictionary(e => e.Key, e => e.Value),
            SourceHistory = snapshot.SourceHistory.Where(e => enabled.Contains(e.Key)).ToDictionary(e => e.Key, e => e.Value),
        };
    }

    /// <summary>Stored days without the rows of sources outside <paramref name="enabled"/>; <c>machine</c> rows and unknown keys stay.</summary>
    public static IReadOnlyList<TrafficDay> Days(IReadOnlyList<TrafficDay> days, SourceSet enabled)
    {
        ArgumentNullException.ThrowIfNull(days);
        return days.Any(d => Hidden(d, enabled)) ? days.Where(d => !Hidden(d, enabled)).ToArray() : days;
    }

    private static bool Hidden(TrafficDay day, SourceSet enabled) => day.Source is { } source && !enabled.Contains(source);

    private static bool HidesAny(IEnumerable<SourceKind> sources, SourceSet enabled)
    {
        foreach (var source in sources)
        {
            if (!enabled.Contains(source))
            {
                return true;
            }
        }

        return false;
    }
}

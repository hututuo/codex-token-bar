namespace AgentSpeed.Core.Traffic.Engine;

internal static class CounterDelta
{
    /// <summary>100 Gbit/s (METRICS 10.4).</summary>
    public const double MaxBytesPerSecond = 12_500_000_000.0;

    /// <summary><c>cur − prev</c>; a decrease or more than 12.5 GB/s × Δt is a reset (0).</summary>
    public static long Of(long previous, long current, long? intervalMs)
    {
        if (current < previous)
        {
            return 0;
        }

        var delta = current - previous;
        if (intervalMs is { } dt && delta > MaxBytesPerSecond * Math.Max(dt, 1) / 1000)
        {
            return 0;
        }

        return delta;
    }

    public static TrafficBytes Of(TrafficCounter previous, TrafficCounter current, long? intervalMs) =>
        new(Of(previous.Rx, current.Rx, intervalMs), Of(previous.Tx, current.Tx, intervalMs));
}

/// <summary>
/// Process-counter baselines of one stream (METRICS 10.4.2–10.4.4, 10.4.7): a key absent from three consecutive samples
/// is forgotten.
/// </summary>
internal sealed class CounterBaselines
{
    public const int ForgetAfter = 3;

    private sealed class Entry
    {
        public TrafficCounter Value;
        public int Missing;
        public bool Seen;
    }

    private readonly Dictionary<ProcessIdentity, Entry> _values = new();
    private readonly List<ProcessIdentity> _forgotten = new();

    public int Count => _values.Count;

    public bool TryGet(ProcessIdentity key, out TrafficCounter value)
    {
        if (_values.TryGetValue(key, out var entry))
        {
            value = entry.Value;
            return true;
        }

        value = default;
        return false;
    }

    public void Reset() => _values.Clear();

    /// <summary>Sets the newest value and marks the key as seen in this sample.</summary>
    public void Set(ProcessIdentity key, TrafficCounter value)
    {
        if (!_values.TryGetValue(key, out var entry))
        {
            entry = new Entry();
            _values[key] = entry;
        }

        entry.Value = value;
        entry.Seen = true;
    }

    /// <summary>Ends a sample: every key not set in it ages by one and is forgotten after <see cref="ForgetAfter"/>.</summary>
    public void Age()
    {
        _forgotten.Clear();
        foreach (var (key, entry) in _values)
        {
            if (entry.Seen)
            {
                entry.Seen = false;
                entry.Missing = 0;
            }
            else if (++entry.Missing >= ForgetAfter)
            {
                _forgotten.Add(key);
            }
        }

        foreach (var key in _forgotten)
        {
            _values.Remove(key);
        }
    }
}

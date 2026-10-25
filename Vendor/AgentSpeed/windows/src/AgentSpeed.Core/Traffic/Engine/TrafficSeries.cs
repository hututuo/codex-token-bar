namespace AgentSpeed.Core.Traffic.Engine;

/// <summary>
/// Deltas of one counter series with their sample times, for the live rate (METRICS 10.7): the bytes of the samples in
/// <c>(t − 3000, t]</c> over <c>t − t₀</c>, <c>t₀</c> the latest sample time ≤ <c>t − 3000</c>. A gap restarts the series.
/// </summary>
internal sealed class TrafficSeries
{
    public const long WindowMs = 3000;

    private readonly List<(long T, TrafficBytes Bytes)> _points = new(8);

    public void Add(long t, TrafficBytes bytes, bool gap)
    {
        if (gap)
        {
            _points.Clear();
            _points.Add((t, TrafficBytes.Zero));
            return;
        }

        _points.Add((t, bytes));
        var drop = 0;
        while (_points.Count - drop > 2 && _points[drop + 1].T <= t - WindowMs)
        {
            drop++;
        }

        if (drop > 0)
        {
            _points.RemoveRange(0, drop);
        }
    }

    /// <summary>Null before two samples exist.</summary>
    public TrafficRate? Rate
    {
        get
        {
            if (_points.Count < 2)
            {
                return null;
            }

            var last = _points[^1].T;
            var start = 0;
            for (var i = 0; i < _points.Count; i++)
            {
                if (_points[i].T <= last - WindowMs)
                {
                    start = i;
                }
            }

            var seconds = (last - _points[start].T) / 1000.0;
            if (seconds <= 0)
            {
                return null;
            }

            long rx = 0, tx = 0;
            for (var i = start + 1; i < _points.Count; i++)
            {
                rx += _points[i].Bytes.Rx;
                tx += _points[i].Bytes.Tx;
            }

            return new TrafficRate(rx / seconds, tx / seconds);
        }
    }
}

/// <summary>The self and self + tools series of a source or agent tree (<c>includeTools</c>, DESIGN 10).</summary>
internal sealed class TrafficSeriesPair
{
    private readonly TrafficSeries _self = new();
    private readonly TrafficSeries _all = new();

    public void Add(long t, TrafficSplit split, bool gap)
    {
        _self.Add(t, split.Self, gap);
        _all.Add(t, split.Self + split.Tools, gap);
    }

    public TrafficRate? WithTools => _all.Rate;

    public TrafficRate? SelfOnly => _self.Rate;
}

/// <summary>
/// One-second buckets of the last 300 s (METRICS 10.7 history buffer). A sample's rate (bytes ÷ interval seconds) fills
/// the buckets of the wall-clock seconds its interval ends in or covers, so a 5-second sample fills five buckets and a
/// 1-second sample one; gap samples are not added.
/// </summary>
internal sealed class TrafficBuckets
{
    public const int Seconds = 300;

    private readonly TrafficRate[] _rates = new TrafficRate[Seconds];
    private long? _newestSecond;
    private int _cursor;

    public bool IsEmpty => _newestSecond is null;

    public void Add(long wallMs, long intervalMs, TrafficBytes bytes)
    {
        if (intervalMs <= 0)
        {
            return;
        }

        var seconds = intervalMs / 1000.0;
        var rate = new TrafficRate(bytes.Rx / seconds, bytes.Tx / seconds);
        var last = SecondOf(wallMs);
        var first = Math.Max(SecondOf(wallMs - intervalMs) + 1, last - Seconds + 1);
        Advance(last);
        for (var second = first; second <= last; second++)
        {
            if (Slot(second) is { } slot)
            {
                _rates[slot] = rate;
            }
        }
    }

    /// <summary>The 300 buckets ending at <paramref name="nowMs"/>'s second, oldest first.</summary>
    public TrafficPoint[] Points(long nowMs)
    {
        var last = SecondOf(nowMs);
        var first = last - Seconds + 1;
        var points = new TrafficPoint[Seconds];
        for (var i = 0; i < Seconds; i++)
        {
            var second = first + i;
            points[i] = new TrafficPoint(DateTimeOffset.FromUnixTimeSeconds(second), Slot(second) is { } slot ? _rates[slot] : TrafficRate.Zero);
        }

        return points;
    }

    /// <summary>Points for a series that never had a sample.</summary>
    public static TrafficPoint[] Empty(long nowMs) => new TrafficBuckets().Points(nowMs);

    private static long SecondOf(long ms) => ms >= 0 ? ms / 1000 : (ms - 999) / 1000;

    private int? Slot(long second)
    {
        if (_newestSecond is not { } newest || second > newest || newest - second >= Seconds)
        {
            return null;
        }

        var back = (int)(newest - second);
        return (_cursor - back + Seconds) % Seconds;
    }

    private void Advance(long second)
    {
        if (_newestSecond is not { } newest)
        {
            _newestSecond = second;
            return;
        }

        if (second <= newest)
        {
            // The wall clock went back: start over rather than mix two timelines.
            if (newest - second >= Seconds || second < newest - 5)
            {
                Reset(second);
            }

            return;
        }

        var steps = second - newest;
        if (steps >= Seconds)
        {
            Reset(second);
            return;
        }

        for (var i = 0; i < steps; i++)
        {
            _cursor = (_cursor + 1) % Seconds;
            _rates[_cursor] = TrafficRate.Zero;
        }

        _newestSecond = second;
    }

    private void Reset(long second)
    {
        Array.Clear(_rates);
        _cursor = 0;
        _newestSecond = second;
    }
}

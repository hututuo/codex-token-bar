namespace AgentSpeed.Core.Engine;

/// <summary>
/// Today's measured output per source in one-second buckets (METRICS 6.6) and the measured peak of any source set
/// (METRICS 6.8). A source gets buckets only once it has measured data today.
/// </summary>
/// <remarks>
/// Each requested set caches the peak trailing average per chunk. A change marks the chunks whose windows it touched in
/// the cached sets that contain its source, so a set is rescanned only after one of its sources changed, and then only
/// those chunks.
/// </remarks>
internal sealed class SourceSeconds
{
    /// <summary>Sets beyond this are dropped oldest first; at most eight orbs ask at a time.</summary>
    public const int MaxCachedSets = 32;

    private const int ChunkSeconds = SecondSeries.ChunkSeconds;

    private static readonly int SourceCount = Enum.GetValues<SourceKind>().Length;

    private readonly SecondSeries?[] _series = new SecondSeries?[SourceCount];
    private readonly List<SetPeak> _sets = [];
    private readonly double[]?[] _members = new double[SourceCount][];

    /// <summary>Sources whose buckets are allocated.</summary>
    public SourceSet Allocated
    {
        get
        {
            var set = SourceSet.Empty;
            for (var i = 0; i < SourceCount; i++)
            {
                if (_series[i] is not null)
                {
                    set = set.With((SourceKind)i);
                }
            }

            return set;
        }
    }

    /// <summary>Chunks rescanned to answer peak requests (tests).</summary>
    public long ChunkScans { get; private set; }

    public void Clear()
    {
        Array.Clear(_series);
        _sets.Clear();
    }

    /// <summary>Adds (positive) or removes (negative) measured output of one source, like the all-sources buckets.</summary>
    public void AddInterval(SourceKind source, long startMs, long endMs, double amount, long floorMs)
    {
        var from = Math.Max(startMs, floorMs);
        if (endMs <= startMs || amount == 0 || from >= endMs)
        {
            return;
        }

        ref var series = ref _series[(int)source];
        if (series is null)
        {
            if (amount < 0)
            {
                return;
            }

            series = new SecondSeries();
        }

        series.AddInterval(startMs, endMs, amount, floorMs);

        // Trailing windows that include a changed second end up to two seconds after it.
        var firstChunk = SecondSeries.ChunkOf(SpeedMath.FloorDiv(from, 1000));
        var lastChunk = SecondSeries.ChunkOf(SpeedMath.FloorDiv(endMs - 1, 1000) + 2);
        foreach (var set in _sets)
        {
            if (!set.Sources.Contains(source))
            {
                continue;
            }

            for (var chunk = firstChunk; chunk <= lastChunk; chunk++)
            {
                set.Dirty.Add(chunk);
            }
        }
    }

    /// <summary>Maximum over today of the 3-bucket trailing average of the members' summed buckets.</summary>
    public double MeasuredPeak(SourceSet sources)
    {
        var set = Find(sources) ?? Cache(sources);
        if (set.Dirty.Count == 0)
        {
            return set.Peak;
        }

        foreach (var chunk in set.Dirty)
        {
            if (ChunkPeak(sources, chunk) is { } peak)
            {
                set.ChunkPeaks[chunk] = peak;
            }
            else
            {
                set.ChunkPeaks.Remove(chunk);
            }

            ChunkScans++;
        }

        set.Dirty.Clear();
        var best = 0.0;
        foreach (var peak in set.ChunkPeaks.Values)
        {
            best = Math.Max(best, peak);
        }

        set.Peak = best;
        return best;
    }

    private SetPeak? Find(SourceSet sources)
    {
        foreach (var set in _sets)
        {
            if (set.Sources == sources)
            {
                return set;
            }
        }

        return null;
    }

    private SetPeak Cache(SourceSet sources)
    {
        if (_sets.Count >= MaxCachedSets)
        {
            _sets.RemoveAt(0);
        }

        var set = new SetPeak(sources);
        foreach (var kind in sources)
        {
            if (_series[(int)kind] is { } series)
            {
                set.Dirty.UnionWith(series.ChunkKeys);
            }
        }

        _sets.Add(set);
        return set;
    }

    /// <summary>
    /// Peak of the trailing averages that end inside <paramref name="chunk"/>; null when no member has data there (such
    /// windows never exceed the window that ends at the last second with data).
    /// </summary>
    private double? ChunkPeak(SourceSet sources, long chunk)
    {
        var count = 0;
        double previous2 = 0, previous1 = 0;
        foreach (var kind in sources)
        {
            if (_series[(int)kind] is not { } series)
            {
                continue;
            }

            if (series.TryGetChunk(chunk, out var values))
            {
                _members[count++] = values;
            }

            if (series.TryGetChunk(chunk - 1, out var before))
            {
                previous2 += Math.Max(0, before[ChunkSeconds - 2]);
                previous1 += Math.Max(0, before[ChunkSeconds - 1]);
            }
        }

        if (count == 0)
        {
            return null;
        }

        var best = 0.0;
        for (var i = 0; i < ChunkSeconds; i++)
        {
            var value = 0.0;
            for (var m = 0; m < count; m++)
            {
                value += Math.Max(0, _members[m]![i]);
            }

            var average = (previous2 + previous1 + value) / 3;
            if (average > best)
            {
                best = average;
            }

            previous2 = previous1;
            previous1 = value;
        }

        Array.Clear(_members, 0, count);
        return best;
    }

    private sealed class SetPeak(SourceSet sources)
    {
        public SourceSet Sources { get; } = sources;

        /// <summary>Peak trailing average per chunk with data.</summary>
        public Dictionary<long, double> ChunkPeaks { get; } = [];

        /// <summary>Chunks whose peak is out of date.</summary>
        public HashSet<long> Dirty { get; } = [];

        public double Peak { get; set; }
    }
}

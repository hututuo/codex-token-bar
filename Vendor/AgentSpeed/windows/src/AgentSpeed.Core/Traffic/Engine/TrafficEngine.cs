namespace AgentSpeed.Core.Traffic.Engine;

/// <summary>One process-counter sample (METRICS 10.3, 10.4).</summary>
/// <param name="Stream">A different stream starts over (every process a baseline) unless <paramref name="Continues"/> (10.4.7).</param>
/// <param name="StreamStartUs">
/// When sampling of this stream began; in its first sample only processes started by then are baselines, later ones are
/// new. Null: the sample's own time.
/// </param>
/// <param name="IsStandby">
/// No agent process exists, so the sampler is stopped and every source's traffic is a real zero (METRICS 10.10): the
/// interval counts as sampled and the series get zeros, but baselines are neither used nor aged.
/// </param>
internal sealed record CounterSample(int Stream, IReadOnlyList<CounterRow> Rows, bool Continues = false, long? StreamStartUs = null,
    bool IsStandby = false);

/// <summary>
/// One tick (METRICS 10.4.1). <see cref="T"/> is monotonic (deltas, rates, gaps); <see cref="WallMs"/> names the local
/// date, the history buckets and the agent activity window.
/// </summary>
/// <param name="Processes">Null when the process table was not refreshed this tick.</param>
/// <param name="Interfaces">Counted interfaces' cumulative counters; null when they were not read.</param>
internal readonly record struct TrafficSample(
    long T,
    long WallMs,
    IReadOnlyList<ProcessEntry>? Processes,
    IReadOnlyDictionary<ulong, TrafficCounter>? Interfaces,
    CounterSample? Counters);

/// <summary>The sampler-independent traffic core (METRICS 10.4–10.9): deltas, attribution, live rates, history buckets, today.</summary>
internal sealed class TrafficEngine
{
    public const long GapMs = 15_000;

    private static readonly SourceKind[] AllSources = Enum.GetValues<SourceKind>();

    private readonly Dictionary<ulong, TrafficCounter> _interfaces = new();
    private readonly CounterBaselines _baselines = new();
    private readonly Dictionary<ProcessIdentity, (SourceKind Source, TrafficSplit Split)> _perRoot = new();
    private readonly Dictionary<SourceKind, TrafficSplit> _sourceTotals = new();
    private readonly Dictionary<string, TrafficSplit> _agentTotals = new(StringComparer.Ordinal);
    private readonly HashSet<string> _openFiles = new(StringComparer.Ordinal);
    private long? _previousT;
    private int? _stream;
    private long _streamStartUs;
    private bool _awaitingFirstSample;
    private long? _previousCounterT;
    private static long _epochs;
    private readonly Dictionary<SourceKind, TrafficSplit> _reportTotals = new();
    private TrafficReportTotals? _reportSnapshot;

    public TrafficEngine(TrafficPlatform platform, TimeZoneInfo? zone = null)
    {
        Platform = platform;
        Table = new ProcessTable(platform);
        Ledger = new TrafficLedger(zone ?? TimeZoneInfo.Local);
    }

    public TrafficPlatform Platform { get; }

    public ProcessTable Table { get; }

    public AgentTrees Trees { get; } = new();

    public TrafficLedger Ledger { get; }

    public string? CurrentDay { get; private set; }

    public TrafficSeries MachineSeries { get; } = new();

    public TrafficBuckets MachineBuckets { get; } = new();

    public Dictionary<SourceKind, TrafficSeriesPair> SourceSeries { get; } = new();

    public Dictionary<SourceKind, TrafficBuckets> SourceBuckets { get; } = new();

    public Dictionary<string, TrafficSeriesPair> AgentSeries { get; } = new(StringComparer.Ordinal);

    /// <summary>Diagnostics: bytes per root agent process since the engine started, and the trees they went to ("" = none).</summary>
    public Dictionary<ProcessIdentity, (TrafficSplit Split, Dictionary<string, TrafficSplit> Assigned)> RootTotals { get; } = new();

    public TrafficRate? MachineRate => MachineSeries.Rate;

    /// <summary>This engine's identity for live reporting's differences (METRICS 11.4).</summary>
    public long Epoch { get; } = Interlocked.Increment(ref _epochs);

    /// <summary>Bytes for live reporting since the engine started, without gap samples (METRICS 11.4); copied only after a change.</summary>
    public TrafficReportTotals ReportTotals => _reportSnapshot ??= new TrafficReportTotals(Epoch, new Dictionary<SourceKind, TrafficSplit>(_reportTotals));

    public void SetAgents(IEnumerable<TrafficAgent> agents)
    {
        Trees.Replace(agents);
        var roots = new HashSet<string>(Trees.Roots, StringComparer.Ordinal);
        foreach (var key in AgentSeries.Keys.Where(k => !roots.Contains(k)).ToArray())
        {
            AgentSeries.Remove(key);
        }
    }

    /// <summary>Today's restored totals (METRICS 10.8), before the first tick.</summary>
    public void Restore(string day, IEnumerable<TrafficDay> rows) => Ledger.Restore(day, rows);

    /// <summary>"Clear history": today starts over at zero.</summary>
    public void ResetToday()
    {
        if (CurrentDay is { } day)
        {
            Ledger.Reset(day);
        }
    }

    public TrafficDayTotals Today() => CurrentDay is { } day && Ledger.Totals(day) is { } totals ? totals : new TrafficDayTotals();

    public void Tick(in TrafficSample sample, IProcessInspector inspector)
    {
        var t = sample.T;
        long? dt = _previousT is { } previous ? t - previous : null;
        var gap = dt is not { } interval || interval > GapMs;
        _previousT = t;
        if (sample.Processes is { } processes)
        {
            Table.Refresh(processes, inspector, t);
        }

        var day = Ledger.Label(sample.WallMs);
        CurrentDay = day;
        var totals = Ledger.Day(day);

        if (sample.Interfaces is { } current)
        {
            var sum = TrafficBytes.Zero;
            foreach (var (key, counter) in current)
            {
                if (_interfaces.TryGetValue(key, out var last))
                {
                    sum += CounterDelta.Of(last, counter, dt);
                }
            }

            _interfaces.Clear();
            foreach (var (key, counter) in current)
            {
                _interfaces[key] = counter;
            }

            totals.Machine += sum;
            if (dt is { } d && d <= GapMs)
            {
                totals.MachineSampledMs += d;
            }

            MachineSeries.Add(t, sum, gap);
            if (!gap && dt is { } machineDt)
            {
                MachineBuckets.Add(sample.WallMs, machineDt, sum);
            }
        }

        if (sample.Counters is { } counters)
        {
            Apply(counters, t, sample.WallMs, totals, inspector);
        }
    }

    private void Apply(CounterSample counters, long t, long wallMs, TrafficDayTotals totals, IProcessInspector inspector)
    {
        long? dt = _previousCounterT is { } previous ? t - previous : null;
        var gap = dt is not { } interval || interval > GapMs;
        _previousCounterT = t;
        var newStream = counters.Stream != _stream && !counters.Continues;
        _stream = counters.Stream;
        if (newStream)
        {
            _baselines.Reset();
            _awaitingFirstSample = true;
            _streamStartUs = counters.StreamStartUs ?? t * 1000;
        }

        if (dt is { } d && d <= GapMs && !newStream)
        {
            totals.ProcessSampledMs += d;
        }

        _sourceTotals.Clear();
        _agentTotals.Clear();
        if (counters.IsStandby)
        {
            Record(t, wallMs, dt, gap);
            return;
        }

        var firstSample = _awaitingFirstSample;
        _awaitingFirstSample = false;
        _perRoot.Clear();
        foreach (var row in counters.Rows)
        {
            if (Table.Find(row.Identity) is not { } record)
            {
                continue;
            }

            TrafficBytes delta;
            if (_baselines.TryGet(row.Identity, out var last))
            {
                delta = CounterDelta.Of(last, row.Counter, dt);
            }
            else if (firstSample && record.Entry.StartUs <= _streamStartUs)
            {
                delta = TrafficBytes.Zero;
            }
            else
            {
                delta = new TrafficBytes(row.Counter.Rx, row.Counter.Tx);
            }

            _baselines.Set(row.Identity, row.Counter);
            if (record.Class is not { } processClass || delta.IsZero)
            {
                continue;
            }

            (SourceKind Source, TrafficSplit Split) entry = _perRoot.TryGetValue(processClass.Root, out var existing) ? existing : (processClass.Source, TrafficSplit.Zero);
            entry.Split = processClass.Role == TrafficRole.Tool
                ? entry.Split with { Tools = entry.Split.Tools + delta }
                : entry.Split with { Self = entry.Split.Self + delta };
            _perRoot[processClass.Root] = entry;
        }

        _baselines.Age();

        var startMs = wallMs - (dt ?? 0);
        foreach (var (root, (source, split)) in _perRoot)
        {
            _sourceTotals[source] = _sourceTotals.GetValueOrDefault(source) + split;
            if (!gap)
            {
                _reportTotals[source] = _reportTotals.GetValueOrDefault(source) + split;
                _reportSnapshot = null;
            }

            var candidates = Trees.Candidates(source, startMs, wallMs, Platform,
                () => OpenFiles(root, inspector, t),
                () => Table.WorkingDirectory(root, inspector));
            var traffic = totals.Source(source);
            traffic.Split += split;
            string? assigned = candidates.Count == 1 ? candidates[0] : null;
            if (assigned is not null)
            {
                totals.Agents[assigned] = totals.Agents.GetValueOrDefault(assigned) + split;
                _agentTotals[assigned] = _agentTotals.GetValueOrDefault(assigned) + split;
            }
            else
            {
                traffic.Unassigned += split.Self + split.Tools;
            }

            if (!RootTotals.TryGetValue(root, out var rootTotals))
            {
                rootTotals = (TrafficSplit.Zero, new Dictionary<string, TrafficSplit>(StringComparer.Ordinal));
            }

            var key = assigned ?? string.Empty;
            rootTotals.Assigned[key] = rootTotals.Assigned.GetValueOrDefault(key) + split;
            RootTotals[root] = (rootTotals.Split + split, rootTotals.Assigned);
        }

        Record(t, wallMs, dt, gap);
    }

    private void Record(long t, long wallMs, long? dt, bool gap)
    {
        foreach (var source in AllSources)
        {
            var split = _sourceTotals.GetValueOrDefault(source);
            if (!SourceSeries.TryGetValue(source, out var series))
            {
                series = new TrafficSeriesPair();
                SourceSeries[source] = series;
            }

            series.Add(t, split, gap);
            if (!gap && dt is { } interval)
            {
                if (!SourceBuckets.TryGetValue(source, out var buckets))
                {
                    buckets = new TrafficBuckets();
                    SourceBuckets[source] = buckets;
                }

                buckets.Add(wallMs, interval, split.Self + split.Tools);
            }
        }

        foreach (var root in Trees.Roots)
        {
            if (!AgentSeries.TryGetValue(root, out var series))
            {
                series = new TrafficSeriesPair();
                AgentSeries[root] = series;
            }

            series.Add(t, _agentTotals.GetValueOrDefault(root), gap);
        }
    }

    private HashSet<string> OpenFiles(ProcessIdentity root, IProcessInspector inspector, long nowMs)
    {
        _openFiles.Clear();
        if (Table.Members.TryGetValue(root, out var members))
        {
            foreach (var member in members)
            {
                if (Table.Find(member) is { Alive: true } record)
                {
                    foreach (var path in inspector.OpenFiles(record.Entry, nowMs))
                    {
                        _openFiles.Add(Platform.Normalize(path));
                    }
                }
            }
        }

        return _openFiles;
    }
}

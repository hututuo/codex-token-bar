using AgentSpeed.Core.Traffic;

namespace AgentSpeed.Core.Reporting;

public enum ReportTrafficStatus
{
    Ok,
    Off,
    Unavailable,
}

/// <summary>One source's instantaneous values (METRICS 11.2).</summary>
public readonly record struct ReportSourceSample(Rate Live, Rate LiveEstimated, LiveCost LiveCost);

/// <summary>Traffic as live reporting reads it (METRICS 11.2): rates of the latest sample and cumulative bytes.</summary>
/// <param name="Rate">Σ over the reported sources of own (+ tools); null while the series has fewer than two samples.</param>
/// <param name="Totals">Cumulative bytes of every source, disabled ones included, so a baseline stays valid across a toggle.</param>
/// <param name="Enabled">The sources whose bytes are reported (METRICS 11.4: a disabled source reports no traffic).</param>
public sealed record ReportTrafficSample(
    ReportTrafficStatus Status,
    bool IncludesTools,
    TrafficRate? Rate,
    IReadOnlyDictionary<SourceKind, TrafficRate> SourceRates,
    TrafficReportTotals Totals,
    SourceSet Enabled)
{
    public static ReportTrafficSample Off { get; } = new(ReportTrafficStatus.Off, true, null, new Dictionary<SourceKind, TrafficRate>(),
        TrafficReportTotals.Zero, SourceSet.Everything);

    public static ReportTrafficSample Unavailable { get; } = Off with { Status = ReportTrafficStatus.Unavailable };

    /// <summary>From the traffic snapshot and the <c>includeTools</c> setting, leaving out sources outside <paramref name="enabled"/>.</summary>
    public static ReportTrafficSample From(TrafficSnapshot snapshot, bool includeTools, SourceSet enabled)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!snapshot.Enabled)
        {
            return Off;
        }

        var available = snapshot.ProcessState.IsAvailable;
        var rates = new Dictionary<SourceKind, TrafficRate>();
        if (available)
        {
            foreach (var (kind, traffic) in snapshot.Sources)
            {
                if (enabled.Contains(kind) && traffic.Live(includeTools) is { } rate)
                {
                    rates[kind] = rate;
                }
            }
        }

        return new ReportTrafficSample(
            available ? ReportTrafficStatus.Ok : ReportTrafficStatus.Unavailable,
            includeTools,
            available ? snapshot.Live(enabled, includeTools) : null,
            rates,
            snapshot.ReportTotals,
            enabled);
    }

    /// <summary>Agent bytes of the window: own plus tools of every reported source (own only without tools).</summary>
    public IReadOnlyDictionary<SourceKind, TrafficBytes> AgentBytes(TrafficReportTotals baseline)
    {
        var output = new Dictionary<SourceKind, TrafficBytes>();
        var restarted = baseline.Epoch != Totals.Epoch;
        foreach (var (kind, split) in Totals.Sources)
        {
            if (!Enabled.Contains(kind))
            {
                continue;
            }

            var now = split.Total(IncludesTools);
            var then = restarted ? TrafficBytes.Zero : baseline.Sources.GetValueOrDefault(kind).Total(IncludesTools);
            var delta = new TrafficBytes(Math.Max(0, now.Rx - then.Rx), Math.Max(0, now.Tx - then.Tx));
            if (!delta.IsZero)
            {
                output[kind] = delta;
            }
        }

        return output;
    }
}

/// <summary>The instantaneous values of one tick (METRICS 11.2), read from a speed snapshot and the latest traffic snapshot.</summary>
public sealed record ReportSample(
    Rate Live,
    double EstimatedShare,
    LiveCost LiveCost,
    IReadOnlyDictionary<SourceKind, ReportSourceSample> Sources,
    ReportLiveFacts Facts,
    ReportTrafficSample Traffic)
{
    public static ReportSample Empty { get; } = new(Rate.Zero, 0, LiveCost.Zero, new Dictionary<SourceKind, ReportSourceSample>(),
        ReportLiveFacts.Empty, ReportTrafficSample.Off);

    /// <summary>From the app's snapshots: every enabled source together, never an orb's subset (METRICS 11.1).</summary>
    public static ReportSample From(SpeedSnapshot snapshot, ReportTrafficSample traffic)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var sources = new Dictionary<SourceKind, ReportSourceSample>();
        foreach (var status in snapshot.Sources)
        {
            if (status.Enabled)
            {
                sources[status.Kind] = new ReportSourceSample(status.Live, status.LiveEstimated, status.LiveCost);
            }
        }

        return new ReportSample(snapshot.Live, snapshot.LiveEstimatedShare, snapshot.LiveCost, sources, snapshot.Report, traffic);
    }

    /// <summary>The live value the title follows (<c>title.metric</c>).</summary>
    public double Value(SpeedMetric metric) => Live.ValueFor(metric);

    /// <summary>An agent generates or runs tools (the activity rule of METRICS 11.5).</summary>
    public bool IsWorking => Facts.Agents.Values.Any(a => a.Generating + a.Tools > 0);
}

/// <summary>
/// What a built report takes from its window (METRICS 11.4, 11.5): the deltas since the last build or discard and the peaks
/// of the ticks inside it.
/// </summary>
public sealed record ReportWindowContent(
    ReportCounters Usage,
    IReadOnlyDictionary<SourceKind, TrafficBytes> AgentBytes,
    Rate Peak,
    double PeakCost,
    TrafficRate? PeakRate);

/// <summary>The open window of a run: a baseline of the cumulative counters and the peaks since the window started.</summary>
public sealed class ReportWindow
{
    private ReportCounters _baseline;
    private long _baselineEpoch;
    private TrafficReportTotals _trafficBaseline;
    private ReportCounters _lastCounters;
    private long _lastEpoch;
    private TrafficReportTotals _lastTraffic;
    private Rate _peak;
    private double _peakCost;
    private TrafficRate? _peakRate;

    public ReportWindow(ReportSample sample)
    {
        ArgumentNullException.ThrowIfNull(sample);
        _baseline = sample.Facts.Counters;
        _baselineEpoch = sample.Facts.Epoch;
        _trafficBaseline = sample.Traffic.Totals;
        _lastCounters = _baseline;
        _lastEpoch = _baselineEpoch;
        _lastTraffic = _trafficBaseline;
    }

    /// <summary>The ledger received a token increment since the previous tick (the activity rule of METRICS 11.5).</summary>
    public bool HasTokenIncrement(ReportSample sample) =>
        sample.Facts.Counters.HasTokensSince(sample.Facts.Epoch == _lastEpoch ? _lastCounters : ReportCounters.Zero);

    /// <summary>Empties the window. <paramref name="keepingTick"/> keeps this tick's increments (the gap rule, METRICS 11.1).</summary>
    public void Discard(ReportSample sample, bool keepingTick)
    {
        if (keepingTick && sample.Facts.Epoch == _lastEpoch)
        {
            _baseline = _lastCounters;
            _baselineEpoch = _lastEpoch;
            _trafficBaseline = _lastTraffic;
        }
        else if (keepingTick)
        {
            _baseline = ReportCounters.Zero;
            _baselineEpoch = sample.Facts.Epoch;
            _trafficBaseline = _lastTraffic;
        }
        else
        {
            _baseline = sample.Facts.Counters;
            _baselineEpoch = sample.Facts.Epoch;
            _trafficBaseline = sample.Traffic.Totals;
        }

        _peak = Rate.Zero;
        _peakCost = 0;
        _peakRate = null;
    }

    /// <summary>
    /// Ends a tick: its values join the peaks unless the window started at this tick (<paramref name="peaks"/> false), and it
    /// becomes the previous tick of the gap and activity rules.
    /// </summary>
    public void Observe(ReportSample sample, bool peaks = true)
    {
        if (peaks)
        {
            _peak = new Rate(Math.Max(_peak.Output, sample.Live.Output), Math.Max(_peak.Total, sample.Live.Total));
            _peakCost = Math.Max(_peakCost, sample.LiveCost.MicroUsdPerSecond);
            _peakRate = Larger(_peakRate, sample.Traffic.Status == ReportTrafficStatus.Ok ? sample.Traffic.Rate : null);
        }

        _lastCounters = sample.Facts.Counters;
        _lastEpoch = sample.Facts.Epoch;
        _lastTraffic = sample.Traffic.Totals;
    }

    /// <summary>The window's content as of <paramref name="sample"/> (which it includes), without emptying it (the preview).</summary>
    public ReportWindowContent Content(ReportSample sample)
    {
        var baseline = sample.Facts.Epoch == _baselineEpoch ? _baseline : ReportCounters.Zero;
        var peak = new Rate(Math.Max(_peak.Output, sample.Live.Output), Math.Max(_peak.Total, sample.Live.Total));
        var peakCost = Math.Max(_peakCost, sample.LiveCost.MicroUsdPerSecond);
        var peakRate = Larger(_peakRate, sample.Traffic.Status == ReportTrafficStatus.Ok ? sample.Traffic.Rate : null);
        return new ReportWindowContent(sample.Facts.Counters.Since(baseline), sample.Traffic.AgentBytes(_trafficBaseline), peak, peakCost, peakRate);
    }

    /// <summary>Builds: the content, then an empty window starting at <paramref name="sample"/>.</summary>
    public ReportWindowContent Take(ReportSample sample)
    {
        var taken = Content(sample);
        Discard(sample, keepingTick: false);
        Observe(sample, peaks: false);
        return taken;
    }

    private static TrafficRate? Larger(TrafficRate? a, TrafficRate? b) => (a, b) switch
    {
        (null, _) => b,
        (_, null) => a,
        ({ } x, { } y) => new TrafficRate(Math.Max(x.Rx, y.Rx), Math.Max(x.Tx, y.Tx)),
    };
}

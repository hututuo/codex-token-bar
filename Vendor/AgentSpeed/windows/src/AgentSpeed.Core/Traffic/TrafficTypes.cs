namespace AgentSpeed.Core.Traffic;

/// <summary>Bytes per second, download (<c>rx</c>) and upload (<c>tx</c>) (METRICS 10.1, 10.7).</summary>
public readonly record struct TrafficRate(double Rx, double Tx)
{
    public double Sum => Rx + Tx;

    public static TrafficRate Zero => default;

    public static TrafficRate operator +(TrafficRate a, TrafficRate b) => new(a.Rx + b.Rx, a.Tx + b.Tx);
}

/// <summary>Bytes, download (<c>rx</c>) and upload (<c>tx</c>).</summary>
public readonly record struct TrafficBytes(long Rx, long Tx)
{
    public long Sum => Rx + Tx;

    public bool IsZero => Rx == 0 && Tx == 0;

    public static TrafficBytes Zero => default;

    public static TrafficBytes operator +(TrafficBytes a, TrafficBytes b) => new(a.Rx + b.Rx, a.Tx + b.Tx);
}

/// <summary>
/// Bytes of a source or agent, split into its own agent processes (<see cref="Self"/>) and the tool processes they run
/// (<see cref="Tools"/>) (METRICS 10.1, 10.5).
/// </summary>
public readonly record struct TrafficSplit(TrafficBytes Self, TrafficBytes Tools)
{
    public static TrafficSplit Zero => default;

    /// <summary>The displayed value: tools only when <c>includeTools</c> (DESIGN 10).</summary>
    public TrafficBytes Total(bool includeTools) => includeTools ? Self + Tools : Self;

    public TrafficSplit Add(TrafficSplit other) => new(Self + other.Self, Tools + other.Tools);

    public static TrafficSplit operator +(TrafficSplit a, TrafficSplit b) => a.Add(b);
}

/// <summary>
/// Bytes counted since the traffic engine started, without the deltas of gap samples (METRICS 11.4): each source's own and
/// tool processes (the machine series is never reported). Live reporting takes differences of it; a new engine has a new
/// <see cref="Epoch"/>, so a difference never spans two of them.
/// </summary>
public sealed record TrafficReportTotals(long Epoch, IReadOnlyDictionary<SourceKind, TrafficSplit> Sources)
{
    public static TrafficReportTotals Zero { get; } = new(0, new Dictionary<SourceKind, TrafficSplit>());
}

/// <summary>One source's traffic (METRICS 10.7, 10.8).</summary>
/// <param name="Unassigned">The part of today's bytes (self and tools) not attributed to an agent tree (METRICS 10.6).</param>
/// <param name="LiveWithTools">Live rate with tools; null before two samples exist (METRICS 10.7).</param>
public sealed record SourceTraffic(
    SourceKind Source,
    TrafficSplit Today,
    TrafficBytes Unassigned,
    TrafficRate? LiveWithTools,
    TrafficRate? LiveSelf)
{
    public TrafficRate? Live(bool includeTools) => includeTools ? LiveWithTools : LiveSelf;
}

/// <summary>One agent tree's traffic (METRICS 10.6, 10.8), keyed by the root agent's id. Memory only.</summary>
public sealed record AgentTraffic(string AgentId, TrafficSplit Today, TrafficRate? LiveWithTools, TrafficRate? LiveSelf)
{
    public TrafficRate? Live(bool includeTools) => includeTools ? LiveWithTools : LiveSelf;
}

/// <summary>One second of traffic for sparklines (METRICS 10.7 history buffer).</summary>
/// <param name="Time">Start of the one-second bucket.</param>
public readonly record struct TrafficPoint(DateTimeOffset Time, TrafficRate Rate);

/// <summary>Why per-process traffic cannot be measured (METRICS 10.3; DESIGN 10 <c>traffic.unavailable.*</c>).</summary>
public enum TrafficUnavailableReason
{
    /// <summary>The sampler failed (macOS nettop; Windows: an unexpected helper error).</summary>
    Sampler,

    HelperMissing,

    HelperStopped,

    HelperOutdated,

    Denied,
}

public enum ProcessTrafficKind
{
    /// <summary>Measuring is off.</summary>
    Off,

    /// <summary>Started; the first sample has not arrived yet.</summary>
    Starting,

    /// <summary>No agent process is running, so per-process sampling is stopped (METRICS 10.10); values are real zeros.</summary>
    Standby,

    Running,

    Unavailable,
}

/// <summary>The per-process sampler's state (METRICS 10.3, 10.10).</summary>
/// <param name="Interval">Seconds between samples while <see cref="ProcessTrafficKind.Running"/>.</param>
public readonly record struct ProcessTrafficState(ProcessTrafficKind Kind, int Interval = 0, TrafficUnavailableReason? Reason = null)
{
    public static ProcessTrafficState Off => new(ProcessTrafficKind.Off);

    public static ProcessTrafficState Starting => new(ProcessTrafficKind.Starting);

    public static ProcessTrafficState Standby => new(ProcessTrafficKind.Standby);

    public static ProcessTrafficState Running(int interval) => new(ProcessTrafficKind.Running, interval);

    public static ProcessTrafficState Unavailable(TrafficUnavailableReason reason) => new(ProcessTrafficKind.Unavailable, 0, reason);

    /// <summary>Per-source and per-agent values can be shown (as opposed to <c>–</c> with a reason).</summary>
    public bool IsAvailable => Kind is ProcessTrafficKind.Starting or ProcessTrafficKind.Standby or ProcessTrafficKind.Running;

    public TrafficUnavailableReason? UnavailableReason => Kind == ProcessTrafficKind.Unavailable ? Reason : null;
}

/// <summary>Everything the UI shows about network traffic (METRICS 10.7, 10.8), published once per tick.</summary>
public sealed record TrafficSnapshot
{
    public static IReadOnlyDictionary<SourceKind, SourceTraffic> NoSources { get; } = new Dictionary<SourceKind, SourceTraffic>();

    public static IReadOnlyDictionary<string, AgentTraffic> NoAgents { get; } = new Dictionary<string, AgentTraffic>();

    public static IReadOnlyDictionary<SourceKind, IReadOnlyList<TrafficPoint>> NoHistory { get; } =
        new Dictionary<SourceKind, IReadOnlyList<TrafficPoint>>();

    public static TrafficSnapshot Off { get; } = new() { Enabled = false, ProcessState = ProcessTrafficState.Off };

    public DateTimeOffset Timestamp { get; init; } = DateTimeOffset.MinValue;

    /// <summary><c>trafficEnabled</c> (DESIGN 10); everything else is empty while off.</summary>
    public bool Enabled { get; init; }

    /// <summary>This computer's live rate; null before two samples exist.</summary>
    public TrafficRate? MachineLive { get; init; }

    public TrafficBytes MachineToday { get; init; }

    /// <summary>Sum of machine sample intervals ≤ 15 s today (METRICS 10.8).</summary>
    public long MachineSampledMs { get; init; }

    /// <summary>The last 300 one-second buckets of this computer's traffic, oldest first.</summary>
    public IReadOnlyList<TrafficPoint> MachineHistory { get; init; } = [];

    /// <summary>The last 300 one-second buckets per source (self + tools), oldest first.</summary>
    public IReadOnlyDictionary<SourceKind, IReadOnlyList<TrafficPoint>> SourceHistory { get; init; } = NoHistory;

    public ProcessTrafficState ProcessState { get; init; } = ProcessTrafficState.Off;

    /// <summary>The per-process sampler's last failure text (a Win32 message) while it is unavailable; null otherwise.</summary>
    public string? ProcessError { get; init; }

    /// <summary>Sum of process sample intervals ≤ 15 s today (METRICS 10.8).</summary>
    public long ProcessSampledMs { get; init; }

    /// <summary>Every source with traffic today or now.</summary>
    public IReadOnlyDictionary<SourceKind, SourceTraffic> Sources { get; init; } = NoSources;

    /// <summary>Agent trees with attributed traffic today, by root agent id.</summary>
    public IReadOnlyDictionary<string, AgentTraffic> Agents { get; init; } = NoAgents;

    /// <summary>Local midnight at which "today" starts.</summary>
    public DateTimeOffset DayStart { get; init; } = DateTimeOffset.MinValue;

    /// <summary>Live reporting's cumulative bytes (METRICS 11.4).</summary>
    public TrafficReportTotals ReportTotals { get; init; } = TrafficReportTotals.Zero;

    /// <summary>
    /// The summed live rate of <paramref name="sources"/> (all sources when null); null when per-process data is
    /// unavailable or no sample pair exists yet.
    /// </summary>
    public TrafficRate? Live(SourceSet? sources, bool includeTools)
    {
        if (!ProcessState.IsAvailable)
        {
            return null;
        }

        TrafficRate? total = null;
        foreach (var (kind, traffic) in Sources)
        {
            if ((sources is null || sources.Value.Contains(kind)) && traffic.Live(includeTools) is { } rate)
            {
                total = (total ?? TrafficRate.Zero) + rate;
            }
        }

        if (total is null && MachineLive is not null)
        {
            return TrafficRate.Zero;
        }

        return total;
    }

    /// <summary>Today's bytes of <paramref name="sources"/> (all sources when null).</summary>
    public TrafficBytes Today(SourceSet? sources, bool includeTools)
    {
        var sum = TrafficBytes.Zero;
        foreach (var (kind, traffic) in Sources)
        {
            if (sources is null || sources.Value.Contains(kind))
            {
                sum += traffic.Today.Total(includeTools);
            }
        }

        return sum;
    }
}

/// <summary>One stored day of traffic (METRICS 10.9 <c>day_traffic</c>): <see cref="Key"/> is <c>machine</c> or a source name.</summary>
/// <param name="Day">Local date <c>yyyy-MM-dd</c>.</param>
/// <param name="Rx">Self bytes for a source, all bytes for <c>machine</c>.</param>
/// <param name="RxTools">Tool bytes (0 for <c>machine</c>).</param>
/// <param name="SampledMs">Machine <c>sampledMs</c> on the machine row, <c>processSampledMs</c> on source rows.</param>
public sealed record TrafficDay(string Day, string Key, long Rx, long Tx, long RxTools, long TxTools, long SampledMs)
{
    public const string MachineKey = "machine";

    public bool IsMachine => Key == MachineKey;

    public SourceKind? Source => History.SourceNames.Parse(Key);

    public TrafficBytes Total(bool includeTools) => includeTools ? new TrafficBytes(Rx + RxTools, Tx + TxTools) : new TrafficBytes(Rx, Tx);
}

using System.Collections.Concurrent;
using System.Diagnostics;
using AgentSpeed.Core.Traffic.Engine;

namespace AgentSpeed.Core.Traffic.Monitor;

/// <summary>
/// Runs traffic sampling on one background thread (METRICS 10): a 1 Hz tick reads the machine counters, refreshes the
/// process table, polls the per-process counter source at the adaptive cadence, publishes a snapshot and keeps the
/// stored days. Every mutable field is only touched on that thread; commands are queued to it.
/// </summary>
internal sealed class TrafficCore : IDisposable
{
    public const int TickMs = 1000;

    /// <summary>While per-process sampling is stopped the table is only needed to notice agent processes (METRICS 10.10).</summary>
    public const long StandbyTableRefreshMs = 2000;

    /// <summary>
    /// While sampling with no agent active (only a visible surface asks for detail), the full listing runs this often,
    /// and at once whenever a counter row names a process the table does not know yet.
    /// </summary>
    public const long QuietTableRefreshMs = 5000;

    private readonly TrafficPlatform _platform;
    private readonly IProcessLister _lister;
    private readonly IMachineCounterReader _machine;
    private readonly IProcessCounterSource? _counters;
    private readonly Action<TrafficSnapshot> _publish;
    private readonly Action<IReadOnlyList<TrafficDay>, string?> _publishDays;
    private readonly Action<string> _log;
    private readonly TimeZoneInfo? _zone;
    private readonly Func<long> _monotonicMs;
    private readonly Func<long> _wallMs;
    private readonly TrafficHistoryKeeper _history;
    private readonly ConcurrentQueue<Action> _commands = new();
    private readonly AutoResetEvent _wake = new(false);
    private readonly List<ProcessEntry> _entries = new(512);
    private readonly Dictionary<ulong, TrafficCounter> _interfaces = new();
    private Thread? _thread;
    private volatile bool _stopping;

    private TrafficEngine _engine;
    private bool _enabled;
    private IReadOnlyList<AgentStatus>? _pendingAgents;
    private IReadOnlyList<AgentStatus>? _appliedAgents;
    private List<TrafficAgent> _agents = [];
    private volatile bool _detailDemand;
    private volatile bool _sourceHistory;
    private int? _forcedInterval;
    private int _knownStream = int.MinValue;
    private long _streamStartUs;
    private long? _lastTableRefreshMs;
    private long? _lastFetchMs;
    private long? _lastActiveWallMs;
    private bool _standby;
    private bool _hasSampled;
    private int _interval = TrafficCadence.FastInterval;
    private string? _lastDay;
    private long _ticks;
    private long _tickTicks;
    private long _firstTickTicks;
    private readonly long[] _phaseTicks = new long[TrafficDiagnostics.PhaseNames.Count];
    private bool _threadExited = true;
    private readonly HashSet<ProcessIdentity> _unlisted = [];

    public TrafficCore(
        string storePath,
        TrafficPlatform platform,
        IProcessLister lister,
        IMachineCounterReader machine,
        IProcessCounterSource? counters,
        Action<TrafficSnapshot> publish,
        Action<IReadOnlyList<TrafficDay>, string?> publishDays,
        Action<string>? log = null,
        TimeZoneInfo? zone = null,
        Func<long>? monotonicMs = null,
        Func<long>? wallMs = null)
    {
        _platform = platform;
        _lister = lister;
        _machine = machine;
        _counters = counters;
        _publish = publish;
        _publishDays = publishDays;
        _log = log ?? (_ => { });
        _zone = zone;
        _monotonicMs = monotonicMs ?? (() => Environment.TickCount64);
        _wallMs = wallMs ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        _history = new TrafficHistoryKeeper(storePath, _log);
        _engine = new TrafficEngine(platform, zone);
    }

    // ---- Commands (any thread) ----

    public void Start(bool enabled)
    {
        if (_thread is not null)
        {
            SetEnabled(enabled);
            return;
        }

        Post(() =>
        {
            _history.Load();
            _history.DeferWrites(_monotonicMs());
            PublishDays(force: true);
            SetEnabledOnThread(enabled);
        });
        _thread = new Thread(Run) { IsBackground = true, Name = "Agent Speed traffic", Priority = ThreadPriority.BelowNormal };
        _thread.Start();
    }

    public void SetEnabled(bool enabled) => Post(() => SetEnabledOnThread(enabled));

    /// <summary>The agents of every speed snapshot (METRICS 6.7); read once per tick.</summary>
    public void UpdateAgents(IReadOnlyList<AgentStatus> agents) => Volatile.Write(ref _pendingAgents, agents);

    /// <summary>A visible surface shows per-source or per-agent traffic (METRICS 10.10: sample every second).</summary>
    public void SetDetailDemand(bool shown) => _detailDemand = shown;

    /// <summary>Also publish the per-source sparkline buckets.</summary>
    public void SetSourceHistory(bool wanted) => _sourceHistory = wanted;

    /// <summary>Diagnostics: a fixed interval in seconds (0 forces standby); null restores the adaptive cadence.</summary>
    public void SetForcedInterval(int? seconds) => Post(() => _forcedInterval = seconds);

    public void Retry() => Post(() => _counters?.Retry());

    /// <summary>Synchronous: no write is in flight when it returns and today starts over.</summary>
    public void ClearHistory() => Send(() =>
    {
        var now = _monotonicMs();
        _engine.ResetToday();
        if (_engine.CurrentDay is { } day)
        {
            _engine.Ledger.DropExcept(day);
        }

        _history.Clear(now);
        PublishDays(force: true);
    });

    /// <summary>Synchronous write of today's totals (before sleep).</summary>
    public void Flush() => Send(() =>
    {
        if (_enabled)
        {
            WriteToday();
        }
    });

    /// <summary>Synchronous: final write, the counter source released, the thread stopped.</summary>
    public void Stop()
    {
        if (_thread is null)
        {
            return;
        }

        Send(() =>
        {
            if (_enabled)
            {
                WriteToday();
            }

            _enabled = false;
            _counters?.Poll(false, false, _monotonicMs());
        });
        _stopping = true;
        _wake.Set();
        _threadExited = _thread.Join(TimeSpan.FromSeconds(5));
        _thread = null;
    }

    public void Dispose()
    {
        Stop();
        _counters?.Dispose();
        if (_threadExited)
        {
            // Their native buffers may only go once no tick can use them.
            (_machine as IDisposable)?.Dispose();
            (_lister as IDisposable)?.Dispose();
        }

        _wake.Dispose();
    }

    /// <summary>Tests: loads the store and applies <paramref name="enabled"/> on the caller's thread (no background thread).</summary>
    internal void StartInline(bool enabled)
    {
        _history.Load();
        _history.DeferWrites(_monotonicMs());
        PublishDays(force: true);
        SetEnabledOnThread(enabled);
    }

    /// <summary>Tests: one tick on the caller's thread.</summary>
    internal void TickInline() => Tick();

    /// <summary>Tests: switches measuring on the caller's thread.</summary>
    internal void SetEnabledInline(bool enabled) => SetEnabledOnThread(enabled);

    /// <summary>Diagnostics for the probe (runs on the traffic thread).</summary>
    public TrafficDiagnostics Diagnostics()
    {
        TrafficDiagnostics? result = null;
        Send(() => result = BuildDiagnostics());
        return result ?? new TrafficDiagnostics([], [], 0, [], 0, 0, 0, null);
    }

    private void Post(Action action)
    {
        _commands.Enqueue(action);
        _wake.Set();
    }

    /// <summary>Runs <paramref name="action"/> on the traffic thread and waits (at most 5 s); runs inline before the thread starts.</summary>
    private void Send(Action action)
    {
        if (_thread is null || Thread.CurrentThread == _thread)
        {
            action();
            return;
        }

        using var done = new ManualResetEventSlim(false);
        Post(() =>
        {
            try
            {
                action();
            }
            finally
            {
                done.Set();
            }
        });
        done.Wait(TimeSpan.FromSeconds(5));
    }

    // ---- Thread ----

    private void Run()
    {
        var nextTick = _monotonicMs();
        while (!_stopping)
        {
            while (_commands.TryDequeue(out var command))
            {
                Guard(command);
            }

            if (_stopping)
            {
                break;
            }

            var now = _monotonicMs();
            if (_enabled && now >= nextTick)
            {
                Guard(Tick);
                // A late tick (sleep, a stalled thread) does not catch up with a burst.
                nextTick = Math.Max(nextTick + TickMs, _monotonicMs() + 200);
                if (nextTick - _monotonicMs() > TickMs)
                {
                    nextTick = _monotonicMs() + TickMs;
                }
            }

            var wait = _enabled ? Math.Clamp(nextTick - _monotonicMs(), 1, TickMs) : Timeout.Infinite;
            _wake.WaitOne((int)wait);
            if (!_enabled)
            {
                nextTick = _monotonicMs();
            }
        }
    }

    private void Guard(Action action)
    {
        try
        {
            action();
        }
        catch (Exception e)
        {
            // Never let sampling take the app down; the next tick tries again.
            _log($"Traffic tick failed: {e.GetType().Name}: {e.Message}");
        }
    }

    private void SetEnabledOnThread(bool on)
    {
        if (on == _enabled)
        {
            return;
        }

        _enabled = on;
        if (on)
        {
            Begin();
            return;
        }

        WriteToday();
        _counters?.Poll(false, false, _monotonicMs());
        _publish(TrafficSnapshot.Off);
    }

    /// <summary>A fresh engine; today's totals come back from the store (METRICS 10.4.3, 10.8).</summary>
    private void Begin()
    {
        _engine = new TrafficEngine(_platform, _zone);
        _engine.SetAgents(_agents);
        var wall = _wallMs();
        var today = _engine.Ledger.Label(wall);
        _engine.Restore(today, _history.StoredRows(today));
        _lastDay = today;
        _knownStream = int.MinValue;
        _lastTableRefreshMs = null;
        _lastFetchMs = null;
        _lastActiveWallMs = wall;
        _standby = false;
        _hasSampled = false;
    }

    private void Tick()
    {
        var started = Stopwatch.GetTimestamp();
        var t = _monotonicMs();
        var wall = _wallMs();
        ApplyAgents();

        var mark = started;
        var listed = NeedsTable && TableDue(t, wall);
        if (listed)
        {
            RefreshTable(t, ref mark);
        }

        var counters = PollCounters(t, wall);
        Phase(2, ref mark);
        if (!listed && NeedsTable && !_standby && NamesUnknownProcess(counters))
        {
            RefreshTable(t, ref mark);
        }

        if (counters is not null)
        {
            RememberUnlisted(counters);
        }

        IReadOnlyDictionary<ulong, TrafficCounter>? interfaces = _machine.Read(_interfaces) ? _interfaces : null;
        Phase(3, ref mark);
        _engine.Tick(new TrafficSample(t, wall, null, interfaces, counters), _lister);
        Phase(4, ref mark);

        Persist(t);
        Phase(5, ref mark);
        _publish(TrafficSnapshotBuilder.Build(_engine, wall, ProcessState, _sourceHistory, _counters?.LastError));
        Phase(6, ref mark);

        var spent = Stopwatch.GetTimestamp() - started;
        if (_ticks == 0)
        {
            _firstTickTicks = spent;
        }
        else
        {
            _tickTicks += spent;
        }

        _ticks++;
    }

    /// <summary>
    /// The process table only matters when per-process counters can arrive: without the helper (not installed, outdated,
    /// refused) nothing is attributed, so the listing — most of the sampling cost — is skipped until that changes (the
    /// source re-checks at least every 30 s; the first sample of a new stream is a baseline, so nothing is lost).
    /// </summary>
    private bool NeedsTable => _counters?.Status is not (null or ProcessCounterStatus.HelperNotInstalled or ProcessCounterStatus.HelperOutdated
        or ProcessCounterStatus.HelperDenied);

    /// <summary>
    /// The process listing is most of the sampling cost (METRICS 10.10). Before the counters it runs every tick while an
    /// agent is active (its tools come and go then), every <see cref="StandbyTableRefreshMs"/> in standby and otherwise
    /// every <see cref="QuietTableRefreshMs"/>; after them, at once when a row names an unknown process (see
    /// <see cref="NamesUnknownProcess"/>).
    /// </summary>
    private bool TableDue(long t, long wall)
    {
        if (_lastTableRefreshMs is not { } last)
        {
            return true;
        }

        var since = t - last;
        if (_standby)
        {
            return since >= StandbyTableRefreshMs;
        }

        return since >= QuietTableRefreshMs || (_lastActiveWallMs is { } active && wall - active < TrafficCadence.IdleAfterMs);
    }

    /// <summary>
    /// A row arrives the tick a process first uses the network, so listing then finds it still running, as a listing every
    /// tick would; rows of processes a listing already missed (they had exited) do not ask again.
    /// </summary>
    private bool NamesUnknownProcess(CounterSample? counters)
    {
        if (counters is null)
        {
            return false;
        }

        foreach (var row in counters.Rows)
        {
            if (_engine.Table.Find(row.Identity) is null && !_unlisted.Contains(row.Identity))
            {
                return true;
            }
        }

        return false;
    }

    private void RememberUnlisted(CounterSample counters)
    {
        _unlisted.Clear();
        foreach (var row in counters.Rows)
        {
            if (_engine.Table.Find(row.Identity) is null)
            {
                _unlisted.Add(row.Identity);
            }
        }
    }

    private void RefreshTable(long t, ref long mark)
    {
        var listed = _lister.List(_entries);
        Phase(0, ref mark);
        if (listed)
        {
            _engine.Table.Refresh(_entries, _lister, t);
        }

        Phase(1, ref mark);
        _lastTableRefreshMs = t;
    }

    /// <summary>Adds the time since <paramref name="mark"/> to a phase of the tick (diagnostics; the first tick is left out).</summary>
    private void Phase(int index, ref long mark)
    {
        var now = Stopwatch.GetTimestamp();
        if (_ticks > 0)
        {
            _phaseTicks[index] += now - mark;
        }

        mark = now;
    }

    private void ApplyAgents()
    {
        var pending = Volatile.Read(ref _pendingAgents);
        if (pending is null || ReferenceEquals(pending, _appliedAgents))
        {
            return;
        }

        _appliedAgents = pending;
        var converted = pending.Select(TrafficAgent.From).ToList();
        if (!converted.SequenceEqual(_agents))
        {
            _agents = converted;
            _engine.SetAgents(converted);
        }
    }

    private CounterSample? PollCounters(long t, long wall)
    {
        if (TrafficCadence.LastActive(_agents, wall) is { } active && active > (_lastActiveWallMs ?? long.MinValue))
        {
            _lastActiveWallMs = active;
        }

        var desired = TrafficCadence.DesiredInterval(_engine.Table.HasAgentProcess, _lastActiveWallMs, wall, _detailDemand, _forcedInterval);
        if (_counters is null)
        {
            _standby = desired is null;
            return null;
        }

        if (desired is not { } interval)
        {
            _standby = true;
            _hasSampled = false;
            _lastFetchMs = null;
            _counters.Poll(false, false, t);
            return new CounterSample(_counters.Stream, [], IsStandby: true);
        }

        _standby = false;
        _interval = interval;
        var fetch = _lastFetchMs is not { } lastFetch || t - lastFetch >= interval * 1000L - 100;
        var rows = _counters.Poll(true, fetch, t);
        if (_counters.Stream != _knownStream)
        {
            _knownStream = _counters.Stream;
            _streamStartUs = wall * 1000;
            _hasSampled = false;
        }

        if (rows is null)
        {
            return null;
        }

        _lastFetchMs = t;
        _hasSampled = true;
        return new CounterSample(_knownStream, rows, StreamStartUs: _streamStartUs);
    }

    private ProcessTrafficState ProcessState
    {
        get
        {
            if (_counters is null)
            {
                return ProcessTrafficState.Unavailable(TrafficUnavailableReason.Sampler);
            }

            return _counters.Status switch
            {
                ProcessCounterStatus.HelperNotInstalled => ProcessTrafficState.Unavailable(TrafficUnavailableReason.HelperMissing),
                ProcessCounterStatus.HelperOutdated => ProcessTrafficState.Unavailable(TrafficUnavailableReason.HelperOutdated),
                ProcessCounterStatus.HelperDenied => ProcessTrafficState.Unavailable(TrafficUnavailableReason.Denied),
                ProcessCounterStatus.HelperStopped => ProcessTrafficState.Unavailable(TrafficUnavailableReason.HelperStopped),
                ProcessCounterStatus.HelperError or ProcessCounterStatus.SamplerFailed => ProcessTrafficState.Unavailable(TrafficUnavailableReason.Sampler),
                _ when _standby => ProcessTrafficState.Standby,
                ProcessCounterStatus.Sampling => ProcessTrafficState.Running(_interval),
                _ when _hasSampled => ProcessTrafficState.Running(_interval),
                _ => ProcessTrafficState.Starting,
            };
        }
    }

    // ---- Days ----

    private void Persist(long t)
    {
        if (_engine.CurrentDay is not { } day)
        {
            return;
        }

        if (_lastDay is { } lastDay && lastDay != day)
        {
            // The finished day's final rows, then today's (METRICS 10.9 writes at the day change).
            var rows = _engine.Ledger.Totals(lastDay)?.Rows(lastDay) ?? [];
            rows.AddRange(TodayRows());
            _history.Write(rows, t);
            _engine.Ledger.DropExcept(day);
            _lastDay = day;
            PublishDays(force: true);
            return;
        }

        _lastDay = day;
        if (_history.IsWriteDue(t))
        {
            WriteToday();
        }

        PublishDays(force: false);
    }

    private List<TrafficDay> TodayRows() =>
        _engine.CurrentDay is { } day && _engine.Ledger.Totals(day) is { } totals ? totals.Rows(day) : [];

    private void WriteToday() => _history.Write(TodayRows(), _monotonicMs());

    private void PublishDays(bool force)
    {
        var today = _engine.CurrentDay ?? _engine.Ledger.Label(_wallMs());
        if (_history.DaysToPublish(today, TodayRows(), _monotonicMs(), force) is { } published)
        {
            _publishDays(published.Days, published.Since);
        }
    }

    // ---- Diagnostics ----

    private TrafficDiagnostics BuildDiagnostics()
    {
        var table = _engine.Table;
        var processes = table.Records.Values
            .Where(r => r.Class is not null)
            .OrderBy(r => r.Entry.Identity)
            .Select(r => new TrafficDiagnostics.Process(r.Entry.Pid, r.Executable, r.Class!.Value.Source, r.Class.Value.Role.ToString().ToLowerInvariant(),
                r.Class.Value.Root.Pid, r.Alive))
            .ToList();
        var roots = _engine.RootTotals
            .OrderBy(e => e.Key)
            .Select(e => new TrafficDiagnostics.Root(e.Key.Pid, table.ClassOf(e.Key)?.Source, e.Value.Split.Self, e.Value.Split.Tools,
                e.Value.Assigned.ToDictionary(a => a.Key, a => a.Value.Self + a.Value.Tools, StringComparer.Ordinal)))
            .ToList();
        var frequency = (double)Stopwatch.Frequency;
        return new TrafficDiagnostics(
            processes,
            roots,
            table.Records.Count,
            _machine.CountedNames,
            _ticks,
            _ticks > 0 ? _firstTickTicks / frequency * 1e6 : 0,
            _ticks > 1 ? _tickTicks / (double)(_ticks - 1) / frequency * 1e6 : 0,
            _counters?.LastError)
        {
            PhaseMicros = _phaseTicks.Select(p => _ticks > 1 ? p / (double)(_ticks - 1) / frequency * 1e6 : 0).ToArray(),
        };
    }
}

/// <summary>What the probe prints about attribution and cost.</summary>
public sealed record TrafficDiagnostics(
    IReadOnlyList<TrafficDiagnostics.Process> Processes,
    IReadOnlyList<TrafficDiagnostics.Root> Roots,
    int TableSize,
    IReadOnlyList<string> CountedInterfaces,
    long Ticks,
    double FirstTickMicros,
    double AverageTickMicros,
    string? LastError)
{
    /// <summary>The parts of a tick <see cref="PhaseMicros"/> times.</summary>
    public static IReadOnlyList<string> PhaseNames { get; } = ["list", "table", "counters", "machine", "engine", "persist", "snapshot"];

    /// <summary>Average wall time per tick of each of <see cref="PhaseNames"/>, µs (the first tick left out).</summary>
    public IReadOnlyList<double> PhaseMicros { get; init; } = [];

    /// <param name="Role"><c>agent</c>, <c>self</c> or <c>tool</c>.</param>
    public sealed record Process(int Pid, string Executable, SourceKind Source, string Role, int RootPid, bool Alive);

    /// <summary>Bytes of one root agent process since sampling started and the agent trees they went to ("" = unassigned).</summary>
    public sealed record Root(int Pid, SourceKind? Source, TrafficBytes Self, TrafficBytes Tools, IReadOnlyDictionary<string, TrafficBytes> Assigned);
}

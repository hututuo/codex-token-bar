using System.Diagnostics;
using AgentSpeed.Core.Antigravity;
using AgentSpeed.Core.IO;
using AgentSpeed.Core.Monitoring;
using AgentSpeed.Core.Omp;
using AgentSpeed.Core.Pricing;
using AgentSpeed.Core.WorkBuddy;

namespace AgentSpeed.Core;

/// <summary>Reads local agent transcripts on background threads and publishes snapshots to a <see cref="SpeedHub"/>.</summary>
public sealed class LiveMonitor : IDisposable
{
    private static readonly TimeSpan PublishInterval = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan ChangePublishMinInterval = TimeSpan.FromMilliseconds(100);
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan DiscoveryInterval = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(80);
    private static readonly TimeSpan SeedPublishInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan TimeZoneRefreshInterval = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan ErrorBackoff = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan MaxSessionBackoff = TimeSpan.FromMinutes(1);
    private const int MaxPendingPaths = 10_000;

    private readonly SpeedHub _hub;
    private readonly object _gate = new();
    private readonly object _pendingGate = new();
    private readonly AutoResetEvent _wake = new(false);
    private HashSet<string> _pendingPaths = new(StringComparer.Ordinal);
    private long _pendingSince;
    private bool _rescanRequested;
    private MonitorConfiguration _configuration;
    private SourceSet[] _subsets = [];
    private int _subsetsChanged;
    private Thread? _thread;
    private CancellationTokenSource? _stop;
    private CancellationTokenSource? _session;
    private bool _disposed;

    /// <param name="pricing">Prices every response (METRICS 9); null leaves costs unknown.</param>
    public LiveMonitor(SpeedHub hub, MonitorConfiguration? configuration = null, PriceBook? pricing = null)
    {
        ArgumentNullException.ThrowIfNull(hub);
        _hub = hub;
        _configuration = configuration ?? MonitorConfiguration.Default;
        Pricing = pricing;
    }

    public PriceBook? Pricing { get; }

    /// <summary>Runs on the pool thread before each background whole-file read (tests make reads slow with it).</summary>
    internal Action<string>? BeforeBackgroundRead { get; set; }

    public MonitorConfiguration Configuration
    {
        get
        {
            lock (_gate)
            {
                return _configuration;
            }
        }
    }

    public static string DefaultCodexRoot
    {
        get
        {
            var home = Environment.GetEnvironmentVariable("CODEX_HOME");
            return string.IsNullOrEmpty(home)
                ? Path.Combine(UserHome, ".codex", "sessions")
                : Path.Combine(home, "sessions");
        }
    }

    public static string DefaultClaudeRoot
    {
        get
        {
            var dir = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            return string.IsNullOrEmpty(dir)
                ? Path.Combine(UserHome, ".claude", "projects")
                : Path.Combine(dir, "projects");
        }
    }

    public static string DefaultDshRoot
    {
        get
        {
            var home = Environment.GetEnvironmentVariable("DSH_HOME");
            return string.IsNullOrEmpty(home)
                ? Path.Combine(UserHome, ".dsh", "sessions")
                : Path.Combine(home, "sessions");
        }
    }

    /// <summary><c>%XDG_DATA_HOME%\opencode</c>, else <c>~/.local/share/opencode</c> (the folder that contains opencode.db).</summary>
    public static string DefaultOpenCodeRoot
    {
        get
        {
            var data = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
            return string.IsNullOrEmpty(data)
                ? Path.Combine(UserHome, ".local", "share", "opencode")
                : Path.Combine(data, "opencode");
        }
    }

    /// <summary><c>&lt;home&gt;/.gemini/tmp</c>, where home is <c>%GEMINI_CLI_HOME%</c>, else the user profile.</summary>
    public static string DefaultGeminiRoot => Path.Combine(GeminiHome, ".gemini", "tmp");

    /// <summary>Every default Gemini CLI root; on macOS also the seatbelt sandbox root (METRICS 2).</summary>
    internal static IReadOnlyList<string> DefaultGeminiRoots => OperatingSystem.IsMacOS()
        ? [DefaultGeminiRoot, Path.Combine(GeminiHome, ".cache", ".gemini", "tmp")]
        : [DefaultGeminiRoot];

    /// <summary>
    /// The default omp <c>sessions</c> folder (<c>%PI_CODING_AGENT_DIR%\sessions</c>, else <c>~/.omp/agent/sessions</c>);
    /// unless a folder is chosen, every named profile's root is read as well (METRICS 2, 4.7).
    /// </summary>
    public static string DefaultOmpRoot => OmpPaths.DefaultRoot();

    /// <summary>The default omp root followed by one root per named profile.</summary>
    internal static IReadOnlyList<string> DefaultOmpRoots => OmpPaths.AutomaticRoots();

    /// <summary>The three Antigravity stores below <c>~/.gemini</c>: CLI, desktop app, IDE (METRICS 2, 4.8).</summary>
    public static IReadOnlyList<string> DefaultAntigravityStores => AntigravityPaths.DefaultStores(Path.Combine(UserHome, ".gemini"));

    /// <summary>The Antigravity folders read for a setting (null: the default stores); a <c>*-backup</c> store is never read.</summary>
    public static IReadOnlyList<string> AntigravityStores(string? setting) =>
        AntigravityPaths.Stores(Path.Combine(UserHome, ".gemini"), setting);

    /// <summary>The WorkBuddy (China edition) data folder, <c>~/.workbuddy</c>; transcripts are in its <c>projects</c> folder (METRICS 4.9).</summary>
    public static string DefaultWorkBuddyFolder => WorkBuddyPaths.DefaultDataFolder(SourceKind.WorkBuddy, UserHome);

    /// <summary>The WorkBuddy AI (international edition) data folder, <c>~/.workbuddy-ai</c> (METRICS 4.9).</summary>
    public static string DefaultWorkBuddyAiFolder => WorkBuddyPaths.DefaultDataFolder(SourceKind.WorkBuddyAi, UserHome);

    /// <summary>
    /// The data folder a WorkBuddy row names (DESIGN 5): the default one, else the chosen folder, or the parent of a chosen
    /// <c>projects</c> folder.
    /// </summary>
    public static string WorkBuddyDataFolder(SourceKind source, string? setting) =>
        string.IsNullOrWhiteSpace(setting)
            ? WorkBuddyPaths.DefaultDataFolder(source, UserHome)
            : WorkBuddyPaths.DataFolderOf(setting);

    public static string DefaultZCodeRoot
    {
        get
        {
            var baseDir = Environment.GetEnvironmentVariable("ZCODE_DATA_BASE_DIR");
            return Path.Combine(string.IsNullOrWhiteSpace(baseDir) ? UserHome : baseDir, ".zcode", "cli", "db");
        }
    }

    public static string DefaultKimiRoot => Path.Combine(
        Environment.GetEnvironmentVariable("KIMI_CODE_HOME") is { Length: > 0 } home ? home : Path.Combine(UserHome, ".kimi-code"), "sessions");

    public static string DefaultGrokBuildRoot => Path.Combine(
        Environment.GetEnvironmentVariable("GROK_HOME") is { Length: > 0 } home ? home : Path.Combine(UserHome, ".grok"), "sessions");

    private static string GeminiHome
    {
        get
        {
            var home = Environment.GetEnvironmentVariable("GEMINI_CLI_HOME");
            return string.IsNullOrEmpty(home) ? UserHome : home;
        }
    }

    private static string UserHome => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public void Start()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_thread is not null)
            {
                return;
            }

            var stop = new CancellationTokenSource();
            _stop = stop;
            _thread = new Thread(() => Run(stop.Token))
            {
                IsBackground = true,
                Name = "Agent Speed monitor",
                Priority = ThreadPriority.BelowNormal,
            };
            _thread.Start();
        }
    }

    public void Stop()
    {
        Thread? thread;
        CancellationTokenSource? stop;
        lock (_gate)
        {
            thread = _thread;
            stop = _stop;
            _thread = null;
            _stop = null;
        }

        if (thread is null || stop is null)
        {
            return;
        }

        stop.Cancel();
        SignalWake();
        if (thread != Thread.CurrentThread && thread.Join(TimeSpan.FromSeconds(5)))
        {
            stop.Dispose();
        }

        lock (_pendingGate)
        {
            _pendingPaths = new HashSet<string>(StringComparer.Ordinal);
            _pendingSince = 0;
            _rescanRequested = false;
        }
    }

    /// <summary>Source sets whose measured peak today every snapshot reports in <see cref="SpeedSnapshot.SubsetPeaks"/>.</summary>
    public IReadOnlyCollection<SourceSet> Subsets => Volatile.Read(ref _subsets).AsReadOnly();

    /// <summary>
    /// Requests <see cref="SpeedSnapshot.SubsetPeaks"/> for these sets (one per floating orb that tracks a subset,
    /// METRICS 6.8). Callable from any thread, also before <see cref="Start"/>; kept across configuration changes. A
    /// running monitor publishes a fresh snapshot promptly when the sets change.
    /// </summary>
    public void SetSubsets(IReadOnlyCollection<SourceSet> sets)
    {
        ArgumentNullException.ThrowIfNull(sets);
        var next = sets.Distinct().ToArray();
        lock (_gate)
        {
            var current = _subsets;
            if (current.Length == next.Length && current.All(next.Contains))
            {
                return;
            }

            Volatile.Write(ref _subsets, next);
        }

        Interlocked.Exchange(ref _subsetsChanged, 1);
        SignalWake();
    }

    /// <summary>Applies new settings; the monitor re-reads its sources in the background when anything changed.</summary>
    public void Update(MonitorConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        lock (_gate)
        {
            if (configuration.Equals(_configuration))
            {
                return;
            }

            _configuration = configuration;
            try
            {
                _session?.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }
        }

        SignalWake();
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
        }

        Stop();
        _wake.Dispose();
    }

    private void Run(CancellationToken stopToken)
    {
        var backoff = ErrorBackoff;
        while (!stopToken.IsCancellationRequested)
        {
            MonitorConfiguration configuration;
            using var session = CancellationTokenSource.CreateLinkedTokenSource(stopToken);
            lock (_gate)
            {
                configuration = _configuration;
                _session = session;
            }

            try
            {
                RunSession(configuration, session.Token);
            }
            catch (OperationCanceledException) when (session.IsCancellationRequested)
            {
                backoff = ErrorBackoff;
            }
            catch (Exception)
            {
                WaitFor(backoff, stopToken);
                backoff = TimeSpan.FromTicks(Math.Min(backoff.Ticks * 2, MaxSessionBackoff.Ticks));
            }
            finally
            {
                lock (_gate)
                {
                    _session = null;
                }
            }
        }
    }

    private void RunSession(MonitorConfiguration configuration, CancellationToken token)
    {
        var zone = TimeZoneInfo.Local;
        using var core = new MonitorCore(
            configuration, SourceLocations.Resolve(configuration), LocalDay.StartMs(NowMs(), zone), pricing: Pricing, zone: zone);
        core.ReadWholeFilesInBackground = true;
        core.BackgroundReadCompleted = SignalWake;
        core.BeforeBackgroundRead = BeforeBackgroundRead;
        var watchers = new Dictionary<SourceRoot, RootWatcher>();
        try
        {
            ResetPending();
            EnsureWatchers(core, watchers);
            if (!core.AnyEnabledRootAvailable)
            {
                Publish(core, MonitorState.NoSources, zone, observeLive: false);
            }
            else
            {
                var lastSeedPublish = 0L;
                PublishSafely(core.BuildStartingSnapshot(NowMs(), LocalDay.StartMs(NowMs(), zone), 0));
                core.Seed(NowMs(), LocalDay.StartMs(NowMs(), zone), token, progress =>
                {
                    if (Stopwatch.GetElapsedTime(lastSeedPublish) >= SeedPublishInterval)
                    {
                        lastSeedPublish = Stopwatch.GetTimestamp();
                        PublishSafely(core.BuildStartingSnapshot(NowMs(), LocalDay.StartMs(NowMs(), zone), progress));
                    }
                });
                // Seeding decodes hundreds of megabytes; return the freed memory instead of keeping it committed.
                GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
                Publish(core, StateOf(core), zone, observeLive: true);
            }

            Loop(core, watchers, zone, token);
        }
        finally
        {
            foreach (var watcher in watchers.Values)
            {
                watcher.Dispose();
            }
        }
    }

    private void Loop(MonitorCore core, Dictionary<SourceRoot, RootWatcher> watchers, TimeZoneInfo zone, CancellationToken token)
    {
        var start = Stopwatch.GetTimestamp();
        var nextPublish = PublishInterval;
        var nextPoll = PollInterval;
        var nextDiscovery = DiscoveryInterval;
        var nextZoneRefresh = TimeZoneRefreshInterval;
        var lastPublish = TimeSpan.Zero;
        var dirty = false;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var elapsed = Stopwatch.GetElapsedTime(start);
            var due = Min(dirty ? lastPublish + ChangePublishMinInterval : nextPublish, nextPoll, nextDiscovery);
            var pendingDue = PendingDeadline(start);
            if (pendingDue is { } pending && pending < due)
            {
                due = pending;
            }

            var wait = due - elapsed;
            if (wait > TimeSpan.Zero)
            {
                WaitHandle.WaitAny([_wake, token.WaitHandle], wait);
                token.ThrowIfCancellationRequested();
            }

            elapsed = Stopwatch.GetElapsedTime(start);
            var now = NowMs();
            if (elapsed >= nextZoneRefresh)
            {
                TimeZoneInfo.ClearCachedData();
                zone = TimeZoneInfo.Local;
                nextZoneRefresh = elapsed + TimeZoneRefreshInterval;
            }

            var today = LocalDay.StartMs(now, zone);
            var changed = false;
            try
            {
                if (TakeRescanRequest() || elapsed >= nextDiscovery)
                {
                    changed |= core.Rediscover(now, today, token);
                    EnsureWatchers(core, watchers);
                    nextDiscovery = elapsed + DiscoveryInterval;
                }

                changed |= core.ApplyCompletedReads();
                if (TakePendingPaths(start, elapsed) is { } paths)
                {
                    changed |= core.ProcessPaths(paths, now, today);
                }

                if (elapsed >= nextPoll)
                {
                    changed |= core.PollRecent(now);
                    nextPoll = elapsed + PollInterval;
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception)
            {
                WaitFor(ErrorBackoff, token);
            }

            elapsed = Stopwatch.GetElapsedTime(start);
            dirty |= changed | (Interlocked.Exchange(ref _subsetsChanged, 0) != 0);
            if (elapsed >= nextPublish || (dirty && elapsed - lastPublish >= ChangePublishMinInterval))
            {
                Publish(core, StateOf(core), zone, observeLive: true);
                lastPublish = elapsed;
                nextPublish = elapsed + PublishInterval;
                dirty = false;
            }
        }
    }

    private void Publish(MonitorCore core, MonitorState state, TimeZoneInfo zone, bool observeLive)
    {
        var now = NowMs();
        SpeedSnapshot snapshot;
        IReadOnlyList<SpeedEvent> events;
        try
        {
            (snapshot, events) = core.BuildSnapshot(now, LocalDay.StartMs(now, zone), state, observeLive, Volatile.Read(ref _subsets));
        }
        catch (Exception e) when (e is not OperationCanceledException and not OutOfMemoryException)
        {
            return;
        }

        PublishSafely(snapshot, events.Count > 0 ? events : null);
    }

    private void PublishSafely(SpeedSnapshot snapshot, IReadOnlyList<SpeedEvent>? events = null)
    {
        try
        {
            _hub.PublishLive(snapshot, events);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
        }
    }

    private static MonitorState StateOf(MonitorCore core) =>
        core.AnyEnabledRootAvailable ? MonitorState.Running : MonitorState.NoSources;

    private void EnsureWatchers(MonitorCore core, Dictionary<SourceRoot, RootWatcher> watchers)
    {
        var roots = core.WatchRoots.ToArray();
        var current = roots.ToHashSet();
        foreach (var old in watchers.Keys.Where(root => !current.Contains(root)).ToList())
        {
            watchers.Remove(old, out var watcher);
            watcher?.Dispose();
        }

        foreach (var root in roots)
        {
            var wanted = root.Enabled && root.Available;
            if (wanted && !watchers.ContainsKey(root))
            {
                if (RootWatcher.TryCreate(root.Path, root.Naming, OnWatcherPath, OnWatcherOverflow) is { } watcher)
                {
                    watchers[root] = watcher;
                }
            }
            else if (!wanted && watchers.Remove(root, out var stale))
            {
                stale.Dispose();
            }
        }
    }

    private void OnWatcherPath(string path)
    {
        var signal = false;
        lock (_pendingGate)
        {
            if (_pendingPaths.Count < MaxPendingPaths)
            {
                _pendingPaths.Add(path);
            }
            else
            {
                _rescanRequested = true;
            }

            if (_pendingSince == 0)
            {
                _pendingSince = Stopwatch.GetTimestamp();
                signal = true;
            }
        }

        if (signal)
        {
            SignalWake();
        }
    }

    private void OnWatcherOverflow()
    {
        lock (_pendingGate)
        {
            _rescanRequested = true;
        }

        SignalWake();
    }

    private TimeSpan? PendingDeadline(long start)
    {
        lock (_pendingGate)
        {
            if (_pendingSince == 0)
            {
                return _rescanRequested ? TimeSpan.Zero : null;
            }

            return Stopwatch.GetElapsedTime(start, _pendingSince) + Debounce;
        }
    }

    private HashSet<string>? TakePendingPaths(long start, TimeSpan elapsed)
    {
        lock (_pendingGate)
        {
            if (_pendingSince == 0 || Stopwatch.GetElapsedTime(start, _pendingSince) + Debounce > elapsed)
            {
                return null;
            }

            var paths = _pendingPaths;
            _pendingPaths = new HashSet<string>(StringComparer.Ordinal);
            _pendingSince = 0;
            return paths;
        }
    }

    private bool TakeRescanRequest()
    {
        lock (_pendingGate)
        {
            var requested = _rescanRequested;
            _rescanRequested = false;
            return requested;
        }
    }

    private void ResetPending()
    {
        lock (_pendingGate)
        {
            _pendingPaths = new HashSet<string>(StringComparer.Ordinal);
            _pendingSince = 0;
            _rescanRequested = false;
        }
    }

    private void SignalWake()
    {
        try
        {
            _wake.Set();
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private static void WaitFor(TimeSpan delay, CancellationToken token) => token.WaitHandle.WaitOne(delay);

    private static TimeSpan Min(TimeSpan a, TimeSpan b, TimeSpan c) => a < b ? (a < c ? a : c) : (b < c ? b : c);

    private static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}

using System.Diagnostics;
using System.Globalization;
using AgentSpeed.Core.IO;
using AgentSpeed.Core.IO.Sqlite;
using AgentSpeed.Core.Monitoring;
using AgentSpeed.Core.OpenCode;
using AgentSpeed.Core.Parsing;
using AgentSpeed.Core.Pricing;

namespace AgentSpeed.Core.History;

internal sealed record HistoryOptions
{
    /// <summary>Bumped whenever a parser change alters results; stored files of other versions are analysed again.</summary>
    public int Version { get; init; } = HistoryAnalyzer.AnalysisVersion;

    public int Workers { get; init; } = Math.Clamp(Environment.ProcessorCount / 2, 1, 4);

    /// <summary>Analysed files are written in batches at least this often.</summary>
    public long SaveIntervalMs { get; init; } = 1500;

    /// <summary>Upper bound for files read ahead of the consumer (by estimated decoded size).</summary>
    public long MaxBufferedBytes { get; init; } = 256L * 1024 * 1024;
}

internal readonly record struct HistoryProgress(int FilesDone, int FilesTotal, long BytesDone, long BytesTotal)
{
    public double Fraction => BytesTotal > 0
        ? Math.Min(1, (double)BytesDone / BytesTotal)
        : FilesTotal > 0 ? (double)FilesDone / FilesTotal : 1;
}

internal sealed record HistoryReport(
    int FilesDiscovered,
    int FilesPlanned,
    int FilesAnalyzed,
    long BytesAnalyzed,
    int SessionsAnalyzed,
    int FilesUnreadable,
    long ElapsedMs,
    bool Cancelled);

/// <summary>
/// Computes the daily history (METRICS 8): every transcript of the enabled sources (plus Codex
/// <c>archived_sessions</c>, every omp root and every Antigravity conversation database) and every OpenCode session,
/// parsed completely with the live rules in startup order, incrementally against a <see cref="HistoryStore"/>. One
/// owner thread.
/// </summary>
internal sealed partial class HistoryAnalyzer
{
    /// <summary>2: measured output and time per model (METRICS 8). 3: cost (METRICS 9.7).</summary>
    public const int AnalysisVersion = 4;

    private const string OpenCodeFamily = "opencode";
    private const string ZoneMeta = "timeZone";
    private const string OpenCodeMeta = "opencode";

    /// <summary>
    /// The current price table version of the last complete run; when it changes, files with unpriced responses are
    /// analysed again (METRICS 9.7).
    /// </summary>
    private const string PriceVersionMeta = "priceTableVersion";

    private static readonly StringComparer PathComparer =
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private readonly HistoryStore _store;
    private readonly HistoryOptions _options;
    private readonly Dictionary<string, StoredFile> _entries;
    private readonly Dictionary<string, double> _peaks;

    /// <param name="pricing">Shared with the live engine in the app, so today is priced alike (METRICS 9.6); null uses the bundled table.</param>
    public HistoryAnalyzer(HistoryStore store, HistoryOptions? options = null, PriceBook? pricing = null)
    {
        _store = store;
        _options = options ?? new HistoryOptions();
        Pricing = pricing ?? new PriceBook();
        _entries = store.LoadFiles(PathComparer);
        _peaks = store.Peaks();
        var repaired = Pricing.Restore(store.PriceBindings(), store.PriceTables());
        if (repaired.Count > 0)
        {
            Trace.TraceInformation("Price bindings without a valid table rebound to the current table: {0}", repaired.Count);
        }

        SaveBindings();
    }

    public IReadOnlyDictionary<string, StoredFile> Entries => _entries;

    public PriceBook Pricing { get; }

    /// <summary>Stores the dates bound since the last save, with a copy of each referenced table.</summary>
    public void SaveBindings()
    {
        var bindings = Pricing.TakeNewBindings();
        if (bindings.Count > 0)
        {
            _store.SavePriceBindings(bindings, version => Pricing.Table(version)?.Data);
        }
    }

    /// <summary>Daily totals: sums over files, for the given sources (all when null), sorted by day then source name.</summary>
    public List<DailyUsage> Days(IReadOnlySet<SourceKind>? sources = null, IReadOnlyDictionary<string, double>? livePeaks = null)
    {
        var totals = new Dictionary<DayKey, DayAggregate>();
        foreach (var entry in _entries.Values)
        {
            foreach (var (key, day) in entry.Days)
            {
                if (sources is not null && !sources.Contains(key.Source))
                {
                    continue;
                }

                if (!totals.TryGetValue(key, out var total))
                {
                    totals[key] = total = new DayAggregate();
                }

                total.Merge(day);
            }
        }

        return [.. totals
            .OrderBy(t => t.Key.Day, StringComparer.Ordinal)
            .ThenBy(t => SourceNames.Of(t.Key.Source), StringComparer.Ordinal)
            .Select(t => t.Value.ToUsage(t.Key, Peak(t.Key.Day, livePeaks), Pricing.BoundVersion(t.Key.Day)))];
    }

    /// <summary>Stores day peaks observed live (all sources together) where they raise the stored value.</summary>
    public bool RecordPeaks(IReadOnlyDictionary<string, double> peaks)
    {
        var raised = new Dictionary<string, double>(StringComparer.Ordinal);
        foreach (var (day, peak) in peaks)
        {
            if (double.IsFinite(peak) && peak > 0 && peak > _peaks.GetValueOrDefault(day))
            {
                raised[day] = peak;
            }
        }

        if (raised.Count == 0)
        {
            return false;
        }

        _store.SavePeaks(raised);
        foreach (var (day, peak) in raised)
        {
            _peaks[day] = peak;
        }

        return true;
    }

    /// <summary>Analyses what changed since the last run and stores it.</summary>
    /// <param name="progress">Called after every file with the work done so far.</param>
    public HistoryReport Run(
        SourceLocations locations,
        IReadOnlySet<SourceKind> enabled,
        TimeZoneInfo zone,
        CancellationToken cancellationToken,
        Action<HistoryProgress>? progress = null)
    {
        var stopwatch = Stopwatch.StartNew();
        var zoneId = zone.Id;
        var zoneChanged = _entries.Count > 0 && !string.Equals(_store.Meta(ZoneMeta), zoneId, StringComparison.Ordinal);
        var priceVersion = Pricing.CurrentVersion.ToString(CultureInfo.InvariantCulture);
        var repricing = _entries.Count > 0 && !string.Equals(_store.Meta(PriceVersionMeta), priceVersion, StringComparison.Ordinal);
        var plan = BuildPlan(locations, enabled, zoneChanged, repricing, zoneId, cancellationToken);
        var state = new HistoryProgress(0, plan.Files.Count + plan.Sessions.Count + plan.ZCodeSessions.Count, 0, plan.Files.Sum(f => f.Size));
        progress?.Invoke(state);
        int analyzed = 0, sessions = 0, unreadable = (plan.OpenCodeFailed ? 1 : 0) + (plan.ZCodeFailed ? 1 : 0);
        long bytes = 0;
        var cancelled = false;
        try
        {
            if (plan.Files.Count > 0 || plan.Sessions.Count > 0 || plan.ZCodeSessions.Count > 0)
            {
                var ledger = new KeyLedger();
                var replaced = plan.Files.Select(f => f.Previous?.Id ?? 0).Concat(plan.Sessions.Select(s => s.Previous?.Id ?? 0)).Concat(plan.ZCodeSessions.Select(s => s.Previous?.Id ?? 0))
                    .Where(id => id != 0).ToHashSet();
                _store.LoadKeys(ledger, replaced);
                var labeler = new DayLabeler(zone);
                var pending = new List<(StoredFile, ulong[])>();
                var lastSave = Stopwatch.GetTimestamp();
                void Flush(bool force)
                {
                    if (pending.Count > 0 && (force || Stopwatch.GetElapsedTime(lastSave).TotalMilliseconds >= _options.SaveIntervalMs))
                    {
                        _store.Save(pending);
                        SaveBindings();
                        pending.Clear();
                        lastSave = Stopwatch.GetTimestamp();
                    }
                }

                try
                {
                    cancelled = !AnalyzeFiles(plan.Files, ledger, labeler, pending, Flush, ref state, ref analyzed, ref bytes, ref unreadable,
                        progress, cancellationToken);
                    if (!cancelled)
                    {
                        cancelled = !AnalyzeZCodeSessions(plan.ZCodeSessions, ledger, labeler, pending, Flush, ref state, ref sessions,
                            progress, cancellationToken);
                    }

                    if (!cancelled && plan.Database is { } database)
                    {
                        cancelled = !AnalyzeSessions(database, plan.Sessions, ledger, labeler, pending, Flush, ref state, ref sessions,
                            progress, cancellationToken);
                    }
                }
                finally
                {
                    Flush(force: true);
                    SaveBindings();
                }
            }

            if (!cancelled)
            {
                _store.SetMeta(ZoneMeta, zoneId);
                _store.SetMeta(PriceVersionMeta, priceVersion);
                if (plan.OpenCodeIdentity is { } identity)
                {
                    _store.SetMeta(OpenCodeMeta, identity);
                }
            }
        }
        finally
        {
            plan.Database?.Dispose();
        }

        return new HistoryReport(plan.Discovered, plan.Files.Count + plan.Sessions.Count + plan.ZCodeSessions.Count, analyzed, bytes, sessions, unreadable,
            stopwatch.ElapsedMilliseconds, cancelled);
    }

    private double? Peak(string day, IReadOnlyDictionary<string, double>? livePeaks)
    {
        var stored = _peaks.TryGetValue(day, out var value) ? value : (double?)null;
        if (livePeaks is not null && livePeaks.TryGetValue(day, out var live) && live > (stored ?? 0))
        {
            return live;
        }

        return stored;
    }

    /// <param name="repricing">The current price table changed: files with unpriced responses are analysed again (METRICS 9.7).</param>
    private Plan BuildPlan(
        SourceLocations locations,
        IReadOnlySet<SourceKind> enabled,
        bool zoneChanged,
        bool repricing,
        string zoneId,
        CancellationToken cancellationToken)
    {
        var plan = new Plan();
        var seen = new HashSet<string>(PathComparer);
        foreach (var (family, root) in Roots(locations, enabled))
        {
            if (!SafeDirectoryExists(root))
            {
                continue;
            }

            var familyName = family.ToString();
            foreach (var file in TranscriptDiscovery.Enumerate(root, Families.Naming(family), cancellationToken, int.MaxValue))
            {
                if (!seen.Add(file.Path))
                {
                    continue;
                }

                plan.Discovered++;
                // An Antigravity database's size and time already combine its -wal (METRICS 8).
                var previous = _entries.GetValueOrDefault(file.Path);
                if (previous is not null && !zoneChanged && previous.Version == _options.Version
                    && string.Equals(previous.Family, familyName, StringComparison.Ordinal)
                    && previous.Size == file.Length && previous.Modified == file.LastWriteUtc.Ticks
                    && !(repricing && previous.HasUnpriced))
                {
                    continue;
                }

                plan.Files.Add(new PlannedFile(file.Path, family, root, file.Length, file.LastWriteUtc, previous));
            }
        }

        plan.Files.Sort(static (a, b) =>
        {
            var byTime = a.LastWriteUtc.CompareTo(b.LastWriteUtc);
            return byTime != 0 ? byTime : string.CompareOrdinal(a.Path, b.Path);
        });

        if (Families.IsEnabled(RootFamily.OpenCode, enabled) && locations.OpenCodeRoot.Length > 0)
        {
            PlanOpenCode(plan, OpenCodeDatabase.DatabasePath(locations.OpenCodeRoot), zoneChanged, repricing, zoneId);
        }

        PlanZCode(plan, locations, enabled, zoneChanged, repricing, cancellationToken);
        return plan;
    }

    private void PlanOpenCode(Plan plan, string path, bool zoneChanged, bool repricing, string zoneId)
    {
        var database = new FileInfo(path);
        if (!database.Exists)
        {
            return;
        }

        plan.Discovered++;
        var wal = new FileInfo(path + "-wal");
        var identity = string.Join('|',
            path,
            string.Create(CultureInfo.InvariantCulture, $"{database.Length}:{database.LastWriteTimeUtc.Ticks}"),
            wal.Exists ? string.Create(CultureInfo.InvariantCulture, $"{wal.Length}:{wal.LastWriteTimeUtc.Ticks}") : "-",
            string.Create(CultureInfo.InvariantCulture, $"v{_options.Version}"),
            zoneId);
        var reprices = repricing && _entries.Values.Any(e => e.Family == OpenCodeFamily && e.HasUnpriced);
        if (!zoneChanged && !reprices && string.Equals(_store.Meta(OpenCodeMeta), identity, StringComparison.Ordinal))
        {
            return;
        }

        OpenCodeDatabase opened;
        try
        {
            opened = OpenCodeDatabase.Open(path);
        }
        catch (OpenCodeOpenException e)
        {
            plan.OpenCodeFailed = e.Status != OpenCodeStatus.Unsupported;
            return;
        }

        try
        {
            var activity = opened.SessionActivity();
            foreach (var info in opened.Sessions().OrderBy(s => s.Id, StringComparer.Ordinal))
            {
                var (rows, lastUpdated) = activity.GetValueOrDefault(info.Id);
                var modified = Math.Max(info.UpdatedMs, lastUpdated);
                var previous = _entries.GetValueOrDefault(OpenCodeRules.AgentId(info.Id));
                if (previous is not null && !zoneChanged && previous.Version == _options.Version
                    && previous.Size == rows && previous.Modified == modified && !(repricing && previous.HasUnpriced))
                {
                    continue;
                }

                plan.Sessions.Add(new PlannedSession(info, rows, modified, previous));
            }
        }
        catch (SqliteException)
        {
            opened.Dispose();
            plan.OpenCodeFailed = true;
            plan.Sessions.Clear();
            return;
        }

        plan.Database = opened;
        plan.OpenCodeIdentity = identity;
    }

    /// <summary>Transcript roots of the enabled sources; Codex also contributes its <c>archived_sessions</c> sibling.</summary>
    private static IEnumerable<(RootFamily Family, string Path)> Roots(SourceLocations locations, IReadOnlySet<SourceKind> enabled)
    {
        foreach (var (family, path) in locations.FileRoots())
        {
            if (!Families.IsEnabled(family, enabled) || path.Length == 0)
            {
                continue;
            }

            yield return (family, path);
            if (family == RootFamily.Codex && locations.CodexArchiveRoot is { Length: > 0 } archive)
            {
                yield return (family, archive);
            }
        }
    }

    private bool AnalyzeFiles(
        List<PlannedFile> files,
        KeyLedger ledger,
        DayLabeler labeler,
        List<(StoredFile, ulong[])> pending,
        Action<bool> flush,
        ref HistoryProgress state,
        ref int analyzed,
        ref long bytes,
        ref int unreadable,
        Action<HistoryProgress>? progress,
        CancellationToken cancellationToken)
    {
        if (files.Count == 0)
        {
            return true;
        }

        using var reader = new OrderedFileReader(
            [.. files.Select(f => new ReadJob(f.Path, f.Family, f.Root, f.Size))], ledger, _options.Workers, _options.MaxBufferedBytes,
            cancellationToken);
        foreach (var file in files)
        {
            if (cancellationToken.IsCancellationRequested || reader.Next() is not { } prepared)
            {
                return false;
            }

            state = state with { FilesDone = state.FilesDone + 1, BytesDone = state.BytesDone + file.Size };
            var sink = new LatestResponses(merge: file.Family == RootFamily.Claude);
            var applied = false;
            if (prepared is { Error: null, Batch: { } batch })
            {
                try
                {
                    batch.ApplyTo(sink);
                    applied = true;
                }
                catch (Exception e) when (e is not OutOfMemoryException)
                {
                    applied = false;
                }
            }

            if (!applied)
            {
                // Unreadable or vanished: keep what was stored, including its key ownership.
                ledger.AbandonFile();
                unreadable++;
                if (file.Previous is { Id: > 0 } previous)
                {
                    _store.LoadKeys(ledger, previous.Id);
                }

                progress?.Invoke(state);
                continue;
            }

            var owned = ledger.FinishFile();
            var result = prepared.Result;
            var entry = new StoredFile
            {
                Id = file.Previous?.Id ?? 0,
                Path = file.Path,
                Family = file.Family.ToString(),
                Size = result.Length,
                Modified = result.LastWriteUtc.Ticks,
                Version = _options.Version,
                Days = DayAggregate.Contributions(sink.Items.Values, prepared.Parser.Source, labeler, Pricing),
            };
            _entries[file.Path] = entry;
            pending.Add((entry, owned));
            analyzed++;
            bytes += result.Length;
            flush(false);
            progress?.Invoke(state);
        }

        return true;
    }

    private bool AnalyzeSessions(
        OpenCodeDatabase database,
        List<PlannedSession> sessions,
        KeyLedger ledger,
        DayLabeler labeler,
        List<(StoredFile, ulong[])> pending,
        Action<bool> flush,
        ref HistoryProgress state,
        ref int analyzed,
        Action<HistoryProgress>? progress,
        CancellationToken cancellationToken)
    {
        foreach (var session in sessions)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return false;
            }

            state = state with { FilesDone = state.FilesDone + 1 };
            var agentId = OpenCodeRules.AgentId(session.Info.Id);
            List<OpenCodeRow> rows;
            try
            {
                rows = database.SessionRows(session.Info.Id);
            }
            catch (SqliteException)
            {
                if (session.Previous is { Id: > 0 } previous)
                {
                    _store.LoadKeys(ledger, previous.Id);
                }

                progress?.Invoke(state);
                continue;
            }

            var latest = new Dictionary<string, ParsedResponse>(StringComparer.Ordinal);
            foreach (var row in rows)
            {
                if (OpenCodeRules.Response(row, session.Info) is not { } response)
                {
                    continue;
                }

                if (ledger.TryClaim(row.Id, agentId, out var owner) || string.Equals(owner, agentId, StringComparison.Ordinal))
                {
                    latest[row.Id] = response;
                }
            }

            var entry = new StoredFile
            {
                Id = session.Previous?.Id ?? 0,
                Path = agentId,
                Family = OpenCodeFamily,
                Size = session.Rows,
                Modified = session.ModifiedMs,
                Version = _options.Version,
                Days = DayAggregate.Contributions(latest.Values, SourceKind.OpenCode, labeler, Pricing),
            };
            _entries[agentId] = entry;
            pending.Add((entry, ledger.FinishFile()));
            analyzed++;
            flush(false);
            progress?.Invoke(state);
        }

        return true;
    }

    private static bool SafeDirectoryExists(string path)
    {
        try
        {
            return path.Length > 0 && Directory.Exists(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    private sealed record PlannedFile(string Path, RootFamily Family, string Root, long Size, DateTime LastWriteUtc, StoredFile? Previous);

    private sealed record PlannedSession(OpenCodeSessionInfo Info, long Rows, long ModifiedMs, StoredFile? Previous);

    private sealed class Plan
    {
        public List<PlannedFile> Files { get; } = [];

        public List<PlannedSession> Sessions { get; } = [];

        public List<PlannedZCodeSession> ZCodeSessions { get; } = [];

        public bool ZCodeFailed { get; set; }

        public int Discovered { get; set; }

        public OpenCodeDatabase? Database { get; set; }

        public string? OpenCodeIdentity { get; set; }

        public bool OpenCodeFailed { get; set; }
    }

    /// <summary>The latest version of every response of one file; Claude repeats merge like the parser does (4.1).</summary>
    private sealed class LatestResponses(bool merge) : IResponseSink
    {
        public Dictionary<string, ParsedResponse> Items { get; } = new(StringComparer.Ordinal);

        public void OnResponse(ParsedResponse response, bool isCompletion)
        {
            if (merge && !isCompletion && Items.TryGetValue(response.Key, out var previous))
            {
                response = previous with
                {
                    EndMs = Math.Max(previous.EndMs, response.EndMs),
                    Tokens = TokenCounts.Max(previous.Tokens, response.Tokens),
                    Model = response.Model ?? previous.Model,
                    Final = previous.Final || response.Final,
                    Fast = previous.Fast || response.Fast,
                };
            }

            Items[response.Key] = response;
        }
    }
}

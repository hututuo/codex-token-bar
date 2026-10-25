using AgentSpeed.Core.History;

namespace AgentSpeed.Core.Traffic.Monitor;

/// <summary>
/// Stored traffic days (METRICS 10.9): loads them once, upserts today's totals every 60 s, at the day change, on flush
/// and at stop, and merges today's unsaved part into what it publishes. The database is opened per write (under
/// <see cref="HistoryStore.FileGate"/>), so "Clear history" deleting the file needs no other coordination.
/// </summary>
internal sealed class TrafficHistoryKeeper
{
    public const long WriteIntervalMs = 60_000;
    public const long PublishIntervalMs = 10_000;

    private readonly string _storePath;
    private readonly Action<string> _log;
    private Dictionary<string, List<TrafficDay>> _stored = new(StringComparer.Ordinal);
    private long? _lastWriteMs;
    private long? _lastPublishMs;
    private (IReadOnlyList<TrafficDay> Days, string? Since)? _lastPublished;

    public TrafficHistoryKeeper(string storePath, Action<string>? log = null)
    {
        _storePath = storePath;
        _log = log ?? (_ => { });
    }

    public string? Since { get; private set; }

    public void Load()
    {
        var (days, since) = HistoryStore.StoredTraffic(_storePath);
        _stored = days.GroupBy(d => d.Day, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.ToList(), StringComparer.Ordinal);
        Since = since;
    }

    public IReadOnlyList<TrafficDay> StoredRows(string day) => _stored.TryGetValue(day, out var rows) ? rows : [];

    public bool IsWriteDue(long nowMs) => _lastWriteMs is not { } last || nowMs - last >= WriteIntervalMs;

    /// <summary>The first write happens a full interval after launch or a clear.</summary>
    public void DeferWrites(long nowMs) => _lastWriteMs = nowMs;

    /// <summary>Upserts <paramref name="rows"/> (one or more whole days); on failure they stay in memory and the next write retries.</summary>
    public void Write(IReadOnlyList<TrafficDay> rows, long nowMs)
    {
        _lastWriteMs = nowMs;
        if (rows.Count == 0)
        {
            return;
        }

        try
        {
            lock (HistoryStore.FileGate)
            {
                using var store = HistoryStore.Open(_storePath);
                store.SaveTraffic(rows);
            }

            foreach (var group in rows.GroupBy(r => r.Day, StringComparer.Ordinal))
            {
                _stored[group.Key] = group.ToList();
            }

            var first = rows.Select(r => r.Day).Min(StringComparer.Ordinal)!;
            if (Since is null || string.CompareOrdinal(first, Since) < 0)
            {
                Since = first;
            }
        }
        catch (Exception e) when (e is IO.Sqlite.SqliteException or IOException or UnauthorizedAccessException)
        {
            _log($"Traffic rows could not be saved: {e.GetType().Name}: {e.Message}");
        }
    }

    /// <summary>"Clear history": nothing stored any more; the next write recreates today's rows.</summary>
    public void Clear(long nowMs)
    {
        _stored = new Dictionary<string, List<TrafficDay>>(StringComparer.Ordinal);
        Since = null;
        _lastWriteMs = nowMs;
        _lastPublished = null;
    }

    /// <summary>
    /// Stored days with <paramref name="today"/>'s rows replaced by the in-memory ones, oldest first (machine first within a
    /// day); null when not due (every 10 s, or <paramref name="force"/>) or unchanged.
    /// </summary>
    public (IReadOnlyList<TrafficDay> Days, string? Since)? DaysToPublish(string today, IReadOnlyList<TrafficDay> rows, long nowMs, bool force)
    {
        if (!force && _lastPublishMs is { } last && nowMs - last < PublishIntervalMs)
        {
            return null;
        }

        _lastPublishMs = nowMs;
        var merged = new Dictionary<string, IReadOnlyList<TrafficDay>>(StringComparer.Ordinal);
        foreach (var (day, dayRows) in _stored)
        {
            merged[day] = dayRows;
        }

        if (rows.Count > 0)
        {
            merged[today] = rows;
        }

        var days = merged.Keys.Order(StringComparer.Ordinal).SelectMany(day => merged[day].OrderBy(r => Rank(r.Key))).ToArray();
        var since = Since ?? (rows.Count > 0 ? today : null);
        if (_lastPublished is { } previous && previous.Since == since && previous.Days.SequenceEqual(days))
        {
            return null;
        }

        _lastPublished = (days, since);
        return (days, since);
    }

    /// <summary><c>machine</c> first, then sources in their declared order.</summary>
    private static int Rank(string key) => key == TrafficDay.MachineKey ? -1 : SourceNames.Parse(key) is { } source ? (int)source : int.MaxValue;
}

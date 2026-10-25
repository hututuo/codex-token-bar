using AgentSpeed.Core.IO;
using AgentSpeed.Core.IO.Sqlite;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.OpenCode;

/// <summary>What one read of the OpenCode database changed.</summary>
internal sealed class OpenCodeUpdate
{
    public List<(ParsedResponse Response, bool IsCompletion)> Responses { get; } = [];

    /// <summary>Agent id → state of sessions whose state may have changed.</summary>
    public Dictionary<string, OpenCodeAgentState> Agents { get; } = new(StringComparer.Ordinal);

    public List<string> Removed { get; } = [];

    /// <summary>Everything was read again from the start (seeding, or the database was replaced).</summary>
    public bool Reset { get; set; }

    public bool IsEmpty => Responses.Count == 0 && Agents.Count == 0 && Removed.Count == 0 && !Reset;
}

/// <summary>
/// Follows OpenCode's database for the live monitor (METRICS 4.5, 5.2). Every session is one agent. Rows are kept per
/// session, reduced to the fields that matter, so its state can be replayed in <c>seq</c> order whenever a row changes.
/// Not thread-safe: owned by the monitor thread.
/// </summary>
internal sealed class OpenCodeSource : IDisposable
{
    /// <summary>Rows created or updated this close to a cursor are read again, in case they were committed out of order.</summary>
    public const long CursorOverlapMs = 2000;

    /// <summary>Rows updated this recently are re-read by id on every change.</summary>
    public const long RecentRowMs = 60_000;

    public const int MaxWatchedRows = 256;

    /// <summary>In-flight rows that have not changed for this long are no longer re-read by id.</summary>
    public const long StaleInFlightMs = 30 * 60_000;

    /// <summary>Sessions quiet for this long release their rows; later rows start a fresh replay.</summary>
    public const long CompactAfterMs = 2 * 3_600_000;

    public const long StartupLookbackMs = 15 * 60_000;

    private static readonly StringComparer PathComparer =
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private readonly IDeduper _deduper;
    private readonly Dictionary<string, Tracked> _sessions = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _rowSessions = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> _watchedRows = new(StringComparer.Ordinal);
    private OpenCodeDatabase? _database;
    private FileIdentity? _identity;
    private (long Length, DateTime WriteUtc)? _databaseStamp;
    private (long Length, DateTime WriteUtc)? _walStamp;
    private long? _createdCursor;
    private long? _sessionCursor;
    private long _newestRowUpdate;
    private bool _needsSeed;

    public OpenCodeSource(string root, IDeduper deduper)
    {
        RootPath = root;
        DatabasePath = OpenCodeDatabase.DatabasePath(root);
        WalPath = DatabasePath.Length > 0 ? DatabasePath + "-wal" : string.Empty;
        _deduper = deduper;
    }

    public string RootPath { get; }

    public string DatabasePath { get; }

    public string WalPath { get; }

    /// <summary>The folder a watcher observes for <c>opencode.db</c> and <c>opencode.db-wal</c>.</summary>
    public string WatchDirectory => DatabasePath.Length > 0 ? Path.GetDirectoryName(DatabasePath) ?? string.Empty : string.Empty;

    public OpenCodeStatus Status { get; private set; } = OpenCodeStatus.Missing;

    /// <summary>The database is read with <c>immutable=1</c> because OpenCode closed it (METRICS 4.5).</summary>
    public bool IsImmutable => _database?.IsImmutable == true;

    /// <summary>The database file exists (it may still be unreadable or unsupported).</summary>
    public bool DatabaseExists { get; private set; }

    public long MalformedRows => _sessions.Values.Sum(s => s.State?.MalformedRows ?? 0);

    public long DatabaseBytes => _databaseStamp?.Length ?? 0;

    /// <summary>Agents of every session that has at least one row read.</summary>
    public IEnumerable<OpenCodeAgentState> Agents =>
        _sessions.Values.Select(s => s.State).Where(s => s?.LastLineMs is not null).Select(s => s!);

    public bool IsWatchedPath(string path) =>
        DatabasePath.Length > 0 && (PathComparer.Equals(path, DatabasePath) || PathComparer.Equals(path, WalPath));

    /// <summary>Cheap existence check for availability (does not open the database).</summary>
    public bool CheckExists()
    {
        DatabaseExists = SafeExists(DatabasePath);
        return DatabaseExists;
    }

    /// <summary>Sessions with a row updated today.</summary>
    public int ActiveSessionCount(long todayStartMs) =>
        _sessions.Values.Count(s => s.State?.LastLineMs is { } last && last >= todayStartMs);

    /// <summary>
    /// Opens the database when it appeared, closes it when it vanished, reopens it when it was replaced. Returns true
    /// when the status changed or the database must be read again from the start.
    /// </summary>
    public bool RefreshAvailability()
    {
        var previous = Status;
        if (!CheckExists())
        {
            Close(OpenCodeStatus.Missing);
            return previous != OpenCodeStatus.Missing;
        }

        var identity = ReadIdentity(DatabasePath);
        if (_database is not null && (identity is null || identity == _identity))
        {
            return false;
        }

        Close(OpenCodeStatus.Missing);
        try
        {
            _database = OpenCodeDatabase.Open(DatabasePath);
            Status = OpenCodeStatus.Ready;
        }
        catch (OpenCodeOpenException e)
        {
            Status = e.Status;
        }

        _identity = identity;
        _databaseStamp = Stamp(DatabasePath);
        _walStamp = Stamp(WalPath);
        _needsSeed = Status == OpenCodeStatus.Ready;
        return Status != previous || Status == OpenCodeStatus.Ready;
    }

    /// <summary>
    /// Startup read (METRICS 5.2): sessions updated since <c>todayStartMs - 15 min</c> are read completely; older
    /// sessions are known by their metadata and continue from their current state.
    /// </summary>
    public OpenCodeUpdate Seed(long todayStartMs)
    {
        var update = new OpenCodeUpdate { Reset = true };
        var previous = _sessions.Values.Where(s => s.State?.LastLineMs is not null).Select(s => s.Info.Id).ToList();
        _sessions.Clear();
        _rowSessions.Clear();
        _watchedRows.Clear();
        _createdCursor = null;
        _sessionCursor = null;
        _newestRowUpdate = 0;
        _needsSeed = false;
        if (_database is { } database)
        {
            var threshold = todayStartMs - StartupLookbackMs;
            try
            {
                _createdCursor = database.MaxCreatedMs() ?? 0;
                foreach (var info in database.Sessions().OrderBy(s => s.Id, StringComparer.Ordinal))
                {
                    _sessionCursor = Math.Max(_sessionCursor ?? info.UpdatedMs, info.UpdatedMs);
                    if (info.UpdatedMs < threshold)
                    {
                        _sessions[info.Id] = new Tracked(info) { RowWatermark = info.UpdatedMs };
                        continue;
                    }

                    _sessions[info.Id] = new Tracked(info);
                    Apply(database.SessionRows(info.Id), info.Id, update);
                }
            }
            catch (SqliteException)
            {
                // Busy or vanished: read again on the next rediscovery.
                _needsSeed = true;
            }
        }

        foreach (var id in previous)
        {
            var agent = OpenCodeRules.AgentId(id);
            if (!update.Agents.ContainsKey(agent))
            {
                update.Removed.Add(agent);
            }
        }

        return update;
    }

    /// <summary>Reads what changed since the last read (METRICS 5.2).</summary>
    public OpenCodeUpdate Refresh()
    {
        var update = new OpenCodeUpdate();
        DropStaleImmutableConnection();
        if (Status != OpenCodeStatus.Ready || _database is not { } database)
        {
            return update;
        }

        _databaseStamp = Stamp(DatabasePath) ?? _databaseStamp;
        _walStamp = Stamp(WalPath);
        try
        {
            var advanced = new List<string>();
            foreach (var info in database.Sessions((_sessionCursor ?? 0) - CursorOverlapMs))
            {
                _sessionCursor = Math.Max(_sessionCursor ?? info.UpdatedMs, info.UpdatedMs);
                if (_sessions.TryGetValue(info.Id, out var tracked))
                {
                    if (info == tracked.Info)
                    {
                        continue;
                    }

                    var moved = info.UpdatedMs > tracked.Info.UpdatedMs;
                    tracked.Info = info;
                    if (tracked.Rows.Count > 0)
                    {
                        update.Agents[OpenCodeRules.AgentId(info.Id)] = Replay(tracked);
                    }

                    if (moved)
                    {
                        advanced.Add(info.Id);
                    }
                }
                else
                {
                    _sessions[info.Id] = new Tracked(info);
                    advanced.Add(info.Id);
                }
            }

            var changed = new Dictionary<string, List<OpenCodeRow>>(StringComparer.Ordinal);
            void Collect(IEnumerable<OpenCodeRow> rows)
            {
                foreach (var row in rows)
                {
                    if (!changed.TryGetValue(row.SessionId, out var list))
                    {
                        changed[row.SessionId] = list = [];
                    }

                    list.Add(row);
                }
            }

            Collect(database.RowsCreatedSince((_createdCursor ?? 0) - CursorOverlapMs, IsKnown));
            if (_watchedRows.Count > 0)
            {
                Collect(database.RowsByIds(_watchedRows.Keys.ToList(), IsKnown));
            }

            foreach (var id in advanced)
            {
                var since = _sessions[id].RowWatermark is { } watermark ? watermark - CursorOverlapMs : (long?)null;
                Collect(database.SessionRows(id, since, IsKnown));
            }

            foreach (var (session, rows) in changed.OrderBy(p => p.Key, StringComparer.Ordinal))
            {
                if (_sessions.ContainsKey(session))
                {
                    Apply(rows, session, update);
                }
            }
        }
        catch (SqliteException)
        {
            // A busy or vanished database is read again on the next change, poll or rediscovery.
        }

        return update;
    }

    /// <summary>The 1-second fallback: reads again when the database or its WAL changed.</summary>
    public OpenCodeUpdate? RefreshIfChanged()
    {
        if (Status != OpenCodeStatus.Ready)
        {
            return null;
        }

        var database = Stamp(DatabasePath);
        var wal = Stamp(WalPath);
        if (database == _databaseStamp && wal == _walStamp)
        {
            return null;
        }

        return database is null ? null : Refresh();
    }

    /// <summary>Periodic check: replaced or vanished databases, deleted sessions, and quiet sessions' rows released.</summary>
    public OpenCodeUpdate Rediscover(long nowMs, long todayStartMs)
    {
        if (RefreshAvailability() || _needsSeed)
        {
            return Status == OpenCodeStatus.Ready ? Seed(todayStartMs) : Drop();
        }

        var update = Refresh();
        if (Status != OpenCodeStatus.Ready || _database is not { } database)
        {
            return update;
        }

        HashSet<string> present;
        try
        {
            present = database.Sessions().Select(s => s.Id).ToHashSet(StringComparer.Ordinal);
        }
        catch (SqliteException)
        {
            return update;
        }

        foreach (var id in _sessions.Keys.Where(id => !present.Contains(id)).ToList())
        {
            var tracked = _sessions[id];
            Release(tracked);
            _sessions.Remove(id);
            var agent = OpenCodeRules.AgentId(id);
            update.Agents.Remove(agent);
            update.Removed.Add(agent);
        }

        foreach (var tracked in _sessions.Values)
        {
            if (tracked.Rows.Count > 0 && tracked.State is { Phase: not AgentPhase.Generating, LastLineMs: { } last }
                && nowMs - last > CompactAfterMs)
            {
                tracked.Model = tracked.State.Model;
                Release(tracked);
            }
        }

        return update;
    }

    public void Dispose() => Close(OpenCodeStatus.Missing);

    /// <summary>
    /// An immutable connection (OpenCode had closed the database) is replaced by a <c>mode=ro</c> one as soon as the
    /// file changes or a WAL appears (METRICS 4.5); sessions and cursors carry over.
    /// </summary>
    private void DropStaleImmutableConnection()
    {
        if (_database is not { IsImmutable: true } database
            || (!SafeExists(WalPath) && Stamp(DatabasePath) == _databaseStamp))
        {
            return;
        }

        database.Dispose();
        _database = null;
        try
        {
            _database = OpenCodeDatabase.Open(DatabasePath);
            Status = OpenCodeStatus.Ready;
        }
        catch (OpenCodeOpenException e)
        {
            Status = e.Status;
        }
    }

    private OpenCodeUpdate Drop()
    {
        var update = new OpenCodeUpdate { Reset = true };
        foreach (var tracked in _sessions.Values)
        {
            if (tracked.State?.LastLineMs is not null)
            {
                update.Removed.Add(OpenCodeRules.AgentId(tracked.Info.Id));
            }
        }

        _sessions.Clear();
        _rowSessions.Clear();
        _watchedRows.Clear();
        return update;
    }

    private void Apply(List<OpenCodeRow> rows, string sessionId, OpenCodeUpdate update)
    {
        if (!_sessions.TryGetValue(sessionId, out var tracked))
        {
            return;
        }

        var agentId = OpenCodeRules.AgentId(sessionId);
        rows.Sort(static (a, b) => a.Seq.CompareTo(b.Seq));
        foreach (var row in rows)
        {
            if (tracked.Rows.TryGetValue(row.Id, out var known) && known == row)
            {
                continue;
            }

            tracked.Rows[row.Id] = row;
            _rowSessions[row.Id] = sessionId;
            tracked.RowWatermark = Math.Max(tracked.RowWatermark ?? row.TimeUpdated, row.TimeUpdated);
            _newestRowUpdate = Math.Max(_newestRowUpdate, row.TimeUpdated);
            _createdCursor = Math.Max(_createdCursor ?? row.TimeCreated, row.TimeCreated);
            Watch(row);
            if (OpenCodeRules.Response(row, tracked.Info) is not { } response)
            {
                continue;
            }

            var isCompletion = false;
            if (tracked.Emitted.TryGetValue(row.Id, out var previous))
            {
                if (previous == response)
                {
                    continue;
                }
            }
            else if (_deduper.TryClaim(row.Id, agentId, out var owner))
            {
                isCompletion = true;
            }
            else if (!string.Equals(owner, agentId, StringComparison.Ordinal))
            {
                continue;
            }

            tracked.Emitted[row.Id] = response;
            update.Responses.Add((response, isCompletion));
        }

        update.Agents[agentId] = Replay(tracked);
        PruneWatchedRows();
    }

    private OpenCodeAgentState Replay(Tracked tracked)
    {
        var rows = tracked.Rows.Values.ToList();
        rows.Sort(static (a, b) => a.Seq.CompareTo(b.Seq));
        tracked.State = OpenCodeRules.Replay(tracked.Info, rows, tracked.Model);
        return tracked.State;
    }

    private bool IsKnown(string id, long updated) =>
        _rowSessions.TryGetValue(id, out var session)
        && _sessions.TryGetValue(session, out var tracked)
        && tracked.Rows.TryGetValue(id, out var row)
        && row.TimeUpdated == updated;

    /// <summary>Rows still in flight, unfinished or recently updated are re-read by id on every change.</summary>
    private void Watch(OpenCodeRow row)
    {
        if (row.IsUnfinished || row.TimeUpdated >= _newestRowUpdate - RecentRowMs)
        {
            _watchedRows[row.Id] = row.TimeUpdated;
        }
        else
        {
            _watchedRows.Remove(row.Id);
        }
    }

    private void PruneWatchedRows()
    {
        var staleBefore = _newestRowUpdate - StaleInFlightMs;
        foreach (var (id, updated) in _watchedRows.ToList())
        {
            if (updated < staleBefore)
            {
                _watchedRows.Remove(id);
            }
        }

        if (_watchedRows.Count <= MaxWatchedRows)
        {
            return;
        }

        foreach (var (id, _) in _watchedRows.OrderByDescending(p => p.Value).Skip(MaxWatchedRows).ToList())
        {
            _watchedRows.Remove(id);
        }
    }

    private void Release(Tracked tracked)
    {
        foreach (var id in tracked.Rows.Keys)
        {
            _rowSessions.Remove(id);
            _watchedRows.Remove(id);
        }

        tracked.Rows.Clear();
        tracked.Emitted.Clear();
    }

    private void Close(OpenCodeStatus status)
    {
        _database?.Dispose();
        _database = null;
        _identity = null;
        _databaseStamp = null;
        _walStamp = null;
        Status = status;
    }

    private static (long Length, DateTime WriteUtc)? Stamp(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists ? (info.Length, info.LastWriteTimeUtc) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }

    private static FileIdentity? ReadIdentity(string path)
    {
        try
        {
            using var handle = TranscriptTailer.Open(path);
            return FileIdentity.From(handle);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }

    private static bool SafeExists(string path)
    {
        try
        {
            return path.Length > 0 && File.Exists(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    private sealed class Tracked(OpenCodeSessionInfo info)
    {
        public OpenCodeSessionInfo Info { get; set; } = info;

        public Dictionary<string, OpenCodeRow> Rows { get; } = new(StringComparer.Ordinal);

        public Dictionary<string, ParsedResponse> Emitted { get; } = new(StringComparer.Ordinal);

        /// <summary>Latest <c>time_updated</c> of the rows read (or the session's at startup when its rows were not read).</summary>
        public long? RowWatermark { get; set; }

        /// <summary>The model known when the rows were released.</summary>
        public string? Model { get; set; }

        public OpenCodeAgentState? State { get; set; }
    }
}

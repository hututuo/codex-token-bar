using System.Text;
using AgentSpeed.Core.IO.Sqlite;

namespace AgentSpeed.Core.OpenCode;

internal enum OpenCodeStatus
{
    Missing,
    Unreadable,

    /// <summary>The tables or columns of METRICS 4.5 are absent.</summary>
    Unsupported,
    Ready,
}

internal sealed class OpenCodeOpenException(OpenCodeStatus status, string message) : Exception(message)
{
    public OpenCodeStatus Status { get; } = status;
}

/// <summary>
/// Read-only access to OpenCode's <c>opencode.db</c> (METRICS 4.5, 5.2). The database is never written and never
/// opened with <c>immutable</c>; every query is its own short read transaction so OpenCode's checkpoints are never held
/// back. Not thread-safe.
/// </summary>
internal sealed class OpenCodeDatabase : IDisposable
{
    public const string FileName = "opencode.db";
    private const int IdBatch = 200;
    private const string SessionColumns = "id, parent_id, directory, time_created, time_updated";
    private const string RowColumns = "id, session_id, type, seq, time_created, time_updated, data";

    private readonly SqliteConnection _connection;
    private readonly SqliteStatement _sessions;
    private readonly SqliteStatement _sessionsSince;
    private readonly SqliteStatement _sessionRows;
    private readonly SqliteStatement _sessionRowsSince;
    private readonly SqliteStatement _rowsCreatedSince;
    private readonly SqliteStatement _maxCreated;

    private OpenCodeDatabase(SqliteConnection connection, bool immutable)
    {
        _connection = connection;
        IsImmutable = immutable;
        _sessions = connection.Prepare($"SELECT {SessionColumns} FROM session_v2");
        _sessionsSince = connection.Prepare($"SELECT {SessionColumns} FROM session_v2 WHERE time_updated >= ?1");
        _sessionRows = connection.Prepare($"SELECT {RowColumns} FROM session_message WHERE session_id = ?1 ORDER BY seq");
        _sessionRowsSince = connection.Prepare(
            $"SELECT {RowColumns} FROM session_message WHERE session_id = ?1 AND time_updated >= ?2 ORDER BY seq");
        _rowsCreatedSince = connection.Prepare(
            $"SELECT {RowColumns} FROM session_message WHERE time_created >= ?1 ORDER BY session_id, seq");
        _maxCreated = connection.Prepare("SELECT max(time_created) FROM session_message");
    }

    public string Path => _connection.Path;

    /// <summary>
    /// Opened with <c>immutable=1</c> because OpenCode closed the database (no WAL); the connection must be dropped on
    /// the next change of the file or once a WAL appears.
    /// </summary>
    public bool IsImmutable { get; }

    /// <summary><c>opencode.db</c> inside a configured folder; a configured path that names the file itself also works.</summary>
    public static string DatabasePath(string root)
    {
        if (string.IsNullOrEmpty(root))
        {
            return string.Empty;
        }

        try
        {
            return File.Exists(root) ? root : System.IO.Path.Combine(root, FileName);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return System.IO.Path.Combine(root, FileName);
        }
    }

    /// <summary>
    /// Opens read-only (<c>mode=ro</c>); when that fails and no WAL exists (OpenCode closed the database and deleted
    /// its WAL files), opens with <c>immutable=1</c> instead (METRICS 4.5).
    /// </summary>
    /// <exception cref="OpenCodeOpenException">The database is missing, unreadable or of an unsupported format.</exception>
    public static OpenCodeDatabase Open(string path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path))
        {
            throw new OpenCodeOpenException(OpenCodeStatus.Missing, "missing");
        }

        // Closed cleanly: a mode=ro open would fail (macOS) or create -wal/-shm inside OpenCode's folder (winsqlite3).
        if (IsClosedWalDatabase(path))
        {
            return Open(path, SqliteOpenMode.Immutable);
        }

        try
        {
            return Open(path, SqliteOpenMode.ReadOnly);
        }
        catch (OpenCodeOpenException e) when (e.Status == OpenCodeStatus.Unreadable && !File.Exists(path + "-wal"))
        {
            return Open(path, SqliteOpenMode.Immutable);
        }
    }

    /// <summary>A WAL-mode database (header bytes 18 and 19 are 2) whose <c>-wal</c> file is gone: nobody has it open.</summary>
    internal static bool IsClosedWalDatabase(string path) => SqliteReadOnly.IsClosedWalDatabase(path);

    private static OpenCodeDatabase Open(string path, SqliteOpenMode mode)
    {
        SqliteConnection connection;
        try
        {
            connection = SqliteConnection.Open(path, mode);
        }
        catch (SqliteException e)
        {
            throw new OpenCodeOpenException(OpenCodeStatus.Unreadable, e.Message);
        }

        try
        {
            if (!HasRequiredTables(connection))
            {
                throw new OpenCodeOpenException(OpenCodeStatus.Unsupported, "required tables are missing");
            }

            return new OpenCodeDatabase(connection, mode == SqliteOpenMode.Immutable);
        }
        catch (SqliteException e)
        {
            connection.Dispose();
            var status = e.PrimaryCode is SqliteNative.Error or SqliteNative.NotADatabase
                ? OpenCodeStatus.Unsupported
                : OpenCodeStatus.Unreadable;
            throw new OpenCodeOpenException(status, e.Message);
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    public List<OpenCodeSessionInfo> Sessions(long? updatedSince = null)
    {
        var statement = updatedSince is { } since ? _sessionsSince.Bind(1, since) : _sessions;
        var sessions = new List<OpenCodeSessionInfo>();
        try
        {
            while (statement.Step())
            {
                if (statement.GetString(0) is not { } id)
                {
                    continue;
                }

                sessions.Add(new OpenCodeSessionInfo(
                    id, statement.GetString(1), statement.GetString(2), statement.GetInt64(3), statement.GetInt64(4)));
            }
        }
        finally
        {
            statement.Reset();
        }

        return sessions;
    }

    /// <summary>Every row of a session in <c>seq</c> order; <paramref name="skip"/> sees (id, time_updated) before <c>data</c> is decoded.</summary>
    public List<OpenCodeRow> SessionRows(string sessionId, long? updatedSince = null, Func<string, long, bool>? skip = null)
    {
        var statement = updatedSince is { } since
            ? _sessionRowsSince.Bind(1, sessionId).Bind(2, since)
            : _sessionRows.Bind(1, sessionId);
        return ReadRows(statement, skip);
    }

    /// <summary>Rows created at or after <paramref name="sinceMs"/> (the <c>time_created</c> index).</summary>
    public List<OpenCodeRow> RowsCreatedSince(long sinceMs, Func<string, long, bool>? skip = null) =>
        ReadRows(_rowsCreatedSince.Bind(1, sinceMs), skip);

    /// <summary>The current versions of the given rows.</summary>
    public List<OpenCodeRow> RowsByIds(IReadOnlyCollection<string> ids, Func<string, long, bool>? skip = null)
    {
        var rows = new List<OpenCodeRow>();
        foreach (var chunk in ids.Chunk(IdBatch))
        {
            var placeholders = new StringBuilder();
            for (var i = 0; i < chunk.Length; i++)
            {
                placeholders.Append(i == 0 ? "?" : ",?");
            }

            using var statement = _connection.Prepare(
                $"SELECT {RowColumns} FROM session_message WHERE id IN ({placeholders}) ORDER BY session_id, seq");
            for (var i = 0; i < chunk.Length; i++)
            {
                statement.Bind(i + 1, chunk[i]);
            }

            rows.AddRange(ReadRows(statement, skip));
        }

        return rows;
    }

    public long? MaxCreatedMs()
    {
        try
        {
            return _maxCreated.Step() ? _maxCreated.GetNullableInt64(0) : null;
        }
        finally
        {
            _maxCreated.Reset();
        }
    }

    /// <summary>Number of rows and latest <c>time_updated</c> per session (one scan; <c>data</c> is not read).</summary>
    public Dictionary<string, (long Rows, long LastUpdatedMs)> SessionActivity()
    {
        using var statement = _connection.Prepare(
            "SELECT session_id, count(*), max(time_updated) FROM session_message GROUP BY session_id");
        var activity = new Dictionary<string, (long, long)>(StringComparer.Ordinal);
        while (statement.Step())
        {
            if (statement.GetString(0) is { } id)
            {
                activity[id] = (statement.GetInt64(1), statement.GetInt64(2));
            }
        }

        return activity;
    }

    public void Dispose() => _connection.Dispose();

    private static bool HasRequiredTables(SqliteConnection connection)
    {
        using var statement = connection.Prepare(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('session_v2', 'session_message')");
        return statement.Step() && statement.GetInt64(0) == 2;
    }

    private static List<OpenCodeRow> ReadRows(SqliteStatement statement, Func<string, long, bool>? skip)
    {
        var rows = new List<OpenCodeRow>();
        try
        {
            while (statement.Step())
            {
                if (statement.GetString(0) is not { } id || statement.GetString(1) is not { } session)
                {
                    continue;
                }

                var updated = statement.GetInt64(5);
                if (skip?.Invoke(id, updated) == true)
                {
                    continue;
                }

                rows.Add(new OpenCodeRow(
                    id,
                    session,
                    OpenCodeRow.KindOf(statement.GetUtf8(2)),
                    statement.GetInt64(3),
                    statement.GetInt64(4),
                    updated,
                    OpenCodeDataReader.Read(statement.GetUtf8(6))));
            }
        }
        finally
        {
            statement.Reset();
        }

        return rows;
    }
}

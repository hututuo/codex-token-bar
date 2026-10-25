using System.Globalization;
using System.Text;
using AgentSpeed.Core.IO.Sqlite;

namespace AgentSpeed.Core.Antigravity;

internal enum AntigravityFormat
{
    Supported,

    /// <summary>No <c>steps</c> table with <c>idx</c>, <c>step_type</c>, <c>status</c> and <c>metadata</c>.</summary>
    Unsupported,
}

/// <summary>
/// What has been read of one conversation database so far (METRICS 5.4): the <c>idx</c> cursors of each table, the
/// steps last seen with an open status, and whether the trajectory metadata was found.
/// </summary>
internal sealed class AntigravityCursors
{
    /// <summary>Open steps re-read by <c>idx</c> on every read, at most this many (the newest).</summary>
    public const int MaxOpenSteps = 256;

    public long Steps { get; set; } = -1;

    public long Generations { get; set; } = -1;

    public long Executors { get; set; } = -1;

    public SortedSet<long> OpenSteps { get; } = [];

    /// <summary>Steps whose malformed metadata was already counted: open steps are read again, each idx counts once.</summary>
    public HashSet<long> MalformedSteps { get; } = [];

    public bool TrajectoryFound { get; set; }

    /// <summary>A malformed trajectory blob is retried until a valid one is found, but counts one malformed line once.</summary>
    public bool TrajectoryMalformed { get; set; }

    public bool IsComplete => Steps < 0 && Generations < 0 && Executors < 0;
}

/// <summary>
/// Read-only access to one Antigravity conversation database (METRICS 4.8): opened with the rules of 4.5, never
/// written, read in one short transaction with only the queries of 4.8 and their 1 MiB size guards. Not thread-safe.
/// </summary>
internal sealed class AntigravityDatabase : IDisposable
{
    public const int MaxBlobBytes = 1024 * 1024;

    private static readonly string StepColumns =
        string.Create(CultureInfo.InvariantCulture, $"idx, step_type, status, CASE WHEN length(metadata) <= {MaxBlobBytes} THEN metadata END");

    private static readonly string StepsSql = $"SELECT {StepColumns} FROM steps WHERE idx > ?1 ORDER BY idx, rowid";

    private static readonly string GenerationsSql = string.Create(CultureInfo.InvariantCulture,
        $"SELECT idx, CASE WHEN typeof(size) = 'integer' AND size <= {MaxBlobBytes} AND length(data) <= {MaxBlobBytes} THEN data END FROM gen_metadata WHERE idx > ?1 ORDER BY idx, rowid");

    private static readonly string ExecutorsSql = string.Create(CultureInfo.InvariantCulture,
        $"SELECT idx, CASE WHEN length(data) <= {MaxBlobBytes} THEN data END FROM executor_metadata WHERE idx > ?1 ORDER BY idx, rowid");

    private static readonly string TrajectorySql = string.Create(CultureInfo.InvariantCulture,
        $"SELECT CASE WHEN length(data) <= {MaxBlobBytes} THEN data END FROM trajectory_metadata_blob ORDER BY rowid LIMIT 1");

    private static readonly string[] RequiredStepColumns = ["idx", "step_type", "status", "metadata"];

    private readonly SqliteConnection _connection;

    private AntigravityDatabase(SqliteConnection connection, bool immutable, AntigravityFormat format)
    {
        _connection = connection;
        IsImmutable = immutable;
        Format = format;
    }

    public string Path => _connection.Path;

    /// <summary>Opened with <c>immutable=1</c>: drop it on the next change of the database or once a <c>-wal</c> appears.</summary>
    public bool IsImmutable { get; }

    public AntigravityFormat Format { get; }

    /// <exception cref="SqliteException">The database cannot be opened or read.</exception>
    public static AntigravityDatabase Open(string path)
    {
        var connection = SqliteReadOnly.Open(path, out var immutable);
        try
        {
            return new AntigravityDatabase(connection, immutable, HasStepsTable(connection) ? AntigravityFormat.Supported : AntigravityFormat.Unsupported);
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    /// <summary>
    /// Reads what is new since <paramref name="cursors"/> into <paramref name="batch"/> in one read transaction and
    /// advances the cursors; returns the number of blob bytes read. A query that fails reads nothing (like a missing table).
    /// </summary>
    public long Read(AntigravityCursors cursors, AntigravityBatch batch)
    {
        long bytes = 0;
        _connection.Execute("BEGIN");
        try
        {
            if (!cursors.TrajectoryFound)
            {
                bytes += ReadTrajectory(cursors, batch);
            }

            bytes += ReadGenerations(cursors, batch);
            bytes += ReadExecutors(cursors, batch);
            bytes += ReadSteps(cursors, batch);
        }
        finally
        {
            try
            {
                _connection.Execute("COMMIT");
            }
            catch (SqliteException)
            {
            }
        }

        return bytes;
    }

    public void Dispose() => _connection.Dispose();

    private static bool HasStepsTable(SqliteConnection connection)
    {
        var columns = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            using var statement = connection.Prepare("PRAGMA table_info(steps)");
            while (statement.Step())
            {
                if (statement.GetString(1) is { } name)
                {
                    columns.Add(name);
                }
            }
        }
        catch (SqliteException)
        {
            return false;
        }

        return RequiredStepColumns.All(columns.Contains);
    }

    private long ReadTrajectory(AntigravityCursors cursors, AntigravityBatch batch)
    {
        try
        {
            using var statement = _connection.Prepare(TrajectorySql);
            if (!statement.Step() || statement.IsNull(0))
            {
                return 0;
            }

            var blob = statement.GetBlob(0);
            try
            {
                batch.Trajectory = AntigravityDecoder.Trajectory(blob);
                cursors.TrajectoryFound = true;
            }
            catch (ProtoFormatException)
            {
                if (!cursors.TrajectoryMalformed)
                {
                    cursors.TrajectoryMalformed = true;
                    batch.OnMalformed();
                }
            }

            return blob.Length;
        }
        catch (SqliteException)
        {
            return 0;
        }
    }

    private long ReadGenerations(AntigravityCursors cursors, AntigravityBatch batch)
    {
        long bytes = 0;
        try
        {
            using var statement = _connection.Prepare(GenerationsSql);
            statement.Bind(1, cursors.Generations);
            while (statement.Step())
            {
                var idx = statement.GetInt64(0);
                cursors.Generations = Math.Max(cursors.Generations, idx);
                if (statement.IsNull(1))
                {
                    continue;
                }

                var blob = statement.GetBlob(1);
                bytes += blob.Length;
                try
                {
                    batch.Generations.Add(AntigravityDecoder.Generation(idx, blob));
                }
                catch (ProtoFormatException)
                {
                    batch.OnMalformed();
                }
            }
        }
        catch (SqliteException)
        {
        }

        return bytes;
    }

    private long ReadExecutors(AntigravityCursors cursors, AntigravityBatch batch)
    {
        long bytes = 0;
        try
        {
            using var statement = _connection.Prepare(ExecutorsSql);
            statement.Bind(1, cursors.Executors);
            while (statement.Step())
            {
                var idx = statement.GetInt64(0);
                cursors.Executors = Math.Max(cursors.Executors, idx);
                if (statement.IsNull(1))
                {
                    continue;
                }

                var blob = statement.GetBlob(1);
                bytes += blob.Length;
                try
                {
                    batch.Executors.Add(AntigravityDecoder.Executor(idx, blob));
                }
                catch (ProtoFormatException)
                {
                    batch.OnMalformed();
                }
            }
        }
        catch (SqliteException)
        {
        }

        return bytes;
    }

    private long ReadSteps(AntigravityCursors cursors, AntigravityBatch batch)
    {
        long bytes = 0;
        var reread = cursors.OpenSteps.ToArray();
        try
        {
            using var statement = _connection.Prepare(reread.Length == 0 ? StepsSql : StepsWithOpenSql(reread.Length));
            statement.Bind(1, cursors.Steps);
            for (var i = 0; i < reread.Length; i++)
            {
                statement.Bind(i + 2, reread[i]);
            }

            var cursor = cursors.Steps;
            var counted = new List<long>();
            while (statement.Step())
            {
                var idx = statement.GetInt64(0);
                var status = statement.GetInt64(2);
                cursor = Math.Max(cursor, idx);
                var open = StepCodes.IsOpen(status);
                if (open)
                {
                    cursors.OpenSteps.Add(idx);
                }
                else
                {
                    cursors.OpenSteps.Remove(idx);
                }

                AntigravityStep? step = null;
                if (!statement.IsNull(3))
                {
                    var blob = statement.GetBlob(3);
                    bytes += blob.Length;
                    try
                    {
                        step = AntigravityDecoder.Step(blob);
                    }
                    catch (ProtoFormatException)
                    {
                        // An open step is read again on every change; its malformed metadata counts once.
                        if (!cursors.MalformedSteps.Contains(idx))
                        {
                            batch.OnMalformed();
                            counted.Add(idx);
                        }
                    }
                }

                batch.Steps.Add(new AntigravityStepRow(idx, statement.GetInt64(1), status, step));
            }

            cursors.Steps = cursor;
            cursors.MalformedSteps.UnionWith(counted);
        }
        catch (SqliteException)
        {
        }

        while (cursors.OpenSteps.Count > AntigravityCursors.MaxOpenSteps)
        {
            cursors.OpenSteps.Remove(cursors.OpenSteps.Min);
        }

        return bytes;
    }

    private static string StepsWithOpenSql(int count)
    {
        var placeholders = new StringBuilder();
        for (var i = 0; i < count; i++)
        {
            placeholders.Append(i == 0 ? "?" : ",?").Append((i + 2).ToString(CultureInfo.InvariantCulture));
        }

        return $"SELECT {StepColumns} FROM steps WHERE idx > ?1 OR idx IN ({placeholders}) ORDER BY idx, rowid";
    }
}

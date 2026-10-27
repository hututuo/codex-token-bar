using System.Buffers.Binary;
using System.Runtime.InteropServices;
using AgentSpeed.Core.IO.Sqlite;

namespace AgentSpeed.Core.History;

/// <summary>What the store keeps for one analysed file (or OpenCode session): its identity and per-day contributions.</summary>
internal sealed class StoredFile
{
    /// <summary>Row id in the store; 0 until saved.</summary>
    public long Id { get; set; }

    public required string Path { get; init; }

    public required string Family { get; init; }

    public long Size { get; init; }

    /// <summary>Modification time in ticks (files) or Unix milliseconds (OpenCode sessions).</summary>
    public long Modified { get; init; }

    public int Version { get; init; }

    public required Dictionary<DayKey, DayAggregate> Days { get; init; }

    /// <summary>Some response has no known price (METRICS 9.7 re-analysis).</summary>
    public bool HasUnpriced => Days.Values.Any(d => d.HasUnpriced);
}

/// <summary>
/// The persistent daily-history store (METRICS 8): per file its identity, the 64-bit hashes of the response keys it
/// owns and its per-day contributions, plus live day peaks. Only aggregates; never keys in plain text or content.
/// One owner thread.
/// </summary>
internal sealed partial class HistoryStore : IDisposable
{
    /// <summary>
    /// 2 adds measured output and time per model (METRICS 8). 3 adds cost per contribution and model, the day bindings
    /// of the price tables and their copies (METRICS 9.7).
    /// </summary>
    public const int SchemaVersion = 3;

    /// <summary>Day → price table version, and a copy of every version a binding references (METRICS 9.7).</summary>
    private const string PriceTablesSchema = """
        CREATE TABLE IF NOT EXISTS price_bindings (day TEXT PRIMARY KEY, version INTEGER NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS price_tables (version INTEGER PRIMARY KEY, body BLOB NOT NULL);
        """;

    private const string Schema = """
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            family TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified INTEGER NOT NULL,
            version INTEGER NOT NULL,
            keys BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS contributions (
            file_id INTEGER NOT NULL,
            day TEXT NOT NULL,
            source TEXT NOT NULL,
            requests INTEGER NOT NULL,
            input INTEGER NOT NULL,
            cached_input INTEGER NOT NULL,
            cache_write_input INTEGER NOT NULL,
            output INTEGER NOT NULL,
            reasoning INTEGER NOT NULL,
            measured_output INTEGER NOT NULL,
            measured_ms INTEGER NOT NULL,
            unfinalized INTEGER NOT NULL,
            agents INTEGER NOT NULL,
            cost_micro_usd INTEGER,
            unpriced_requests INTEGER,
            PRIMARY KEY (file_id, day, source)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS contribution_models (
            file_id INTEGER NOT NULL,
            day TEXT NOT NULL,
            source TEXT NOT NULL,
            model TEXT NOT NULL,
            requests INTEGER NOT NULL,
            output INTEGER NOT NULL,
            measured_output INTEGER NOT NULL DEFAULT 0,
            measured_ms INTEGER NOT NULL DEFAULT 0,
            cost_micro_usd INTEGER,
            unpriced_requests INTEGER,
            PRIMARY KEY (file_id, day, source, model)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS day_peaks (day TEXT PRIMARY KEY, peak REAL NOT NULL) WITHOUT ROWID;
        """;

    /// <summary>
    /// Observed network traffic per day and key (METRICS 10.9), created whenever the store is opened; the schema version
    /// does not change for it, so older builds still open the file.
    /// </summary>
    private const string TrafficSchema = """
        CREATE TABLE IF NOT EXISTS day_traffic (
            day TEXT NOT NULL,
            key TEXT NOT NULL,
            rx INTEGER NOT NULL,
            tx INTEGER NOT NULL,
            rx_tools INTEGER NOT NULL,
            tx_tools INTEGER NOT NULL,
            sampled_ms INTEGER NOT NULL,
            PRIMARY KEY (day, key)) WITHOUT ROWID;
        """;

    /// <summary>The meta key holding the first local date with a stored traffic sample.</summary>
    public const string TrafficSinceKey = "trafficSince";

    /// <summary>
    /// Held while a short-lived connection (the traffic writer) has the file open and while "Clear history" deletes it,
    /// so the delete never meets an open file.
    /// </summary>
    public static readonly object FileGate = new();

    private readonly SqliteConnection _connection;

    private HistoryStore(SqliteConnection connection)
    {
        _connection = connection;
    }

    public string Path => _connection.Path;

    /// <summary>Opens (creating when needed) the store; a corrupt store is deleted and created again.</summary>
    /// <exception cref="SqliteException">The store cannot be opened (or was written by a newer schema).</exception>
    public static HistoryStore Open(string path)
    {
        var directory = System.IO.Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        try
        {
            return OpenOnce(path);
        }
        catch (SqliteException e) when (e.IsCorrupt)
        {
            Delete(path);
            return OpenOnce(path);
        }
    }

    /// <summary>Removes the store and its WAL files.</summary>
    public static void Delete(string path)
    {
        foreach (var suffix in (string[])["", "-wal", "-shm", "-journal"])
        {
            try
            {
                File.Delete(path + suffix);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                if (suffix.Length == 0)
                {
                    throw;
                }
            }
        }
    }

    public string? Meta(string key)
    {
        using var statement = _connection.Prepare("SELECT value FROM meta WHERE key = ?1");
        statement.Bind(1, key);
        return statement.Step() ? statement.GetString(0) : null;
    }

    public void SetMeta(string key, string value)
    {
        using var statement = _connection.Prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)");
        statement.Bind(1, key).Bind(2, value).Run();
    }

    /// <summary>Every stored file with its contributions, by path.</summary>
    public Dictionary<string, StoredFile> LoadFiles(StringComparer pathComparer)
    {
        var byId = new Dictionary<long, StoredFile>();
        using (var files = _connection.Prepare("SELECT id, path, family, size, modified, version FROM files"))
        {
            while (files.Step())
            {
                var entry = new StoredFile
                {
                    Id = files.GetInt64(0),
                    Path = files.GetString(1) ?? string.Empty,
                    Family = files.GetString(2) ?? string.Empty,
                    Size = files.GetInt64(3),
                    Modified = files.GetInt64(4),
                    Version = (int)files.GetInt64(5),
                    Days = [],
                };
                byId[entry.Id] = entry;
            }
        }

        using (var days = _connection.Prepare(
            "SELECT file_id, day, source, requests, input, cached_input, cache_write_input, output, reasoning, " +
            "measured_output, measured_ms, unfinalized, agents, cost_micro_usd, unpriced_requests FROM contributions"))
        {
            while (days.Step())
            {
                if (!byId.TryGetValue(days.GetInt64(0), out var entry) || Key(days.GetString(1), days.GetString(2)) is not { } key)
                {
                    continue;
                }

                entry.Days[key] = new DayAggregate
                {
                    Requests = days.GetInt64(3),
                    Input = days.GetInt64(4),
                    CachedInput = days.GetInt64(5),
                    CacheWriteInput = days.GetInt64(6),
                    Output = days.GetInt64(7),
                    Reasoning = days.GetInt64(8),
                    MeasuredOutput = days.GetInt64(9),
                    MeasuredMs = days.GetInt64(10),
                    Unfinalized = days.GetInt64(11),
                    Agents = (int)days.GetInt64(12),
                    Cost = ReadCost(days, 13),
                };
            }
        }

        using (var models = _connection.Prepare(
            "SELECT file_id, day, source, model, requests, output, measured_output, measured_ms, cost_micro_usd, " +
            "unpriced_requests FROM contribution_models"))
        {
            while (models.Step())
            {
                if (byId.TryGetValue(models.GetInt64(0), out var entry)
                    && Key(models.GetString(1), models.GetString(2)) is { } key
                    && entry.Days.TryGetValue(key, out var day))
                {
                    day.Models[models.GetString(3) ?? string.Empty] = new ModelTotals(
                        models.GetInt64(4), models.GetInt64(5), models.GetInt64(6), models.GetInt64(7), ReadCost(models, 8));
                }
            }
        }

        LoadModes(byId);
        var result = new Dictionary<string, StoredFile>(byId.Count, pathComparer);
        foreach (var entry in byId.Values)
        {
            result[entry.Path] = entry;
        }

        return result;
    }

    /// <summary>Settles the keys of every stored file except <paramref name="excludedIds"/> (they are analysed again).</summary>
    public void LoadKeys(Parsing.KeyLedger ledger, IReadOnlySet<long> excludedIds)
    {
        using var statement = _connection.Prepare("SELECT id, keys FROM files");
        while (statement.Step())
        {
            if (!excludedIds.Contains(statement.GetInt64(0)))
            {
                SettleBlob(ledger, statement.GetBlob(1));
            }
        }
    }

    public void LoadKeys(Parsing.KeyLedger ledger, long fileId)
    {
        using var statement = _connection.Prepare("SELECT keys FROM files WHERE id = ?1");
        statement.Bind(1, fileId);
        if (statement.Step())
        {
            SettleBlob(ledger, statement.GetBlob(0));
        }
    }

    /// <summary>Writes files with their owned key hashes and contributions in one transaction; assigns new ids.</summary>
    public void Save(IReadOnlyList<(StoredFile Entry, ulong[] Keys)> batch)
    {
        if (batch.Count == 0)
        {
            return;
        }

        using var insertFile = _connection.Prepare(
            "INSERT INTO files (path, family, size, modified, version, keys) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
        using var updateFile = _connection.Prepare(
            "UPDATE files SET family = ?2, size = ?3, modified = ?4, version = ?5, keys = ?6 WHERE id = ?1");
        using var findFile = _connection.Prepare("SELECT id FROM files WHERE path = ?1");
        using var deleteDays = _connection.Prepare("DELETE FROM contributions WHERE file_id = ?1");
        using var deleteModels = _connection.Prepare("DELETE FROM contribution_models WHERE file_id = ?1");
        using var insertDay = _connection.Prepare(
            "INSERT INTO contributions (file_id, day, source, requests, input, cached_input, cache_write_input, output, " +
            "reasoning, measured_output, measured_ms, unfinalized, agents, cost_micro_usd, unpriced_requests) " +
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)");
        using var insertModel = _connection.Prepare(
            "INSERT INTO contribution_models (file_id, day, source, model, requests, output, measured_output, measured_ms, " +
            "cost_micro_usd, unpriced_requests) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)");
        _connection.Transaction(() =>
        {
            foreach (var (entry, keys) in batch)
            {
                var blob = KeyBlob(keys);
                if (entry.Id == 0)
                {
                    findFile.Bind(1, entry.Path);
                    entry.Id = findFile.Step() ? findFile.GetInt64(0) : 0;
                    findFile.Reset();
                }

                var write = entry.Id == 0 ? insertFile.Bind(1, entry.Path) : updateFile.Bind(1, entry.Id);
                write.Bind(2, entry.Family).Bind(3, entry.Size).Bind(4, entry.Modified).Bind(5, entry.Version).BindBlob(6, blob).Run();
                if (entry.Id == 0)
                {
                    entry.Id = _connection.LastInsertRowId;
                }

                deleteDays.Bind(1, entry.Id).Run();
                deleteModels.Bind(1, entry.Id).Run();
                SaveModes(entry);
                foreach (var (key, day) in entry.Days)
                {
                    var source = SourceNames.Of(key.Source);
                    insertDay.Bind(1, entry.Id).Bind(2, key.Day).Bind(3, source)
                        .Bind(4, day.Requests).Bind(5, day.Input).Bind(6, day.CachedInput).Bind(7, day.CacheWriteInput)
                        .Bind(8, day.Output).Bind(9, day.Reasoning).Bind(10, day.MeasuredOutput).Bind(11, day.MeasuredMs)
                        .Bind(12, day.Unfinalized).Bind(13, day.Agents);
                    BindCost(insertDay, 14, day.Cost).Run();
                    foreach (var (model, usage) in day.Models)
                    {
                        insertModel.Bind(1, entry.Id).Bind(2, key.Day).Bind(3, source).Bind(4, model)
                            .Bind(5, usage.Requests).Bind(6, usage.Output).Bind(7, usage.MeasuredOutput).Bind(8, usage.MeasuredMs);
                        BindCost(insertModel, 9, usage.Cost).Run();
                    }
                }
            }
        });
    }

    public Dictionary<string, int> PriceBindings()
    {
        using var statement = _connection.Prepare("SELECT day, version FROM price_bindings");
        var bindings = new Dictionary<string, int>(StringComparer.Ordinal);
        while (statement.Step())
        {
            if (statement.GetString(0) is { } day)
            {
                bindings[day] = (int)statement.GetInt64(1);
            }
        }

        return bindings;
    }

    /// <summary>The stored table copies, by version.</summary>
    public Dictionary<int, byte[]> PriceTables()
    {
        using var statement = _connection.Prepare("SELECT version, body FROM price_tables");
        var tables = new Dictionary<int, byte[]>();
        while (statement.Step())
        {
            tables[(int)statement.GetInt64(0)] = statement.GetBlob(1).ToArray();
        }

        return tables;
    }

    /// <summary>
    /// Saves bindings, a copy of every table they reference that is not stored yet (<paramref name="tables"/> supplies
    /// them), and deletes the copies no binding references any more.
    /// </summary>
    public void SavePriceBindings(IReadOnlyDictionary<string, int> bindings, Func<int, byte[]?> tables)
    {
        if (bindings.Count == 0)
        {
            return;
        }

        using var upsert = _connection.Prepare(
            "INSERT INTO price_bindings (day, version) VALUES (?1, ?2) ON CONFLICT(day) DO UPDATE SET version = excluded.version");
        using var stored = _connection.Prepare("SELECT version FROM price_tables");
        using var insert = _connection.Prepare("INSERT INTO price_tables (version, body) VALUES (?1, ?2)");
        _connection.Transaction(() =>
        {
            foreach (var (day, version) in bindings.OrderBy(b => b.Key, StringComparer.Ordinal))
            {
                upsert.Bind(1, day).Bind(2, version).Run();
            }

            var have = new HashSet<int>();
            while (stored.Step())
            {
                have.Add((int)stored.GetInt64(0));
            }

            stored.Reset();
            foreach (var version in bindings.Values.Distinct().Where(v => !have.Contains(v)).Order())
            {
                if (tables(version) is { } body)
                {
                    insert.Bind(1, version).BindBlob(2, body).Run();
                }
            }

            _connection.Execute("DELETE FROM price_tables WHERE version NOT IN (SELECT DISTINCT version FROM price_bindings)");
        });
    }

    /// <summary>
    /// Bindings and table copies of the store at <paramref name="path"/>, read without changing it; empty when the store
    /// does not exist yet or predates costs. The app reads them before the live engine prices anything (METRICS 9.7).
    /// </summary>
    public static (Dictionary<string, int> Bindings, Dictionary<int, byte[]> Tables) StoredPricing(string path)
    {
        var bindings = new Dictionary<string, int>(StringComparer.Ordinal);
        var tables = new Dictionary<int, byte[]>();
        try
        {
            if (!File.Exists(path))
            {
                return (bindings, tables);
            }

            using var connection = SqliteConnection.Open(path, SqliteOpenMode.ReadOnly);
            using (var statement = connection.Prepare("SELECT day, version FROM price_bindings"))
            {
                while (statement.Step())
                {
                    if (statement.GetString(0) is { } day)
                    {
                        bindings[day] = (int)statement.GetInt64(1);
                    }
                }
            }

            using (var statement = connection.Prepare("SELECT version, body FROM price_tables"))
            {
                while (statement.Step())
                {
                    tables[(int)statement.GetInt64(0)] = statement.GetBlob(1).ToArray();
                }
            }
        }
        catch (Exception e) when (e is SqliteException or IOException or UnauthorizedAccessException)
        {
            bindings.Clear();
            tables.Clear();
        }

        return (bindings, tables);
    }

    public Dictionary<string, double> Peaks()
    {
        using var statement = _connection.Prepare("SELECT day, peak FROM day_peaks");
        var peaks = new Dictionary<string, double>(StringComparer.Ordinal);
        while (statement.Step())
        {
            if (statement.GetString(0) is { } day)
            {
                peaks[day] = statement.GetDouble(1);
            }
        }

        return peaks;
    }

    public void SavePeaks(IReadOnlyDictionary<string, double> peaks)
    {
        if (peaks.Count == 0)
        {
            return;
        }

        using var statement = _connection.Prepare("INSERT OR REPLACE INTO day_peaks (day, peak) VALUES (?1, ?2)");
        _connection.Transaction(() =>
        {
            foreach (var (day, peak) in peaks)
            {
                statement.Bind(1, day).Bind(2, peak).Run();
            }
        });
    }

    /// <summary>Upserts whole days of traffic rows and moves <c>trafficSince</c> back when needed (METRICS 10.9).</summary>
    public void SaveTraffic(IReadOnlyList<Traffic.TrafficDay> rows)
    {
        if (rows.Count == 0)
        {
            return;
        }

        using var upsert = _connection.Prepare(
            "INSERT INTO day_traffic (day, key, rx, tx, rx_tools, tx_tools, sampled_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) " +
            "ON CONFLICT(day, key) DO UPDATE SET rx = excluded.rx, tx = excluded.tx, rx_tools = excluded.rx_tools, " +
            "tx_tools = excluded.tx_tools, sampled_ms = excluded.sampled_ms");
        var first = rows.Select(r => r.Day).Min(StringComparer.Ordinal)!;
        _connection.Transaction(() =>
        {
            foreach (var row in rows)
            {
                upsert.Bind(1, row.Day).Bind(2, row.Key).Bind(3, row.Rx).Bind(4, row.Tx).Bind(5, row.RxTools).Bind(6, row.TxTools)
                    .Bind(7, row.SampledMs).Run();
            }

            if (Meta(TrafficSinceKey) is not { } since || string.CompareOrdinal(first, since) < 0)
            {
                SetMeta(TrafficSinceKey, first);
            }
        });
    }

    /// <summary>Every stored traffic row and <c>trafficSince</c>.</summary>
    public (List<Traffic.TrafficDay> Days, string? Since) LoadTraffic() => ReadTraffic(_connection);

    /// <summary>The traffic rows of the store at <paramref name="path"/>, read without changing it; empty when there is none.</summary>
    public static (List<Traffic.TrafficDay> Days, string? Since) StoredTraffic(string path)
    {
        try
        {
            lock (FileGate)
            {
                if (!File.Exists(path))
                {
                    return ([], null);
                }

                using var connection = SqliteConnection.Open(path, SqliteOpenMode.ReadOnly);
                return ReadTraffic(connection);
            }
        }
        catch (Exception e) when (e is SqliteException or IOException or UnauthorizedAccessException)
        {
            return ([], null);
        }
    }

    private static (List<Traffic.TrafficDay> Days, string? Since) ReadTraffic(SqliteConnection connection)
    {
        var days = new List<Traffic.TrafficDay>();
        if (connection.ScalarInt64("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'day_traffic'") is not > 0)
        {
            return (days, null);
        }

        using (var statement = connection.Prepare(
            "SELECT day, key, rx, tx, rx_tools, tx_tools, sampled_ms FROM day_traffic ORDER BY day, key"))
        {
            while (statement.Step())
            {
                if (statement.GetString(0) is { Length: 10 } day && statement.GetString(1) is { } key
                    && (key == Traffic.TrafficDay.MachineKey || SourceNames.Parse(key) is not null))
                {
                    days.Add(new Traffic.TrafficDay(day, key, Math.Max(0, statement.GetInt64(2)), Math.Max(0, statement.GetInt64(3)),
                        Math.Max(0, statement.GetInt64(4)), Math.Max(0, statement.GetInt64(5)), Math.Max(0, statement.GetInt64(6))));
                }
            }
        }

        string? since = null;
        using (var meta = connection.Prepare("SELECT value FROM meta WHERE key = ?1"))
        {
            meta.Bind(1, TrafficSinceKey);
            if (meta.Step())
            {
                since = meta.GetString(0);
            }
        }

        if (since is null && days.Count > 0)
        {
            since = days[0].Day;
        }

        return (days, since);
    }

    public void Dispose() => _connection.Dispose();

    private static HistoryStore OpenOnce(string path)
    {
        var connection = SqliteConnection.Open(path, SqliteOpenMode.ReadWriteCreate);
        try
        {
            connection.Execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;");
            var version = connection.ScalarInt64("PRAGMA user_version") ?? 0;
            if (version > SchemaVersion)
            {
                throw new SqliteException(SqliteNative.Error, "The history store was written by a newer version.");
            }

            if (version < SchemaVersion)
            {
                connection.Transaction(() =>
                {
                    connection.Execute(Schema);
                    // Stored models gain measured totals (AnalysisVersion 2) and costs (3); each bump analyses every file
                    // again to fill them, and contributions of files that are gone keep NULL costs (METRICS 8).
                    AddMissingColumns(connection, "contribution_models",
                        ("measured_output", "INTEGER NOT NULL DEFAULT 0"), ("measured_ms", "INTEGER NOT NULL DEFAULT 0"),
                        ("cost_micro_usd", "INTEGER"), ("unpriced_requests", "INTEGER"));
                    AddMissingColumns(connection, "contributions", ("cost_micro_usd", "INTEGER"), ("unpriced_requests", "INTEGER"));

                    connection.Execute(PriceTablesSchema);
                    connection.Execute($"PRAGMA user_version = {SchemaVersion}");
                });
            }

            connection.Execute(TrafficSchema);
            connection.Execute(ModesSchema);
            return new HistoryStore(connection);
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    private static void AddMissingColumns(SqliteConnection connection, string table, params (string Name, string Type)[] columns)
    {
        var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var info = connection.Prepare($"PRAGMA table_info({table})"))
        {
            while (info.Step())
            {
                if (info.GetString(1) is { } name)
                {
                    existing.Add(name);
                }
            }
        }

        foreach (var (name, type) in columns)
        {
            if (!existing.Contains(name))
            {
                connection.Execute($"ALTER TABLE {table} ADD COLUMN {name} {type}");
            }
        }
    }

    /// <summary>A cost pair stored at <paramref name="column"/> and the next column; null when stored before costs existed.</summary>
    private static CostTally? ReadCost(SqliteStatement row, int column) =>
        row.GetNullableInt64(column) is { } micro && row.GetNullableInt64(column + 1) is { } unpriced
            ? new CostTally(micro, unpriced)
            : null;

    private static SqliteStatement BindCost(SqliteStatement statement, int column, CostTally? cost) => cost is { } value
        ? statement.Bind(column, value.CostMicroUsd).Bind(column + 1, value.UnpricedRequests)
        : statement.Bind(column, (string?)null).Bind(column + 1, (string?)null);

    private static DayKey? Key(string? day, string? source) =>
        day is not null && SourceNames.Parse(source) is { } kind ? new DayKey(day, kind) : null;

    private static byte[] KeyBlob(ulong[] keys)
    {
        var blob = new byte[keys.Length * sizeof(ulong)];
        for (var i = 0; i < keys.Length; i++)
        {
            BinaryPrimitives.WriteUInt64LittleEndian(blob.AsSpan(i * sizeof(ulong)), keys[i]);
        }

        return blob;
    }

    private static void SettleBlob(Parsing.KeyLedger ledger, ReadOnlySpan<byte> blob)
    {
        var count = blob.Length / sizeof(ulong);
        if (count == 0)
        {
            return;
        }

        if (BitConverter.IsLittleEndian)
        {
            ledger.Settle(MemoryMarshal.Cast<byte, ulong>(blob[..(count * sizeof(ulong))]));
            return;
        }

        var keys = new ulong[count];
        for (var i = 0; i < count; i++)
        {
            keys[i] = BinaryPrimitives.ReadUInt64LittleEndian(blob[(i * sizeof(ulong))..]);
        }

        ledger.Settle(keys);
    }
}

/// <summary>Stable source names, as in METRICS 1 and the dumps.</summary>
internal static class SourceNames
{
    public static string Of(SourceKind source) => source switch
    {
        SourceKind.Codex => "codex",
        SourceKind.ClaudeCode => "claudeCode",
        SourceKind.ClaudeDesktop => "claudeDesktop",
        SourceKind.DeepSeek => "deepseek",
        SourceKind.OpenCode => "opencode",
        SourceKind.Gemini => "gemini",
        SourceKind.Omp => "omp",
        SourceKind.Antigravity => "antigravity",
        SourceKind.WorkBuddy => "workbuddy",
        SourceKind.WorkBuddyAi => "workbuddyAi",
        SourceKind.ZCode => "zcode",
        SourceKind.Kimi => "kimi",
        SourceKind.GrokBuild => "grokBuild",
        _ => throw new ArgumentOutOfRangeException(nameof(source)),
    };

    public static SourceKind? Parse(string? name) => name switch
    {
        "codex" => SourceKind.Codex,
        "claudeCode" => SourceKind.ClaudeCode,
        "claudeDesktop" => SourceKind.ClaudeDesktop,
        "deepseek" => SourceKind.DeepSeek,
        "opencode" => SourceKind.OpenCode,
        "gemini" => SourceKind.Gemini,
        "omp" => SourceKind.Omp,
        "antigravity" => SourceKind.Antigravity,
        "workbuddy" => SourceKind.WorkBuddy,
        "workbuddyAi" => SourceKind.WorkBuddyAi,
        "zcode" => SourceKind.ZCode,
        "kimi" => SourceKind.Kimi,
        "grokBuild" => SourceKind.GrokBuild,
        _ => null,
    };
}

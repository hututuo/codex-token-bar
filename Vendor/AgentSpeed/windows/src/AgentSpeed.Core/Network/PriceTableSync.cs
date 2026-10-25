using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using AgentSpeed.Core.Pricing;

namespace AgentSpeed.Core.Network;

/// <summary>
/// <c>&lt;app data&gt;/prices/sync.json</c> (NETWORK 3). <see cref="Version"/>, <see cref="Updated"/>, <see cref="Url"/> and
/// <see cref="ETag"/> describe the last valid table downloaded (whether or not it became current); <see cref="Failures"/>
/// counts consecutive failed rounds for the retry rule.
/// </summary>
public sealed record PriceSyncState
{
    public int? Version { get; init; }

    public string? Updated { get; init; }

    public string? Url { get; init; }

    public string? ETag { get; init; }

    public long? LastSuccessMs { get; init; }

    public long? LastAttemptMs { get; init; }

    public string? LastError { get; init; }

    public int Failures { get; init; }

    internal byte[] ToJson() => StoreJson.Write(writer =>
    {
        WriteOptional(writer, "etag", ETag);
        writer.WriteNumber("failures", Failures);
        WriteOptional(writer, "lastAttemptMs", LastAttemptMs);
        WriteOptional(writer, "lastError", LastError);
        WriteOptional(writer, "lastSuccessMs", LastSuccessMs);
        WriteOptional(writer, "updated", Updated);
        WriteOptional(writer, "url", Url);
        WriteOptional(writer, "version", Version);
    });

    /// <summary>Missing or null fields stay unset (<see cref="Failures"/> defaults to 0); a field of the wrong type makes it null.</summary>
    internal static PriceSyncState? FromJson(ReadOnlySpan<byte> utf8)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray());
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            var ok = true;
            var state = new PriceSyncState
            {
                Version = (int?)StoreJson.OptionalInt64(root, "version", int.MinValue, int.MaxValue, ref ok),
                Updated = StoreJson.OptionalString(root, "updated", ref ok),
                Url = StoreJson.OptionalString(root, "url", ref ok),
                ETag = StoreJson.OptionalString(root, "etag", ref ok),
                LastSuccessMs = StoreJson.OptionalInt64(root, "lastSuccessMs", long.MinValue, long.MaxValue, ref ok),
                LastAttemptMs = StoreJson.OptionalInt64(root, "lastAttemptMs", long.MinValue, long.MaxValue, ref ok),
                LastError = StoreJson.OptionalString(root, "lastError", ref ok),
                Failures = (int)(StoreJson.OptionalInt64(root, "failures", int.MinValue, int.MaxValue, ref ok) ?? 0),
            };
            return ok ? state : null;
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    private static void WriteOptional(Utf8JsonWriter writer, string name, string? value)
    {
        if (value is not null)
        {
            writer.WriteString(name, value);
        }
    }

    private static void WriteOptional(Utf8JsonWriter writer, string name, long? value)
    {
        if (value is { } number)
        {
            writer.WriteNumber(name, number);
        }
    }
}

/// <summary>What one sync round (or a manual check) found.</summary>
public abstract record PriceSyncOutcome
{
    private PriceSyncOutcome()
    {
    }

    public sealed record UpToDate : PriceSyncOutcome;

    public sealed record Updated(int Version) : PriceSyncOutcome;

    /// <summary>Only tables of a newer schema were offered: this build needs an update to use them.</summary>
    public sealed record NewerSchema : PriceSyncOutcome;

    public sealed record Failed(string Reason) : PriceSyncOutcome;
}

/// <param name="Table">The table that became current; hand it to the price book.</param>
public sealed record PriceSyncResult(PriceSyncOutcome Outcome, PriceTable? Table, PriceSyncState State);

/// <summary>The synced price table on disk: <c>&lt;app data&gt;/prices/prices.json</c> and <c>sync.json</c>, written atomically.</summary>
public sealed class PriceTableStore
{
    private const int MaxStateBytes = 64 << 10;

    private readonly Action<string>? _log;

    /// <param name="appDataDirectory"><c>%LOCALAPPDATA%\AgentSpeed</c> in the app; any folder in tests and the probe.</param>
    public PriceTableStore(string appDataDirectory, Action<string>? log = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(appDataDirectory);
        DirectoryPath = Path.Combine(appDataDirectory, "prices");
        _log = log;
    }

    public string DirectoryPath { get; }

    public string TablePath => Path.Combine(DirectoryPath, "prices.json");

    public string StatePath => Path.Combine(DirectoryPath, "sync.json");

    /// <summary>The stored table, validated again; an invalid copy is deleted (logged) so the bundled table is used.</summary>
    public PriceTable? LoadTable()
    {
        byte[]? data;
        try
        {
            var info = new FileInfo(TablePath);
            if (!info.Exists)
            {
                return null;
            }

            data = info.Length <= PriceTable.MaxBytes ? File.ReadAllBytes(TablePath) : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }

        var loaded = data is null ? default : PriceTable.Load(data);
        if (loaded.Table is { } table)
        {
            return table;
        }

        _log?.Invoke($"Stored price table is invalid ({loaded.Error?.ToString() ?? "too large"}); deleted");
        AtomicFile.TryDelete(TablePath);
        return null;
    }

    public PriceSyncState LoadState()
    {
        try
        {
            var info = new FileInfo(StatePath);
            if (!info.Exists || info.Length > MaxStateBytes)
            {
                return new PriceSyncState();
            }

            return PriceSyncState.FromJson(File.ReadAllBytes(StatePath)) ?? new PriceSyncState();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new PriceSyncState();
        }
    }

    /// <exception cref="IOException">The file could not be written.</exception>
    /// <exception cref="UnauthorizedAccessException">The folder is not writable.</exception>
    public void SaveTable(ReadOnlySpan<byte> data) => AtomicFile.Write(TablePath, data);

    /// <inheritdoc cref="SaveTable"/>
    public void SaveState(PriceSyncState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        AtomicFile.Write(StatePath, state.ToJson());
    }
}

/// <summary>
/// The daily price-table sync of NETWORK 3: GitHub raw first, the jsDelivr mirror second, every download validated like
/// <c>spec/tools/prices.py</c>, never a downgrade.
/// </summary>
public sealed class PriceTableSync
{
    public static readonly IReadOnlyList<Uri> Urls =
    [
        new("https://raw.githubusercontent.com/zoefix/agent-speed/main/spec/assets/prices.json"),
        new("https://cdn.jsdelivr.net/gh/zoefix/agent-speed@main/spec/assets/prices.json"),
    ];

    public static readonly IReadOnlySet<string> AllowedHosts =
        new HashSet<string>(["raw.githubusercontent.com", "cdn.jsdelivr.net"], StringComparer.Ordinal);

    /// <summary>Where Settings' <c>prices.viewSource</c> link points.</summary>
    public static readonly Uri SourcePage = new("https://github.com/zoefix/agent-speed/blob/main/spec/assets/prices.json");

    public static readonly TimeSpan LaunchDelay = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan Interval = TimeSpan.FromHours(24);
    public static readonly TimeSpan RetryDelay = TimeSpan.FromHours(1);

    /// <summary>The schedule is re-checked at least this often (and on wake).</summary>
    public static readonly TimeSpan CheckInterval = TimeSpan.FromHours(1);

    /// <summary>A table's <c>updated</c> may be at most this many days after the local date.</summary>
    public const int MaxUpdatedAheadDays = 2;

    private readonly PriceTableStore _store;
    private readonly IHttpTransport _transport;
    private readonly string _userAgent;
    private readonly TimeZoneInfo _timeZone;
    private readonly Func<DateTimeOffset> _now;
    private readonly Action<string>? _log;

    /// <param name="userAgent"><see cref="HttpFetchRequest.UserAgentFor"/> of the app's version.</param>
    /// <param name="timeZone">The local zone for check 5; null uses <see cref="TimeZoneInfo.Local"/>.</param>
    /// <param name="log">Receives one line per request outcome: host, status, size and reason, nothing personal.</param>
    public PriceTableSync(
        PriceTableStore store,
        IHttpTransport transport,
        string userAgent,
        TimeZoneInfo? timeZone = null,
        Func<DateTimeOffset>? now = null,
        Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(transport);
        ArgumentNullException.ThrowIfNull(userAgent);
        _store = store;
        _transport = transport;
        _userAgent = userAgent;
        _timeZone = timeZone ?? TimeZoneInfo.Local;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _log = log;
    }

    /// <summary>
    /// The next automatic round: 60 s after launch, then 24 h after the last success; a failed round retries once after
    /// 1 h and then follows the daily rhythm. Stamps in the future (clock moved back) count as now.
    /// </summary>
    public static DateTimeOffset NextAttempt(DateTimeOffset launchedAt, PriceSyncState state, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(state);
        var earliest = launchedAt + LaunchDelay;
        if (state.Failures > 0 && state.LastAttemptMs is { } attempt)
        {
            var delay = state.Failures == 1 ? RetryDelay : Interval;
            return Later(earliest, Clamped(attempt, now) + delay);
        }

        return state.LastSuccessMs is { } success ? Later(earliest, Clamped(success, now) + Interval) : earliest;
    }

    /// <summary>
    /// One round: tries each URL until one answers with a usable table (or <c>304</c>). <paramref name="currentVersion"/>
    /// is the higher of the bundled and the stored table.
    /// </summary>
    /// <exception cref="OperationCanceledException">The caller cancelled.</exception>
    public async Task<PriceSyncResult> RunAsync(int currentVersion, CancellationToken cancellationToken = default)
    {
        var started = _now();
        var state = _store.LoadState() with { LastAttemptMs = started.ToUnixTimeMilliseconds() };
        var failure = "no response";
        var sawNewerSchema = false;
        foreach (var url in Urls)
        {
            var host = url.IdnHost;
            // A 304 means "the table behind this ETag", which is only worth knowing when it is not newer than ours.
            var etag = state.Url == url.AbsoluteUri && state.Version is { } known && known <= currentVersion ? state.ETag : null;
            var request = new HttpFetchRequest(url, _userAgent, PriceTable.MaxBytes, AllowedHosts) { IfNoneMatch = etag };
            HttpFetchResponse response;
            try
            {
                response = await _transport.GetAsync(request, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                failure = ex is HttpFetchException fetch ? fetch.Reason : "transport error";
                Log($"Price table {host}: {failure}");
                continue;
            }

            if (response.Status == 304)
            {
                Log($"Price table {host}: 304, unchanged");
                return Finish(state, new PriceSyncOutcome.UpToDate(), null);
            }

            if (!response.IsSuccess)
            {
                failure = "HTTP " + response.Status.ToString(CultureInfo.InvariantCulture);
                Log($"Price table {host}: {failure}");
                continue;
            }

            var loaded = PriceTable.Load(response.Body);
            if (loaded.Table is not { } table)
            {
                if (loaded.Error?.IsNewerSchema == true)
                {
                    sawNewerSchema = true;
                }
                else
                {
                    failure = "invalid table";
                }

                Log($"Price table {host}: {response.Body.Length} bytes rejected ({loaded.Error})");
                continue;
            }

            if (!IsAcceptableUpdated(table.Updated, started))
            {
                failure = "table dated in the future";
                Log($"Price table {host}: updated {table.Updated} is in the future");
                continue;
            }

            state = state with { Version = table.Version, Updated = table.Updated, Url = url.AbsoluteUri, ETag = response.ETag };
            if (table.Version <= currentVersion)
            {
                Log($"Price table {host}: v{table.Version} ({response.Body.Length} bytes), current is v{currentVersion}");
                return Finish(state, new PriceSyncOutcome.UpToDate(), null);
            }

            try
            {
                _store.SaveTable(response.Body);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                failure = "could not save";
                Log($"Price table v{table.Version} could not be saved");
                state = state with { Version = null, ETag = null };
                continue;
            }

            Log($"Price table {host}: updated to v{table.Version} ({response.Body.Length} bytes)");
            return Finish(state, new PriceSyncOutcome.Updated(table.Version), table);
        }

        if (sawNewerSchema)
        {
            Log("Price table: only a newer schema is offered; this build needs an update");
            return Finish(state, new PriceSyncOutcome.NewerSchema(), null);
        }

        state = state with { Failures = state.Failures + 1, LastError = failure };
        TrySaveState(state);
        return new PriceSyncResult(new PriceSyncOutcome.Failed(failure), null, state);
    }

    /// <summary>Check 5: <c>updated</c> is at most two days after the local date.</summary>
    internal bool IsAcceptableUpdated(string updated, DateTimeOffset at)
    {
        var local = TimeZoneInfo.ConvertTime(at, _timeZone);
        var limit = DateOnly.FromDateTime(local.DateTime).AddDays(MaxUpdatedAheadDays).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        return string.CompareOrdinal(updated, limit) <= 0;
    }

    private static DateTimeOffset Clamped(long ms, DateTimeOffset now)
    {
        const long MinMs = -62_135_596_800_000;
        return ms >= now.ToUnixTimeMilliseconds() ? now : DateTimeOffset.FromUnixTimeMilliseconds(Math.Max(ms, MinMs));
    }

    private static DateTimeOffset Later(DateTimeOffset lhs, DateTimeOffset rhs) => lhs > rhs ? lhs : rhs;

    private PriceSyncResult Finish(PriceSyncState state, PriceSyncOutcome outcome, PriceTable? table)
    {
        var finished = state with { LastSuccessMs = state.LastAttemptMs, Failures = 0, LastError = null };
        TrySaveState(finished);
        return new PriceSyncResult(outcome, table, finished);
    }

    private void TrySaveState(PriceSyncState state)
    {
        try
        {
            _store.SaveState(state);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log("Price table sync state could not be saved");
        }
    }

    private void Log(string message) => _log?.Invoke(message);
}

/// <summary>Writes go to a temporary file in the same folder that then replaces the target, so readers never see half a file.</summary>
internal static class AtomicFile
{
    public static void Write(string path, ReadOnlySpan<byte> data)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, "." + Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(data);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            TryDelete(temporary);
            throw;
        }
    }

    public static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}

/// <summary>The small JSON files of the network features: sorted keys, indented, read back strictly.</summary>
internal static class StoreJson
{
    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static byte[] Write(Action<Utf8JsonWriter> members)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, WriterOptions))
        {
            writer.WriteStartObject();
            members(writer);
            writer.WriteEndObject();
        }

        return buffer.ToArray();
    }

    public static void WriteMap(Utf8JsonWriter writer, string name, IReadOnlyDictionary<string, string> map)
    {
        writer.WriteStartObject(name);
        foreach (var (key, value) in map.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            writer.WriteString(key, value);
        }

        writer.WriteEndObject();
    }

    public static string? String(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    public static long? Int64(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number)
            ? number
            : null;

    public static Dictionary<string, string>? Map(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (property.Value.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            map[property.Name] = property.Value.GetString()!;
        }

        return map;
    }

    public static string? OptionalString(JsonElement root, string name, ref bool ok)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        ok &= value.ValueKind == JsonValueKind.String;
        return value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    }

    public static long? OptionalInt64(JsonElement root, string name, long min, long max, ref bool ok)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) && number >= min && number <= max)
        {
            return number;
        }

        ok = false;
        return null;
    }
}

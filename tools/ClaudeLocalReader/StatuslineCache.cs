using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClaudeLocalReader;

internal sealed record StatuslineSnapshot(
    [property: JsonPropertyName("schema_version")] int SchemaVersion,
    [property: JsonPropertyName("captured_at_epoch")] double CapturedAtEpoch,
    [property: JsonPropertyName("session_id")] string? SessionId,
    [property: JsonPropertyName("model")] StatuslineModel? Model,
    [property: JsonPropertyName("rate_limits")] StatuslineRateLimits? RateLimits,
    [property: JsonPropertyName("cost")] StatuslineCost? Cost,
    [property: JsonPropertyName("context_window")] StatuslineContextWindow? ContextWindow);

internal sealed record StatuslineModel(
    [property: JsonPropertyName("id")] string? Id,
    [property: JsonPropertyName("display_name")] string? DisplayName);

internal sealed record StatuslineRateLimits(
    [property: JsonPropertyName("five_hour")] StatuslineWindow? FiveHour,
    [property: JsonPropertyName("seven_day")] StatuslineWindow? SevenDay,
    [property: JsonPropertyName("spend_limit")] StatuslineWindow? SpendLimit);

internal sealed record StatuslineWindow(
    [property: JsonPropertyName("used_percentage")] double? UsedPercentage,
    [property: JsonPropertyName("resets_at")] long? ResetsAt);

internal sealed record StatuslineCost(
    [property: JsonPropertyName("total_api_duration_ms")] long? TotalApiDurationMs,
    [property: JsonPropertyName("total_duration_ms")] long? TotalDurationMs);

internal sealed record StatuslineContextWindow(
    [property: JsonPropertyName("context_window_size")] long? ContextWindowSize,
    [property: JsonPropertyName("total_input_tokens")] long? TotalInputTokens,
    [property: JsonPropertyName("total_output_tokens")] long? TotalOutputTokens,
    [property: JsonPropertyName("current_usage")] StatuslineCurrentUsage? CurrentUsage);

internal sealed record StatuslineCurrentUsage(
    [property: JsonPropertyName("input_tokens")] long? InputTokens,
    [property: JsonPropertyName("output_tokens")] long? OutputTokens,
    [property: JsonPropertyName("cache_creation_input_tokens")] long? CacheCreationInputTokens,
    [property: JsonPropertyName("cache_read_input_tokens")] long? CacheReadInputTokens);

internal static class StatuslineCache
{
    public const int MaximumInputBytes = 64 * 1024;
    public const int MaximumSessionFiles = 64;
    private const int MaximumTextLength = 512;
    private const string CacheDirectoryName = "claude-local-statusline";
    private const string CacheLockName = "CodexTokenBar_ClaudeLocalStatuslineCache";
    private const string SessionFilePrefix = "session-";
    private const string SessionFileSuffix = ".json";

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        MaxDepth = 12,
    };

    public static StatuslineSnapshot Parse(ReadOnlySpan<byte> input, bool fromStatusline = false)
    {
        if (input.Length is 0 or > MaximumInputBytes)
        {
            throw new InvalidDataException("Statusline input must be between 1 byte and 64 KiB.");
        }

        using var document = JsonDocument.Parse(input.ToArray(), new JsonDocumentOptions { MaxDepth = 12 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || (!fromStatusline && (!TryInt64(root, "schema_version", out var version) || version != 1)))
        {
            throw new InvalidDataException("Unsupported Claude statusline cache schema.");
        }

        var capturedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        if (!fromStatusline && (!TryFiniteNumber(root, "captured_at_epoch", out capturedAt) || capturedAt < 0))
        {
            throw new InvalidDataException("Claude statusline cache has an invalid capture time.");
        }
        if (capturedAt > DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 60)
        {
            throw new InvalidDataException("Claude statusline cache capture time is in the future.");
        }

        var sessionId = ReadText(root, "session_id");
        var model = ReadModel(root);
        var rateLimits = ReadRateLimits(root);
        var cost = ReadCost(root);
        var contextWindow = ReadContextWindow(root);
        return new StatuslineSnapshot(1, capturedAt, sessionId, model, rateLimits, cost, contextWindow);
    }

    public static byte[] Serialize(StatuslineSnapshot snapshot) =>
        JsonSerializer.SerializeToUtf8Bytes(snapshot, SerializerOptions);

    public static async Task<StatuslineSnapshot> ReadAndCacheAsync(Stream input, CancellationToken cancellationToken)
    {
        var bytes = await ReadBoundedAsync(input, cancellationToken).ConfigureAwait(false);
        // Claude sends raw statusline JSON, not our normalized on-disk schema.
        // Capture time is assigned locally; never trust a producer-supplied clock.
        var snapshot = Parse(bytes, fromStatusline: true);
        await WriteAtomicallyAsync(snapshot, cancellationToken).ConfigureAwait(false);
        return snapshot;
    }

    public static Task WriteAtomicallyAsync(StatuslineSnapshot snapshot, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new IOException("LocalApplicationData is unavailable.");
        }

        RequirePlainDirectoryTree(localAppData);
        var appDirectory = Path.Combine(localAppData, "CodexTokenBar", CacheDirectoryName);
        Directory.CreateDirectory(appDirectory);
        RequirePlainDirectoryTree(appDirectory);

        using var cacheMutex = new Mutex(false, CacheLockName);
        var ownsMutex = false;
        try
        {
            try
            {
                ownsMutex = cacheMutex.WaitOne(TimeSpan.FromSeconds(5));
            }
            catch (AbandonedMutexException)
            {
                ownsMutex = true;
            }
            if (!ownsMutex)
            {
                throw new IOException("The local statusline cache is busy.");
            }

            var bytes = Serialize(snapshot);
            if (snapshot.SessionId is { Length: > 0 } sessionId)
            {
                var sessionTarget = Path.Combine(appDirectory, SessionCacheFileName(sessionId));
                WriteFileAtomically(appDirectory, sessionTarget, bytes);
                PruneSessionFiles(appDirectory);
            }

            var latestTarget = Path.Combine(appDirectory, "latest.json");
            WriteFileAtomically(appDirectory, latestTarget, bytes);
        }
        finally
        {
            if (ownsMutex)
            {
                cacheMutex.ReleaseMutex();
            }
        }

        return Task.CompletedTask;
    }

    private static void WriteFileAtomically(string directory, string target, byte[] bytes)
    {
        EnsureRegularFileIfPresent(target);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(target)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 4096,
                FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }

            RequirePlainDirectoryTree(directory);
            File.Move(temporary, target, overwrite: true);
            EnsureRegularFileIfPresent(target);
        }
        finally
        {
            try
            {
                File.Delete(temporary);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static void EnsureRegularFileIfPresent(string target)
    {
        FileAttributes? existingAttributes = null;
        try
        {
            existingAttributes = File.GetAttributes(target);
        }
        catch (FileNotFoundException)
        {
        }
        catch (DirectoryNotFoundException)
        {
        }
        if (existingAttributes is { } attributes
            && ((attributes & FileAttributes.ReparsePoint) != 0 || (attributes & FileAttributes.Directory) != 0))
        {
            throw new IOException("Refusing to replace a reparse point or directory in the local cache.");
        }
    }

    private static string SessionCacheFileName(string sessionId)
    {
        var digest = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(sessionId))).ToLowerInvariant();
        return SessionFilePrefix + digest + SessionFileSuffix;
    }

    private static void PruneSessionFiles(string directory)
    {
        var entries = Directory.EnumerateFiles(directory, SessionFilePrefix + "*" + SessionFileSuffix)
            .Select(path =>
            {
                if (!IsSessionCacheFileName(Path.GetFileName(path)))
                {
                    return (Path: path, LastWrite: DateTime.MinValue, IsRegular: false);
                }

                try
                {
                    var attributes = File.GetAttributes(path);
                    return (Path: path, LastWrite: File.GetLastWriteTimeUtc(path),
                        IsRegular: (attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0);
                }
                catch (FileNotFoundException)
                {
                    return (Path: path, LastWrite: DateTime.MinValue, IsRegular: false);
                }
            })
            .Where(entry => entry.IsRegular)
            .OrderBy(entry => entry.LastWrite)
            .ThenBy(entry => entry.Path, StringComparer.Ordinal)
            .ToList();
        foreach (var stale in entries.Take(Math.Max(0, entries.Count - MaximumSessionFiles)))
        {
            try
            {
                File.Delete(stale.Path);
            }
            catch (FileNotFoundException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static bool IsSessionCacheFileName(string name) =>
        name.Length == SessionFilePrefix.Length + 64 + SessionFileSuffix.Length
        && name.StartsWith(SessionFilePrefix, StringComparison.Ordinal)
        && name.EndsWith(SessionFileSuffix, StringComparison.Ordinal)
        && name.Substring(SessionFilePrefix.Length, 64).All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static async Task<byte[]> ReadBoundedAsync(Stream input, CancellationToken cancellationToken)
    {
        using var output = new MemoryStream();
        var buffer = new byte[4096];
        while (true)
        {
            var remaining = MaximumInputBytes + 1 - (int)output.Length;
            if (remaining <= 0)
            {
                throw new InvalidDataException("Claude statusline input exceeds 64 KiB.");
            }

            var read = await input.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, remaining)), cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            output.Write(buffer, 0, read);
            if (output.Length > MaximumInputBytes)
            {
                throw new InvalidDataException("Claude statusline input exceeds 64 KiB.");
            }
        }

        return output.ToArray();
    }

    private static void RequirePlainDirectoryTree(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var current = Path.GetPathRoot(fullPath);
        if (string.IsNullOrEmpty(current))
        {
            throw new IOException("Refusing to use an unrooted local cache directory.");
        }

        var attributes = File.GetAttributes(current);
        if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException("Refusing to use a cache path containing a reparse point.");
        }

        foreach (var component in fullPath[current.Length..].Split(
            [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            attributes = File.GetAttributes(current);
            if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException("Refusing to use a cache path containing a reparse point.");
            }
        }
    }

    private static StatuslineModel? ReadModel(JsonElement root)
    {
        if (!root.TryGetProperty("model", out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        RequireObject(value, "model");
        return new StatuslineModel(ReadText(value, "id"), ReadText(value, "display_name"));
    }

    private static StatuslineRateLimits? ReadRateLimits(JsonElement root)
    {
        if (!root.TryGetProperty("rate_limits", out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        RequireObject(value, "rate_limits");
        return new StatuslineRateLimits(
            ReadWindow(value, "five_hour"),
            ReadWindow(value, "seven_day"),
            ReadWindow(value, "spend_limit"));
    }

    private static StatuslineWindow? ReadWindow(JsonElement parent, string property)
    {
        if (!parent.TryGetProperty(property, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        RequireObject(value, property);
        double? percentage = null;
        if (value.TryGetProperty("used_percentage", out var rawPercentage) && rawPercentage.ValueKind != JsonValueKind.Null)
        {
            if (!rawPercentage.TryGetDouble(out var parsed) || !double.IsFinite(parsed) || parsed is < 0 or > 100)
            {
                throw new InvalidDataException($"Claude statusline {property} percentage is invalid.");
            }

            percentage = parsed;
        }

        long? resetsAt = null;
        if (value.TryGetProperty("resets_at", out var rawReset) && rawReset.ValueKind != JsonValueKind.Null)
        {
            resetsAt = ParseResetEpoch(rawReset, property);
        }

        return new StatuslineWindow(percentage, resetsAt);
    }

    private static long ParseResetEpoch(JsonElement value, string property)
    {
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var numeric) && double.IsFinite(numeric)
            && numeric >= 0 && numeric < long.MaxValue)
        {
            return checked((long)Math.Floor(numeric));
        }

        if (value.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(
            value.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out var parsed))
        {
            return parsed.ToUnixTimeSeconds();
        }

        throw new InvalidDataException($"Claude statusline {property} reset time is invalid.");
    }

    private static StatuslineCost? ReadCost(JsonElement root)
    {
        if (!root.TryGetProperty("cost", out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        RequireObject(value, "cost");
        return new StatuslineCost(
            ReadOptionalCounter(value, "total_api_duration_ms"),
            ReadOptionalCounter(value, "total_duration_ms"));
    }

    private static StatuslineContextWindow? ReadContextWindow(JsonElement root)
    {
        if (!root.TryGetProperty("context_window", out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        RequireObject(value, "context_window");
        StatuslineCurrentUsage? usage = null;
        if (value.TryGetProperty("current_usage", out var rawUsage) && rawUsage.ValueKind != JsonValueKind.Null)
        {
            RequireObject(rawUsage, "context_window.current_usage");
            usage = new StatuslineCurrentUsage(
                ReadOptionalCounter(rawUsage, "input_tokens"),
                ReadOptionalCounter(rawUsage, "output_tokens"),
                ReadOptionalCounter(rawUsage, "cache_creation_input_tokens"),
                ReadOptionalCounter(rawUsage, "cache_read_input_tokens"));
        }

        return new StatuslineContextWindow(
            ReadOptionalCounter(value, "context_window_size"),
            ReadOptionalCounter(value, "total_input_tokens"),
            ReadOptionalCounter(value, "total_output_tokens"),
            usage);
    }

    private static long? ReadOptionalCounter(JsonElement parent, string property)
    {
        if (!parent.TryGetProperty(property, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out var count) || count < 0)
        {
            throw new InvalidDataException($"Claude statusline {property} count must be a nonnegative integer.");
        }

        return count;
    }

    private static string? ReadText(JsonElement parent, string property)
    {
        if (!parent.TryGetProperty(property, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind != JsonValueKind.String)
        {
            throw new InvalidDataException($"Claude statusline {property} must be text.");
        }

        var text = value.GetString()?.Trim();
        if (string.IsNullOrEmpty(text))
        {
            return null;
        }

        if (text.Length > MaximumTextLength || text.Any(char.IsControl))
        {
            throw new InvalidDataException($"Claude statusline {property} is too long or contains control characters.");
        }

        return text;
    }

    private static bool TryFiniteNumber(JsonElement parent, string property, out double number)
    {
        number = 0;
        return parent.TryGetProperty(property, out var value)
            && value.ValueKind == JsonValueKind.Number
            && value.TryGetDouble(out number)
            && double.IsFinite(number);
    }

    private static bool TryInt64(JsonElement parent, string property, out long number)
    {
        number = 0;
        return parent.TryGetProperty(property, out var value)
            && value.ValueKind == JsonValueKind.Number
            && value.TryGetInt64(out number);
    }

    private static void RequireObject(JsonElement value, string property)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException($"Claude statusline {property} must be an object.");
        }
    }
}

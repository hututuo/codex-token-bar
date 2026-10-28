using System.Text.Json;
using System.Text.Json.Serialization;
using CodexTokenBar.LocalSource;
using AgentSpeed.Core;

namespace CodexTokenBar.AgentSpeedReporter;

internal sealed record StartCommand(bool Enabled, bool LocalDisplay, string Username, string Transport,
    IReadOnlySet<string> DeniedSourceIds, IReadOnlyDictionary<string, string> LocalSourceRoots);

internal sealed record AgentSpeedDisplayRate(
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("tokensPerSecond")] double TokensPerSecond);

internal sealed record AgentSpeedDisplaySnapshot(
    [property: JsonPropertyName("available")] bool Available,
    [property: JsonPropertyName("tokensPerSecond")] double TokensPerSecond,
    [property: JsonPropertyName("modelRates")] IReadOnlyList<AgentSpeedDisplayRate> ModelRates,
    [property: JsonPropertyName("clientRates")] IReadOnlyList<AgentSpeedDisplayRate> ClientRates,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("updatedAtMs")] long UpdatedAtMs)
{
    public static AgentSpeedDisplaySnapshot Empty(string status, bool available = false) =>
        new(available, 0, [], [], status, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
}

internal sealed record StatusSource(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("tps")] double Tps);

internal sealed record HelperStatus(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("phase")] string Phase,
    [property: JsonPropertyName("messageCode")] string MessageCode,
    [property: JsonPropertyName("liveOutputTps")] double LiveOutputTps,
    [property: JsonPropertyName("estimatedShare")] double EstimatedShare,
    [property: JsonPropertyName("lastReportAt")] string? LastReportAt,
    [property: JsonPropertyName("sources")] IReadOnlyList<StatusSource> Sources,
    [property: JsonPropertyName("profileUrl")] string? ProfileUrl,
    [property: JsonPropertyName("localDisplay")] AgentSpeedDisplaySnapshot? LocalDisplay = null);

internal static class StatusProtocol
{
    public const int MaxInputBytes = 4096;
    public const int MaxStatusBytes = 65_536;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        MaxDepth = 8,
    };

    public static async Task<StartCommand?> ReadStartCommandAsync(Stream input)
    {
        var bytes = new byte[MaxInputBytes];
        var count = 0;
        var one = new byte[1];
        while (count < bytes.Length)
        {
            var read = await input.ReadAsync(one.AsMemory(0, 1)).ConfigureAwait(false);
            if (read == 0)
            {
                return null;
            }

            if (one[0] == (byte)'\n')
            {
                break;
            }

            if (one[0] != (byte)'\r')
            {
                bytes[count++] = one[0];
            }
        }

        if (count == 0 || count == bytes.Length)
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(bytes.AsMemory(0, count), new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || root.EnumerateObject().Select(property => property.Name).Distinct(StringComparer.Ordinal).Count()
                    != root.EnumerateObject().Count()
                || root.EnumerateObject().Any(property => property.Name is not ("enabled" or "localDisplay" or "username" or "transport" or "deniedSourceIds" or "localSourceRoots"))
                || !root.TryGetProperty("enabled", out var enabled)
                || enabled.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            {
                return null;
            }

            if (!root.TryGetProperty("deniedSourceIds", out var deniedSourceIds)
                || deniedSourceIds.ValueKind != JsonValueKind.Array || deniedSourceIds.GetArrayLength() > 16) return null;
            var denied = new List<string>();
            foreach (var source in deniedSourceIds.EnumerateArray())
            {
                if (source.ValueKind != JsonValueKind.String || source.GetString() is not { } sourceId
                    || sourceId.Length > 32)
                {
                    return null;
                }

                denied.Add(sourceId);
            }
            if (!AgentSpeedReportSourcePolicy.HasRequiredDenyList(denied))
            {
                return null;
            }

            var reportingEnabled = enabled.GetBoolean();
            var localDisplay = false;
            if (root.TryGetProperty("localDisplay", out var localDisplayValue))
            {
                if (localDisplayValue.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                {
                    return null;
                }
                localDisplay = localDisplayValue.GetBoolean();
            }
            if (!reportingEnabled && !localDisplay) return null;

            var value = root.TryGetProperty("username", out var username) && username.ValueKind == JsonValueKind.String
                ? username.GetString()
                : null;
            if (reportingEnabled && (string.IsNullOrWhiteSpace(value) || value.Length > 128
                || value.Trim().EnumerateRunes().Count() is < 2 or > 32 || value.Any(char.IsControl))) return null;
            if (!reportingEnabled && value is not null) return null;

            var transport = root.TryGetProperty("transport", out var requestedTransport)
                ? requestedTransport.ValueKind == JsonValueKind.String ? requestedTransport.GetString() : null
                : "http";
            if (transport is not ("http" or "websocket"))
            {
                return null;
            }

            var localSourceRoots = new Dictionary<string, string>(StringComparer.Ordinal);
            if (root.TryGetProperty("localSourceRoots", out var rootsElement))
            {
                if (rootsElement.ValueKind != JsonValueKind.Object || rootsElement.EnumerateObject().Count() > 3)
                {
                    return null;
                }

                foreach (var property in rootsElement.EnumerateObject())
                {
                    if (!IsLocalRootSourceId(property.Name)
                        || property.Value.ValueKind != JsonValueKind.String
                        || property.Value.GetString() is not { } path
                        || !IsValidLocalSourceRoot(path)
                        || !localSourceRoots.TryAdd(property.Name, path))
                    {
                        return null;
                    }
                }
            }

            return new StartCommand(reportingEnabled, localDisplay, value?.Trim() ?? string.Empty, transport,
                denied.ToHashSet(StringComparer.Ordinal), localSourceRoots);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool IsLocalRootSourceId(string sourceId) =>
        sourceId is "deepseek" or "gemini" or "opencode";

    private static bool IsValidLocalSourceRoot(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Length > 1024 || path.Any(char.IsControl))
        {
            return false;
        }

        const string extendedPrefix = @"\\?\";
        if (path.StartsWith(extendedPrefix, StringComparison.Ordinal))
        {
            return IsDriveRootedPath(path, extendedPrefix.Length);
        }

        if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.StartsWith("//", StringComparison.Ordinal))
        {
            return false;
        }

        return IsDriveRootedPath(path, 0);
    }

    private static bool IsDriveRootedPath(string path, int start) =>
        path.Length >= start + 3
        && ((path[start] is >= 'A' and <= 'Z') || (path[start] is >= 'a' and <= 'z'))
        && path[start + 1] == ':'
        && path[start + 2] is '\\' or '/';

    public static async Task WatchParentExitAsync(Stream input, CancellationTokenSource lifetime)
    {
        var buffer = new byte[256];
        try
        {
            while (await input.ReadAsync(buffer.AsMemory(), lifetime.Token).ConfigureAwait(false) > 0)
            {
                // The protocol has one bounded startup line. Later input is ignored; EOF is the
                // parent's shutdown signal and cancels scans and in-flight HTTP calls.
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (IOException)
        {
        }

        if (!lifetime.IsCancellationRequested)
        {
            lifetime.Cancel();
        }
    }

    public static string MessageFor(string code) => code switch
    {
        "waiting_for_snapshot" => "Waiting for a live snapshot",
        "discovering" => "Checking the reporting service",
        "registering" => "Registering this device",
        "websocket_waiting_for_activity" => "Device registered; waiting for activity",
        "websocket_connected" => "WebSocket connected; waiting for a valid report acknowledgement",
        "reporting" => "Reporting live speed",
        "http_fallback" => "WebSocket disconnected; using HTTP for this run",
        "websocket_reconnecting" => "WebSocket reconnecting",
        "websocket_not_supported" => "This service does not support WebSocket reports",
        "websocket_configuration_mismatch" => "The WebSocket service settings do not match discovery",
        "websocket_protocol_error" => "The WebSocket service is incompatible",
        "websocket_replaced" => "This device is connected elsewhere",
        "unknown_device" => "The reporting service no longer recognizes this device",
        "service_unavailable" => "Reporting service unavailable",
        "service_unsupported" => "Reporting service is not supported",
        "username_invalid" => "Username is not accepted",
        "username_taken" => "Username is already in use",
        "api_key_required" => "The service requires an API key",
        "forbidden" => "The service refused registration",
        "key_unavailable" => "Device signing key is unavailable",
        "reporting_failed" => "Reporting stopped after a service error",
        "disabled" => "Off",
        _ => "Reporter stopped unexpectedly",
    };

    public static string SourceId(SourceKind kind) => AgentSpeed.Core.Reporting.ReportBody.SourceId(kind);

    public static string SourceName(SourceKind kind) => kind switch
    {
        SourceKind.Codex => "Codex",
        SourceKind.ClaudeCode => "Claude Code",
        SourceKind.ClaudeDesktop => "Claude Desktop",
        SourceKind.DeepSeek => "DeepSeek",
        SourceKind.OpenCode => "OpenCode",
        SourceKind.Gemini => "Gemini CLI",
        SourceKind.Omp => "omp",
        SourceKind.Antigravity => "Antigravity",
        SourceKind.WorkBuddy => "WorkBuddy",
        SourceKind.WorkBuddyAi => "WorkBuddy AI",
        SourceKind.ZCode => "ZCode",
        SourceKind.Kimi => "Kimi",
        SourceKind.GrokBuild => "Grok Build",
        _ => "Agent",
    };

    public static byte[] Serialize(HelperStatus status)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(status, JsonOptions);
        if (bytes.Length > MaxStatusBytes)
        {
            throw new InvalidOperationException("status_too_large");
        }

        return bytes;
    }

    public static string DisplaySourceId(SourceKind kind) => kind switch
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
        _ => "agent",
    };
}

internal sealed class StatusEmitter(LocalSourceProtocolOutput output)
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private HelperStatus _latest = new(
        1, "starting", "waiting_for_snapshot", 0, 0, null, Array.Empty<StatusSource>(), null);

    public async Task PublishAsync(HelperStatus status, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var next = status with { LocalDisplay = _latest.LocalDisplay };
            await WriteAsync(next, cancellationToken).ConfigureAwait(false);
            _latest = next;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task PublishDisplayAsync(AgentSpeedDisplaySnapshot snapshot, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var next = _latest with { LocalDisplay = snapshot };
            await WriteAsync(next, cancellationToken).ConfigureAwait(false);
            _latest = next;
        }
        finally
        {
            _gate.Release();
        }
    }

    private Task WriteAsync(HelperStatus status, CancellationToken cancellationToken)
    {
        var bytes = StatusProtocol.Serialize(status);
        cancellationToken.ThrowIfCancellationRequested();
        output.WriteLine(bytes);
        return Task.CompletedTask;
    }

    public Task PublishErrorAsync(string messageCode, CancellationToken cancellationToken) =>
        PublishAsync(_latest with { Phase = "error", MessageCode = messageCode }, cancellationToken);
}

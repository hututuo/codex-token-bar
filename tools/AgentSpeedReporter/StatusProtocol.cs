using System.Text.Json;
using System.Text.Json.Serialization;
using AgentSpeed.Core;

namespace CodexTokenBar.AgentSpeedReporter;

internal sealed record StartCommand(bool Enabled, string Username);

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
    [property: JsonPropertyName("profileUrl")] string? ProfileUrl);

internal static class StatusProtocol
{
    public const int MaxInputBytes = 4096;
    public const int MaxStatusBytes = 4096;

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
                || root.EnumerateObject().Any(property => property.Name is not ("enabled" or "username"))
                || !root.TryGetProperty("enabled", out var enabled) || enabled.ValueKind != JsonValueKind.True
                || !root.TryGetProperty("username", out var username) || username.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            var value = username.GetString();
            if (string.IsNullOrWhiteSpace(value) || value.Length > 128 || value.Trim().EnumerateRunes().Count() is < 2 or > 32
                || value.Any(char.IsControl))
            {
                return null;
            }

            return new StartCommand(true, value.Trim());
        }
        catch (JsonException)
        {
            return null;
        }
    }

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
        "reporting" => "Reporting live speed",
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
}

internal sealed class StatusEmitter(Stream output)
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private HelperStatus _latest = new(
        1, "starting", "waiting_for_snapshot", 0, 0, null, Array.Empty<StatusSource>(), null);

    public async Task PublishAsync(HelperStatus status, CancellationToken cancellationToken)
    {
        var bytes = StatusProtocol.Serialize(status);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await output.WriteAsync(bytes.AsMemory(), cancellationToken).ConfigureAwait(false);
            await output.WriteAsync("\n"u8.ToArray().AsMemory(), cancellationToken).ConfigureAwait(false);
            await output.FlushAsync(cancellationToken).ConfigureAwait(false);
            _latest = status;
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task PublishErrorAsync(string messageCode, CancellationToken cancellationToken) =>
        PublishAsync(_latest with { Phase = "error", MessageCode = messageCode }, cancellationToken);
}

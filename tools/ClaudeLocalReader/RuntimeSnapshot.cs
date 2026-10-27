using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;
using AgentSpeed.Core;

namespace ClaudeLocalReader;

internal sealed record RuntimeSnapshot(
    [property: JsonPropertyName("schema")] int Schema,
    [property: JsonPropertyName("capturedAt")] string CapturedAt,
    [property: JsonPropertyName("client")] string Client,
    [property: JsonPropertyName("sourceAvailable")] IReadOnlyDictionary<string, bool> SourceAvailable,
    [property: JsonPropertyName("liveOutputTps")] double LiveOutputTps,
    [property: JsonPropertyName("liveTotalTps")] double LiveTotalTps,
    [property: JsonPropertyName("estimatedShare")] double EstimatedShare,
    [property: JsonPropertyName("modelRates")] IReadOnlyList<ModelRate> ModelRates,
    [property: JsonPropertyName("mainAgents")] IReadOnlyList<RuntimeAgent> MainAgents,
    [property: JsonPropertyName("subagents")] IReadOnlyList<RuntimeAgent> Subagents,
    [property: JsonPropertyName("latestResponse")] RuntimeResponse? LatestResponse,
    [property: JsonPropertyName("responseEvents")] IReadOnlyList<RuntimeEvent> ResponseEvents);

internal sealed record ModelRate(
    [property: JsonPropertyName("client")] string Client,
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("outputTps")] double OutputTps,
    [property: JsonPropertyName("totalTps")] double TotalTps,
    [property: JsonPropertyName("generatingAgents")] int GeneratingAgents,
    [property: JsonPropertyName("toolsAgents")] int ToolsAgents);

internal sealed record RuntimeAgent(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("client")] string Client,
    [property: JsonPropertyName("parentId")] string? ParentId,
    [property: JsonPropertyName("phase")] string Phase,
    [property: JsonPropertyName("model")] string? Model,
    [property: JsonPropertyName("lastActivity")] string LastActivity,
    [property: JsonPropertyName("liveOutputTps")] double LiveOutputTps,
    [property: JsonPropertyName("liveTotalTps")] double LiveTotalTps,
    [property: JsonPropertyName("recentSpeed")] double? RecentSpeed);

internal sealed record RuntimeResponse(
    [property: JsonPropertyName("client")] string Client,
    [property: JsonPropertyName("model")] string? Model,
    [property: JsonPropertyName("outputTokens")] long OutputTokens,
    [property: JsonPropertyName("totalTokens")] long TotalTokens,
    [property: JsonPropertyName("durationMs")] long? DurationMs,
    [property: JsonPropertyName("speed")] double? Speed,
    [property: JsonPropertyName("endedAt")] string EndedAt);

internal sealed record RuntimeEvent(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("client")] string Client,
    [property: JsonPropertyName("model")] string? Model,
    [property: JsonPropertyName("outputTokens")] long OutputTokens,
    [property: JsonPropertyName("totalTokens")] long TotalTokens,
    [property: JsonPropertyName("durationMs")] long? DurationMs,
    [property: JsonPropertyName("speed")] double? Speed,
    [property: JsonPropertyName("endedAt")] string EndedAt);

internal sealed record ResponseEventInput(long Sequence, ResponseSummary Response);

internal static class RuntimeSnapshotMapper
{
    private static readonly SourceKind[] ClaudeSources = [SourceKind.ClaudeCode, SourceKind.ClaudeDesktop];
    private static readonly SourceKind[] RuntimeSources = [SourceKind.Codex, SourceKind.ClaudeCode, SourceKind.ClaudeDesktop];
    private const int MaximumResponseEvents = 32;

    public static RuntimeSnapshot Map(
        SpeedSnapshot snapshot,
        byte[] processSalt,
        IReadOnlySet<SourceKind>? enabledSources = null,
        IReadOnlyList<ResponseEventInput>? responseEvents = null)
    {
        enabledSources ??= ClaudeSources.ToHashSet();
        var now = DateTimeOffset.UtcNow;
        var selected = snapshot.Agents
            .Where(agent => RuntimeSources.Contains(agent.Source) && enabledSources.Contains(agent.Source))
            // Old idle transcript records are not current task state. Keep recent idle records
            // for context, but do not leak historical sessions into the compact live task list.
            .Where(agent => agent.Phase != AgentPhase.Idle || now - agent.LastActivity <= TimeSpan.FromMinutes(5))
            .ToArray();
        var safeIds = selected.ToDictionary(agent => agent.Id, agent => SafeId(processSalt, agent.Id), StringComparer.Ordinal);
        var sourceAvailable = RuntimeSources
            .Where(source => source != SourceKind.Codex || enabledSources.Contains(SourceKind.Codex))
            .ToDictionary(
            ClientId,
            source => enabledSources.Contains(source)
                && snapshot.Sources.FirstOrDefault(row => row.Kind == source) is { Enabled: true, Available: true },
            StringComparer.Ordinal);
        var selectedStatuses = snapshot.Sources
            .Where(row => RuntimeSources.Contains(row.Kind) && enabledSources.Contains(row.Kind))
            .ToArray();
        var liveOutput = FiniteNonnegative(selectedStatuses.Sum(row => row.Live.Output));
        var liveTotal = FiniteNonnegative(selectedStatuses.Sum(row => row.Live.Total));
        var estimatedOutput = FiniteNonnegative(selectedStatuses.Sum(row => row.LiveEstimated.Output));
        var estimatedShare = liveOutput > 0 ? Math.Clamp(estimatedOutput / liveOutput, 0, 1) : 0;
        var modelRates = selected
            .GroupBy(agent => (agent.Source, Model: CleanModel(agent.Model)))
            .OrderBy(group => ClientId(group.Key.Source), StringComparer.Ordinal)
            .ThenBy(group => group.Key.Model, StringComparer.Ordinal)
            .Select(group => new ModelRate(
                ClientId(group.Key.Source),
                group.Key.Model,
                FiniteNonnegative(group.Sum(agent => agent.Live.Output)),
                FiniteNonnegative(group.Sum(agent => agent.Live.Total)),
                group.Count(agent => agent.Phase == AgentPhase.Generating),
                group.Count(agent => agent.Phase == AgentPhase.Tools)))
            .ToArray();
        var runtimeAgents = selected
            .Select(agent => new RuntimeAgent(
                safeIds[agent.Id],
                ClientId(agent.Source),
                agent.ParentId is { } parent && safeIds.TryGetValue(parent, out var safeParent) ? safeParent : null,
                PhaseName(agent.Phase),
                CleanModelOrNull(agent.Model),
                agent.LastActivity.ToUniversalTime().ToString("O"),
                FiniteNonnegative(agent.Live.Output),
                FiniteNonnegative(agent.Live.Total),
                agent.RecentSpeed is { } recent ? FiniteNonnegative(recent) : null))
            .ToArray();
        var latest = snapshot.LastResponse is { } response
            && RuntimeSources.Contains(response.Source)
            && enabledSources.Contains(response.Source)
            ? MapResponse(response)
            : null;
        var boundedEvents = (responseEvents ?? Array.Empty<ResponseEventInput>())
            .Where(item => RuntimeSources.Contains(item.Response.Source) && enabledSources.Contains(item.Response.Source))
            .TakeLast(MaximumResponseEvents)
            .Select(item => new RuntimeEvent(
                SafeEventId(processSalt, item.Sequence),
                "responseCompleted",
                ClientId(item.Response.Source),
                CleanModelOrNull(item.Response.Model),
                Math.Max(0, item.Response.OutputTokens),
                Math.Max(0, item.Response.TotalTokens),
                item.Response.Duration is { } duration ? Math.Max(0, (long)duration.TotalMilliseconds) : null,
                item.Response.Speed is { } speed ? FiniteNonnegative(speed) : null,
                item.Response.EndedAt.ToUniversalTime().ToString("O")))
            .ToArray();

        return new RuntimeSnapshot(
            Schema: 1,
            CapturedAt: snapshot.Timestamp == DateTimeOffset.MinValue ? DateTimeOffset.UtcNow.ToString("O") : snapshot.Timestamp.ToUniversalTime().ToString("O"),
            Client: "claude",
            SourceAvailable: sourceAvailable,
            LiveOutputTps: liveOutput,
            LiveTotalTps: liveTotal,
            EstimatedShare: estimatedShare,
            ModelRates: modelRates,
            MainAgents: runtimeAgents.Where((_, index) => !selected[index].IsSubagent).ToArray(),
            Subagents: runtimeAgents.Where((_, index) => selected[index].IsSubagent).ToArray(),
            LatestResponse: latest,
            ResponseEvents: boundedEvents);
    }

    private static RuntimeResponse MapResponse(ResponseSummary response) => new(
        ClientId(response.Source),
        CleanModelOrNull(response.Model),
        Math.Max(0, response.OutputTokens),
        Math.Max(0, response.TotalTokens),
        response.Duration is { } duration ? Math.Max(0, (long)duration.TotalMilliseconds) : null,
        response.Speed is { } speed ? FiniteNonnegative(speed) : null,
        response.EndedAt.ToUniversalTime().ToString("O"));

    private static string SafeId(byte[] salt, string privateId)
    {
        var digest = HMACSHA256.HashData(salt, Encoding.UTF8.GetBytes(privateId));
        return "agent-" + Convert.ToHexString(digest.AsSpan(0, 12)).ToLowerInvariant();
    }

    private static string ClientId(SourceKind source) => source switch
    {
        SourceKind.Codex => "codex",
        SourceKind.ClaudeCode => "claudeCode",
        SourceKind.ClaudeDesktop => "claudeDesktop",
        _ => throw new ArgumentOutOfRangeException(nameof(source)),
    };

    private static string SafeEventId(byte[] salt, long sequence)
    {
        var digest = HMACSHA256.HashData(salt, Encoding.UTF8.GetBytes(sequence.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        return "event-" + Convert.ToHexString(digest.AsSpan(0, 12)).ToLowerInvariant();
    }

    private static string PhaseName(AgentPhase phase) => phase switch
    {
        AgentPhase.Generating => "generating",
        AgentPhase.Tools => "tools",
        _ => "idle",
    };

    private static string CleanModel(string? model) => CleanModelOrNull(model) ?? "unknown";

    private static string? CleanModelOrNull(string? model)
    {
        if (string.IsNullOrWhiteSpace(model))
        {
            return null;
        }

        var cleaned = model.Trim();
        return cleaned.Length <= 256 && !cleaned.Any(char.IsControl) ? cleaned : null;
    }

    private static double FiniteNonnegative(double value) => double.IsFinite(value) ? Math.Max(0, value) : 0;
}

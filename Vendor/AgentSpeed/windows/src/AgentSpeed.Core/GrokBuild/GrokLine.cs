using System.Text.Json;
using AgentSpeed.Core.Harnesses;
using AgentSpeed.Core.Parsing;
using static AgentSpeed.Core.Harnesses.HarnessJson;

namespace AgentSpeed.Core.GrokBuild;

internal sealed record GrokUsage(string? Model, TokenCounts Tokens, long DurationMs, long Requests);

internal struct GrokLine
{
    public LineStatus Status;
    public string? Type;
    public string? SessionId;
    public string? PromptId;
    public string? Model;
    public long? TimeMs;
    public string? ToolStatus;
    public IReadOnlyList<GrokUsage>? Usage;

    public static GrokLine Read(ReadOnlySpan<byte> line)
    {
        if (JsonScan.IsBlank(line))
        {
            return new GrokLine { Status = LineStatus.Blank };
        }

        try
        {
            var reader = new Utf8JsonReader(line, JsonScan.Options);
            using var document = JsonDocument.ParseValue(ref reader);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return new GrokLine { Status = LineStatus.Malformed };
            }

            var result = new GrokLine { Status = LineStatus.Valid };
            if (String(root, "method") is not "session/update" and not "_x.ai/session/update")
            {
                return result;
            }

            var parameters = Get(root, "params");
            var update = Get(parameters, "update");
            var meta = Get(parameters, "_meta");
            result.Type = String(update, "sessionUpdate");
            result.SessionId = String(parameters, "sessionId");
            result.PromptId = String(update, "prompt_id") ?? String(meta, "promptId") ?? String(meta, "eventId");
            result.Model = String(update, "model_id") ?? String(Get(update, "_meta"), "modelId");
            result.TimeMs = Timestamp(Get(meta, "agentTimestampMs"));
            if (result.TimeMs is null)
            {
                var timestamp = Get(root, "timestamp");
                var seconds = Milliseconds(timestamp);
                result.TimeMs = timestamp.ValueKind == JsonValueKind.Number
                    ? seconds is { } value && value <= long.MaxValue / 1000 ? ValidTimestamp(value * 1000) : null : ValidTimestamp(seconds);
            }

            result.ToolStatus = String(update, "status");
            if (result.Type != "turn_completed")
            {
                return result;
            }

            var usage = Get(update, "usage");
            var buckets = Get(usage, "modelUsage");
            var parsed = new List<GrokUsage>();
            if (buckets.ValueKind == JsonValueKind.Object && buckets.EnumerateObject().Any())
            {
                foreach (var model in buckets.EnumerateObject().Take(256))
                {
                    if (model.Value.ValueKind == JsonValueKind.Object)
                    {
                        parsed.Add(ReadUsage(model.Value, model.Name));
                    }
                }
            }
            else
            {
                var totals = Get(usage, "totals");
                if (totals.ValueKind != JsonValueKind.Object)
                {
                    totals = usage;
                }

                if (totals.ValueKind == JsonValueKind.Object)
                {
                    parsed.Add(ReadUsage(totals, result.Model));
                }
            }

            result.Usage = parsed;
            return result;
        }
        catch (JsonException)
        {
            return new GrokLine { Status = LineStatus.Malformed };
        }
    }

    private static GrokUsage ReadUsage(JsonElement usage, string? model)
    {
        var input = Count(usage, "inputTokens");
        var output = Count(usage, "outputTokens");
        var tokens = new TokenCounts(input, Math.Min(input, Count(usage, "cachedReadTokens")),
            Math.Min(input, Count(usage, "cacheCreationTokens")), output, Math.Min(output, Count(usage, "reasoningTokens")));
        return new GrokUsage(model, tokens, Count(usage, "apiDurationMs"), Math.Clamp(Count(usage, "modelCalls"), 1, 100_000));
    }
}

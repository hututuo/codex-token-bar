using System.Text.Json;

namespace AgentSpeed.Core.ZCode;

internal static class ZCodeModes
{
    public static ExecutionModes Read(ReadOnlySpan<byte> data, string? provider, string? model)
    {
        if (data.IsEmpty) return ExecutionModes.Empty;
        try
        {
            using var document = JsonDocument.Parse(data.ToArray(), new JsonDocumentOptions { MaxDepth = 64 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("metadata", out var metadata) || metadata.ValueKind != JsonValueKind.Object
                || !metadata.TryGetProperty("highspeed", out var highspeed) || highspeed.ValueKind != JsonValueKind.Object)
                return ExecutionModes.Empty;
            if (!highspeed.TryGetProperty("schemaVersion", out var schema) || schema.ValueKind != JsonValueKind.Number || !schema.TryGetInt32(out var version) || version != 1
                || !highspeed.TryGetProperty("provider", out var p) || p.ValueKind != JsonValueKind.String
                || !highspeed.TryGetProperty("model", out var m) || m.ValueKind != JsonValueKind.String
                || !ExecutionModes.IsIdentifier(p.GetString(), 64) || !ExecutionModes.IsIdentifier(m.GetString(), 64)) return ExecutionModes.Empty;
            var modes = ExecutionModes.Of(ExecutionModeFact.Create(ExecutionModeKind.Accelerator, "highspeed",
                ExecutionModeEvidence.Selected, scope: ExecutionModeScope.Turn));
            var mock = highspeed.TryGetProperty("cardId", out var card) && card.ValueKind == JsonValueKind.String
                && card.GetString()!.StartsWith("hsc_mock_", StringComparison.Ordinal);
            if (!mock && provider is { Length: > 0 } && ExecutionModes.IsIdentifier(provider, 64))
            {
                var recorded = ExecutionModeFact.Create(ExecutionModeKind.Accelerator, provider,
                    ExecutionModeEvidence.Recorded, "zcode", ExecutionModeScope.Request);
                if (recorded is not null) modes = modes.Merge(ExecutionModes.Of(recorded with
                { Value = provider is "account:zai-highspeed-card" or "account:bigmodel-highspeed-card" ? "highspeed" : "standard" }));
            }
            return modes;
        }
        catch (JsonException) { return ExecutionModes.Empty; }
    }
}

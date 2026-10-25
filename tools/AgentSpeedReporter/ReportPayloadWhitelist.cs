using System.Globalization;
using System.Text.Json;

namespace CodexTokenBar.AgentSpeedReporter;

/// <summary>Defense in depth around the upstream body builder: this integration only sends live, source, and model data.</summary>
internal static class ReportPayloadWhitelist
{
    private static readonly HashSet<string> TopLevel = new(StringComparer.Ordinal)
    {
        "schema", "client", "deviceId", "username", "run", "sentAt", "windowMs", "activity",
        "live", "peak", "delta", "title", "sources", "models",
    };

    private static readonly HashSet<string> Forbidden = new(StringComparer.OrdinalIgnoreCase)
    {
        "cost", "costMicroUsd", "deltaMicroUsd", "liveMicroUsdPerSecond", "peakMicroUsdPerSecond",
        "knownShare", "unpricedRequests", "priceVersion", "traffic", "rxBytes", "txBytes",
        "rxBytesPerSecond", "txBytesPerSecond", "machineTraffic", "networkTraffic", "computerName",
        "hostname", "hostName", "machineName", "codexHome", "auth", "authorization", "apiKey",
        "token", "path", "rootPath", "transcriptPath", "sessionPath",
    };

    public static bool IsAllowed(ReadOnlySpan<byte> body, bool allowRealtime = false)
    {
        try
        {
            using var document = JsonDocument.Parse(body.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || root.EnumerateObject().Any(property => !TopLevel.Contains(property.Name)
                    && !(allowRealtime && property.Name == "realtime"))
                || root.EnumerateObject().Select(property => property.Name).Distinct(StringComparer.Ordinal).Count()
                    != root.EnumerateObject().Count()
                || ContainsForbidden(root))
            {
                return false;
            }

            return !allowRealtime || HasRealtime(root);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool HasRealtime(JsonElement root)
    {
        if (root.EnumerateObject().Count(property => property.NameEquals("realtime")) != 1
            || !root.TryGetProperty("realtime", out var realtime)
            || realtime.ValueKind != JsonValueKind.Object
            || !realtime.EnumerateObject().Select(property => property.Name)
                .SequenceEqual(new[] { "sourceMode", "observedAt", "observationAgeMs", "sourceResolutionMs" }, StringComparer.Ordinal)
            || !realtime.TryGetProperty("sourceMode", out var sourceModeElement)
            || sourceModeElement.ValueKind != JsonValueKind.String
            || sourceModeElement.GetString() is not { } sourceMode
            || sourceMode is not ("event" or "log" or "poll" or "mixed" or "unknown")
            || !realtime.TryGetProperty("observedAt", out var observedAt)
            || !realtime.TryGetProperty("observationAgeMs", out var age)
            || !realtime.TryGetProperty("sourceResolutionMs", out var resolution))
        {
            return false;
        }

        if (sourceMode == "unknown")
        {
            return observedAt.ValueKind == JsonValueKind.Null
                && age.ValueKind == JsonValueKind.Null
                && resolution.ValueKind == JsonValueKind.Null;
        }

        if (observedAt.ValueKind != JsonValueKind.String
            || !DateTimeOffset.TryParseExact(
                observedAt.GetString(),
                "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out _)
            || !IsBoundedInteger(age, 900_000))
        {
            return false;
        }

        return resolution.ValueKind == JsonValueKind.Null || IsBoundedInteger(resolution, 900_000);
    }

    private static bool IsBoundedInteger(JsonElement value, int maximum) =>
        value.ValueKind == JsonValueKind.Number
        && value.TryGetInt32(out var integer)
        && integer is >= 0 && integer <= maximum;

    private static bool ContainsForbidden(JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in value.EnumerateObject())
                {
                    if (Forbidden.Contains(property.Name) || ContainsForbidden(property.Value))
                    {
                        return true;
                    }
                }

                break;
            case JsonValueKind.Array:
                foreach (var item in value.EnumerateArray())
                {
                    if (ContainsForbidden(item))
                    {
                        return true;
                    }
                }

                break;
        }

        return false;
    }
}

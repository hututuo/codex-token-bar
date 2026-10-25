using System.Globalization;
using System.Text.Json;

namespace CodexTokenBar.AgentSpeedReporter;

/// <summary>Defense in depth around the upstream body builder: this integration only sends negotiated speed, token, cost, source, and model statistics.</summary>
internal static class ReportPayloadWhitelist
{
    private static readonly HashSet<string> TopLevel = new(StringComparer.Ordinal)
    {
        "schema", "client", "deviceId", "username", "run", "sentAt", "windowMs", "activity",
        "live", "peak", "delta", "title", "sources", "models", "cost",
    };

    private static readonly HashSet<string> Forbidden = new(StringComparer.OrdinalIgnoreCase)
    {
        "costMicroUsd", "traffic", "rxBytes", "txBytes",
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
                || ContainsForbidden(root, isRoot: true))
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

    // Cost is a negotiated statistical section, not arbitrary nested user content.
    private static bool IsCostSummary(JsonElement value, bool total)
    {
        string[] names = total
            ? ["liveMicroUsdPerSecond", "peakMicroUsdPerSecond", "knownShare", "deltaMicroUsd", "unpricedRequests", "priceVersion"]
            : ["liveMicroUsdPerSecond", "knownShare", "deltaMicroUsd", "unpricedRequests"];
        if (value.ValueKind != JsonValueKind.Object
            || value.EnumerateObject().Count() != names.Length
            || names.Any(name => !value.TryGetProperty(name, out _))) return false;
        foreach (var property in value.EnumerateObject())
        {
            if (property.Value.ValueKind != JsonValueKind.Number) return false;
            if (property.Name == "knownShare")
            {
                if (!property.Value.TryGetDouble(out var share) || !double.IsFinite(share) || share < 0 || share > 1) return false;
            }
            else if (!property.Value.TryGetInt64(out var number) || number < (property.Name == "priceVersion" ? 1 : 0)
                || number > 9_007_199_254_740_991) return false;
        }
        return true;
    }

    private static bool ContainsForbidden(JsonElement value, bool isRoot = false)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in value.EnumerateObject())
                {
                    if (property.NameEquals("cost"))
                    {
                        if (!IsCostSummary(property.Value, isRoot)) return true;
                        continue;
                    }
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

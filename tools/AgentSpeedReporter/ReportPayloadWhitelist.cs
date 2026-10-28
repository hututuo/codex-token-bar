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

            return ContainsOnlyReportableSources(root) && AggregatesHaveSourceAttribution(root)
                && (!allowRealtime || HasRealtime(root));
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

    private static bool ContainsOnlyReportableSources(JsonElement root)
    {
        var foundSourceProvenance = false;
        return Visit(root) && foundSourceProvenance;

        bool Visit(JsonElement value)
        {
            switch (value.ValueKind)
            {
                case JsonValueKind.Object:
                    foreach (var property in value.EnumerateObject())
                    {
                        if (property.NameEquals("source"))
                        {
                            foundSourceProvenance = true;
                            if (property.Value.ValueKind != JsonValueKind.String
                                || property.Value.GetString() is not { } sourceId
                                || !AgentSpeedReportSourcePolicy.IsReportableId(sourceId))
                            {
                                return false;
                            }
                        }
                        else if (property.NameEquals("sources"))
                        {
                            foundSourceProvenance = true;
                            if (!VisitSources(property.Value))
                            {
                                return false;
                            }
                        }
                        else if (property.NameEquals("models"))
                        {
                            if (property.Value.ValueKind != JsonValueKind.Array)
                            {
                                return false;
                            }

                            foreach (var model in property.Value.EnumerateArray())
                            {
                                if (model.ValueKind != JsonValueKind.Object
                                    || !model.TryGetProperty("sources", out var modelSources)
                                    || modelSources.ValueKind != JsonValueKind.Array || modelSources.GetArrayLength() == 0
                                    || !Visit(model))
                                {
                                    return false;
                                }
                            }
                        }
                        else if (!Visit(property.Value))
                        {
                            return false;
                        }
                    }

                    break;
                case JsonValueKind.Array:
                    foreach (var item in value.EnumerateArray())
                    {
                        if (!Visit(item))
                        {
                            return false;
                        }
                    }

                    break;
            }

            return true;
        }

        bool VisitSources(JsonElement value)
        {
            if (value.ValueKind != JsonValueKind.Array)
            {
                return false;
            }

            foreach (var item in value.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.String)
                {
                    if (!AgentSpeedReportSourcePolicy.IsReportableId(item.GetString() ?? string.Empty))
                    {
                        return false;
                    }
                }
                else if (item.ValueKind == JsonValueKind.Object)
                {
                    if (!item.TryGetProperty("source", out var source)
                        || source.ValueKind != JsonValueKind.String
                        || !AgentSpeedReportSourcePolicy.IsReportableId(source.GetString() ?? string.Empty)
                        || !Visit(item))
                    {
                        return false;
                    }
                }
                else
                {
                    return false;
                }
            }

            return true;
        }
    }

    private static bool AggregatesHaveSourceAttribution(JsonElement root)
    {
        var hasSources = root.TryGetProperty("sources", out var sourceRows)
            && sourceRows.ValueKind == JsonValueKind.Array && sourceRows.GetArrayLength() > 0;
        var hasModels = root.TryGetProperty("models", out var modelRows)
            && modelRows.ValueKind == JsonValueKind.Array
            && modelRows.EnumerateArray().Any(model => model.ValueKind == JsonValueKind.Object
                && model.TryGetProperty("sources", out var modelSources)
                && modelSources.ValueKind == JsonValueKind.Array && modelSources.GetArrayLength() > 0);
        var hasLiveOrPeak = IsNonZero(root, "live") || IsNonZero(root, "peak");
        var hasDelta = IsNonZero(root, "delta");

        if (hasLiveOrPeak && !hasSources)
        {
            return false;
        }

        if (hasDelta && !hasSources && !hasModels)
        {
            return false;
        }

        return true;
    }

    private static bool IsNonZero(JsonElement root, string propertyName) =>
        root.TryGetProperty(propertyName, out var value) && ContainsNonZeroNumber(value);

    private static bool ContainsNonZeroNumber(JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Number:
                return value.TryGetDouble(out var number) && number != 0;
            case JsonValueKind.Object:
                return value.EnumerateObject().Any(property => ContainsNonZeroNumber(property.Value));
            case JsonValueKind.Array:
                return value.EnumerateArray().Any(ContainsNonZeroNumber);
            default:
                return false;
        }
    }
}

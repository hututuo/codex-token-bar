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

    public static bool IsAllowed(ReadOnlySpan<byte> body)
    {
        try
        {
            using var document = JsonDocument.Parse(body.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
            var root = document.RootElement;
            return root.ValueKind == JsonValueKind.Object
                && root.EnumerateObject().All(property => TopLevel.Contains(property.Name))
                && !ContainsForbidden(root)
                && ContainsOnlyReportableSources(root)
                && AggregatesHaveSourceAttribution(root);
        }
        catch (JsonException)
        {
            return false;
        }
    }

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

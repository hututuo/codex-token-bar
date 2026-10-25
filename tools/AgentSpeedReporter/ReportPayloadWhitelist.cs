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
                && !ContainsForbidden(root);
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
}

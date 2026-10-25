using System.Globalization;
using System.Text.Json;
using AgentSpeed.Core;

namespace CodexTokenBar.AgentSpeedReporter;

internal static class RealtimeReportBody
{
    public static bool TryAppendSourceTiming(
        ReadOnlySpan<byte> reportBody,
        SourceReadObservation? observation,
        long nowTimestamp,
        long clockCorrectionSeconds,
        out byte[]? result,
        out long? observationAgeMs)
    {
        observation = observation is { SourceMode: not SourceReadMode.Unknown } ? observation : null;
        observationAgeMs = observation?.AgeMilliseconds(nowTimestamp);
        if (observationAgeMs is > 1_000)
        {
            result = null;
            return false;
        }

        using var document = JsonDocument.Parse(reportBody.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
        if (document.RootElement.ValueKind != JsonValueKind.Object
            || document.RootElement.TryGetProperty("realtime", out _))
        {
            throw new InvalidDataException("Invalid WebSocket report body.");
        }

        using var output = new MemoryStream(reportBody.Length + 160);
        using (var writer = new Utf8JsonWriter(output))
        {
            writer.WriteStartObject();
            foreach (var property in document.RootElement.EnumerateObject())
            {
                writer.WritePropertyName(property.Name);
                property.Value.WriteTo(writer);
            }

            writer.WritePropertyName("realtime");
            writer.WriteStartObject();
            writer.WriteString("sourceMode", observation is null ? "unknown" : ModeName(observation.SourceMode));
            if (observation is null)
            {
                writer.WriteNull("observedAt");
                writer.WriteNull("observationAgeMs");
                writer.WriteNull("sourceResolutionMs");
            }
            else
            {
                var correctedObservedAt = observation.ObservedAt.AddSeconds(clockCorrectionSeconds).ToUniversalTime();
                writer.WriteString("observedAt", correctedObservedAt.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture));
                writer.WriteNumber("observationAgeMs", observationAgeMs!.Value);
                if (observation.SourceResolutionMs is { } resolution && resolution is >= 0 and <= 900_000)
                {
                    writer.WriteNumber("sourceResolutionMs", resolution);
                }
                else
                {
                    writer.WriteNull("sourceResolutionMs");
                }
            }

            writer.WriteEndObject();
            writer.WriteEndObject();
        }

        result = output.ToArray();
        return true;
    }

    private static string ModeName(SourceReadMode mode) => mode switch
    {
        SourceReadMode.Event => "event",
        SourceReadMode.Log => "log",
        SourceReadMode.Poll => "poll",
        SourceReadMode.Mixed => "mixed",
        _ => "unknown",
    };
}

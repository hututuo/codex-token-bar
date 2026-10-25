using System.Text;
using System.Text.Json;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Harnesses;

internal static class HarnessJson
{
    public static JsonDocument? ReadMetadata(string path, int maxBytes)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            return null;
        }

        using var handle = IO.TranscriptTailer.Open(path);
        var length = RandomAccess.GetLength(handle);
        if (length <= 0 || length > maxBytes)
        {
            return null;
        }

        var bytes = new byte[(int)length];
        var offset = 0;
        while (offset < bytes.Length)
        {
            var read = RandomAccess.Read(handle, bytes.AsSpan(offset), offset);
            if (read <= 0) return null;
            offset += read;
        }

        var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 64 });
        if (document.RootElement.ValueKind == JsonValueKind.Object) return document;
        document.Dispose();
        return null;
    }

    public static JsonElement Get(JsonElement element, string key) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) ? value : default;

    public static string? String(JsonElement element, string key) => Text(Get(element, key));

    public static string? Text(JsonElement value) => value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text ? text : null;

    public static long Count(JsonElement element, string key)
    {
        var value = Get(element, key);
        if (value.ValueKind != JsonValueKind.Number)
        {
            return 0;
        }

        var reader = new Utf8JsonReader(Encoding.UTF8.GetBytes(value.GetRawText()));
        reader.Read();
        return JsonScan.ReadCount(ref reader);
    }

    public static long? Milliseconds(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number)
            && number >= 0 && number < long.MaxValue)
        {
            return (long)number;
        }

        if (value.ValueKind == JsonValueKind.String && Text(value) is { } timestamp && timestamp.Length <= 64
            && Rfc3339.TryParseUnixMs(Encoding.UTF8.GetBytes(timestamp), out var parsed))
        {
            return parsed;
        }

        return null;
    }

    public static long? Timestamp(JsonElement value) => ValidTimestamp(Milliseconds(value));

    public static long? ValidTimestamp(long? value) => value is >= -62_135_596_800_000 and <= 253_402_300_799_999 ? value : null;

    public static TokenCounts KimiUsage(JsonElement usage)
    {
        var cache = Count(usage, "inputCacheRead");
        var write = Count(usage, "inputCacheCreation");
        var input = JsonScan.SaturatingAdd(Count(usage, "inputOther"), JsonScan.SaturatingAdd(cache, write));
        var output = Count(usage, "output");
        var raw = Get(usage, "raw");
        var reasoning = Count(raw, "reasoning_tokens");
        if (reasoning == 0)
        {
            reasoning = Count(Get(raw, "completion_tokens_details"), "reasoning_tokens");
        }

        return new TokenCounts(input, Math.Min(input, cache), Math.Min(input, write), output, Math.Min(output, reasoning));
    }
}

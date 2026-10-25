using System.Text.Json;

namespace AgentSpeed.Core.Parsing;

/// <summary>Small helpers over <see cref="Utf8JsonReader"/> positioned on a value token.</summary>
internal static class JsonScan
{
    public static readonly JsonReaderOptions Options = new() { MaxDepth = 512 };

    public static bool IsBlank(ReadOnlySpan<byte> line)
    {
        foreach (var b in line)
        {
            if (b is not ((byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n' or 0x0B or 0x0C))
            {
                return false;
            }
        }

        return true;
    }

    public static void SkipValue(ref Utf8JsonReader reader)
    {
        if (reader.TokenType is JsonTokenType.StartObject or JsonTokenType.StartArray)
        {
            reader.Skip();
        }
    }

    /// <summary>Reads a string value; empty strings count as missing.</summary>
    public static string? ReadString(ref Utf8JsonReader reader)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            return reader.ValueSpan.IsEmpty ? null : reader.GetString();
        }

        SkipValue(ref reader);
        return null;
    }

    /// <summary>
    /// Reads a token counter (METRICS 3.2): missing or non-numeric is 0, a number is truncated and clamped to 0 … the
    /// cap, also one beyond the double range (<c>1e999</c> counts the cap, <c>-1e999</c> counts 0).
    /// </summary>
    public static long ReadCount(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.Number)
        {
            SkipValue(ref reader);
            return 0;
        }

        if (reader.TryGetInt64(out var value))
        {
            return TokenCounts.Clamp(value);
        }

        if (reader.TryGetDouble(out var real) && double.IsFinite(real))
        {
            return real <= 0 ? 0 : real >= TokenCounts.MaxValue ? TokenCounts.MaxValue : (long)real;
        }

        // A JSON number the double range cannot hold: its sign decides.
        return reader.ValueSpan[0] == (byte)'-' ? 0 : TokenCounts.MaxValue;
    }

    public static bool TryReadTimestamp(ref Utf8JsonReader reader, out long unixMs)
    {
        unixMs = 0;
        if (reader.TokenType != JsonTokenType.String)
        {
            SkipValue(ref reader);
            return false;
        }

        if (!reader.ValueIsEscaped)
        {
            return Rfc3339.TryParseUnixMs(reader.ValueSpan, out unixMs);
        }

        // A timestamp has at most 64 characters, each at most a 6-byte \uXXXX escape (METRICS 3.1).
        if (reader.ValueSpan.Length > 384)
        {
            return false;
        }

        Span<byte> buffer = stackalloc byte[384];
        var written = reader.CopyString(buffer);
        return Rfc3339.TryParseUnixMs(buffer[..written], out unixMs);
    }

    /// <summary>True when the current string token's raw bytes start with an ASCII prefix that never needs escaping.</summary>
    public static bool StringStartsWith(ref Utf8JsonReader reader, ReadOnlySpan<byte> prefix) =>
        reader.TokenType == JsonTokenType.String && reader.ValueSpan.StartsWith(prefix);

    public static long SaturatingAdd(long a, long b) => Math.Min(TokenCounts.MaxValue, a + b);
}

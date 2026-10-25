using System.Text.Json;

namespace AgentSpeed.Core.Parsing;

internal enum ClaudeLineKind : byte
{
    Other,
    User,
    Assistant,
    ApiRequest,
}

internal enum EntrypointKind : byte
{
    None,
    Desktop,
    Other,
}

internal enum StopReasonKind : byte
{
    Missing,
    ToolUse,
    PauseTurn,
    Other,
}

/// <summary>The facts of one Claude transcript line that the state machine needs (METRICS 4.1).</summary>
internal struct ClaudeLine
{
    public LineStatus Status;
    public bool HasTimestamp;
    public long TimestampMs;
    public ClaudeLineKind Kind;
    public EntrypointKind Entrypoint;
    public bool IsSidechain;
    public bool IsInterrupt;
    public bool HasToolUse;
    public StopReasonKind StopReason;
    public string? Cwd;
    public string? MessageId;
    public string? RequestId;
    public string? Uuid;
    public string? Model;
    public TokenCounts Usage;

    /// <summary><c>message.usage.speed == "fast"</c> (METRICS 3.2).</summary>
    public bool Fast;
    public string? Speed;

    public readonly string? Key => MessageId ?? RequestId ?? Uuid;
}

/// <summary>Pure, thread-safe extraction of <see cref="ClaudeLine"/> from one JSONL line.</summary>
internal static class ClaudeLineReader
{
    private static ReadOnlySpan<byte> InterruptPrefix => "[Request interrupted by user"u8;

    public static ClaudeLine Read(ReadOnlySpan<byte> line)
    {
        var result = default(ClaudeLine);
        if (JsonScan.IsBlank(line))
        {
            result.Status = LineStatus.Blank;
            return result;
        }

        var hints = new Hints(
            line.IndexOf("\"assistant\""u8) >= 0,
            line.IndexOf(InterruptPrefix) >= 0,
            line.IndexOf("\"tool_use\""u8) >= 0);
        try
        {
            var reader = new Utf8JsonReader(line, JsonScan.Options);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
            {
                return Malformed();
            }

            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                ReadTopLevelProperty(ref reader, ref result, hints);
            }

            if (reader.TokenType != JsonTokenType.EndObject || reader.Read())
            {
                return Malformed();
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException)
        {
            return Malformed();
        }

        return result;
    }

    private static ClaudeLine Malformed() => new() { Status = LineStatus.Malformed };

    private static bool IsDesktopEntrypoint(ref Utf8JsonReader reader)
    {
        if (reader.ValueIsEscaped || reader.HasValueSequence)
        {
            return reader.GetString()!.StartsWith("claude-desktop", StringComparison.Ordinal);
        }

        return reader.ValueSpan.StartsWith("claude-desktop"u8);
    }

    private static void ReadTopLevelProperty(ref Utf8JsonReader reader, ref ClaudeLine result, Hints hints)
    {
        if (reader.ValueTextEquals("type"u8))
        {
            reader.Read();
            result.Kind = reader.TokenType != JsonTokenType.String ? ClaudeLineKind.Other
                : reader.ValueTextEquals("assistant"u8) ? ClaudeLineKind.Assistant
                : reader.ValueTextEquals("user"u8) ? ClaudeLineKind.User
                : reader.ValueTextEquals("api-request"u8) ? ClaudeLineKind.ApiRequest
                : ClaudeLineKind.Other;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("timestamp"u8))
        {
            reader.Read();
            result.HasTimestamp = JsonScan.TryReadTimestamp(ref reader, out result.TimestampMs);
        }
        else if (reader.ValueTextEquals("message"u8))
        {
            reader.Read();
            if (reader.TokenType == JsonTokenType.StartObject && (hints.Assistant || hints.Interrupt || hints.ToolUse))
            {
                ReadMessage(ref reader, ref result, hints);
            }
            else
            {
                JsonScan.SkipValue(ref reader);
            }
        }
        else if (reader.ValueTextEquals("entrypoint"u8))
        {
            reader.Read();
            if (reader.TokenType == JsonTokenType.String)
            {
                result.Entrypoint = IsDesktopEntrypoint(ref reader) ? EntrypointKind.Desktop : EntrypointKind.Other;
            }
            else
            {
                JsonScan.SkipValue(ref reader);
            }
        }
        else if (reader.ValueTextEquals("cwd"u8))
        {
            reader.Read();
            result.Cwd = JsonScan.ReadString(ref reader);
        }
        else if (reader.ValueTextEquals("isSidechain"u8))
        {
            reader.Read();
            result.IsSidechain = reader.TokenType == JsonTokenType.True;
            JsonScan.SkipValue(ref reader);
        }
        else if (hints.Assistant && reader.ValueTextEquals("requestId"u8))
        {
            reader.Read();
            result.RequestId = JsonScan.ReadString(ref reader);
        }
        else if (hints.Assistant && reader.ValueTextEquals("uuid"u8))
        {
            reader.Read();
            result.Uuid = JsonScan.ReadString(ref reader);
        }
        else
        {
            reader.Read();
            JsonScan.SkipValue(ref reader);
        }
    }

    private static void ReadMessage(ref Utf8JsonReader reader, ref ClaudeLine result, Hints hints)
    {
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (hints.Assistant && reader.ValueTextEquals("id"u8))
            {
                reader.Read();
                result.MessageId = JsonScan.ReadString(ref reader);
            }
            else if (hints.Assistant && reader.ValueTextEquals("model"u8))
            {
                reader.Read();
                result.Model = JsonScan.ReadString(ref reader);
            }
            else if (hints.Assistant && reader.ValueTextEquals("stop_reason"u8))
            {
                reader.Read();
                result.StopReason = reader.TokenType switch
                {
                    JsonTokenType.Null => StopReasonKind.Missing,
                    JsonTokenType.String when reader.ValueTextEquals("tool_use"u8) => StopReasonKind.ToolUse,
                    JsonTokenType.String when reader.ValueTextEquals("pause_turn"u8) => StopReasonKind.PauseTurn,
                    _ => StopReasonKind.Other,
                };
                JsonScan.SkipValue(ref reader);
            }
            else if (hints.Assistant && reader.ValueTextEquals("usage"u8))
            {
                reader.Read();
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    (result.Usage, result.Fast, result.Speed) = ReadUsage(ref reader);
                }
                else
                {
                    JsonScan.SkipValue(ref reader);
                }
            }
            else if ((hints.Interrupt || hints.ToolUse) && reader.ValueTextEquals("content"u8))
            {
                reader.Read();
                (result.IsInterrupt, result.HasToolUse) = ReadContent(ref reader);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }
    }

    private static (TokenCounts Usage, bool Fast, string? Speed) ReadUsage(ref Utf8JsonReader reader)
    {
        long input = 0, cacheCreation = 0, cacheCreation1h = 0, cacheRead = 0, output = 0, thinking = 0;
        var fast = false;
        string? speed = null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("input_tokens"u8))
            {
                reader.Read();
                input = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("cache_creation_input_tokens"u8))
            {
                reader.Read();
                cacheCreation = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("cache_read_input_tokens"u8))
            {
                reader.Read();
                cacheRead = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("output_tokens"u8))
            {
                reader.Read();
                output = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("output_tokens_details"u8))
            {
                reader.Read();
                thinking = ReadNestedCount(ref reader, "thinking_tokens"u8);
            }
            else if (reader.ValueTextEquals("cache_creation"u8))
            {
                reader.Read();
                cacheCreation1h = ReadNestedCount(ref reader, "ephemeral_1h_input_tokens"u8);
            }
            else if (reader.ValueTextEquals("speed"u8))
            {
                reader.Read();
                speed = JsonScan.ReadString(ref reader);
                fast = speed == "fast";
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        var totalInput = JsonScan.SaturatingAdd(JsonScan.SaturatingAdd(input, cacheCreation), cacheRead);
        return (new TokenCounts(totalInput, cacheRead, cacheCreation, output, thinking, Math.Min(cacheCreation1h, cacheCreation)), fast, speed);
    }

    /// <summary>
    /// One integer member of a nested object (<c>output_tokens_details.thinking_tokens</c>,
    /// <c>cache_creation.ephemeral_1h_input_tokens</c>); 0 when absent.
    /// </summary>
    private static long ReadNestedCount(ref Utf8JsonReader reader, ReadOnlySpan<byte> name)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return 0;
        }

        long count = 0;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var isMatch = reader.ValueTextEquals(name);
            reader.Read();
            if (isMatch)
            {
                count = JsonScan.ReadCount(ref reader);
            }
            else
            {
                JsonScan.SkipValue(ref reader);
            }
        }

        return count;
    }

    /// <summary>Inspects the direct content blocks: an interrupt marker text and any <c>tool_use</c> block.</summary>
    private static (bool Interrupt, bool ToolUse) ReadContent(ref Utf8JsonReader reader)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            return (JsonScan.StringStartsWith(ref reader, InterruptPrefix), false);
        }

        if (reader.TokenType != JsonTokenType.StartArray)
        {
            JsonScan.SkipValue(ref reader);
            return (false, false);
        }

        bool interrupt = false, toolUse = false;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            bool isText = false, isToolUse = false, startsWithPrefix = false;
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                if (reader.ValueTextEquals("type"u8))
                {
                    reader.Read();
                    isText = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("text"u8);
                    isToolUse = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("tool_use"u8);
                    JsonScan.SkipValue(ref reader);
                }
                else if (reader.ValueTextEquals("text"u8))
                {
                    reader.Read();
                    startsWithPrefix = JsonScan.StringStartsWith(ref reader, InterruptPrefix);
                    JsonScan.SkipValue(ref reader);
                }
                else
                {
                    reader.Read();
                    JsonScan.SkipValue(ref reader);
                }
            }

            interrupt |= isText && startsWithPrefix;
            toolUse |= isToolUse;
        }

        return (interrupt, toolUse);
    }

    private readonly record struct Hints(bool Assistant, bool Interrupt, bool ToolUse);
}

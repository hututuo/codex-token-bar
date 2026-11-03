using System.Text;
using System.Text.Json;

namespace AgentSpeed.Core.Parsing;

internal enum ClaudeLineKind : byte
{
    Other,
    User,
    Assistant,
    ApiRequest,
    Error,
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
    public bool ToolEndsTurn;
    public bool IsApiError;
    public bool HasToolUse;
    public StopReasonKind StopReason;
    public string? Cwd;
    public string? DisplayTitle;
    public int DisplayTitlePriority;
    public string? UserTextTitleCandidate;
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
    private const int DisplayTitleSourceByteLimit = 16 * 1024;

    public static ClaudeLine Read(ReadOnlySpan<byte> line)
    {
        var result = default(ClaudeLine);
        result.DisplayTitlePriority = int.MaxValue;
        if (JsonScan.IsBlank(line))
        {
            result.Status = LineStatus.Blank;
            return result;
        }

        var hints = new Hints(
            line.IndexOf("\"assistant\""u8) >= 0,
            line.IndexOf("\"user\""u8) >= 0,
            line.IndexOf(InterruptPrefix) >= 0,
            line.IndexOf("\"tool_use\""u8) >= 0,
            line.IndexOf("\"isApiErrorMessage\""u8) >= 0);
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

        if (result.Kind != ClaudeLineKind.User)
        {
            result.UserTextTitleCandidate = null;
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
                : reader.ValueTextEquals("api_error"u8) || reader.ValueTextEquals("stream_error"u8) ? ClaudeLineKind.Error
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
            if (reader.TokenType == JsonTokenType.StartObject && (hints.Assistant || hints.User || hints.Interrupt || hints.ToolUse || hints.ApiError))
            {
                ReadMessage(ref reader, ref result, hints);
            }
            else
            {
                JsonScan.SkipValue(ref reader);
            }
        }
        else if (reader.ValueTextEquals("toolEndsTurn"u8))
        {
            reader.Read();
            result.ToolEndsTurn = reader.TokenType == JsonTokenType.True;
            JsonScan.SkipValue(ref reader);
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
        else if (reader.ValueTextEquals("agentName"u8))
        {
            reader.Read();
            SetDisplayTitle(ref result, ReadDisplayString(ref reader), 0);
        }
        else if (reader.ValueTextEquals("title"u8))
        {
            reader.Read();
            SetDisplayTitle(ref result, ReadDisplayString(ref reader), 1);
        }
        else if (reader.ValueTextEquals("customTitle"u8))
        {
            reader.Read();
            SetDisplayTitle(ref result, ReadDisplayString(ref reader), 1);
        }
        else if (reader.ValueTextEquals("summary"u8))
        {
            reader.Read();
            SetDisplayTitle(ref result, ReadDisplayString(ref reader), 2);
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
            else if ((hints.User || hints.Interrupt || hints.ToolUse) && reader.ValueTextEquals("content"u8))
            {
                reader.Read();
                // Unknown type is allowed here so property order does not matter. The final record type is
                // checked before returning; known assistant lines avoid retaining their message body.
                (result.IsInterrupt, result.HasToolUse, result.UserTextTitleCandidate) = ReadContent(
                    ref reader,
                    result.Kind != ClaudeLineKind.Assistant);
            }
            else if (hints.ApiError && reader.ValueTextEquals("isApiErrorMessage"u8))
            {
                reader.Read();
                result.IsApiError = reader.TokenType == JsonTokenType.True;
                JsonScan.SkipValue(ref reader);
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
    private static (bool Interrupt, bool ToolUse, string? UserTextTitle) ReadContent(ref Utf8JsonReader reader, bool captureUserText)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            var interrupt = JsonScan.StringStartsWith(ref reader, InterruptPrefix);
            var content = ReadDisplayString(ref reader, captureUserText);
            return (interrupt,
                false,
                captureUserText ? FirstMeaningfulDisplayTitle(content) : null);
        }

        if (reader.TokenType != JsonTokenType.StartArray)
        {
            JsonScan.SkipValue(ref reader);
            return (false, false, null);
        }

        bool interrupt = false, toolUse = false;
        string? userTextTitle = null;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            bool isText = false, isToolUse = false, startsWithPrefix = false;
            string? text = null;
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
                    text = ReadDisplayString(ref reader, captureUserText);
                }
                else
                {
                    reader.Read();
                    JsonScan.SkipValue(ref reader);
                }
            }

            interrupt |= isText && startsWithPrefix;
            toolUse |= isToolUse;
            if (captureUserText && isText && userTextTitle is null)
            {
                userTextTitle = FirstMeaningfulDisplayTitle(text);
            }
        }

        return (interrupt, toolUse, userTextTitle);
    }

    private static string? ReadDisplayString(ref Utf8JsonReader reader, bool capture = true)
    {
        if (!capture || reader.TokenType != JsonTokenType.String || reader.ValueSpan.Length > DisplayTitleSourceByteLimit)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        return reader.GetString();
    }

    private static void SetDisplayTitle(ref ClaudeLine result, string? raw, int priority)
    {
        var title = FirstMeaningfulDisplayTitle(raw);
        if (title is null || priority >= result.DisplayTitlePriority) return;
        result.DisplayTitle = title;
        result.DisplayTitlePriority = priority;
    }

    private static string? FirstMeaningfulDisplayTitle(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        string? skippedTag = null;
        foreach (var rawLine in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var line = new string(rawLine.Select(ch => char.IsControl(ch) ? ' ' : ch).ToArray()).Trim();
            if (line.Length == 0 || line.StartsWith("[Request interrupted by user", StringComparison.Ordinal)) continue;
            if (skippedTag is not null)
            {
                var closing = "</" + skippedTag + ">";
                var closingAt = line.IndexOf(closing, StringComparison.OrdinalIgnoreCase);
                if (closingAt < 0) continue;
                line = line[(closingAt + closing.Length)..].Trim();
                skippedTag = null;
                if (line.Length == 0) continue;
            }

            foreach (var tag in SystemTags)
            {
                var opening = "<" + tag + ">";
                if (!line.StartsWith(opening, StringComparison.OrdinalIgnoreCase)) continue;
                var closing = "</" + tag + ">";
                var closingAt = line.IndexOf(closing, opening.Length, StringComparison.OrdinalIgnoreCase);
                if (closingAt < 0)
                {
                    skippedTag = tag;
                    line = string.Empty;
                }
                else
                {
                    line = line[(closingAt + closing.Length)..].Trim();
                }
                break;
            }

            if (line.Length == 0 || line.StartsWith('<') && line.EndsWith('>')) continue;
            return TruncateUnicode(line);
        }
        return null;
    }

    private static string TruncateUnicode(string value)
    {
        var count = 0;
        var end = 0;
        foreach (var rune in value.EnumerateRunes())
        {
            if (count == 120) break;
            end += rune.Utf16SequenceLength;
            count++;
        }
        return end < value.Length ? value[..end] : value;
    }

    private static readonly string[] SystemTags =
    [
        "system-reminder", "task-notification", "command-message", "command-name", "command-args",
        "local-command-caveat", "local-command-stdout", "local-command-stderr", "available-deferred-tools",
        "user-prompt-submit-hook",
    ];

    private readonly record struct Hints(bool Assistant, bool User, bool Interrupt, bool ToolUse, bool ApiError);
}

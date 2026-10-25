using System.Text.Json;

namespace AgentSpeed.Core.Parsing;

internal enum CodexLineKind : byte
{
    Other,
    SessionMeta,
    TurnContext,
    ResponseItem,
    EventMsg,
    TokenUsageRecord,
}

internal enum CodexPayloadKind : byte
{
    None,
    Other,
    Message,
    Reasoning,
    AgentMessage,
    OutputSuffix,
    CallSuffix,
    TaskStarted,
    UserMessage,
    TokenCount,
    TaskComplete,
    TurnAborted,
}

internal enum CodexRole : byte
{
    None,
    User,
    Developer,
    System,
    Assistant,
    Other,
}

internal enum CodexInfoKind : byte
{
    Missing,
    Null,
    Object,
}

/// <summary>Cumulative or last usage of a legacy <c>token_count</c> event, including <c>total_tokens</c>.</summary>
internal readonly record struct CodexUsage(TokenCounts Tokens, long TotalTokens)
{
    public CodexUsage Minus(in CodexUsage other) => new(
        new TokenCounts(
            Tokens.Input - other.Tokens.Input,
            Tokens.CachedInput - other.Tokens.CachedInput,
            Tokens.CacheWriteInput - other.Tokens.CacheWriteInput,
            Tokens.Output - other.Tokens.Output,
            Tokens.Reasoning - other.Tokens.Reasoning),
        TotalTokens - other.TotalTokens);

    public bool AnyNegative =>
        Tokens.Input < 0 || Tokens.CachedInput < 0 || Tokens.CacheWriteInput < 0 || Tokens.Output < 0
        || Tokens.Reasoning < 0 || TotalTokens < 0;
}

/// <summary>The facts of one Codex envelope line that the state machine needs (METRICS 4.2).</summary>
internal struct CodexLine
{
    public LineStatus Status;
    public bool HasTimestamp;
    public long TimestampMs;
    public CodexLineKind Kind;
    public CodexPayloadKind PayloadKind;
    public CodexRole Role;
    public bool ThreadSourceIsSubagent;
    public bool SourceHasSubagent;
    public bool HasUsage;
    public CodexInfoKind Info;
    public bool HasTotal;
    public bool HasLast;
    public string? Recipient;
    public string? Cwd;
    public string? Model;
    public string? AgentPath;
    public string? Id;
    public string? ParentThreadId;
    public string? SpawnParentThreadId;
    public string? ThreadId;
    public string? ResponseId;

    /// <summary><c>payload.model_provider</c> of a <c>session_meta</c> (METRICS 3.2).</summary>
    public string? ModelProvider;
    public TokenCounts Usage;
    public CodexUsage Total;
    public CodexUsage Last;
}

/// <summary>Pure, thread-safe extraction of <see cref="CodexLine"/> from one JSONL line.</summary>
internal static class CodexLineReader
{
    public static CodexLine Read(ReadOnlySpan<byte> line)
    {
        var result = default(CodexLine);
        if (JsonScan.IsBlank(line))
        {
            result.Status = LineStatus.Blank;
            return result;
        }

        var hints = new Hints(
            line.IndexOf("\"session_meta\""u8) >= 0 || line.IndexOf("\"turn_context\""u8) >= 0,
            line.IndexOf("\"agent_message\""u8) >= 0,
            line.IndexOf("\"token_usage_record\""u8) >= 0,
            line.IndexOf("\"token_count\""u8) >= 0);
        try
        {
            var reader = new Utf8JsonReader(line, JsonScan.Options);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
            {
                return Malformed();
            }

            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                if (reader.ValueTextEquals("timestamp"u8))
                {
                    reader.Read();
                    result.HasTimestamp = JsonScan.TryReadTimestamp(ref reader, out result.TimestampMs);
                }
                else if (reader.ValueTextEquals("type"u8))
                {
                    reader.Read();
                    result.Kind = ClassifyKind(ref reader);
                    JsonScan.SkipValue(ref reader);
                }
                else if (reader.ValueTextEquals("payload"u8))
                {
                    reader.Read();
                    if (reader.TokenType == JsonTokenType.StartObject)
                    {
                        ReadPayload(ref reader, ref result, hints);
                    }
                    else
                    {
                        JsonScan.SkipValue(ref reader);
                    }
                }
                else
                {
                    reader.Read();
                    JsonScan.SkipValue(ref reader);
                }
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

    private static CodexLine Malformed() => new() { Status = LineStatus.Malformed };

    private static CodexLineKind ClassifyKind(ref Utf8JsonReader reader) =>
        reader.TokenType != JsonTokenType.String ? CodexLineKind.Other
        : reader.ValueTextEquals("response_item"u8) ? CodexLineKind.ResponseItem
        : reader.ValueTextEquals("event_msg"u8) ? CodexLineKind.EventMsg
        : reader.ValueTextEquals("token_usage_record"u8) ? CodexLineKind.TokenUsageRecord
        : reader.ValueTextEquals("session_meta"u8) ? CodexLineKind.SessionMeta
        : reader.ValueTextEquals("turn_context"u8) ? CodexLineKind.TurnContext
        : CodexLineKind.Other;

    private static void ReadPayload(ref Utf8JsonReader reader, ref CodexLine result, Hints hints)
    {
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("type"u8))
            {
                reader.Read();
                result.PayloadKind = ClassifyPayload(ref reader);
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("role"u8))
            {
                reader.Read();
                result.Role = reader.TokenType != JsonTokenType.String ? CodexRole.None
                    : reader.ValueTextEquals("user"u8) ? CodexRole.User
                    : reader.ValueTextEquals("developer"u8) ? CodexRole.Developer
                    : reader.ValueTextEquals("system"u8) ? CodexRole.System
                    : reader.ValueTextEquals("assistant"u8) ? CodexRole.Assistant
                    : CodexRole.Other;
                JsonScan.SkipValue(ref reader);
            }
            else if (hints.AgentMessage && reader.ValueTextEquals("recipient"u8))
            {
                reader.Read();
                result.Recipient = JsonScan.ReadString(ref reader);
            }
            else if (hints.Meta && reader.ValueTextEquals("cwd"u8))
            {
                reader.Read();
                result.Cwd = JsonScan.ReadString(ref reader);
            }
            else if (hints.Meta && reader.ValueTextEquals("model"u8))
            {
                reader.Read();
                result.Model = JsonScan.ReadString(ref reader);
            }
            else if (hints.Meta && reader.ValueTextEquals("model_provider"u8))
            {
                reader.Read();
                result.ModelProvider = JsonScan.ReadString(ref reader);
            }
            else if (hints.Meta && reader.ValueTextEquals("agent_path"u8))
            {
                reader.Read();
                result.AgentPath = JsonScan.ReadString(ref reader);
            }
            else if (hints.Meta && reader.ValueTextEquals("thread_source"u8))
            {
                reader.Read();
                result.ThreadSourceIsSubagent =
                    reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("subagent"u8);
                JsonScan.SkipValue(ref reader);
            }
            else if (hints.Meta && reader.ValueTextEquals("source"u8))
            {
                reader.Read();
                ReadSource(ref reader, ref result);
            }
            else if (hints.Meta && reader.ValueTextEquals("id"u8))
            {
                reader.Read();
                result.Id = JsonScan.ReadString(ref reader);
            }
            else if (hints.Meta && reader.ValueTextEquals("parent_thread_id"u8))
            {
                reader.Read();
                result.ParentThreadId = JsonScan.ReadString(ref reader);
            }
            else if ((hints.UsageRecord || hints.TokenCount) && reader.ValueTextEquals("thread_id"u8))
            {
                reader.Read();
                result.ThreadId = JsonScan.ReadString(ref reader);
            }
            else if (hints.UsageRecord && reader.ValueTextEquals("response_id"u8))
            {
                reader.Read();
                result.ResponseId = JsonScan.ReadString(ref reader);
            }
            else if (hints.UsageRecord && reader.ValueTextEquals("usage"u8))
            {
                reader.Read();
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    result.HasUsage = true;
                    result.Usage = ReadUsage(ref reader).Tokens;
                }
                else
                {
                    JsonScan.SkipValue(ref reader);
                }
            }
            else if (hints.TokenCount && reader.ValueTextEquals("info"u8))
            {
                reader.Read();
                ReadInfo(ref reader, ref result);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }
    }

    private static void ReadInfo(ref Utf8JsonReader reader, ref CodexLine result)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            result.Info = reader.TokenType == JsonTokenType.Null ? CodexInfoKind.Null : CodexInfoKind.Missing;
            JsonScan.SkipValue(ref reader);
            return;
        }

        result.Info = CodexInfoKind.Object;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("total_token_usage"u8))
            {
                reader.Read();
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    result.HasTotal = true;
                    result.Total = ReadUsage(ref reader);
                }
                else
                {
                    JsonScan.SkipValue(ref reader);
                }
            }
            else if (reader.ValueTextEquals("last_token_usage"u8))
            {
                reader.Read();
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    result.HasLast = true;
                    result.Last = ReadUsage(ref reader);
                }
                else
                {
                    JsonScan.SkipValue(ref reader);
                }
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }
    }

    private static CodexUsage ReadUsage(ref Utf8JsonReader reader)
    {
        long input = 0, cached = 0, cacheWrite = 0, output = 0, reasoning = 0, total = 0;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("input_tokens"u8))
            {
                reader.Read();
                input = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("cached_input_tokens"u8))
            {
                reader.Read();
                cached = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("cache_write_input_tokens"u8))
            {
                reader.Read();
                cacheWrite = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("output_tokens"u8))
            {
                reader.Read();
                output = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("reasoning_output_tokens"u8))
            {
                reader.Read();
                reasoning = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("total_tokens"u8))
            {
                reader.Read();
                total = JsonScan.ReadCount(ref reader);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        return new CodexUsage(new TokenCounts(input, cached, cacheWrite, output, reasoning), total);
    }

    private static CodexPayloadKind ClassifyPayload(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            return CodexPayloadKind.Other;
        }

        if (reader.ValueTextEquals("message"u8))
        {
            return CodexPayloadKind.Message;
        }

        if (reader.ValueTextEquals("reasoning"u8))
        {
            return CodexPayloadKind.Reasoning;
        }

        if (reader.ValueTextEquals("agent_message"u8))
        {
            return CodexPayloadKind.AgentMessage;
        }

        if (reader.ValueTextEquals("token_count"u8))
        {
            return CodexPayloadKind.TokenCount;
        }

        if (reader.ValueTextEquals("task_started"u8))
        {
            return CodexPayloadKind.TaskStarted;
        }

        if (reader.ValueTextEquals("user_message"u8))
        {
            return CodexPayloadKind.UserMessage;
        }

        if (reader.ValueTextEquals("task_complete"u8))
        {
            return CodexPayloadKind.TaskComplete;
        }

        if (reader.ValueTextEquals("turn_aborted"u8))
        {
            return CodexPayloadKind.TurnAborted;
        }

        ReadOnlySpan<byte> text = reader.ValueIsEscaped
            ? System.Text.Encoding.UTF8.GetBytes(reader.GetString() ?? string.Empty)
            : reader.ValueSpan;
        return text.EndsWith("_output"u8) ? CodexPayloadKind.OutputSuffix
            : text.EndsWith("_call"u8) ? CodexPayloadKind.CallSuffix
            : CodexPayloadKind.Other;
    }

    // source.subagent marks a sub-agent; source.subagent.thread_spawn.parent_thread_id names its parent.
    private static void ReadSource(ref Utf8JsonReader reader, ref CodexLine result)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return;
        }

        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var subagent = reader.ValueTextEquals("subagent"u8);
            reader.Read();
            if (!subagent)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            result.SourceHasSubagent = true;
            result.SpawnParentThreadId = null;
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                var spawn = reader.ValueTextEquals("thread_spawn"u8);
                reader.Read();
                if (spawn)
                {
                    result.SpawnParentThreadId = ReadStringProperty(ref reader, "parent_thread_id"u8);
                }
                else
                {
                    JsonScan.SkipValue(ref reader);
                }
            }
        }
    }

    private static string? ReadStringProperty(ref Utf8JsonReader reader, ReadOnlySpan<byte> name)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        string? value = null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var match = reader.ValueTextEquals(name);
            reader.Read();
            if (match)
            {
                value = JsonScan.ReadString(ref reader);
            }
            else
            {
                JsonScan.SkipValue(ref reader);
            }
        }

        return value;
    }

    private readonly record struct Hints(bool Meta, bool AgentMessage, bool UsageRecord, bool TokenCount);
}

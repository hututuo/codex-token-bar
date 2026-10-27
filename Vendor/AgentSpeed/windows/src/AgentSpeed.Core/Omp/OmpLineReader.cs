using System.Text.Json;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Omp;

/// <summary>
/// Pure, thread-safe extraction of <see cref="OmpLine"/> (METRICS 4.7). Duplicate keys resolve like Python's
/// <c>json.loads</c>: the last occurrence wins.
/// </summary>
internal static class OmpLineReader
{
    private const double TwoTo63 = 9_223_372_036_854_775_808.0;

    public static OmpLine Read(ReadOnlySpan<byte> line)
    {
        if (JsonScan.IsBlank(line))
        {
            return new OmpLine { Status = LineStatus.Blank };
        }

        // Like json.loads on the line's bytes: invalid UTF-8 anywhere, even in values never read, makes it malformed.
        if (!System.Text.Unicode.Utf8.IsValid(line))
        {
            return Malformed();
        }

        var result = default(OmpLine);
        var top = default(TopLevel);
        try
        {
            var reader = new Utf8JsonReader(line, JsonScan.Options);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
            {
                return Malformed();
            }

            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                ReadTopLevelProperty(ref reader, ref result, ref top);
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

        Classify(ref result, in top);
        return result;
    }

    private static OmpLine Malformed() => new() { Status = LineStatus.Malformed };

    private static void Classify(ref OmpLine result, in TopLevel top)
    {
        result.Kind = top.Type switch
        {
            TypeName.Title => OmpEntryKind.Title,
            TypeName.Session => OmpEntryKind.Session,
            TypeName.Message => top.HasMessage ? OmpEntryKind.Message : OmpEntryKind.Other,
            TypeName.ModelUsage => OmpEntryKind.ModelUsage,
            TypeName.ServiceTierChange => OmpEntryKind.ServiceTierChange,
            TypeName.Custom when top.IsSessionExit => OmpEntryKind.SessionExit,
            _ => OmpEntryKind.Other,
        };

        if (result.Kind == OmpEntryKind.Message)
        {
            var message = top.Message;
            result.Role = message.Role;
            result.Call = message.Call;
            result.StartedMs = message.StartedMs;
            result.DurationMs = message.DurationMs;
            result.CompletedAtMs = message.CompletedAtMs;
            result.Stop = message.Stop;
            result.PauseTurn = message.PauseTurn;
            result.ToolCallIds = message.ToolCallIds;
            result.ToolCallId = message.ToolCallId;
            result.IsFinalYield = message.IsYield && !message.IsErrorTrue;
        }
        else if (result.Kind == OmpEntryKind.ModelUsage)
        {
            result.Call = top.Call.ToCall();
        }
        if (result.Kind != OmpEntryKind.ServiceTierChange) result.SelectedModes = null;
    }

    private static void ReadTopLevelProperty(ref Utf8JsonReader reader, ref OmpLine result, ref TopLevel top)
    {
        if (reader.ValueTextEquals("type"u8))
        {
            reader.Read();
            top.Type = reader.TokenType != JsonTokenType.String ? TypeName.Other
                : reader.ValueTextEquals("message"u8) ? TypeName.Message
                : reader.ValueTextEquals("session"u8) ? TypeName.Session
                : reader.ValueTextEquals("title"u8) ? TypeName.Title
                : reader.ValueTextEquals("service_tier_change"u8) ? TypeName.ServiceTierChange
                : reader.ValueTextEquals("model_usage"u8) ? TypeName.ModelUsage
                : reader.ValueTextEquals("custom"u8) ? TypeName.Custom
                : TypeName.Other;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("id"u8))
        {
            reader.Read();
            result.Id = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("parentId"u8))
        {
            reader.Read();
            result.HasParentId = true;
            result.ParentId = JsonScan.ReadString(ref reader);
        }
        else if (reader.ValueTextEquals("serviceTier"u8))
        {
            reader.Read();
            var modes = ExecutionModes.Empty;
            if (reader.TokenType == JsonTokenType.StartObject)
            {
                while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
                {
                    var family = reader.GetString();
                    reader.Read();
                    var tier = JsonScan.ReadString(ref reader);
                    if (family is "openai" or "anthropic" or "google")
                        modes = modes.Merge(ExecutionModeNative.OmpTier(tier, family, ExecutionModeEvidence.Selected, ExecutionModeScope.Session));
                }
            }
            else if (reader.TokenType == JsonTokenType.String) top.Call.ServiceTier = reader.GetString();
            else JsonScan.SkipValue(ref reader);
            result.SelectedModes = modes;
        }
        else if (reader.ValueTextEquals("timestamp"u8))
        {
            reader.Read();
            result.TimestampMs = JsonScan.TryReadTimestamp(ref reader, out var ms) ? ms : null;
        }
        else if (reader.ValueTextEquals("cwd"u8))
        {
            reader.Read();
            result.Cwd = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("message"u8))
        {
            reader.Read();
            top.HasMessage = reader.TokenType == JsonTokenType.StartObject;
            top.Message = top.HasMessage ? ReadMessage(ref reader) : default;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("customType"u8))
        {
            reader.Read();
            top.IsSessionExit = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("session_exit"u8);
            JsonScan.SkipValue(ref reader);
        }
        else if (!TryReadCallProperty(ref reader, ref top.Call))
        {
            reader.Read();
            JsonScan.SkipValue(ref reader);
        }
    }

    // The reader is on the message object; it ends on its EndObject.
    private static Message ReadMessage(ref Utf8JsonReader reader)
    {
        var message = new Message { Stop = OmpStop.Aborted };
        var call = default(CallFields);
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("role"u8))
            {
                reader.Read();
                message.Role = reader.TokenType != JsonTokenType.String ? OmpRole.Other
                    : reader.ValueTextEquals("assistant"u8) ? OmpRole.Assistant
                    : reader.ValueTextEquals("user"u8) ? OmpRole.User
                    : reader.ValueTextEquals("toolResult"u8) ? OmpRole.ToolResult
                    : reader.ValueTextEquals("developer"u8) ? OmpRole.Developer
                    : OmpRole.Other;
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("timestamp"u8))
            {
                reader.Read();
                message.StartedMs = ReadFinite(ref reader) is { } started && started > 0 ? Truncate(started) : null;
            }
            else if (reader.ValueTextEquals("duration"u8))
            {
                reader.Read();
                message.DurationMs = ReadFinite(ref reader) is { } duration && duration >= 0 ? Truncate(duration) : null;
            }
            else if (reader.ValueTextEquals("completedAt"u8))
            {
                reader.Read();
                message.CompletedAtMs = ReadFinite(ref reader) is { } completed && completed > 0 ? Truncate(completed) : null;
            }
            else if (reader.ValueTextEquals("stopReason"u8))
            {
                reader.Read();
                message.Stop = reader.TokenType != JsonTokenType.String ? OmpStop.Aborted
                    : reader.ValueTextEquals("stop"u8) ? OmpStop.Stop
                    : reader.ValueTextEquals("toolUse"u8) ? OmpStop.ToolUse
                    : reader.ValueTextEquals("length"u8) ? OmpStop.Length
                    : reader.ValueTextEquals("error"u8) ? OmpStop.Error
                    : reader.ValueTextEquals("aborted"u8) ? OmpStop.Aborted
                    : OmpStop.Other;
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("stopDetails"u8))
            {
                reader.Read();
                message.PauseTurn = reader.TokenType == JsonTokenType.StartObject && ReadPauseTurn(ref reader);
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("content"u8))
            {
                reader.Read();
                message.ToolCallIds = reader.TokenType == JsonTokenType.StartArray ? ReadToolCallIds(ref reader) : null;
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("toolCallId"u8))
            {
                reader.Read();
                message.ToolCallId = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("toolName"u8))
            {
                reader.Read();
                message.IsYield = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("yield"u8);
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("isError"u8))
            {
                reader.Read();
                message.IsErrorTrue = reader.TokenType == JsonTokenType.True;
                JsonScan.SkipValue(ref reader);
            }
            else if (!TryReadCallProperty(ref reader, ref call))
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        message.Call = call.ToCall();
        return message;
    }

    // model, provider, api and usage: on assistant messages and on model_usage entries.
    private static bool TryReadCallProperty(ref Utf8JsonReader reader, ref CallFields call)
    {
        if (reader.ValueTextEquals("model"u8))
        {
            reader.Read();
            call.Model = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("provider"u8))
        {
            reader.Read();
            call.HasProvider = reader.TokenType == JsonTokenType.String;
            call.Provider = call.HasProvider && !reader.ValueSpan.IsEmpty ? reader.GetString() : null;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("serviceTier"u8))
        {
            reader.Read();
            call.ServiceTier = JsonScan.ReadString(ref reader);
        }
        else if (reader.ValueTextEquals("disabledFeatures"u8))
        {
            reader.Read();
            if (reader.TokenType == JsonTokenType.StartArray)
            {
                while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
                {
                    if (reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("priority"u8)) call.DisabledPriority = true;
                    JsonScan.SkipValue(ref reader);
                }
            }
            else JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("api"u8))
        {
            reader.Read();
            call.HasApi = reader.TokenType == JsonTokenType.String;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("usage"u8))
        {
            reader.Read();
            call.HasUsageObject = reader.TokenType == JsonTokenType.StartObject;
            call.Usage = call.HasUsageObject ? ReadUsage(ref reader) : default;
            JsonScan.SkipValue(ref reader);
        }
        else
        {
            return false;
        }

        return true;
    }

    // The reader is on the usage object; it ends on its EndObject.
    private static Usage ReadUsage(ref Utf8JsonReader reader)
    {
        var usage = default(Usage);
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("input"u8))
            {
                reader.Read();
                usage.Input = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("output"u8))
            {
                reader.Read();
                usage.Output = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("cacheRead"u8))
            {
                reader.Read();
                usage.CacheRead = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("cacheWrite"u8))
            {
                reader.Read();
                usage.CacheWrite = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("reasoningTokens"u8))
            {
                reader.Read();
                usage.Reasoning = JsonScan.ReadCount(ref reader);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        return usage;
    }

    // The reader is on the stopDetails object; it ends on its EndObject.
    private static bool ReadPauseTurn(ref Utf8JsonReader reader)
    {
        var pause = false;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var isType = reader.ValueTextEquals("type"u8);
            reader.Read();
            if (isType)
            {
                pause = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("pause_turn"u8);
            }

            JsonScan.SkipValue(ref reader);
        }

        return pause;
    }

    // The reader is on the content array; it ends on its EndArray.
    private static string[]? ReadToolCallIds(ref Utf8JsonReader reader)
    {
        List<string>? ids = null;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            var isToolCall = false;
            string? id = null;
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                if (reader.ValueTextEquals("type"u8))
                {
                    reader.Read();
                    isToolCall = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("toolCall"u8);
                }
                else if (reader.ValueTextEquals("id"u8))
                {
                    reader.Read();
                    id = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
                }
                else
                {
                    reader.Read();
                }

                JsonScan.SkipValue(ref reader);
            }

            if (isToolCall && id is not null && (ids ??= []).IndexOf(id) < 0)
            {
                ids.Add(id);
            }
        }

        return ids?.ToArray();
    }

    private static double? ReadFinite(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.Number)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        return reader.TryGetDouble(out var value) && double.IsFinite(value) ? value : null;
    }

    /// <summary>Toward zero, saturated to the <see cref="long"/> range.</summary>
    private static long Truncate(double value) =>
        value >= TwoTo63 ? long.MaxValue : value <= -TwoTo63 ? long.MinValue : (long)Math.Truncate(value);

    private enum TypeName : byte
    {
        Other,
        Title,
        Session,
        Message,
        ModelUsage,
        Custom,
        ServiceTierChange,
    }

    private struct Usage
    {
        public long Input;
        public long Output;
        public long CacheRead;
        public long CacheWrite;
        public long Reasoning;
    }

    private struct CallFields
    {
        public string? Model;
        public string? ServiceTier;
        public bool DisabledPriority;
        public bool HasProvider;
        public string? Provider;
        public bool HasApi;
        public bool HasUsageObject;
        public Usage Usage;

        public readonly OmpCall ToCall() => new()
        {
            Guarded = Model is not null && HasProvider && HasApi && HasUsageObject,
            Model = Model,
            ServiceTier = ServiceTier,
            DisabledPriority = DisabledPriority,
            Provider = Provider,
            HasUsage = Usage.Input > 0 || Usage.Output > 0 || Usage.CacheRead > 0 || Usage.CacheWrite > 0,
            Tokens = new TokenCounts(
                JsonScan.SaturatingAdd(JsonScan.SaturatingAdd(Usage.Input, Usage.CacheRead), Usage.CacheWrite),
                Usage.CacheRead,
                Usage.CacheWrite,
                Usage.Output,
                Usage.Reasoning),
        };
    }

    private struct Message
    {
        public OmpRole Role;
        public OmpCall Call;
        public long? StartedMs;
        public long? DurationMs;
        public long? CompletedAtMs;
        public OmpStop Stop;
        public bool PauseTurn;
        public string[]? ToolCallIds;
        public string? ToolCallId;
        public bool IsYield;
        public bool IsErrorTrue;
    }

    private struct TopLevel
    {
        public TypeName Type;
        public bool HasMessage;
        public Message Message;
        public bool IsSessionExit;
        public CallFields Call;
    }
}

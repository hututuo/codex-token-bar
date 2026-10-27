using System.Text;
using System.Text.Json;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.WorkBuddy;

/// <summary>
/// Pure, thread-safe extraction of <see cref="WorkBuddyLine"/> (METRICS 4.9). Duplicate keys resolve like Python's
/// <c>json.loads</c>: the last occurrence wins.
/// </summary>
internal static class WorkBuddyLineReader
{
    private const double TwoTo63 = 9_223_372_036_854_775_808.0;

    private static readonly string[] UserProviderPrefixes = ["custom:", "custom-local:"];

    public static WorkBuddyLine Read(ReadOnlySpan<byte> line)
    {
        if (JsonScan.IsBlank(line))
        {
            return new WorkBuddyLine { Status = LineStatus.Blank };
        }

        // Like json.loads on the line's bytes: invalid UTF-8 anywhere, even in values never read, makes it malformed.
        if (!System.Text.Unicode.Utf8.IsValid(line))
        {
            return Malformed();
        }

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
                ReadTopLevelProperty(ref reader, ref top);
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

        return Classify(in top);
    }

    /// <summary>
    /// The stream's model, else the requested id, trimmed; a <c>custom:</c> or <c>custom-local:</c> prefix (a model of
    /// the user's own provider) is removed and makes the provider <c>custom</c>.
    /// </summary>
    internal static (string? Model, string? Provider) ResolveModel(string? streamModel, string? requestModelId)
    {
        var model = FirstNonBlank(streamModel) ?? FirstNonBlank(requestModelId);
        if (model is null)
        {
            return (null, null);
        }

        foreach (var prefix in UserProviderPrefixes)
        {
            if (model.Length >= prefix.Length && Ascii.EqualsIgnoreCase(model.AsSpan(0, prefix.Length), prefix))
            {
                var rest = TrimWhiteSpace(model[(model.IndexOf(':') + 1)..]);
                return (rest.Length > 0 ? rest : null, "custom");
            }
        }

        return (model, null);
    }

    private static string? FirstNonBlank(string? value) =>
        value is not null && TrimWhiteSpace(value) is { Length: > 0 } trimmed ? trimmed : null;

    // Whitespace is Python's str.isspace() (METRICS 4.9): .NET's white space plus the separators U+001C–U+001F.
    private static bool IsWhiteSpace(char c) => char.IsWhiteSpace(c) || c is >= '\u001c' and <= '\u001f';

    private static string TrimWhiteSpace(string value)
    {
        var start = 0;
        var end = value.Length;
        while (start < end && IsWhiteSpace(value[start]))
        {
            start++;
        }

        while (end > start && IsWhiteSpace(value[end - 1]))
        {
            end--;
        }

        return value[start..end];
    }

    private static WorkBuddyLine Malformed() => new() { Status = LineStatus.Malformed };

    private static WorkBuddyLine Classify(in TopLevel top)
    {
        var data = top.Data;
        var (model, provider) = ResolveModel(data.Model, data.RequestModelId);
        return new WorkBuddyLine
        {
            Status = LineStatus.Valid,
            Item = top.Type switch
            {
                TypeName.Message when top.Role == RoleName.User => WorkBuddyItem.UserMessage,
                TypeName.Message when top.Role == RoleName.Assistant => WorkBuddyItem.AssistantMessage,
                TypeName.FunctionCall => WorkBuddyItem.FunctionCall,
                TypeName.FunctionCallResult => WorkBuddyItem.FunctionCallResult,
                TypeName.Reasoning => WorkBuddyItem.Reasoning,
                TypeName.ModelUsage => WorkBuddyItem.ModelUsage,
                _ => WorkBuddyItem.Other,
            },
            TimestampMs = top.TimestampMs,
            Cwd = top.Cwd is null || TrimWhiteSpace(top.Cwd).Length == 0 ? null : top.Cwd,
            Id = top.Id,
            CallId = top.CallId,
            Incomplete = top.Incomplete,
            SkipRun = data.SkipRun,
            PartialAborted = data.PartialAborted,
            HasError = data.HasError,
            Compaction = data.Compaction,
            MessageId = data.MessageId,
            Model = model,
            RequestModelId = data.RequestModelId,
            Provider = provider,
            HasUsage = data.Usage.HasCore || data.Usage.HasRaw,
            Tokens = data.Usage.Normalize(),
        };
    }

    private static void ReadTopLevelProperty(ref Utf8JsonReader reader, ref TopLevel top)
    {
        if (reader.ValueTextEquals("type"u8))
        {
            reader.Read();
            top.Type = reader.TokenType != JsonTokenType.String ? TypeName.Other
                : reader.ValueTextEquals("message"u8) ? TypeName.Message
                : reader.ValueTextEquals("function_call"u8) ? TypeName.FunctionCall
                : reader.ValueTextEquals("function_call_result"u8) ? TypeName.FunctionCallResult
                : reader.ValueTextEquals("reasoning"u8) ? TypeName.Reasoning
                : reader.ValueTextEquals("model-usage"u8) ? TypeName.ModelUsage
                : TypeName.Other;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("role"u8))
        {
            reader.Read();
            top.Role = reader.TokenType != JsonTokenType.String ? RoleName.Other
                : reader.ValueTextEquals("user"u8) ? RoleName.User
                : reader.ValueTextEquals("assistant"u8) ? RoleName.Assistant
                : RoleName.Other;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("timestamp"u8))
        {
            reader.Read();
            top.TimestampMs = ReadTimestamp(ref reader);
        }
        else if (reader.ValueTextEquals("cwd"u8))
        {
            reader.Read();
            top.Cwd = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("id"u8))
        {
            reader.Read();
            top.Id = JsonScan.ReadString(ref reader);
        }
        else if (reader.ValueTextEquals("callId"u8))
        {
            reader.Read();
            top.CallId = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("status"u8))
        {
            reader.Read();
            top.Incomplete = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("incomplete"u8);
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("providerData"u8))
        {
            reader.Read();
            top.Data = reader.TokenType == JsonTokenType.StartObject ? ReadProviderData(ref reader) : default;
            JsonScan.SkipValue(ref reader);
        }
        else
        {
            reader.Read();
            JsonScan.SkipValue(ref reader);
        }
    }

    // The reader is on the providerData object; it ends on its EndObject.
    private static ProviderData ReadProviderData(ref Utf8JsonReader reader)
    {
        var data = default(ProviderData);
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("skipRun"u8))
            {
                reader.Read();
                data.SkipRun = reader.TokenType == JsonTokenType.True;
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("isPartialAborted"u8))
            {
                reader.Read();
                data.PartialAborted = reader.TokenType == JsonTokenType.True;
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("error"u8))
            {
                reader.Read();
                data.HasError = reader.TokenType == JsonTokenType.StartObject;
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("agent"u8))
            {
                reader.Read();
                data.Compaction = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("compact"u8);
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("messageId"u8))
            {
                reader.Read();
                data.MessageId = JsonScan.ReadString(ref reader);
            }
            else if (reader.ValueTextEquals("model"u8))
            {
                reader.Read();
                data.Model = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("requestModelId"u8))
            {
                reader.Read();
                data.RequestModelId = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("usage"u8))
            {
                reader.Read();
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    data.Usage.ReadCore(ref reader);
                }
                else
                {
                    data.Usage.ClearCore();
                    JsonScan.SkipValue(ref reader);
                }
            }
            else if (reader.ValueTextEquals("rawUsage"u8))
            {
                reader.Read();
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    data.Usage.ReadRaw(ref reader);
                }
                else
                {
                    data.Usage.ClearRaw();
                    JsonScan.SkipValue(ref reader);
                }
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        return data;
    }

    /// <summary>Unix ms as a finite number above 0 (truncated), or an ISO 8601 string (METRICS 3.1); null otherwise.</summary>
    private static long? ReadTimestamp(ref Utf8JsonReader reader)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            return JsonScan.TryReadTimestamp(ref reader, out var parsed) ? parsed : null;
        }

        if (reader.TokenType != JsonTokenType.Number)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        if (reader.TryGetInt64(out var whole))
        {
            return whole > 0 ? whole : null;
        }

        return reader.TryGetDouble(out var real) && double.IsFinite(real) && real > 0
            ? (real >= TwoTo63 ? long.MaxValue : (long)Math.Truncate(real))
            : null;
    }

    private enum TypeName : byte
    {
        Other,
        Message,
        FunctionCall,
        FunctionCallResult,
        Reasoning,
        ModelUsage,
    }

    private enum RoleName : byte
    {
        Other,
        User,
        Assistant,
    }

    private struct ProviderData
    {
        public bool SkipRun;
        public bool PartialAborted;
        public bool HasError;
        public bool Compaction;
        public string? MessageId;
        public string? Model;
        public string? RequestModelId;
        public WorkBuddyUsage Usage;
    }

    private struct TopLevel
    {
        public TypeName Type;
        public RoleName Role;
        public long? TimestampMs;
        public string? Cwd;
        public string? Id;
        public string? CallId;
        public bool Incomplete;
        public ProviderData Data;
    }
}

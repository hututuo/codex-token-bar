using System.Globalization;
using System.Text;
using System.Text.Json;

namespace AgentSpeed.Core.Parsing;

internal enum DshEventKind : byte
{
    Other,

    /// <summary>A session header: a <c>session</c> line or a snapshot's <c>header</c>.</summary>
    Header,
    RequestHeader,
    StepStart,
    AssistantMessage,
    TurnEnd,
}

/// <summary>The facts of one DeepSeek Harness event that the state machine needs (METRICS 4.3).</summary>
internal struct DshEvent
{
    public DshEventKind Kind;
    public bool HasTime;
    public long TimeMs;

    /// <summary><c>seq</c> as written (a JSON number's text), for keys of messages without an id.</summary>
    public string? Seq;

    public string? Id;
    public long CreatedMs;
    public string? Cwd;
    public bool OriginSubagent;
    public bool Delegated;
    public string? ParentSession;

    /// <summary><c>data.header.config.model</c>.</summary>
    public string? ConfigModel;

    /// <summary><c>data.header.config.provider</c> (METRICS 3.2).</summary>
    public string? ConfigProvider;

    /// <summary><c>data.message.source.model</c>.</summary>
    public string? SourceModel;

    /// <summary><c>data.message.source.provider</c> (METRICS 3.2).</summary>
    public string? SourceProvider;
    public string? MessageId;
    public bool HasUsage;
    public TokenCounts Usage;
    public bool HasToolCall;
}

/// <summary>One decoded dsh line; wrappers are already unwrapped into <see cref="Events"/> in order.</summary>
internal struct DshLine
{
    public LineStatus Status;
    public DshEvent Event;

    /// <summary>Set instead of <see cref="Event"/> when the line expands to zero or several events.</summary>
    public DshEvent[]? Events;
}

/// <summary>Pure, thread-safe extraction of <see cref="DshLine"/> from one JSONL line.</summary>
internal static class DshLineReader
{
    private const int MaxWrapperDepth = 64;

    public static DshLine Read(ReadOnlySpan<byte> line)
    {
        if (JsonScan.IsBlank(line))
        {
            return new DshLine { Status = LineStatus.Blank };
        }

        var events = new List<DshEvent>(1);
        try
        {
            var reader = new Utf8JsonReader(line, JsonScan.Options);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
            {
                return Malformed();
            }

            ReadObject(ref reader, events, 0);
            if (reader.Read())
            {
                return Malformed();
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException)
        {
            return Malformed();
        }

        return events.Count == 1
            ? new DshLine { Status = LineStatus.Valid, Event = events[0] }
            : new DshLine { Status = LineStatus.Valid, Events = [.. events] };
    }

    private static DshLine Malformed() => new() { Status = LineStatus.Malformed };

    // Reads one object (the reader is on its StartObject), appends the events it stands for to output and returns
    // its own fields. Without output, nested wrappers are skipped.
    private static DshEvent ReadObject(ref Utf8JsonReader reader, List<DshEvent>? output, int depth)
    {
        var facts = default(DshEvent);
        var type = TypeKind.Missing;
        List<DshEvent>? inner = null;
        List<DshEvent>? records = null;
        DshEvent? header = null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("type"u8))
            {
                reader.Read();
                type = ClassifyType(ref reader);
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("time"u8))
            {
                reader.Read();
                facts.HasTime = TryReadMilliseconds(ref reader, out facts.TimeMs);
            }
            else if (reader.ValueTextEquals("seq"u8))
            {
                reader.Read();
                facts.Seq = ReadScalarText(ref reader);
            }
            else if (reader.ValueTextEquals("data"u8))
            {
                reader.Read();
                ReadData(ref reader, ref facts);
            }
            else if (reader.ValueTextEquals("id"u8))
            {
                reader.Read();
                facts.Id = JsonScan.ReadString(ref reader);
            }
            else if (reader.ValueTextEquals("createdAt"u8))
            {
                reader.Read();
                facts.CreatedMs = TryReadMilliseconds(ref reader, out var created) ? created : 0;
            }
            else if (reader.ValueTextEquals("cwd"u8))
            {
                reader.Read();
                facts.Cwd = JsonScan.ReadString(ref reader);
            }
            else if (reader.ValueTextEquals("origin"u8))
            {
                reader.Read();
                facts.OriginSubagent = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("subagent"u8);
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("delegationDepth"u8))
            {
                reader.Read();
                facts.Delegated = reader.TokenType == JsonTokenType.Number && reader.TryGetDouble(out var level) && level > 0;
                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("parentSession"u8))
            {
                reader.Read();
                facts.ParentSession = JsonScan.ReadString(ref reader);
            }
            else if (output is not null && reader.ValueTextEquals("event"u8))
            {
                reader.Read();
                inner = ReadNested(ref reader, depth);
            }
            else if (output is not null && reader.ValueTextEquals("header"u8))
            {
                reader.Read();
                header = ReadHeader(ref reader);
            }
            else if (output is not null && reader.ValueTextEquals("records"u8))
            {
                reader.Read();
                records = ReadRecords(ref reader, depth);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        facts.Kind = type switch
        {
            TypeKind.Session => DshEventKind.Header,
            TypeKind.RequestHeader => DshEventKind.RequestHeader,
            TypeKind.StepStart => DshEventKind.StepStart,
            TypeKind.AssistantMessage => DshEventKind.AssistantMessage,
            TypeKind.TurnEnd => DshEventKind.TurnEnd,
            _ => DshEventKind.Other,
        };
        switch (type)
        {
            case TypeKind.Event when inner is not null:
                output?.AddRange(inner);
                break;
            case TypeKind.Snapshot:
                if (header is { } first)
                {
                    output?.Add(first);
                }

                if (records is not null)
                {
                    output?.AddRange(records);
                }

                break;
            default:
                output?.Add(facts);
                break;
        }

        return facts;
    }

    private static List<DshEvent>? ReadNested(ref Utf8JsonReader reader, int depth)
    {
        if (reader.TokenType != JsonTokenType.StartObject || depth >= MaxWrapperDepth)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        var events = new List<DshEvent>(1);
        ReadObject(ref reader, events, depth + 1);
        return events;
    }

    // A snapshot header counts by its own fields, whatever its type says.
    private static DshEvent? ReadHeader(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        return ReadObject(ref reader, null, MaxWrapperDepth) with { Kind = DshEventKind.Header };
    }

    private static List<DshEvent>? ReadRecords(ref Utf8JsonReader reader, int depth)
    {
        if (reader.TokenType != JsonTokenType.StartArray || depth >= MaxWrapperDepth)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        var events = new List<DshEvent>();
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            if (reader.TokenType == JsonTokenType.StartObject)
            {
                ReadObject(ref reader, events, depth + 1);
            }
            else
            {
                JsonScan.SkipValue(ref reader);
            }
        }

        return events;
    }

    private static void ReadData(ref Utf8JsonReader reader, ref DshEvent facts)
    {
        facts.ConfigModel = null;
        facts.ConfigProvider = null;
        facts.SourceModel = null;
        facts.SourceProvider = null;
        facts.MessageId = null;
        facts.HasUsage = false;
        facts.Usage = default;
        facts.HasToolCall = false;
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return;
        }

        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("header"u8))
            {
                reader.Read();
                (facts.ConfigModel, facts.ConfigProvider) = ReadConfig(ref reader);
            }
            else if (reader.ValueTextEquals("message"u8))
            {
                reader.Read();
                ReadMessage(ref reader, ref facts);
            }
            else if (reader.ValueTextEquals("usage"u8))
            {
                reader.Read();
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    facts.HasUsage = true;
                    facts.Usage = ReadUsage(ref reader);
                }
                else
                {
                    facts.HasUsage = false;
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

    // data.header.config.model and .provider
    private static (string? Model, string? Provider) ReadConfig(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return (null, null);
        }

        (string?, string?) result = (null, null);
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var config = reader.ValueTextEquals("config"u8);
            reader.Read();
            if (config)
            {
                result = ReadModelAndProvider(ref reader);
            }
            else
            {
                JsonScan.SkipValue(ref reader);
            }
        }

        return result;
    }

    private static void ReadMessage(ref Utf8JsonReader reader, ref DshEvent facts)
    {
        facts.MessageId = null;
        facts.HasToolCall = false;
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return;
        }

        string? sourceModel = null;
        string? sourceProvider = null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("id"u8))
            {
                reader.Read();
                facts.MessageId = JsonScan.ReadString(ref reader);
            }
            else if (reader.ValueTextEquals("source"u8))
            {
                reader.Read();
                (sourceModel, sourceProvider) = ReadModelAndProvider(ref reader);
            }
            else if (reader.ValueTextEquals("content"u8))
            {
                reader.Read();
                facts.HasToolCall = ReadHasToolCall(ref reader);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        facts.SourceModel = sourceModel;
        facts.SourceProvider = sourceProvider;
    }

    private static bool ReadHasToolCall(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartArray)
        {
            JsonScan.SkipValue(ref reader);
            return false;
        }

        var found = false;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            var isToolCall = false;
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                var isType = reader.ValueTextEquals("type"u8);
                reader.Read();
                if (isType)
                {
                    isToolCall = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("tool-call"u8);
                }

                JsonScan.SkipValue(ref reader);
            }

            found |= isToolCall;
        }

        return found;
    }

    private static TokenCounts ReadUsage(ref Utf8JsonReader reader)
    {
        long input = 0, output = 0, cacheRead = 0, cacheWrite = 0;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("inputTokens"u8))
            {
                reader.Read();
                input = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("outputTokens"u8))
            {
                reader.Read();
                output = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("cacheReadTokens"u8))
            {
                reader.Read();
                cacheRead = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("cacheWriteTokens"u8))
            {
                reader.Read();
                cacheWrite = JsonScan.ReadCount(ref reader);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        // dsh reports reasoning inside outputTokens, never separately.
        return new TokenCounts(
            JsonScan.SaturatingAdd(JsonScan.SaturatingAdd(input, cacheRead), cacheWrite), cacheRead, cacheWrite, output, 0);
    }

    private static (string? Model, string? Provider) ReadModelAndProvider(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return (null, null);
        }

        string? model = null;
        string? provider = null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var isModel = reader.ValueTextEquals("model"u8);
            var isProvider = !isModel && reader.ValueTextEquals("provider"u8);
            reader.Read();
            if (isModel)
            {
                model = JsonScan.ReadString(ref reader);
            }
            else if (isProvider)
            {
                provider = JsonScan.ReadString(ref reader);
            }
            else
            {
                JsonScan.SkipValue(ref reader);
            }
        }

        return (model, provider);
    }

    /// <summary>A JSON number (not a boolean) as whole milliseconds, truncated toward zero.</summary>
    private static bool TryReadMilliseconds(ref Utf8JsonReader reader, out long value)
    {
        value = 0;
        if (reader.TokenType != JsonTokenType.Number)
        {
            JsonScan.SkipValue(ref reader);
            return false;
        }

        if (reader.TryGetInt64(out value))
        {
            return true;
        }

        if (reader.TryGetDouble(out var real) && double.IsFinite(real) && Math.Abs(real) < 9.2e18)
        {
            value = (long)Math.Truncate(real);
            return true;
        }

        return false;
    }

    private static string? ReadScalarText(ref Utf8JsonReader reader)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Number:
                return Encoding.UTF8.GetString(reader.ValueSpan);
            case JsonTokenType.String:
                return reader.GetString();
            case JsonTokenType.True or JsonTokenType.False:
                return reader.GetBoolean().ToString(CultureInfo.InvariantCulture);
            default:
                JsonScan.SkipValue(ref reader);
                return null;
        }
    }

    private static TypeKind ClassifyType(ref Utf8JsonReader reader) =>
        reader.TokenType != JsonTokenType.String ? TypeKind.Other
        : reader.ValueTextEquals("assistant/message"u8) ? TypeKind.AssistantMessage
        : reader.ValueTextEquals("step/start"u8) ? TypeKind.StepStart
        : reader.ValueTextEquals("turn/end"u8) ? TypeKind.TurnEnd
        : reader.ValueTextEquals("request/header"u8) ? TypeKind.RequestHeader
        : reader.ValueTextEquals("event"u8) ? TypeKind.Event
        : reader.ValueTextEquals("snapshot"u8) ? TypeKind.Snapshot
        : reader.ValueTextEquals("session"u8) ? TypeKind.Session
        : TypeKind.Other;

    private enum TypeKind : byte
    {
        Missing,
        Other,
        Event,
        Snapshot,
        Session,
        RequestHeader,
        StepStart,
        AssistantMessage,
        TurnEnd,
    }
}

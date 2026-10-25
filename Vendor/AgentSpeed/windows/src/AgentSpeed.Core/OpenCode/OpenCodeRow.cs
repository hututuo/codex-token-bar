using System.Text.Json;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.OpenCode;

internal enum OpenCodeRowKind : byte
{
    Other,
    Assistant,
    Compaction,
    Idle,
}

/// <summary>One <c>session_v2</c> row (METRICS 4.5).</summary>
internal readonly record struct OpenCodeSessionInfo(string Id, string? ParentId, string? Directory, long CreatedMs, long UpdatedMs);

/// <summary>The fields of <c>session_message.data</c> that the rules need (METRICS 4.5).</summary>
/// <param name="Streamed">Null while the request is in flight.</param>
internal readonly record struct OpenCodeData(
    long? Created,
    long? Streamed,
    long? Completed,
    string? Model,
    bool FinishedWithToolCalls,
    bool HasTokens,
    TokenCounts Tokens,
    string? Provider = null,
    string? ServiceTier = null);

/// <param name="Data">Null when <c>data</c> is not a JSON object (a malformed row).</param>
internal sealed record OpenCodeRow(
    string Id,
    string SessionId,
    OpenCodeRowKind Kind,
    long Seq,
    long TimeCreated,
    long TimeUpdated,
    OpenCodeData? Data)
{
    public static OpenCodeRowKind KindOf(ReadOnlySpan<byte> type) =>
        type.SequenceEqual("assistant"u8) ? OpenCodeRowKind.Assistant
        : type.SequenceEqual("compaction"u8) ? OpenCodeRowKind.Compaction
        : type.SequenceEqual("idle"u8) ? OpenCodeRowKind.Idle
        : OpenCodeRowKind.Other;

    /// <summary>Rows that may still change: in-flight or unfinished messages.</summary>
    public bool IsUnfinished => Data is { } data && Kind switch
    {
        OpenCodeRowKind.Assistant => data.Streamed is null || data.Completed is null,
        OpenCodeRowKind.Compaction => data.Completed is null,
        _ => false,
    };
}

/// <summary>Pure extraction of <see cref="OpenCodeData"/> from the UTF-8 JSON in <c>data</c>.</summary>
internal static class OpenCodeDataReader
{
    public static OpenCodeData? Read(ReadOnlySpan<byte> json)
    {
        try
        {
            var reader = new Utf8JsonReader(json, JsonScan.Options);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
            {
                return null;
            }

            long? created = null, streamed = null, completed = null;
            string? model = null;
            string? provider = null;
            string? serviceTier = null;
            var toolCalls = false;
            var hasTokens = false;
            var tokens = default(TokenCounts);
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                if (reader.ValueTextEquals("time"u8))
                {
                    reader.Read();
                    created = streamed = completed = null;
                    ReadTimes(ref reader, ref created, ref streamed, ref completed);
                }
                else if (reader.ValueTextEquals("model"u8))
                {
                    reader.Read();
                    (model, provider) = ReadModel(ref reader);
                }
                else if (reader.ValueTextEquals("native"u8))
                {
                    reader.Read();
                    if (reader.TokenType == JsonTokenType.StartObject)
                    {
                        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
                        {
                            var tier = reader.ValueTextEquals("serviceTier"u8);
                            reader.Read();
                            if (tier) serviceTier = JsonScan.ReadString(ref reader);
                            else JsonScan.SkipValue(ref reader);
                        }
                    }
                    else JsonScan.SkipValue(ref reader);
                }
                else if (reader.ValueTextEquals("finish"u8))
                {
                    reader.Read();
                    toolCalls = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("tool-calls"u8);
                    JsonScan.SkipValue(ref reader);
                }
                else if (reader.ValueTextEquals("tokens"u8))
                {
                    reader.Read();
                    hasTokens = reader.TokenType == JsonTokenType.StartObject;
                    tokens = hasTokens ? ReadTokens(ref reader) : default;
                    if (!hasTokens)
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
                return null;
            }

            return new OpenCodeData(created, streamed, completed, model, toolCalls, hasTokens, tokens, provider, serviceTier);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    private static void ReadTimes(ref Utf8JsonReader reader, ref long? created, ref long? streamed, ref long? completed)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return;
        }

        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("created"u8))
            {
                reader.Read();
                created = ReadTime(ref reader);
            }
            else if (reader.ValueTextEquals("streamed"u8))
            {
                reader.Read();
                streamed = ReadTime(ref reader);
            }
            else if (reader.ValueTextEquals("completed"u8))
            {
                reader.Read();
                completed = ReadTime(ref reader);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }
    }

    private static long? ReadTime(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.Number)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        if (reader.TryGetInt64(out var value))
        {
            return value;
        }

        return reader.TryGetDouble(out var real) && double.IsFinite(real) && Math.Abs(real) < 9e15 ? (long)real : null;
    }

    // model.id and model.providerID (METRICS 3.2).
    private static (string? Id, string? Provider) ReadModel(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return (null, null);
        }

        string? id = null;
        string? provider = null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var isId = reader.ValueTextEquals("id"u8);
            var isProvider = !isId && reader.ValueTextEquals("providerID"u8);
            reader.Read();
            if (isId)
            {
                id = JsonScan.ReadString(ref reader);
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

        return (id, provider);
    }

    // input = input + cache.read + cache.write; output = output + reasoning (OpenCode reports reasoning separately).
    private static TokenCounts ReadTokens(ref Utf8JsonReader reader)
    {
        long input = 0, output = 0, reasoning = 0, read = 0, write = 0;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("input"u8))
            {
                reader.Read();
                input = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("output"u8))
            {
                reader.Read();
                output = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("reasoning"u8))
            {
                reader.Read();
                reasoning = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("cache"u8))
            {
                reader.Read();
                read = write = 0;
                ReadCache(ref reader, ref read, ref write);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        return new TokenCounts(
            JsonScan.SaturatingAdd(JsonScan.SaturatingAdd(input, read), write),
            read,
            write,
            JsonScan.SaturatingAdd(output, reasoning),
            reasoning);
    }

    private static void ReadCache(ref Utf8JsonReader reader, ref long read, ref long write)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return;
        }

        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("read"u8))
            {
                reader.Read();
                read = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("write"u8))
            {
                reader.Read();
                write = JsonScan.ReadCount(ref reader);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }
    }
}

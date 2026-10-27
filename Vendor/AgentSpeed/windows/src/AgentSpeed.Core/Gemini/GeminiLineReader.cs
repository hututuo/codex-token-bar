using System.Text.Json;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Gemini;

/// <summary>
/// Pure, thread-safe extraction of <see cref="GeminiLine"/> (METRICS 4.6). Duplicate keys resolve like Python's
/// <c>json.loads</c>: the last occurrence wins.
/// </summary>
internal static class GeminiLineReader
{
    private static ReadOnlySpan<byte> CancelledText => "Request cancelled."u8;

    /// <summary>One <c>.jsonl</c> line.</summary>
    public static GeminiLine Read(ReadOnlySpan<byte> line)
    {
        if (JsonScan.IsBlank(line))
        {
            return new GeminiLine { Status = LineStatus.Blank };
        }

        return TryReadTopLevel(line, out var top) ? top.Classify() : Malformed();
    }

    /// <summary>A whole legacy <c>.json</c> file: an object with a string <c>sessionId</c>, else malformed.</summary>
    public static GeminiLine ReadDocument(ReadOnlySpan<byte> document)
    {
        if (!TryReadTopLevel(document, out var top) || top.SessionId is not { } sessionId)
        {
            return Malformed();
        }

        return new GeminiLine { Status = LineStatus.Valid, Kind = GeminiRecordKind.Document, Header = top.ToHeader(sessionId) };
    }

    private static GeminiLine Malformed() => new() { Status = LineStatus.Malformed };

    private static bool TryReadTopLevel(ReadOnlySpan<byte> json, out TopLevel top)
    {
        top = default;
        try
        {
            var reader = new Utf8JsonReader(json, JsonScan.Options);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
            {
                return false;
            }

            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                ReadTopLevelProperty(ref reader, ref top);
            }

            return !reader.Read();
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException)
        {
            return false;
        }
    }

    private static void ReadTopLevelProperty(ref Utf8JsonReader reader, ref TopLevel top)
    {
        if (reader.ValueTextEquals("$rewindTo"u8))
        {
            reader.Read();
            top.Rewind = reader.TokenType == JsonTokenType.String;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("$patch"u8))
        {
            reader.Read();
            top.HasPatch = reader.TokenType == JsonTokenType.StartObject;
            top.RemoveIds = top.HasPatch ? ReadRemoveIds(ref reader) : null;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("$set"u8))
        {
            reader.Read();
            top.Metadata = ReadMetadata(ref reader);
        }
        else if (reader.ValueTextEquals("sessionId"u8))
        {
            reader.Read();
            top.SessionId = ReadAnyString(ref reader);
        }
        else if (reader.ValueTextEquals("projectHash"u8))
        {
            reader.Read();
            top.HasProjectHash = reader.TokenType == JsonTokenType.String;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("kind"u8))
        {
            reader.Read();
            top.IsSubagentKind = IsSubagentKind(ref reader);
        }
        else if (reader.ValueTextEquals("startTime"u8))
        {
            reader.Read();
            top.StartMs = ReadTimestamp(ref reader);
        }
        else if (reader.ValueTextEquals("lastUpdated"u8))
        {
            reader.Read();
            top.LastUpdatedMs = ReadTimestamp(ref reader);
        }
        else if (reader.ValueTextEquals("messages"u8))
        {
            reader.Read();
            top.Messages = ReadMessages(ref reader);
        }
        else if (!TryReadMessageProperty(ref reader, ref top.Message, full: true))
        {
            reader.Read();
            JsonScan.SkipValue(ref reader);
        }
    }

    // The reader is on the $patch object; it ends on its EndObject.
    private static string[]? ReadRemoveIds(ref Utf8JsonReader reader)
    {
        string[]? removed = null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var isRemoveIds = reader.ValueTextEquals("removeIds"u8);
            reader.Read();
            if (!isRemoveIds)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            if (reader.TokenType != JsonTokenType.StartArray)
            {
                removed = null;
                JsonScan.SkipValue(ref reader);
                continue;
            }

            var ids = new List<string>();
            while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
            {
                if (ReadAnyString(ref reader) is { } id)
                {
                    ids.Add(id);
                }
            }

            removed = [.. ids];
        }

        return removed;
    }

    private static GeminiMetadata? ReadMetadata(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        long? lastUpdated = null;
        var isSubagent = false;
        string? sessionId = null;
        GeminiCheckpoint? checkpoint = null;
        var hasSummary = false;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("lastUpdated"u8))
            {
                reader.Read();
                lastUpdated = ReadTimestamp(ref reader);
            }
            else if (reader.ValueTextEquals("kind"u8))
            {
                reader.Read();
                isSubagent = IsSubagentKind(ref reader);
            }
            else if (reader.ValueTextEquals("sessionId"u8))
            {
                reader.Read();
                sessionId = ReadAnyString(ref reader);
            }
            else if (reader.ValueTextEquals("messages"u8))
            {
                reader.Read();
                checkpoint = ReadCheckpoint(ref reader);
            }
            else if (reader.ValueTextEquals("summary"u8))
            {
                reader.Read();
                hasSummary = reader.TokenType == JsonTokenType.String && !reader.ValueSpan.IsEmpty;
                JsonScan.SkipValue(ref reader);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        return new GeminiMetadata(lastUpdated, isSubagent, sessionId, checkpoint, hasSummary);
    }

    private static GeminiCheckpoint? ReadCheckpoint(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartArray)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        var ids = new List<string>();
        var responses = new List<GeminiCheckpointResponse>();
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            var fields = ReadMessageObject(ref reader, full: false);
            if (fields.Id is not { } id)
            {
                continue;
            }

            ids.Add(id);
            if (fields.Type == MessageType.Gemini && fields.HasTokens && fields.TimestampMs is { } ts)
            {
                responses.Add(new GeminiCheckpointResponse(id, ts, fields.Tokens, fields.Model));
            }
        }

        return new GeminiCheckpoint([.. ids], [.. responses]);
    }

    private static GeminiMessage[]? ReadMessages(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartArray)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        var messages = new List<GeminiMessage>();
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            var fields = ReadMessageObject(ref reader, full: true);
            if (fields.Id is not null)
            {
                messages.Add(fields.ToMessage());
            }
        }

        return [.. messages];
    }

    // The reader is on the message's StartObject; it ends on its EndObject.
    private static MessageFields ReadMessageObject(ref Utf8JsonReader reader, bool full)
    {
        var fields = default(MessageFields);
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (!TryReadMessageProperty(ref reader, ref fields, full))
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        return fields;
    }

    /// <summary>Reads one message member; returns false (consuming nothing) for any other property name.</summary>
    private static bool TryReadMessageProperty(ref Utf8JsonReader reader, ref MessageFields fields, bool full)
    {
        if (reader.ValueTextEquals("id"u8))
        {
            reader.Read();
            fields.Id = ReadAnyString(ref reader);
        }
        else if (reader.ValueTextEquals("type"u8))
        {
            reader.Read();
            fields.Type = ClassifyType(ref reader);
        }
        else if (reader.ValueTextEquals("timestamp"u8))
        {
            reader.Read();
            fields.TimestampMs = ReadTimestamp(ref reader);
        }
        else if (reader.ValueTextEquals("tokens"u8))
        {
            reader.Read();
            fields.HasTokens = reader.TokenType == JsonTokenType.StartObject;
            fields.Tokens = fields.HasTokens ? ReadTokens(ref reader) : default;
            JsonScan.SkipValue(ref reader);
        }
        else if (reader.ValueTextEquals("model"u8))
        {
            reader.Read();
            fields.Model = JsonScan.ReadString(ref reader);
        }
        else if (full && reader.ValueTextEquals("content"u8))
        {
            reader.Read();
            ReadContent(ref reader, ref fields);
        }
        else if (full && reader.ValueTextEquals("toolCalls"u8))
        {
            reader.Read();
            fields.ToolCalls = ReadToolCalls(ref reader);
        }
        else if (full && reader.ValueTextEquals("thoughts"u8))
        {
            reader.Read();
            fields.ThoughtsMs = ReadThoughts(ref reader);
        }
        else
        {
            return false;
        }

        return true;
    }

    private static MessageType ClassifyType(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            JsonScan.SkipValue(ref reader);
            return MessageType.Other;
        }

        return reader.ValueTextEquals("gemini"u8) ? MessageType.Gemini
            : reader.ValueTextEquals("user"u8) ? MessageType.User
            : reader.ValueTextEquals("info"u8) ? MessageType.Info
            : reader.ValueTextEquals("error"u8) ? MessageType.Error
            : MessageType.Other;
    }

    // Gemini's usageMetadata (METRICS 4.6); the reader is on the tokens object.
    private static TokenCounts ReadTokens(ref Utf8JsonReader reader)
    {
        long input = 0, output = 0, cached = 0, thoughts = 0, tool = 0;
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
            else if (reader.ValueTextEquals("cached"u8))
            {
                reader.Read();
                cached = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("thoughts"u8))
            {
                reader.Read();
                thoughts = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("tool"u8))
            {
                reader.Read();
                tool = JsonScan.ReadCount(ref reader);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }

        return new TokenCounts(
            JsonScan.SaturatingAdd(input, tool), cached, 0, JsonScan.SaturatingAdd(output, thoughts), thoughts);
    }

    // Visible text: a string that is not blank, or a non-thought text part; functionCall parts are calls.
    private static void ReadContent(ref Utf8JsonReader reader, ref MessageFields fields)
    {
        fields.HasVisibleText = false;
        fields.HasFunctionCall = false;
        fields.IsCancelledText = false;
        switch (reader.TokenType)
        {
            case JsonTokenType.String:
                fields.IsCancelledText = reader.ValueTextEquals(CancelledText);
                fields.HasVisibleText = GeminiText.HasVisibleText(ref reader);
                break;
            case JsonTokenType.StartObject:
                ReadPart(ref reader, ref fields);
                break;
            case JsonTokenType.StartArray:
                while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
                {
                    if (reader.TokenType == JsonTokenType.String)
                    {
                        fields.HasVisibleText |= GeminiText.HasVisibleText(ref reader);
                    }
                    else if (reader.TokenType == JsonTokenType.StartObject)
                    {
                        ReadPart(ref reader, ref fields);
                    }
                    else
                    {
                        JsonScan.SkipValue(ref reader);
                    }
                }

                break;
        }
    }

    private static void ReadPart(ref Utf8JsonReader reader, ref MessageFields fields)
    {
        bool visible = false, thought = false, call = false;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("functionCall"u8))
            {
                reader.Read();
                call = reader.TokenType == JsonTokenType.StartObject;
            }
            else if (reader.ValueTextEquals("text"u8))
            {
                reader.Read();
                visible = GeminiText.HasVisibleText(ref reader);
            }
            else if (reader.ValueTextEquals("thought"u8))
            {
                reader.Read();
                thought = reader.TokenType == JsonTokenType.True;
            }
            else
            {
                reader.Read();
            }

            JsonScan.SkipValue(ref reader);
        }

        fields.HasFunctionCall |= call;
        fields.HasVisibleText |= visible && !thought;
    }

    private static GeminiToolCall[]? ReadToolCalls(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartArray)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        List<GeminiToolCall>? calls = null;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            string? id = null;
            long? timestamp = null;
            var isCompleteTask = false;
            var status = CallStatus.Other;
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                if (reader.ValueTextEquals("id"u8))
                {
                    reader.Read();
                    id = ReadAnyString(ref reader);
                }
                else if (reader.ValueTextEquals("name"u8))
                {
                    reader.Read();
                    isCompleteTask = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("complete_task"u8);
                    JsonScan.SkipValue(ref reader);
                }
                else if (reader.ValueTextEquals("status"u8))
                {
                    reader.Read();
                    status = reader.TokenType != JsonTokenType.String ? CallStatus.Other
                        : reader.ValueTextEquals("success"u8) ? CallStatus.Success
                        : reader.ValueTextEquals("cancelled"u8) ? CallStatus.Cancelled
                        : CallStatus.Other;
                    JsonScan.SkipValue(ref reader);
                }
                else if (reader.ValueTextEquals("timestamp"u8))
                {
                    reader.Read();
                    timestamp = ReadTimestamp(ref reader);
                }
                else
                {
                    reader.Read();
                    JsonScan.SkipValue(ref reader);
                }
            }

            if (id is not null)
            {
                (calls ??= []).Add(new GeminiToolCall(
                    id, timestamp, isCompleteTask && status == CallStatus.Success, status == CallStatus.Cancelled));
            }
        }

        return calls?.ToArray();
    }

    // The latest parseable thought timestamp.
    private static long? ReadThoughts(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartArray)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        long? latest = null;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                JsonScan.SkipValue(ref reader);
                continue;
            }

            long? timestamp = null;
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                var isTimestamp = reader.ValueTextEquals("timestamp"u8);
                reader.Read();
                if (isTimestamp)
                {
                    timestamp = ReadTimestamp(ref reader);
                }
                else
                {
                    JsonScan.SkipValue(ref reader);
                }
            }

            latest = Max(latest, timestamp);
        }

        return latest;
    }

    private static bool IsSubagentKind(ref Utf8JsonReader reader)
    {
        var result = reader.TokenType == JsonTokenType.String && reader.ValueTextEquals("subagent"u8);
        JsonScan.SkipValue(ref reader);
        return result;
    }

    private static long? ReadTimestamp(ref Utf8JsonReader reader) =>
        JsonScan.TryReadTimestamp(ref reader, out var ms) ? ms : null;

    /// <summary>Any string value, including the empty string (Python <c>isinstance(value, str)</c>).</summary>
    private static string? ReadAnyString(ref Utf8JsonReader reader)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            return reader.GetString();
        }

        JsonScan.SkipValue(ref reader);
        return null;
    }

    private static long? Max(long? a, long? b) => a is { } x && b is { } y ? Math.Max(x, y) : a ?? b;

    private static long? Min(long? a, long? b) => a is { } x && b is { } y ? Math.Min(x, y) : a ?? b;

    private enum MessageType : byte
    {
        Other,
        User,
        Gemini,
        Error,
        Info,
    }

    private enum CallStatus : byte
    {
        Other,
        Success,
        Cancelled,
    }

    private struct MessageFields
    {
        public string? Id;
        public MessageType Type;
        public long? TimestampMs;
        public bool HasTokens;
        public TokenCounts Tokens;
        public string? Model;
        public bool IsCancelledText;
        public bool HasVisibleText;
        public bool HasFunctionCall;
        public GeminiToolCall[]? ToolCalls;
        public long? ThoughtsMs;

        public readonly GeminiMessage ToMessage()
        {
            long? latestCall = null, firstCall = null;
            foreach (var call in ToolCalls ?? [])
            {
                latestCall = Max(latestCall, call.TimestampMs);
                firstCall = Min(firstCall, call.TimestampMs);
            }

            return new GeminiMessage
            {
                Id = Id!,
                Kind = Type switch
                {
                    MessageType.User => GeminiMessageKind.User,
                    MessageType.Gemini => GeminiMessageKind.Gemini,
                    MessageType.Error => GeminiMessageKind.Error,
                    MessageType.Info when IsCancelledText => GeminiMessageKind.Cancelled,
                    _ => GeminiMessageKind.Other,
                },
                TimestampMs = TimestampMs,
                DetailMs = Max(latestCall, ThoughtsMs),
                FirstCallMs = firstCall,
                HasTokens = HasTokens,
                Tokens = Tokens,
                Model = Model,
                HasVisibleText = HasVisibleText,
                HasFunctionCall = HasFunctionCall,
                ToolCalls = ToolCalls,
            };
        }
    }

    private struct TopLevel
    {
        public bool Rewind;
        public bool HasPatch;
        public string[]? RemoveIds;
        public MessageFields Message;
        public GeminiMetadata? Metadata;
        public string? SessionId;
        public bool HasProjectHash;
        public bool IsSubagentKind;
        public long? StartMs;
        public long? LastUpdatedMs;
        public GeminiMessage[]? Messages;

        public readonly GeminiHeader ToHeader(string sessionId) =>
            new(sessionId, IsSubagentKind, StartMs, LastUpdatedMs, Messages);

        public readonly GeminiLine Classify()
        {
            var line = new GeminiLine { Status = LineStatus.Valid };
            if (Rewind)
            {
                line.Kind = GeminiRecordKind.Rewind;
            }
            else if (HasPatch)
            {
                line.Kind = GeminiRecordKind.Patch;
                line.RemoveIds = RemoveIds;
            }
            else if (Message.Id is not null)
            {
                line.Kind = GeminiRecordKind.Message;
                line.Message = Message.ToMessage();
            }
            else if (Metadata is not null)
            {
                line.Kind = GeminiRecordKind.Metadata;
                line.Metadata = Metadata;
            }
            else if (SessionId is { } sessionId && HasProjectHash)
            {
                line.Kind = GeminiRecordKind.Header;
                line.Header = ToHeader(sessionId);
            }

            return line;
        }
    }
}

using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Gemini;

/// <summary>Record classification, in Gemini's own loader order (METRICS 4.6).</summary>
internal enum GeminiRecordKind : byte
{
    Ignored,
    Rewind,
    Patch,
    Message,

    /// <summary>A <c>$set</c> metadata update.</summary>
    Metadata,
    Header,

    /// <summary>A whole legacy <c>.json</c> session file.</summary>
    Document,
}

internal enum GeminiMessageKind : byte
{
    Other,
    User,
    Gemini,
    Error,

    /// <summary><c>info</c> whose content is exactly the string <c>Request cancelled.</c></summary>
    Cancelled,
}

/// <summary>A tool call that is an object with a string <c>id</c>.</summary>
/// <param name="CompletesTask"><c>name == "complete_task"</c> and <c>status == "success"</c>.</param>
internal readonly record struct GeminiToolCall(string Id, long? TimestampMs, bool CompletesTask, bool IsCancelled);

/// <summary>One message record. Conversation text is never kept, only whether visible text exists.</summary>
internal struct GeminiMessage
{
    public string Id;
    public GeminiMessageKind Kind;
    public long? TimestampMs;

    /// <summary>Latest parseable timestamp of the tool calls and thoughts.</summary>
    public long? DetailMs;

    /// <summary>Earliest parseable tool-call timestamp.</summary>
    public long? FirstCallMs;
    public bool HasTokens;
    public TokenCounts Tokens;
    public string? Model;
    public bool HasVisibleText;
    public bool HasFunctionCall;
    public GeminiToolCall[]? ToolCalls;
}

/// <summary>A <c>gemini</c> message of a checkpoint that has tokens and a parseable timestamp.</summary>
internal readonly record struct GeminiCheckpointResponse(string Id, long TimestampMs, TokenCounts Tokens, string? Model);

/// <summary><c>$set.messages</c>: the ids of every message object, and the messages that stand for responses.</summary>
internal sealed record GeminiCheckpoint(string[] Ids, GeminiCheckpointResponse[] Responses);

/// <summary>A session header; a legacy object (a whole file, or written on one line) also carries its messages.</summary>
internal sealed record GeminiHeader(
    string SessionId, bool IsSubagentKind, long? StartMs, long? LastUpdatedMs, GeminiMessage[]? Messages);

/// <summary>The keys of a <c>$set</c> record that matter.</summary>
/// <param name="HasSummary"><c>summary</c> is a non-empty string.</param>
internal sealed record GeminiMetadata(
    long? LastUpdatedMs, bool IsSubagentKind, string? SessionId, GeminiCheckpoint? Checkpoint, bool HasSummary);

/// <summary>One extracted Gemini CLI record (a <c>.jsonl</c> line or a whole <c>.json</c> document).</summary>
internal struct GeminiLine
{
    public LineStatus Status;
    public GeminiRecordKind Kind;

    /// <summary>Set for <see cref="GeminiRecordKind.Message"/>.</summary>
    public GeminiMessage Message;

    /// <summary>Set for <see cref="GeminiRecordKind.Header"/> and <see cref="GeminiRecordKind.Document"/>.</summary>
    public GeminiHeader? Header;

    /// <summary>Set for <see cref="GeminiRecordKind.Metadata"/>.</summary>
    public GeminiMetadata? Metadata;

    /// <summary>The string elements of <c>$patch.removeIds</c>; null when it is not an array.</summary>
    public string[]? RemoveIds;
}

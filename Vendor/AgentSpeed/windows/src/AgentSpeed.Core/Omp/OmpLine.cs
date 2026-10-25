using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Omp;

/// <summary>Entry classification by <c>type</c> (METRICS 4.7).</summary>
internal enum OmpEntryKind : byte
{
    Other,

    /// <summary>The 256-byte title slot (16.3+), ignored entirely.</summary>
    Title,

    /// <summary>The session header.</summary>
    Session,
    Message,

    /// <summary>A side model call (18.1+).</summary>
    ModelUsage,

    /// <summary><c>custom</c> with <c>customType == "session_exit"</c>.</summary>
    SessionExit,
    ServiceTierChange,
}

internal enum OmpRole : byte
{
    Other,
    User,
    Developer,
    Assistant,
    ToolResult,
}

/// <summary><c>message.stopReason</c>; a missing or non-string value counts as <see cref="Aborted"/>.</summary>
internal enum OmpStop : byte
{
    Aborted,
    Error,
    Stop,
    ToolUse,
    Length,
    Other,
}

/// <summary>
/// The model call fields shared by assistant messages and <c>model_usage</c> entries. <see cref="Guarded"/> means
/// <c>model</c>, <c>provider</c> and <c>api</c> are strings and <c>usage</c> is an object (omp's own statistics guard).
/// </summary>
internal struct OmpCall
{
    public bool Guarded;
    public string? ServiceTier;
    public bool DisabledPriority;
    public string? Model;

    /// <summary>The <c>provider</c> string; null when it is empty (METRICS 3.2).</summary>
    public string? Provider;
    public TokenCounts Tokens;

    /// <summary>One of <c>input</c>, <c>output</c>, <c>cacheRead</c>, <c>cacheWrite</c> is above 0.</summary>
    public bool HasUsage;
}

/// <summary>One extracted omp entry. Conversation text is never kept.</summary>
internal struct OmpLine
{
    public LineStatus Status;
    public OmpEntryKind Kind;

    /// <summary>The entry <c>id</c> when it is a string.</summary>
    public string? Id;
    public string? ParentId;
    public bool HasParentId;
    public ExecutionModes? SelectedModes;

    /// <summary>The entry (or header) <c>timestamp</c>, ISO 8601.</summary>
    public long? TimestampMs;

    /// <summary>Header <c>cwd</c>.</summary>
    public string? Cwd;

    public OmpRole Role;

    /// <summary>Assistant message or <c>model_usage</c> entry.</summary>
    public OmpCall Call;

    /// <summary><c>message.timestamp</c> truncated, when it is a finite number above 0.</summary>
    public long? StartedMs;

    /// <summary><c>message.duration</c> truncated, when it is a finite number of at least 0.</summary>
    public long? DurationMs;

    /// <summary><c>message.completedAt</c> truncated, when it is a finite number above 0.</summary>
    public long? CompletedAtMs;

    public OmpStop Stop;

    /// <summary><c>message.stopDetails.type == "pause_turn"</c>.</summary>
    public bool PauseTurn;

    /// <summary>Distinct string ids of the <c>toolCall</c> content blocks.</summary>
    public string[]? ToolCallIds;

    /// <summary>Tool result <c>toolCallId</c> when it is a string.</summary>
    public string? ToolCallId;

    /// <summary>Tool result of <c>yield</c> whose <c>isError</c> is not <c>true</c>: a sub-agent's final yield.</summary>
    public bool IsFinalYield;
}

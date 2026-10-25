using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.WorkBuddy;

/// <summary>Line classification by <c>type</c> and <c>role</c> (METRICS 4.9).</summary>
internal enum WorkBuddyItem : byte
{
    /// <summary>Every other line: only <c>lastLineMs</c> and <c>cwd</c>.</summary>
    Other,

    /// <summary><c>message</c> with <c>role == "user"</c>.</summary>
    UserMessage,

    /// <summary><c>message</c> with <c>role == "assistant"</c>.</summary>
    AssistantMessage,
    FunctionCall,
    FunctionCallResult,
    Reasoning,

    /// <summary><c>model-usage</c>: usage written when the run ends.</summary>
    ModelUsage,
}

/// <summary>
/// One extracted WorkBuddy line. Only ids, flags, timestamps, the working directory, the model and the usage numbers are
/// kept; content, arguments and tool output are never read.
/// </summary>
internal struct WorkBuddyLine
{
    public LineStatus Status;
    public WorkBuddyItem Item;

    /// <summary><c>timestamp</c>: Unix ms (a finite number above 0, truncated) or an ISO 8601 string; null otherwise.</summary>
    public long? TimestampMs;

    /// <summary><c>cwd</c> when it is a string that is not blank.</summary>
    public string? Cwd;

    /// <summary>The line <c>id</c> when it is a non-empty string.</summary>
    public string? Id;

    /// <summary><c>callId</c> when it is a string.</summary>
    public string? CallId;

    /// <summary><c>status == "incomplete"</c>.</summary>
    public bool Incomplete;

    /// <summary><c>providerData.skipRun == true</c>: the CLI wrote the line itself and no request follows it.</summary>
    public bool SkipRun;

    /// <summary><c>providerData.isPartialAborted == true</c>: a draft saved on interruption.</summary>
    public bool PartialAborted;

    /// <summary><c>providerData.error</c> is an object.</summary>
    public bool HasError;

    /// <summary><c>providerData.agent == "compact"</c>.</summary>
    public bool Compaction;

    /// <summary><c>providerData.messageId</c> when it is a non-empty string: one per model call.</summary>
    public string? MessageId;

    /// <summary>The call's model without a <c>custom:</c> / <c>custom-local:</c> prefix; null when none is named.</summary>
    public string? Model;
    public string? RequestModelId;

    /// <summary><c>custom</c> for a model of the user's own provider (METRICS 3.2).</summary>
    public string? Provider;

    /// <summary><c>providerData.usage</c> or <c>providerData.rawUsage</c> is an object.</summary>
    public bool HasUsage;

    public TokenCounts Tokens;
}

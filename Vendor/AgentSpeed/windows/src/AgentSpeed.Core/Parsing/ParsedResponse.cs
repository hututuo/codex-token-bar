namespace AgentSpeed.Core.Parsing;

/// <summary>One response upsert produced by a parser (METRICS 4 and 4.3).</summary>
/// <param name="Final">False while only a streaming usage snapshot was seen (METRICS 3.3); Codex is always final.</param>
/// <param name="Provider">The API provider the agent says it used, only for pricing (METRICS 3.2, 9.2).</param>
/// <param name="Fast">The request ran in a provider's fast mode (METRICS 3.2).</param>
/// <param name="CostMicroUsd">Integer micro-USD (METRICS 9.3), set by pricing; null while unpriced or when the price is unknown.</param>
internal sealed record ParsedResponse(
    string Key,
    SourceKind Source,
    string AgentId,
    string? Model,
    long? StartMs,
    long EndMs,
    TokenCounts Tokens,
    bool Final = true,
    string? Provider = null,
    bool Fast = false,
    long? CostMicroUsd = null,
    long RequestCount = 1)
{
    public ExecutionModes Modes { get; init; } = ExecutionModes.Empty;

    public long Requests => Math.Clamp(RequestCount, 0, TokenCounts.MaxValue);
}

internal interface IResponseSink
{
    /// <param name="isCompletion">True for the first emission of a key, false for later updates.</param>
    void OnResponse(ParsedResponse response, bool isCompletion);
}

internal enum LineStatus : byte
{
    Valid,
    Malformed,
    Blank,
}

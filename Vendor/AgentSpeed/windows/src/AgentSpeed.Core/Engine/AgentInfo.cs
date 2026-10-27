namespace AgentSpeed.Core.Engine;

/// <summary>Agent state as seen by the engine; produced from a parser after each batch of lines.</summary>
/// <param name="ParentId">Resolved parent agent id (METRICS 6.7), whether or not the parent is listed.</param>
internal readonly record struct AgentInfo(
    string Id,
    SourceKind Source,
    string? Project,
    string? Model,
    bool IsSubagent,
    AgentPhase Phase,
    long? InFlightStartMs,
    long? LastLineMs,
    string? ParentId = null)
{
    public ExecutionModes Modes { get; init; } = ExecutionModes.Empty;
}

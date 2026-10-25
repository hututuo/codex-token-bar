using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.OpenCode;

/// <summary>The agent one OpenCode session stands for, after replaying its rows (METRICS 4.5).</summary>
internal sealed record OpenCodeAgentState(
    string Id,
    string SessionId,
    string? ParentSessionId,
    long CreatedMs,
    string? Project,
    string? Model,
    bool IsSubagent,
    AgentPhase Phase,
    long? InFlightStartMs,
    long? LastLineMs,
    long MalformedRows)
{
    public ExecutionModes Modes { get; init; } = ExecutionModes.Empty;
}

/// <summary>OpenCode rules of METRICS 4.5, shared by the live source and the daily history.</summary>
internal static class OpenCodeRules
{
    /// <summary>Assistant rows created this long before their session are copies made by a fork.</summary>
    public const long ForkToleranceMs = 2000;

    public const string AgentPrefix = "opencode:";

    public static string AgentId(string sessionId) => AgentPrefix + sessionId;

    public static bool IsForkCopy(in OpenCodeData data, in OpenCodeSessionInfo session) =>
        data.Created is { } created && created < session.CreatedMs - ForkToleranceMs;

    /// <summary>The response a row stands for before deduplication; null when the row is not (yet) a response.</summary>
    public static ParsedResponse? Response(OpenCodeRow row, in OpenCodeSessionInfo session)
    {
        if (row.Data is not { HasTokens: true } data)
        {
            return null;
        }

        long? startMs;
        long endMs;
        switch (row.Kind)
        {
            case OpenCodeRowKind.Assistant:
                // The stream end, not the completion: tool execution after the stream is not generation.
                if (IsForkCopy(in data, in session) || data.Streamed is not { } streamed)
                {
                    return null;
                }

                startMs = data.Created;
                endMs = streamed;
                break;
            case OpenCodeRowKind.Compaction:
                startMs = data.Created;
                endMs = data.Completed ?? row.TimeUpdated;
                break;
            default:
                return null;
        }

        return new ParsedResponse(row.Id, SourceKind.OpenCode, AgentId(session.Id), data.Model, startMs, endMs, data.Tokens, Provider: data.Provider)
        { Modes = ExecutionModeNative.OpenAiTier(data.ServiceTier, provider: data.Provider) };
    }

    /// <summary>Agent state after replaying a session's rows in <c>seq</c> order.</summary>
    /// <param name="model">The model known before these rows (rows of a quiet session may have been released).</param>
    public static OpenCodeAgentState Replay(in OpenCodeSessionInfo session, IEnumerable<OpenCodeRow> rows, string? model = null)
    {
        var phase = AgentPhase.Idle;
        long? inFlight = null;
        long? lastLine = null;
        long malformed = 0;
        var modes = ExecutionModes.Empty;
        foreach (var row in rows)
        {
            if (row.Data is not { } data)
            {
                malformed++;
                continue;
            }

            if (row.Kind == OpenCodeRowKind.Assistant)
            {
                if (IsForkCopy(in data, in session))
                {
                    continue;
                }

                model = data.Model ?? model;
                modes = ExecutionModeNative.OpenAiTier(data.ServiceTier, provider: data.Provider);
                if (data.Streamed is null)
                {
                    phase = AgentPhase.Generating;
                    inFlight = data.Created;
                }
                else
                {
                    phase = data.FinishedWithToolCalls ? AgentPhase.Tools : AgentPhase.Idle;
                    inFlight = null;
                }
            }
            else if (row.Kind == OpenCodeRowKind.Idle)
            {
                phase = AgentPhase.Idle;
                inFlight = null;
            }

            lastLine = lastLine is { } last ? Math.Max(last, row.TimeUpdated) : row.TimeUpdated;
        }

        var project = session.Directory is { } directory ? PathText.Basename(directory) : string.Empty;
        return new OpenCodeAgentState(
            AgentId(session.Id),
            session.Id,
            session.ParentId,
            session.CreatedMs,
            project.Length > 0 ? project : null,
            model,
            session.ParentId is not null,
            phase,
            inFlight,
            lastLine,
            malformed) { Modes = modes };
    }
}

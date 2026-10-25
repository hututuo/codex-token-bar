using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.WorkBuddy;

/// <summary>
/// WorkBuddy session state machine (METRICS 4.9), shared by both editions. No line records when a request started, so
/// a call starts at the latest input line before it (the user line, or the tool result that completed the step) and
/// ends at the line that carries its usage; the phase follows the input and output lines.
/// </summary>
internal sealed class WorkBuddyParser : TranscriptParser<WorkBuddyLine>
{
    private const string FallbackKeyPrefix = "workbuddy:";

    private readonly bool _pathIsSubagent;

    // Tool call id → the key of the model call that made it, while its result is outstanding.
    private readonly Dictionary<string, string> _openCalls = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ParsedResponse> _responses = new(StringComparer.Ordinal);
    private readonly List<string> _staleCalls = [];
    private long? _pendingStartMs;

    /// <param name="source"><see cref="SourceKind.WorkBuddy"/> or <see cref="SourceKind.WorkBuddyAi"/>, by the root.</param>
    /// <param name="root">The <c>projects</c> folder the file was found in: sub-agents are decided by the path below it.</param>
    public WorkBuddyParser(string agentId, IDeduper deduper, SourceKind source, string root)
        : base(agentId, deduper, Edition(source))
    {
        _pathIsSubagent = WorkBuddyDiscovery.IsSubagentPath(root, agentId);
        RestorePathState();
    }

    public override void Reset()
    {
        base.Reset();
        _openCalls.Clear();
        _responses.Clear();
        _pendingStartMs = null;
        RestorePathState();
    }

    public override void Apply(in WorkBuddyLine line, IResponseSink sink)
    {
        if (line.Status == LineStatus.Malformed)
        {
            CountMalformed();
            return;
        }

        if (line.Status != LineStatus.Valid || line.TimestampMs is not { } ts)
        {
            return;
        }

        Touch(ts);
        SetProjectFromCwd(line.Cwd);
        switch (line.Item)
        {
            case WorkBuddyItem.UserMessage when !line.SkipRun:
                Modes = ExecutionModes.Empty;
                _openCalls.Clear();
                _pendingStartMs = ts;
                SetPhase(AgentPhase.Generating, ts, ts);
                break;
            case WorkBuddyItem.FunctionCallResult:
                ApplyToolResult(in line, ts);
                break;
            case WorkBuddyItem.AssistantMessage when line.SkipRun:
                // A notice the CLI wrote: an interrupted or failed request ends the turn, hook output changes nothing.
                if (line.Incomplete || line.HasError)
                {
                    Idle(ts);
                }

                break;
            case WorkBuddyItem.AssistantMessage or WorkBuddyItem.FunctionCall
                or WorkBuddyItem.Reasoning or WorkBuddyItem.ModelUsage:
                ApplyOutput(in line, ts, sink);
                break;
        }
    }

    protected override WorkBuddyLine Extract(ReadOnlySpan<byte> line) => WorkBuddyLineReader.Read(line);

    private static SourceKind Edition(SourceKind source) =>
        WorkBuddyPaths.IsWorkBuddy(source) ? source : throw new ArgumentOutOfRangeException(nameof(source), source, null);

    private void ApplyToolResult(in WorkBuddyLine line, long ts)
    {
        if (line.CallId is { } callId)
        {
            _openCalls.Remove(callId);
        }

        if (line.SkipRun)
        {
            // A rejected or cancelled tool: no request follows once every call of the step is answered.
            if (_openCalls.Count == 0)
            {
                Idle(ts);
            }

            return;
        }

        _pendingStartMs = ts;
        if (_openCalls.Count == 0)
        {
            SetPhase(AgentPhase.Generating, ts, ts);
        }
    }

    private void ApplyOutput(in WorkBuddyLine line, long ts, IResponseSink sink)
    {
        if (line.PartialAborted)
        {
            return;
        }

        var key = line.MessageId ?? (line.Id is { } id ? FallbackKeyPrefix + id : null);
        if (key is null || (Deduper.TryGetOwner(key, out var owner) && !string.Equals(owner, AgentId, StringComparison.Ordinal)))
        {
            return;
        }

        if (line.HasUsage && (line.Tokens.Input > 0 || line.Tokens.Output > 0))
        {
            Upsert(key, in line, ts, sink);
        }

        if (line.Item == WorkBuddyItem.ModelUsage)
        {
            Idle(ts);
            return;
        }

        DropCallsOfOtherKeys(key);
        if (line.Item == WorkBuddyItem.FunctionCall)
        {
            if (line.CallId is { } callId)
            {
                _openCalls[callId] = key;
            }

            SetPhase(AgentPhase.Tools, ts, null);
        }
        else if (line.Item == WorkBuddyItem.AssistantMessage && _openCalls.Count == 0)
        {
            if (line.Compaction)
            {
                // The request the compaction made room for follows.
                _pendingStartMs = ts;
                SetPhase(AgentPhase.Generating, ts, ts);
            }
            else
            {
                SetPhase(AgentPhase.Idle, ts, null);
            }
        }
    }

    // A known key in this file merges like a repeated Claude line (METRICS 4.4): later end, every field the maximum.
    private void Upsert(string key, in WorkBuddyLine line, long ts, IResponseSink sink)
    {
        ParsedResponse response;
        bool isCompletion;
        if (_responses.TryGetValue(key, out var previous))
        {
            response = previous with
            {
                EndMs = Math.Max(previous.EndMs, ts),
                Tokens = TokenCounts.Max(previous.Tokens, line.Tokens),
                Model = line.Model ?? previous.Model,
                Provider = line.Provider ?? previous.Provider,
                Modes = previous.Modes.Merge(ExecutionModeNative.Routing(line.RequestModelId)),
            };
            isCompletion = false;
        }
        else
        {
            // A key this file claimed before a reset is replayed as an update.
            isCompletion = Deduper.TryClaim(key, AgentId, out _);
            response = new ParsedResponse(
                key, Source, AgentId, line.Model, _pendingStartMs, ts, line.Tokens, Final: true, Provider: line.Provider)
            { Modes = ExecutionModeNative.Routing(line.RequestModelId) };
            _pendingStartMs = null;
        }

        SetModel(response.Model);
        Modes = response.Modes;
        if (previous is not null && previous == response)
        {
            return;
        }

        _responses[key] = response;
        sink.OnResponse(response, isCompletion);
    }

    private void DropCallsOfOtherKeys(string key)
    {
        foreach (var (callId, owner) in _openCalls)
        {
            if (!string.Equals(owner, key, StringComparison.Ordinal))
            {
                _staleCalls.Add(callId);
            }
        }

        foreach (var callId in _staleCalls)
        {
            _openCalls.Remove(callId);
        }

        _staleCalls.Clear();
    }

    private void Idle(long ts)
    {
        _openCalls.Clear();
        _pendingStartMs = null;
        SetPhase(AgentPhase.Idle, ts, null);
    }

    private void RestorePathState()
    {
        SetSource(InitialSource);
        SetSubagent(_pathIsSubagent);
    }
}

namespace AgentSpeed.Core.Parsing;

/// <summary>Claude Code / Claude Desktop transcript state machine (METRICS 4.1).</summary>
internal sealed class ClaudeParser : TranscriptParser<ClaudeLine>
{
    private const int MergeCacheCapacity = 64;

    private readonly bool _pathIsSubagent;
    private readonly Dictionary<string, ParsedResponse> _recent = new(StringComparer.Ordinal);
    private readonly Queue<string> _recentOrder = new();
    private long? _pendingStartMs;
    private bool _preciseStart;

    public ClaudeParser(string agentId, IDeduper deduper)
        : base(agentId, deduper, SourceKind.ClaudeCode)
    {
        _pathIsSubagent = PathText.HasDirectoryComponent(agentId, "subagents");
        SetSubagent(_pathIsSubagent);
    }

    public override void Reset()
    {
        base.Reset();
        _recent.Clear();
        _recentOrder.Clear();
        _pendingStartMs = null;
        _preciseStart = false;
        SetSubagent(_pathIsSubagent);
    }

    public override void Apply(in ClaudeLine line, IResponseSink sink)
    {
        if (line.Status == LineStatus.Malformed)
        {
            CountMalformed();
            return;
        }

        if (line.Status != LineStatus.Valid || !line.HasTimestamp)
        {
            return;
        }

        var ts = line.TimestampMs;
        Touch(ts);
        if (!SourceDecided && line.Entrypoint != EntrypointKind.None)
        {
            SetSource(line.Entrypoint == EntrypointKind.Desktop ? SourceKind.ClaudeDesktop : SourceKind.ClaudeCode);
        }

        SetProjectFromCwd(line.Cwd);
        if (line.IsSidechain)
        {
            SetSubagent(true);
        }

        switch (line.Kind)
        {
            case ClaudeLineKind.ApiRequest:
                Modes = ExecutionModes.Empty;
                _pendingStartMs = ts;
                _preciseStart = true;
                SetPhase(AgentPhase.Generating, ts, ts);
                break;
            case ClaudeLineKind.User when line.IsInterrupt:
                _pendingStartMs = null;
                _preciseStart = false;
                SetPhase(AgentPhase.Idle, ts, null);
                break;
            case ClaudeLineKind.User:
                Modes = ExecutionModes.Empty;
                if (!_preciseStart)
                {
                    _pendingStartMs = ts;
                }

                SetPhase(AgentPhase.Generating, ts, _pendingStartMs);
                break;
            case ClaudeLineKind.Assistant:
                ApplyAssistant(in line, ts, sink);
                break;
        }
    }

    protected override ClaudeLine Extract(ReadOnlySpan<byte> line) => ClaudeLineReader.Read(line);

    private void ApplyAssistant(in ClaudeLine line, long ts, IResponseSink sink)
    {
        if (string.Equals(line.Model, "<synthetic>", StringComparison.Ordinal) || line.Key is not { } key)
        {
            return;
        }

        ParsedResponse response;
        bool isCompletion;
        if (Deduper.TryClaim(key, AgentId, out var owner))
        {
            response = Create(key, in line, ts);
            isCompletion = true;
        }
        else if (!string.Equals(owner, AgentId, StringComparison.Ordinal))
        {
            return;
        }
        else if (_recent.TryGetValue(key, out var previous))
        {
            response = previous with
            {
                EndMs = Math.Max(previous.EndMs, ts),
                Tokens = TokenCounts.Max(previous.Tokens, line.Usage),
                Model = line.Model ?? previous.Model,
                Final = previous.Final || line.StopReason != StopReasonKind.Missing,
                Fast = previous.Fast || line.Fast,
                Modes = previous.Modes.Merge(ExecutionModeNative.ClaudeSpeed(line.Speed)),
            };
            isCompletion = false;
        }
        else
        {
            // Seen by this file before a reset or beyond the merge cache: replay it as an update.
            response = Create(key, in line, ts);
            isCompletion = false;
        }

        Remember(response);
        SetModel(response.Model);
        Modes = response.Modes;
        sink.OnResponse(response, isCompletion);

        switch (line.StopReason)
        {
            case StopReasonKind.ToolUse:
            case StopReasonKind.Missing when line.HasToolUse:
                SetPhase(AgentPhase.Tools, ts, null);
                break;
            case StopReasonKind.Missing or StopReasonKind.PauseTurn:
                SetPhase(AgentPhase.Generating, ts, response.StartMs ?? ts);
                break;
            default:
                SetPhase(AgentPhase.Idle, ts, null);
                break;
        }
    }

    private ParsedResponse Create(string key, in ClaudeLine line, long ts)
    {
        var response = new ParsedResponse(
            key, Source, AgentId, line.Model, _pendingStartMs, ts, line.Usage, line.StopReason != StopReasonKind.Missing,
            Fast: line.Fast) { Modes = ExecutionModeNative.ClaudeSpeed(line.Speed) };
        _pendingStartMs = null;
        _preciseStart = false;
        return response;
    }

    private void Remember(ParsedResponse response)
    {
        if (!_recent.ContainsKey(response.Key))
        {
            if (_recentOrder.Count >= MergeCacheCapacity && _recentOrder.TryDequeue(out var oldest))
            {
                _recent.Remove(oldest);
            }

            _recentOrder.Enqueue(response.Key);
        }

        _recent[response.Key] = response;
    }
}

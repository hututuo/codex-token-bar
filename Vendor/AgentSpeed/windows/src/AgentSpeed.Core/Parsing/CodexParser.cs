using System.Globalization;

namespace AgentSpeed.Core.Parsing;

/// <summary>Codex rollout state machine (METRICS 4.2) including the copied-history rule (3.5).</summary>
internal sealed class CodexParser : TranscriptParser<CodexLine>
{
    private const long CopiedHistoryToleranceMs = 2000;
    private const string RootAgentPath = "/root";

    private readonly bool _pathIsSubagent;
    private long? _fileCreatedMs;
    private string _myAgentPath = RootAgentPath;
    private string? _metaThreadId;
    private string? _parentThreadId;

    /// <summary><c>model_provider</c> of the first <c>session_meta</c> (METRICS 3.2).</summary>
    private string? _provider;
    private long? _pendingStartMs;
    private bool _streaming;
    private bool _sawModernUsage;
    private CodexUsage? _previousLegacyTotals;

    public CodexParser(string agentId, IDeduper deduper)
        : base(agentId, deduper, SourceKind.Codex)
    {
        _pathIsSubagent = PathText.HasDirectoryComponent(agentId, "subagents");
        SetSubagent(_pathIsSubagent);
    }

    /// <summary>Time of the first <c>session_meta</c>, i.e. when the rollout was created.</summary>
    public long? CreatedMs => _fileCreatedMs;

    /// <summary><c>payload.id</c> of the first <c>session_meta</c>.</summary>
    public string? MetaThreadId => _metaThreadId;

    /// <summary>The spawning thread named by the first <c>session_meta</c> (METRICS 6.7).</summary>
    public string? ParentThreadId => _parentThreadId;

    public override void Reset()
    {
        base.Reset();
        _fileCreatedMs = null;
        _myAgentPath = RootAgentPath;
        _metaThreadId = null;
        _parentThreadId = null;
        _provider = null;
        _pendingStartMs = null;
        _streaming = false;
        _sawModernUsage = false;
        _previousLegacyTotals = null;
        SetSubagent(_pathIsSubagent);
    }

    public override void Apply(in CodexLine line, IResponseSink sink)
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
        if (line.Kind == CodexLineKind.SessionMeta)
        {
            ApplySessionMeta(in line, ts);
            return;
        }

        if (_fileCreatedMs is { } created && ts < created - CopiedHistoryToleranceMs)
        {
            return;
        }

        Touch(ts);
        switch (line.Kind)
        {
            case CodexLineKind.TurnContext:
                SetModel(line.Model);
                SetProjectFromCwd(line.Cwd);
                break;
            case CodexLineKind.ResponseItem:
                ApplyResponseItem(in line, ts);
                break;
            case CodexLineKind.EventMsg:
                ApplyEvent(in line, ts, sink);
                break;
            case CodexLineKind.TokenUsageRecord:
                ApplyModernUsage(in line, ts, sink);
                break;
        }
    }

    protected override CodexLine Extract(ReadOnlySpan<byte> line) => CodexLineReader.Read(line);

    // Only the first session_meta applies; sub-agents copy their parent's afterwards.
    private void ApplySessionMeta(in CodexLine line, long ts)
    {
        if (_fileCreatedMs is not null)
        {
            return;
        }

        _fileCreatedMs = ts;
        Touch(ts);
        SetProjectFromCwd(line.Cwd);
        _myAgentPath = line.AgentPath ?? RootAgentPath;
        _metaThreadId = line.Id ?? _metaThreadId;
        _parentThreadId = line.ParentThreadId ?? line.SpawnParentThreadId;
        _provider = line.ModelProvider;
        MarkChanged();
        SetSubagent(IsSubagent || line.ThreadSourceIsSubagent || line.SourceHasSubagent);
    }

    private void ApplyResponseItem(in CodexLine line, long ts)
    {
        switch (line.PayloadKind)
        {
            case CodexPayloadKind.Reasoning or CodexPayloadKind.CallSuffix:
            case CodexPayloadKind.Message when line.Role == CodexRole.Assistant:
                _streaming = true;
                SetPhase(AgentPhase.Generating, ts, _pendingStartMs ?? ts);
                break;
            case CodexPayloadKind.OutputSuffix:
            case CodexPayloadKind.Message when line.Role is CodexRole.User or CodexRole.Developer or CodexRole.System:
                OnInput(ts);
                break;
            case CodexPayloadKind.AgentMessage
                when string.Equals(line.Recipient, _myAgentPath, StringComparison.Ordinal):
                if (!_streaming)
                {
                    _pendingStartMs = ts;
                }

                break;
        }
    }

    private void OnInput(long ts)
    {
        if (_streaming)
        {
            return;
        }

        _pendingStartMs = ts;
        SetPhase(AgentPhase.Generating, ts, _pendingStartMs);
    }

    private void ApplyEvent(in CodexLine line, long ts, IResponseSink sink)
    {
        switch (line.PayloadKind)
        {
            case CodexPayloadKind.TaskStarted or CodexPayloadKind.UserMessage:
                OnInput(ts);
                break;
            case CodexPayloadKind.TokenCount when _sawModernUsage && _streaming:
                AfterUsage(ts);
                break;
            case CodexPayloadKind.TokenCount:
                ApplyLegacyUsage(in line, ts, sink);
                break;
            case CodexPayloadKind.TaskComplete or CodexPayloadKind.TurnAborted:
                _pendingStartMs = null;
                _streaming = false;
                SetPhase(AgentPhase.Idle, ts, null);
                break;
        }
    }

    private string ThreadId => _metaThreadId ?? AgentId;

    private void ApplyModernUsage(in CodexLine line, long ts, IResponseSink sink)
    {
        _sawModernUsage = true;
        var key = line.ResponseId
            ?? string.Create(CultureInfo.InvariantCulture, $"codex:{line.ThreadId ?? ThreadId}:{ts}");
        if (!Deduper.TryClaim(key, AgentId, out _))
        {
            return;
        }

        Emit(key, line.Usage, ts, sink);
    }

    private void ApplyLegacyUsage(in CodexLine line, long ts, IResponseSink sink)
    {
        if (_sawModernUsage || line.Info != CodexInfoKind.Object || !line.HasTotal)
        {
            return;
        }

        var total = line.Total;
        TokenCounts tokens;
        if (_previousLegacyTotals is not { } previous)
        {
            tokens = line.HasLast ? line.Last.Tokens : total.Tokens;
        }
        else
        {
            var delta = total.Minus(previous);
            if (delta.TotalTokens == 0)
            {
                return;
            }

            tokens = delta.AnyNegative ? line.Last.Tokens : delta.Tokens;
        }

        _previousLegacyTotals = total;
        var key = string.Create(
            CultureInfo.InvariantCulture, $"codex-legacy:{ThreadId}:{total.TotalTokens}");
        if (!Deduper.TryClaim(key, AgentId, out _))
        {
            return;
        }

        Emit(key, tokens, ts, sink);
    }

    private void Emit(string key, TokenCounts tokens, long ts, IResponseSink sink)
    {
        sink.OnResponse(new ParsedResponse(key, SourceKind.Codex, AgentId, Model, _pendingStartMs, ts, tokens, Provider: _provider), true);
        AfterUsage(ts);
    }

    private void AfterUsage(long ts)
    {
        _pendingStartMs = ts;
        _streaming = false;
        SetPhase(AgentPhase.Tools, ts, null);
    }
}

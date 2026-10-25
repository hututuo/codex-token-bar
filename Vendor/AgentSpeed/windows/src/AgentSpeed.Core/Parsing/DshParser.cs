namespace AgentSpeed.Core.Parsing;

/// <summary>DeepSeek Harness (dsh) session state machine (METRICS 4.3), including fork-inherited history.</summary>
internal sealed class DshParser : TranscriptParser<DshLine>
{
    private const long InheritedHistoryToleranceMs = 2000;

    private string? _sessionId;
    private long? _createdMs;
    private string? _parentSession;
    private long? _pendingStartMs;

    /// <summary>The latest <c>request/header</c> <c>config.provider</c> (METRICS 3.2).</summary>
    private string? _provider;

    public DshParser(string agentId, IDeduper deduper)
        : base(agentId, deduper, SourceKind.DeepSeek)
    {
    }

    /// <summary><c>id</c> of the first header.</summary>
    public string? SessionId => _sessionId;

    /// <summary><c>createdAt</c> of the first header (0 when it has none); null before any header.</summary>
    public long? CreatedMs => _createdMs;

    /// <summary>The session that spawned this one, from the first header (METRICS 6.7).</summary>
    public string? ParentSession => _parentSession;

    public override void Reset()
    {
        base.Reset();
        _sessionId = null;
        _createdMs = null;
        _parentSession = null;
        _pendingStartMs = null;
        _provider = null;
    }

    public override void Apply(in DshLine line, IResponseSink sink)
    {
        if (line.Status == LineStatus.Malformed)
        {
            CountMalformed();
            return;
        }

        if (line.Status != LineStatus.Valid)
        {
            return;
        }

        if (line.Events is { } events)
        {
            foreach (ref readonly var item in events.AsSpan())
            {
                ApplyEvent(in item, sink);
            }
        }
        else
        {
            ApplyEvent(in line.Event, sink);
        }
    }

    protected override DshLine Extract(ReadOnlySpan<byte> line) => DshLineReader.Read(line);

    private void ApplyEvent(in DshEvent item, IResponseSink sink)
    {
        if (item.Kind == DshEventKind.Header)
        {
            ApplyHeader(in item);
            return;
        }

        if (!item.HasTime)
        {
            return;
        }

        var ts = item.TimeMs;
        if (_createdMs is { } created && ts < created - InheritedHistoryToleranceMs)
        {
            return;
        }

        Touch(ts);
        switch (item.Kind)
        {
            case DshEventKind.RequestHeader:
                SetModel(item.ConfigModel);
                _provider = item.ConfigProvider ?? _provider;
                break;
            case DshEventKind.StepStart:
                _pendingStartMs = ts;
                SetPhase(AgentPhase.Generating, ts, ts);
                break;
            case DshEventKind.TurnEnd:
                _pendingStartMs = null;
                SetPhase(AgentPhase.Idle, ts, null);
                break;
            case DshEventKind.AssistantMessage:
                ApplyAssistant(in item, ts, sink);
                break;
        }
    }

    // Only the first header applies.
    private void ApplyHeader(in DshEvent header)
    {
        if (_createdMs is not null)
        {
            return;
        }

        _createdMs = header.CreatedMs;
        _sessionId = header.Id ?? _sessionId;
        _parentSession = header.ParentSession;
        SetProjectFromCwd(header.Cwd);
        MarkChanged();
        SetSubagent(IsSubagent || header.OriginSubagent || header.Delegated || header.ParentSession is not null);
    }

    private void ApplyAssistant(in DshEvent item, long ts, IResponseSink sink)
    {
        // Missing parts are spelled like the reference implementation so keys agree across platforms.
        var key = item.MessageId ?? $"dsh:{_sessionId ?? "None"}:{item.Seq ?? "None"}";
        if (!Deduper.TryClaim(key, AgentId, out _))
        {
            return;
        }

        if (item.HasUsage)
        {
            var model = item.SourceModel ?? Model;
            sink.OnResponse(
                new ParsedResponse(key, SourceKind.DeepSeek, AgentId, model, _pendingStartMs, ts, item.Usage, Provider: item.SourceProvider ?? _provider),
                true);
            SetModel(model);
        }

        _pendingStartMs = null;
        SetPhase(item.HasToolCall ? AgentPhase.Tools : AgentPhase.Idle, ts, null);
    }
}

using AgentSpeed.Core.Engine;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.GrokBuild;

internal sealed class GrokParser : TranscriptParser<GrokLine>
{
    private readonly Dictionary<string, ParsedResponse> _responses = new(StringComparer.Ordinal);
    private readonly string _sessionFolder;
    private bool _metadataSeen;
    private bool _suppressUsage;
    private readonly Queue<GrokLine> _pending = new();
    public int PendingUsageCount => _pending.Count;
    public bool PendingOverflow { get; private set; }

    public GrokParser(string agentId, IDeduper deduper) : base(agentId, deduper, SourceKind.GrokBuild)
    {
        _sessionFolder = Path.GetDirectoryName(agentId) ?? string.Empty;
        SessionId = Path.GetFileName(_sessionFolder);
        ApplyMetadata(GrokMetadata.Read(_sessionFolder));
    }

    public string SessionId { get; private set; }
    public string? ParentSessionId { get; private set; }
    public long? CreatedMs { get; private set; }
    public string? ParentPath { get; private set; }

    public override void Reset()
    {
        base.Reset();
        _responses.Clear();
        _metadataSeen = false;
        _suppressUsage = false;
        ParentSessionId = null;
        ParentPath = null;
        CreatedMs = null;
        _pending.Clear();
        PendingOverflow = false;
        ApplyMetadata(GrokMetadata.Read(_sessionFolder));
    }

    public override ILineBatch NewBatch() => new GrokBatch(this, GrokMetadata.Read(_sessionFolder));

    internal void ApplyBatch(GrokMetadata? metadata, List<GrokLine> lines, int malformed, IResponseSink sink)
    {
        for (var i = 0; i < malformed; i++) CountMalformed();
        ApplyMetadata(metadata);
        if (_metadataSeen)
        {
            while (_pending.TryDequeue(out var pending))
            {
                if (pending.TimeMs is { } time) EmitUsage(pending, time, sink, updateModel: false);
            }
        }

        foreach (var line in lines) Apply(line, sink);
    }

    protected override GrokLine Extract(ReadOnlySpan<byte> line) => GrokLine.Read(line);

    public override void Apply(in GrokLine line, IResponseSink sink)
    {
        if (line.Status == LineStatus.Malformed)
        {
            CountMalformed();
            return;
        }

        if (line.Status != LineStatus.Valid || line.TimeMs is not { } time)
        {
            return;
        }

        SetModel(line.Model);
        Touch(time);
        switch (line.Type)
        {
            case "user_message_chunk":
            case "agent_message_chunk":
            case "agent_thought_chunk":
                SetPhase(AgentPhase.Generating, time, InFlightStartMs ?? time);
                break;
            case "tool_call":
            case "tool_call_update":
                SetPhase(line.ToolStatus is "completed" or "failed" ? AgentPhase.Generating : AgentPhase.Tools, time, null);
                break;
            case "turn_completed":
                if (!_metadataSeen && line.Usage is { Count: > 0 })
                {
                    foreach (var bucket in line.Usage)
                    {
                        if (_pending.Count >= 256)
                        {
                            _pending.Dequeue();
                            PendingOverflow = true;
                        }

                        var pending = line;
                        pending.Usage = [bucket];
                        _pending.Enqueue(pending);
                    }
                    MarkChanged();
                    SetPhase(AgentPhase.Idle, time, null);
                    break;
                }

                EmitUsage(line, time, sink);

                SetPhase(AgentPhase.Idle, time, null);
                break;
        }
    }

    private void EmitUsage(in GrokLine line, long time, IResponseSink sink, bool updateModel = true)
    {
        if (_suppressUsage) return;
        var prompt = line.PromptId ?? string.Create(System.Globalization.CultureInfo.InvariantCulture,
            $"{line.SessionId ?? SessionId}:{time}");
        foreach (var bucket in line.Usage ?? [])
        {
            var model = bucket.Model ?? Model;
            var key = "grok:" + prompt + ":" + (model ?? "unknown");
            long? start = bucket.DurationMs is > 0 and <= SpeedMath.MaxIntervalMs && bucket.DurationMs <= time
                ? time - bucket.DurationMs : null;
            var response = new ParsedResponse(key, SourceKind.GrokBuild, AgentId, model, start, time, bucket.Tokens,
                RequestCount: bucket.Requests);
            var completion = Deduper.TryClaim(key, AgentId, out var owner);
            if ((completion || string.Equals(owner, AgentId, StringComparison.Ordinal))
                && (!_responses.TryGetValue(key, out var previous) || previous != response))
            {
                _responses[key] = response;
                sink.OnResponse(response, completion);
            }

            if (updateModel) SetModel(model);
        }
    }

    private void ApplyMetadata(GrokMetadata? metadata)
    {
        SetSource(SourceKind.GrokBuild);
        if (metadata is null) return;
        if (!_metadataSeen) MarkChanged();
        SessionId = metadata.Id ?? SessionId;
        SetProjectFromCwd(metadata.Cwd);
        SetModel(metadata.Model);
        ParentSessionId = metadata.Parent;
        CreatedMs = metadata.CreatedMs;
        SetSubagent(ParentSessionId is { Length: > 0 } && (metadata.Kind is "subagent" or "subagent_fork"));
        _suppressUsage = IsSubagent && ParentSessionId is { Length: > 0 };
        if (ParentSessionId is { Length: <= 256 } parent && parent is not "." and not ".." && parent.IndexOfAny(['/', '\\', ':']) < 0
            && Path.GetDirectoryName(_sessionFolder) is { } workspace)
        {
            ParentPath = Path.Combine(workspace, parent, "updates.jsonl");
        }
        else
        {
            ParentPath = null;
        }

        _metadataSeen = true;
    }
}

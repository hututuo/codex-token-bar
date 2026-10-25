using System.Text.Json;
using AgentSpeed.Core.Harnesses;
using AgentSpeed.Core.Parsing;
using static AgentSpeed.Core.Harnesses.HarnessJson;

namespace AgentSpeed.Core.Kimi;

internal sealed class KimiParser : TranscriptParser<KimiLine>
{
    private readonly Dictionary<string, ParsedResponse> _responses = new(StringComparer.Ordinal);
    private readonly string _localAgent;
    private long? _requestStart;
    private string? _requestId;
    private string? _provider;

    public KimiParser(string agentId, IDeduper deduper) : base(agentId, deduper, SourceKind.Kimi)
    {
        var folder = Path.GetDirectoryName(agentId) ?? string.Empty;
        _localAgent = Path.GetFileName(folder);
        SessionFolder = Path.GetDirectoryName(Path.GetDirectoryName(folder)) ?? string.Empty;
        RestoreMetadata();
    }

    public string SessionFolder { get; }
    public long? CreatedMs { get; private set; }
    public string? ParentPath { get; private set; }

    public override void Reset()
    {
        base.Reset();
        _responses.Clear();
        _requestStart = null;
        _requestId = null;
        _provider = null;
        RestoreMetadata();
    }

    protected override KimiLine Extract(ReadOnlySpan<byte> line) => KimiLine.Read(line);

    public override void Apply(in KimiLine line, IResponseSink sink)
    {
        if (line.Status == LineStatus.Malformed)
        {
            CountMalformed();
            return;
        }

        if (line.Status != LineStatus.Valid || (line.Agent is { } agent && agent != _localAgent))
        {
            return;
        }

        SetProjectFromCwd(line.Cwd);
        SetModel(line.Model);
        _provider = line.Provider ?? _provider;
        if (line.TimeMs is not { } time)
        {
            return;
        }

        Touch(time);
        switch (line.Type)
        {
            case "llm.request":
                Modes = ExecutionModeNative.KimiModel(Model);
                _requestStart = time;
                _requestId = line.ResponseId;
                SetPhase(AgentPhase.Generating, time, time);
                break;
            case "step.begin":
            case "turn.step.started":
                _requestStart ??= time;
                SetPhase(AgentPhase.Generating, time, _requestStart);
                break;
            case "turn.prompt":
            case "turn.started":
                Modes = ExecutionModeNative.KimiModel(Model);
                SetPhase(AgentPhase.Generating, time, time);
                break;
            case "step.end":
                Complete(line, time, sink);
                break;
            case "context.append_message":
            case "agent.message.appended":
            case "human.agent.message.appended":
                if (line.Role == "assistant")
                {
                    Complete(line, time, sink);
                }
                else if (line.Role == "user")
                {
                    SetPhase(AgentPhase.Generating, time, time);
                }
                else if (line.Role is "tool" or "tool_result")
                {
                    SetPhase(AgentPhase.Generating, time, null);
                }

                break;
            case "tool.call":
                SetPhase(AgentPhase.Tools, time, null);
                break;
            case "tool.result":
                SetPhase(AgentPhase.Generating, time, null);
                break;
            case "turn.ended":
            case "turn.cancel":
                _requestStart = null;
                SetPhase(AgentPhase.Idle, time, null);
                break;
        }
    }

    private void Complete(in KimiLine line, long time, IResponseSink sink)
    {
        if (line.Partial)
        {
            SetPhase(AgentPhase.Generating, time, _requestStart);
            return;
        }

        if (line.Usage is { } usage)
        {
            var id = line.ResponseId ?? (line.Type == "step.end" ? _requestId : null) ?? string.Create(System.Globalization.CultureInfo.InvariantCulture,
                $"{Path.GetFileName(SessionFolder)}:{_localAgent}:{time}");
            _requestId = id;
            var key = "kimi:" + id;
            var duration = line.FirstTokenMs is { } first && line.StreamMs is { } stream && first <= long.MaxValue - stream
                ? first + stream : line.DurationMs;
            _responses.TryGetValue(key, out var timed);
            var end = timed?.EndMs ?? time;
            var start = timed?.StartMs ?? _requestStart;
            start ??= duration is >= 0 && duration <= end ? end - duration : null;
            start = ValidTimestamp(start);

            var response = new ParsedResponse(key, SourceKind.Kimi, AgentId, Model, start, end, usage, Provider: _provider)
            { Modes = ExecutionModeNative.KimiModel(Model) };
            Modes = response.Modes;
            var completion = Deduper.TryClaim(key, AgentId, out var owner);
            if ((completion || string.Equals(owner, AgentId, StringComparison.Ordinal))
                && (!_responses.TryGetValue(key, out var previous) || previous != response))
            {
                _responses[key] = response;
                sink.OnResponse(response, completion);
            }
        }

        _requestStart = null;
        SetPhase(line.ToolCalls ? AgentPhase.Tools : AgentPhase.Idle, time, null);
    }

    private void RestoreMetadata()
    {
        SetSource(SourceKind.Kimi);
        SetSubagent(_localAgent != "main");
        ParentPath = IsSubagent ? Path.Combine(SessionFolder, "agents", "main", "wire.jsonl") : null;
        var state = Path.Combine(SessionFolder, "state.json");
        try
        {
            using var document = HarnessJson.ReadMetadata(state, 512 * 1024);
            if (document is null) return;
            var root = document.RootElement;
            SetProjectFromCwd(String(root, "cwd"));
            CreatedMs = Timestamp(Get(root, "createdAt"));
            var metadata = Get(Get(root, "agents"), _localAgent);
            SetSubagent(String(metadata, "type") == "sub" || _localAgent != "main");
            if (String(metadata, "parentAgentId") is { } parent && parent.IndexOfAny(['/', '\\', ':']) < 0 && !parent.Any(char.IsControl) && parent is not "." and not "..")
            {
                ParentPath = Path.Combine(SessionFolder, "agents", parent, "wire.jsonl");
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
        }
    }
}

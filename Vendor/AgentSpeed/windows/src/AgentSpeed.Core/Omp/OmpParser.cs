using System.Globalization;
using AgentSpeed.Core.IO;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Omp;

/// <summary>
/// omp session state machine (METRICS 4.7). Every assistant message is written once, after its stream ended, with its
/// own request start (<c>message.timestamp</c>) and duration; in-flight state is inferred from neighbouring entries.
/// </summary>
internal sealed class OmpParser : TranscriptParser<OmpLine>
{
    /// <summary>Entries this much older than the header were copied from another session (forks, imports, moves).</summary>
    public const long CopiedHistoryMs = 2000;

    private const int HeaderProbeLines = 2;

    private readonly HashSet<string> _pendingToolCalls = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ParsedResponse> _responses = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ExecutionModes> _modeBranches = new(StringComparer.Ordinal);
    private ExecutionModes _branchModes = ExecutionModes.Empty;
    private bool _headerSeen;
    private bool _headerProbed;

    /// <param name="root">The <c>sessions</c> root the file was found in: files three or more levels below it are sub-agents.</param>
    public OmpParser(string agentId, IDeduper deduper, string root)
        : base(agentId, deduper, SourceKind.Omp)
    {
        PathIsSubagent = OmpDiscovery.DepthBelow(root, agentId) >= 3;
        RestorePathState();
    }

    /// <summary>The file lives inside a session's artifacts folder (task sub-agents, advisors, seance consults).</summary>
    public bool PathIsSubagent { get; }

    /// <summary>The header <c>timestamp</c>; null until a header with a parseable timestamp was read.</summary>
    public long? HeaderMs { get; private set; }

    public bool HeaderSeen => _headerSeen;

    /// <summary>The parent transcript a sub-agent attaches to (METRICS 6.7): <c>&lt;dir&gt;.jsonl</c> for <c>&lt;dir&gt;/&lt;name&gt;.jsonl</c>.</summary>
    public string? ParentPath => PathIsSubagent && Path.GetDirectoryName(AgentId) is { Length: > 0 } folder ? folder + ".jsonl" : null;

    public override void Reset()
    {
        base.Reset();
        _pendingToolCalls.Clear();
        _responses.Clear();
        _modeBranches.Clear();
        _branchModes = ExecutionModes.Empty;
        _headerSeen = false;
        _headerProbed = false;
        HeaderMs = null;
        RestorePathState();
    }

    /// <summary>
    /// Reading that starts at an offset above 0 first takes the header from the file's first two lines (the title slot
    /// precedes it since 16.3). Runs on the reading thread; the header is applied before the batch's lines.
    /// </summary>
    public override void PrepareBatch(ILineBatch batch, long startOffset)
    {
        if (startOffset <= 0 || _headerSeen || _headerProbed || batch is not OmpBatch omp)
        {
            return;
        }

        _headerProbed = true;
        omp.Header = ReadHeader(AgentId);
    }

    public override ILineBatch NewBatch() => new OmpBatch(this);

    public override void Apply(in OmpLine line, IResponseSink sink)
    {
        if (line.Status == LineStatus.Malformed)
        {
            CountMalformed();
            return;
        }

        if (line.Status != LineStatus.Valid || line.Kind == OmpEntryKind.Title)
        {
            return;
        }

        if (line.Kind == OmpEntryKind.Session)
        {
            ApplyHeader(in line);
            return;
        }

        if (!_headerSeen || line.Id is null || line.TimestampMs is not { } ts
            || (HeaderMs is { } header && ts < header - CopiedHistoryMs))
        {
            return;
        }

        Touch(ts);
        _branchModes = line.SelectedModes ?? (line.ParentId is { } parent && _modeBranches.TryGetValue(parent, out var inherited)
            ? inherited : ExecutionModes.Empty);
        if (_modeBranches.Count >= 65536) _modeBranches.Clear();
        _modeBranches[line.Id] = _branchModes;
        Modes = _branchModes;
        switch (line.Kind)
        {
            case OmpEntryKind.Message:
                ApplyMessage(in line, ts, sink);
                break;
            case OmpEntryKind.ModelUsage:
                ApplySideCall(in line, ts, sink);
                break;
            case OmpEntryKind.SessionExit:
                _pendingToolCalls.Clear();
                SetPhase(AgentPhase.Idle, ts, null);
                break;
        }
    }

    protected override OmpLine Extract(ReadOnlySpan<byte> line) => OmpLineReader.Read(line);

    /// <summary>The first <c>session</c> line among the first two lines of the file, else a blank line.</summary>
    internal static OmpLine ReadHeader(string path)
    {
        try
        {
            using var handle = TranscriptTailer.Open(path);
            var length = RandomAccess.GetLength(handle);
            var buffer = new byte[(int)Math.Min(length, 64 * 1024)];
            var read = RandomAccess.Read(handle, buffer, 0);
            var span = buffer.AsSpan(0, read);
            for (var i = 0; i < HeaderProbeLines && !span.IsEmpty; i++)
            {
                var newline = span.IndexOf((byte)'\n');
                var raw = newline < 0 ? span : span[..newline];
                var line = OmpLineReader.Read(raw);
                if (line is { Status: LineStatus.Valid, Kind: OmpEntryKind.Session })
                {
                    return line;
                }

                if (newline < 0)
                {
                    break;
                }

                span = span[(newline + 1)..];
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }

        return new OmpLine { Status = LineStatus.Blank };
    }

    private void ApplyHeader(in OmpLine line)
    {
        if (_headerSeen)
        {
            return;
        }

        _headerSeen = true;
        HeaderMs = line.TimestampMs;
        SetProjectFromCwd(line.Cwd);
        MarkChanged();
        if (line.TimestampMs is { } ts)
        {
            Touch(ts);
        }
    }

    private void ApplyMessage(in OmpLine line, long ts, IResponseSink sink)
    {
        switch (line.Role)
        {
            case OmpRole.User or OmpRole.Developer:
                _pendingToolCalls.Clear();
                SetPhase(AgentPhase.Generating, ts, ts);
                break;
            case OmpRole.Assistant:
                ApplyAssistant(in line, ts, sink);
                break;
            case OmpRole.ToolResult:
                if (line.ToolCallId is { } callId)
                {
                    _pendingToolCalls.Remove(callId);
                }

                if (line.IsFinalYield)
                {
                    SetPhase(AgentPhase.Idle, ts, null);
                }
                else if (Phase == AgentPhase.Tools && _pendingToolCalls.Count == 0)
                {
                    SetPhase(AgentPhase.Generating, ts, ts);
                }

                break;
        }
    }

    private void ApplyAssistant(in OmpLine line, long ts, IResponseSink sink)
    {
        var call = line.Call;
        if (!call.Guarded)
        {
            return;
        }

        var key = Key(line.Id!, line.StartedMs ?? ts);
        if (Deduper.TryGetOwner(key, out var owner) && !string.Equals(owner, AgentId, StringComparison.Ordinal))
        {
            return;
        }

        var failed = line.Stop is OmpStop.Error or OmpStop.Aborted;
        var end = line.StartedMs is { } started && line.DurationMs is { } duration
            ? (duration > long.MaxValue - started ? long.MaxValue : started + duration)
            : line.CompletedAtMs ?? ts;
        if (call.HasUsage)
        {
            Emit(key, failed ? null : line.StartedMs, end, in call, sink);
            SetModel(call.Model);
        }

        if (failed)
        {
            _pendingToolCalls.Clear();
            SetPhase(AgentPhase.Idle, ts, null);
        }
        else if (line.ToolCallIds is { Length: > 0 } calls && line.Stop is OmpStop.ToolUse or OmpStop.Stop or OmpStop.Length)
        {
            _pendingToolCalls.Clear();
            _pendingToolCalls.UnionWith(calls);
            SetPhase(AgentPhase.Tools, ts, null);
        }
        else if (line.Stop == OmpStop.Stop && line.PauseTurn)
        {
            SetPhase(AgentPhase.Generating, ts, end);
        }
        else
        {
            SetPhase(AgentPhase.Idle, ts, null);
        }
    }

    // model_usage (18.1+): side calls count in totals only and never set the agent's model.
    private void ApplySideCall(in OmpLine line, long ts, IResponseSink sink)
    {
        var call = line.Call;
        if (!call.Guarded)
        {
            return;
        }

        var key = Key(line.Id!, ts);
        if (Deduper.TryGetOwner(key, out var owner) && !string.Equals(owner, AgentId, StringComparison.Ordinal))
        {
            return;
        }

        if (call.HasUsage)
        {
            Emit(key, null, ts, in call, sink);
        }
    }

    private void Emit(string key, long? startMs, long endMs, in OmpCall call, IResponseSink sink)
    {
        var isCompletion = Deduper.TryClaim(key, AgentId, out _);
        var family = call.Provider is "openai-codex" ? "openai" : call.Provider;
        var selected = new ExecutionModes(_branchModes.Facts.Where(f => f.Provider == family));
        var recorded = call.DisabledPriority ? ExecutionModes.Empty
            : ExecutionModeNative.OmpTier(call.ServiceTier, family, ExecutionModeEvidence.Recorded, ExecutionModeScope.Response);
        var response = new ParsedResponse(key, SourceKind.Omp, AgentId, call.Model, startMs, endMs, call.Tokens, Final: true, Provider: call.Provider)
        { Modes = selected.Merge(recorded) };
        Modes = response.Modes;
        if (_responses.TryGetValue(key, out var previous) && previous == response)
        {
            return;
        }

        _responses[key] = response;
        sink.OnResponse(response, isCompletion);
    }

    private static string Key(string id, long stamp) => string.Create(CultureInfo.InvariantCulture, $"omp:{id}:{stamp}");

    private void RestorePathState()
    {
        SetSource(SourceKind.Omp);
        SetSubagent(PathIsSubagent);
    }

    /// <summary>Lines of one read, with the header probed from the file start applied first.</summary>
    private sealed class OmpBatch(OmpParser owner) : ILineBatch
    {
        private readonly ILineBatch _lines = new Lines(owner);

        public OmpLine? Header { get; set; }

        public int Count => _lines.Count;

        public void OnLine(ReadOnlySpan<byte> line) => _lines.OnLine(line);

        public void OnMalformed() => _lines.OnMalformed();

        public void ApplyTo(IResponseSink sink)
        {
            if (Header is { } header)
            {
                owner.Apply(in header, sink);
            }

            _lines.ApplyTo(sink);
        }

        public void Clear()
        {
            Header = null;
            _lines.Clear();
        }

        private sealed class Lines(OmpParser parser) : ILineBatch
        {
            private readonly List<OmpLine> _items = [];
            private int _malformed;

            public int Count => _items.Count;

            public void OnLine(ReadOnlySpan<byte> line) => _items.Add(OmpLineReader.Read(line));

            public void OnMalformed() => _malformed++;

            public void ApplyTo(IResponseSink sink)
            {
                for (var i = 0; i < _malformed; i++)
                {
                    parser.Apply(new OmpLine { Status = LineStatus.Malformed }, sink);
                }

                foreach (var item in _items)
                {
                    parser.Apply(in item, sink);
                }
            }

            public void Clear()
            {
                _items.Clear();
                _malformed = 0;
            }
        }
    }
}

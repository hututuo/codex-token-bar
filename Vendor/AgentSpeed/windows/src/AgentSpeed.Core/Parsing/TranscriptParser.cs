namespace AgentSpeed.Core.Parsing;

/// <summary>Receives complete lines (without the trailing newline) from a tailer.</summary>
internal interface ILineSink
{
    void OnLine(ReadOnlySpan<byte> line);

    /// <summary>Input that never became a line (an undecodable zstd frame); counted as one malformed line.</summary>
    void OnMalformed();
}

/// <summary>Lines extracted off-thread, applied later to their parser in file order.</summary>
internal interface ILineBatch : ILineSink
{
    int Count { get; }

    void ApplyTo(IResponseSink sink);

    void Clear();
}

/// <summary>Per-file state machine (METRICS 4). Not thread-safe.</summary>
internal abstract class TranscriptParser
{
    private AgentPhase _phase = AgentPhase.Idle;

    protected TranscriptParser(string agentId, IDeduper deduper, SourceKind initialSource)
    {
        AgentId = agentId;
        Deduper = deduper;
        InitialSource = initialSource;
        Source = initialSource;
    }

    public string AgentId { get; }

    public SourceKind Source { get; protected set; }

    /// <summary>True once the transcript itself determined <see cref="Source"/>.</summary>
    public bool SourceDecided { get; protected set; }

    public string? Project { get; protected set; }

    public string? Model { get; protected set; }

    public bool IsSubagent { get; protected set; }

    private ExecutionModes _modes = ExecutionModes.Empty;
    public ExecutionModes Modes
    {
        get => _modes;
        protected set { if (!_modes.Equals(value)) { _modes = value; Version++; } }
    }

    public AgentPhase Phase => _phase;

    public long? PhaseSinceMs { get; private set; }

    public long? InFlightStartMs { get; private set; }

    public long? LastLineMs { get; private set; }

    public long MalformedLines { get; private set; }

    /// <summary>Changes whenever agent-visible state changes.</summary>
    public int Version { get; private set; }

    protected IDeduper Deduper { get; }

    protected SourceKind InitialSource { get; }

    public abstract ILineBatch NewBatch();

    /// <summary>
    /// Called on the reading thread before a tailer fills <paramref name="batch"/> from <paramref name="startOffset"/>;
    /// lets a parser read what it needs from the file start (omp reads its header, METRICS 4.7).
    /// </summary>
    public virtual void PrepareBatch(ILineBatch batch, long startOffset)
    {
    }

    /// <summary>Clears all per-file state after truncation or identity change; the shared deduper is kept.</summary>
    public virtual void Reset()
    {
        Source = InitialSource;
        SourceDecided = false;
        Project = null;
        Model = null;
        Modes = ExecutionModes.Empty;
        IsSubagent = false;
        _phase = AgentPhase.Idle;
        PhaseSinceMs = null;
        InFlightStartMs = null;
        LastLineMs = null;
        Version++;
    }

    protected void CountMalformed() => MalformedLines++;

    protected void MarkChanged() => Version++;

    protected void Touch(long timestampMs)
    {
        if (LastLineMs is not { } last || timestampMs > last)
        {
            LastLineMs = timestampMs;
            Version++;
        }
    }

    protected void SetProjectFromCwd(string? cwd)
    {
        if (cwd is null)
        {
            return;
        }

        var project = PathText.Basename(cwd);
        if (project.Length > 0 && !string.Equals(project, Project, StringComparison.Ordinal))
        {
            Project = project;
            Version++;
        }
    }

    protected void SetModel(string? model)
    {
        if (model is not null && !string.Equals(model, Model, StringComparison.Ordinal))
        {
            Model = model;
            Version++;
        }
    }

    protected void SetSubagent(bool value)
    {
        if (IsSubagent != value)
        {
            IsSubagent = value;
            Version++;
        }
    }

    protected void SetSource(SourceKind source)
    {
        SourceDecided = true;
        if (Source != source)
        {
            Source = source;
            Version++;
        }
    }

    protected void SetPhase(AgentPhase phase, long timestampMs, long? inFlightStartMs)
    {
        if (_phase != phase)
        {
            _phase = phase;
            PhaseSinceMs = timestampMs;
            Version++;
        }

        var inFlight = phase == AgentPhase.Generating ? inFlightStartMs : null;
        if (InFlightStartMs != inFlight)
        {
            InFlightStartMs = inFlight;
            Version++;
        }
    }
}

/// <summary>Splits extraction (pure, may run on any thread) from application (stateful, in order).</summary>
internal abstract class TranscriptParser<TLine> : TranscriptParser
    where TLine : struct
{
    protected TranscriptParser(string agentId, IDeduper deduper, SourceKind initialSource)
        : base(agentId, deduper, initialSource)
    {
    }

    public override ILineBatch NewBatch() => new Batch(this);

    public void Feed(ReadOnlySpan<byte> line, IResponseSink sink)
    {
        var parsed = Extract(line);
        Apply(in parsed, sink);
    }

    public abstract void Apply(in TLine line, IResponseSink sink);

    protected abstract TLine Extract(ReadOnlySpan<byte> line);

    private sealed class Batch(TranscriptParser<TLine> owner) : ILineBatch
    {
        private readonly List<TLine> _lines = [];
        private int _malformed;

        public int Count => _lines.Count;

        public void OnLine(ReadOnlySpan<byte> line) => _lines.Add(owner.Extract(line));

        public void OnMalformed() => _malformed++;

        public void ApplyTo(IResponseSink sink)
        {
            for (var i = 0; i < _malformed; i++)
            {
                owner.CountMalformed();
            }

            foreach (ref readonly var line in System.Runtime.InteropServices.CollectionsMarshal.AsSpan(_lines))
            {
                owner.Apply(in line, sink);
            }
        }

        public void Clear()
        {
            _lines.Clear();
            _malformed = 0;
            if (_lines.Capacity > 4096)
            {
                _lines.Capacity = 4096;
            }
        }
    }
}

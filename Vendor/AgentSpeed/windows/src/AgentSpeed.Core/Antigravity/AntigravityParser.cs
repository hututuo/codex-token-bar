using System.Globalization;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Antigravity;

/// <summary>The rows of one database read, decoded off-thread and applied to the parser in one step.</summary>
internal sealed class AntigravityBatch(AntigravityParser owner) : ILineBatch
{
    public AntigravityTrajectory? Trajectory { get; set; }

    public List<AntigravityGeneration> Generations { get; } = [];

    public List<AntigravityExecutor> Executors { get; } = [];

    public List<AntigravityStepRow> Steps { get; } = [];

    /// <summary>The database has no usable <c>steps</c> table (METRICS 4.8): it contributes nothing.</summary>
    public bool Unsupported { get; set; }

    public int Malformed { get; private set; }

    public int Count => Steps.Count + Generations.Count + Executors.Count + (Trajectory is null ? 0 : 1);

    public void OnLine(ReadOnlySpan<byte> line) => throw new NotSupportedException("Antigravity databases are not read as lines.");

    public void OnMalformed() => Malformed++;

    public void ApplyTo(IResponseSink sink) => owner.Apply(this, sink);

    public void Clear()
    {
        Trajectory = null;
        Generations.Clear();
        Executors.Clear();
        Steps.Clear();
        Unsupported = false;
        Malformed = 0;
    }
}

/// <summary>
/// One Antigravity conversation (METRICS 4.8): every <c>PLANNER_RESPONSE</c> step with a terminal status and usage is a
/// response; the phase is a function of the latest step and the executor rows read so far. Not thread-safe.
/// </summary>
internal sealed class AntigravityParser : TranscriptParser
{
    /// <summary>Steps created this much before the conversation were copied from another one (a fork).</summary>
    public const long CopiedHistoryMs = 2000;

    private readonly SortedDictionary<long, AntigravityGeneration> _generations = [];
    private readonly Dictionary<long, AntigravityExecutor> _executors = [];
    private readonly Dictionary<string, Emitted> _responses = new(StringComparer.Ordinal);
    private AntigravityStepRow? _latest;

    public AntigravityParser(string agentId, IDeduper deduper)
        : base(agentId, deduper, SourceKind.Antigravity)
    {
        ConversationId = AntigravityPaths.ConversationId(agentId);
        SetSource(SourceKind.Antigravity);
    }

    /// <summary>The file name without <c>.db</c>.</summary>
    public string ConversationId { get; }

    /// <summary><c>CortexTrajectoryMetadata.created_at</c>; null until the trajectory metadata was read.</summary>
    public long? CreatedMs { get; private set; }

    /// <summary><c>parent_conversation_id</c> when non-empty (METRICS 6.7).</summary>
    public string? ParentConversationId { get; private set; }

    /// <summary>The last read found no usable <c>steps</c> table.</summary>
    public bool Unsupported { get; private set; }

    public override ILineBatch NewBatch() => new AntigravityBatch(this);

    public override void Reset()
    {
        base.Reset();
        _generations.Clear();
        _executors.Clear();
        _responses.Clear();
        _latest = null;
        CreatedMs = null;
        ParentConversationId = null;
        Unsupported = false;
        SetSource(SourceKind.Antigravity);
    }

    public void Apply(AntigravityBatch batch, IResponseSink sink)
    {
        for (var i = 0; i < batch.Malformed; i++)
        {
            CountMalformed();
        }

        if (batch.Unsupported != Unsupported)
        {
            Unsupported = batch.Unsupported;
            MarkChanged();
        }

        if (batch.Trajectory is { } trajectory)
        {
            ApplyTrajectory(trajectory);
        }

        var modelsChanged = false;
        foreach (var generation in batch.Generations)
        {
            _generations[generation.Idx] = generation;
            modelsChanged = true;
        }

        foreach (var executor in batch.Executors)
        {
            _executors[executor.Idx] = executor;
            modelsChanged = true;
        }

        foreach (var row in batch.Steps)
        {
            ApplyStep(row, sink);
        }

        if (modelsChanged)
        {
            ResolveModels(sink);
        }

        UpdateAgentModel();
        UpdatePhase();
    }

    private void ApplyTrajectory(AntigravityTrajectory trajectory)
    {
        CreatedMs = trajectory.CreatedMs;
        if (trajectory.Project is { } project && !string.Equals(project, Project, StringComparison.Ordinal))
        {
            Project = project;
        }

        SetSubagent(trajectory.IsSubagent);
        ParentConversationId = trajectory.ParentConversationId;
        MarkChanged();
        if (trajectory.CreatedMs is { } created)
        {
            Touch(created);
        }
    }

    private void ApplyStep(AntigravityStepRow row, IResponseSink sink)
    {
        if (row.Step is not { } step)
        {
            return;
        }

        if (CreatedMs is { } created && step.CreatedMs is { } stepCreated && stepCreated < created - CopiedHistoryMs)
        {
            return;
        }

        foreach (var time in step.Times())
        {
            Touch(time);
        }

        if (_latest is null || row.Idx >= _latest.Idx)
        {
            _latest = row;
        }

        if (row.StepType != StepCodes.PlannerResponse || StepCodes.IsOpen(row.Status) || step.Usage is not { HasTokens: true } usage)
        {
            return;
        }

        var key = usage.Key ?? string.Create(CultureInfo.InvariantCulture, $"antigravity:{ConversationId}:{row.Idx}");
        if (Deduper.TryGetOwner(key, out var owner) && !string.Equals(owner, AgentId, StringComparison.Ordinal))
        {
            return;
        }

        var end = step.FinishedGeneratingMs ?? step.LastChunkMs ?? step.CompletedMs;
        var start = step.CreatedMs;
        if (end is null)
        {
            if (step.LatestTime is not { } latest)
            {
                return;
            }

            end = latest;
            start = null;
        }

        if (StepCodes.IsFailed(row.Status))
        {
            start = null;
        }

        var isCompletion = Deduper.TryClaim(key, AgentId, out _);
        var response = new ParsedResponse(
            key, SourceKind.Antigravity, AgentId, ModelFor(row.Idx), start, end.Value, usage.ToTokens(), Final: true);
        Emit(response, row.Idx, isCompletion, sink);
    }

    /// <summary>
    /// <c>chat_model.response_model</c> (else <c>model_display_name</c>) of the lowest generation listing the step, else the
    /// <c>model_name</c> of the executor with the smallest <c>last_step_idx</c> at or after it (ties: lowest idx).
    /// </summary>
    private string? ModelFor(long idx)
    {
        foreach (var generation in _generations.Values)
        {
            if (idx >= 0 && generation.StepIndices.Contains((ulong)idx))
            {
                if (generation.Model is { } model)
                {
                    return model;
                }

                break;
            }
        }

        AntigravityExecutor? covering = null;
        foreach (var executor in _executors.Values)
        {
            if (executor.LastStepIdx >= idx
                && (covering is null || executor.LastStepIdx < covering.LastStepIdx
                    || (executor.LastStepIdx == covering.LastStepIdx && executor.Idx < covering.Idx)))
            {
                covering = executor;
            }
        }

        return covering?.Model;
    }

    // A later read may change a response's model (METRICS 4.8 Metadata): such responses are updated (4.4).
    private void ResolveModels(IResponseSink sink)
    {
        foreach (var emitted in _responses.Values.ToList())
        {
            var model = ModelFor(emitted.Idx);
            if (!string.Equals(model, emitted.Response.Model, StringComparison.Ordinal))
            {
                Emit(emitted.Response with { Model = model }, emitted.Idx, isCompletion: false, sink);
            }
        }
    }

    private void Emit(ParsedResponse response, long idx, bool isCompletion, IResponseSink sink)
    {
        if (_responses.TryGetValue(response.Key, out var previous) && previous.Response == response && previous.Idx == idx)
        {
            return;
        }

        _responses[response.Key] = new Emitted(response, idx);
        sink.OnResponse(response, isCompletion);
    }

    // The agent's model is the model of the response with the highest idx that has one.
    private void UpdateAgentModel()
    {
        Emitted? best = null;
        foreach (var emitted in _responses.Values)
        {
            if (emitted.Response.Model is not null && (best is null || emitted.Idx > best.Idx))
            {
                best = emitted;
            }
        }

        SetModel(best?.Response.Model);
    }

    private void UpdatePhase()
    {
        var since = LastLineMs ?? 0;
        if (_latest is not { Step: { } step } latest
            || _executors.Values.Any(e => e.TerminationReason != 0 && e.LastStepIdx >= latest.Idx))
        {
            SetPhase(AgentPhase.Idle, since, null);
            return;
        }

        var open = StepCodes.IsOpen(latest.Status);
        switch (latest.StepType)
        {
            case StepCodes.PlannerResponse:
                SetPhase(open ? AgentPhase.Generating : AgentPhase.Idle, since, open ? step.CreatedMs : null);
                break;
            case StepCodes.UserInput:
                var failed = StepCodes.IsFailed(latest.Status);
                SetPhase(failed ? AgentPhase.Idle : AgentPhase.Generating, since, failed ? null : step.CreatedMs);
                break;
            default:
                if (open)
                {
                    SetPhase(AgentPhase.Tools, since, null);
                }
                else if (latest.Status == StepCodes.Done)
                {
                    SetPhase(AgentPhase.Generating, since, step.CompletedMs ?? step.CreatedMs);
                }
                else
                {
                    SetPhase(AgentPhase.Idle, since, null);
                }

                break;
        }
    }

    private sealed record Emitted(ParsedResponse Response, long Idx);
}

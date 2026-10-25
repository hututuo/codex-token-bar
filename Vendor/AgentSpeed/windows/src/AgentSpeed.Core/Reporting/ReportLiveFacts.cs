namespace AgentSpeed.Core.Reporting;

/// <summary>Usage counted for live reporting (METRICS 11.4): token fields, measured output and time, cost and unpriced requests.</summary>
public readonly record struct ReportUsage(
    long Requests = 0,
    long Output = 0,
    long Input = 0,
    long CachedInput = 0,
    long CacheWriteInput = 0,
    long Reasoning = 0,
    long MeasuredOutput = 0,
    long MeasuredMs = 0,
    long CostMicroUsd = 0,
    long UnpricedRequests = 0)
{
    public static ReportUsage Zero => default;

    public bool IsZero => this == default;

    /// <summary>Any token field changed (the activity rule of METRICS 11.5).</summary>
    public bool HasTokens => Requests != 0 || Output != 0 || Input != 0 || CachedInput != 0 || CacheWriteInput != 0 || Reasoning != 0;

    public static ReportUsage operator +(ReportUsage a, ReportUsage b) => new(
        a.Requests + b.Requests, a.Output + b.Output, a.Input + b.Input, a.CachedInput + b.CachedInput,
        a.CacheWriteInput + b.CacheWriteInput, a.Reasoning + b.Reasoning, a.MeasuredOutput + b.MeasuredOutput,
        a.MeasuredMs + b.MeasuredMs, a.CostMicroUsd + b.CostMicroUsd, a.UnpricedRequests + b.UnpricedRequests);

    /// <summary>Field-wise difference of two cumulative values, never negative.</summary>
    public static ReportUsage operator -(ReportUsage a, ReportUsage b) => new(
        Math.Max(0, a.Requests - b.Requests), Math.Max(0, a.Output - b.Output), Math.Max(0, a.Input - b.Input),
        Math.Max(0, a.CachedInput - b.CachedInput), Math.Max(0, a.CacheWriteInput - b.CacheWriteInput),
        Math.Max(0, a.Reasoning - b.Reasoning), Math.Max(0, a.MeasuredOutput - b.MeasuredOutput),
        Math.Max(0, a.MeasuredMs - b.MeasuredMs), Math.Max(0, a.CostMicroUsd - b.CostMicroUsd),
        Math.Max(0, a.UnpricedRequests - b.UnpricedRequests));
}

/// <summary>A resolved model id (METRICS 11.3) used by one source.</summary>
public readonly record struct ReportModelKey(string ModelId, SourceKind Source);

/// <summary>
/// Cumulative report increments since the engine started (METRICS 11.4). A report window is the difference of two values,
/// so every increment lands in exactly one window however snapshots are coalesced.
/// </summary>
public sealed class ReportCounters
{
    private readonly Dictionary<ReportModelKey, ReportUsage> _byModel;
    private readonly Dictionary<ReportModeKey, ReportUsage> _byMode;

    public ReportCounters()
        : this(new Dictionary<ReportModelKey, ReportUsage>(), new Dictionary<ReportModeKey, ReportUsage>())
    {
    }

    private ReportCounters(Dictionary<ReportModelKey, ReportUsage> byModel, Dictionary<ReportModeKey, ReportUsage> byMode)
    {
        _byModel = byModel;
        _byMode = byMode;
    }

    public static ReportCounters Zero { get; } = new();

    public IReadOnlyDictionary<ReportModelKey, ReportUsage> ByModel => _byModel;
    public IReadOnlyDictionary<ReportModeKey, ReportUsage> ByMode => _byMode;

    /// <summary>Changes with every non-zero <see cref="Add"/>, so an owner copies only after a change.</summary>
    public long Version { get; private set; }

    public ReportUsage Total
    {
        get
        {
            var total = ReportUsage.Zero;
            foreach (var usage in _byModel.Values)
            {
                total += usage;
            }

            return total;
        }
    }

    /// <summary>The increments since <paramref name="baseline"/>, per model and source; zero entries are left out.</summary>
    public ReportCounters Since(ReportCounters baseline)
    {
        var delta = new Dictionary<ReportModelKey, ReportUsage>();
        foreach (var (key, value) in _byModel)
        {
            var change = value - baseline._byModel.GetValueOrDefault(key);
            if (!change.IsZero)
            {
                delta[key] = change;
            }
        }

        var modes = new Dictionary<ReportModeKey, ReportUsage>();
        foreach (var (key, value) in _byMode)
        {
            var change = value - baseline._byMode.GetValueOrDefault(key);
            if (!change.IsZero) modes[key] = change;
        }
        return new ReportCounters(delta, modes);
    }

    /// <summary>Whether any token field differs from <paramref name="baseline"/>.</summary>
    public bool HasTokensSince(ReportCounters baseline)
    {
        foreach (var (key, value) in _byModel)
        {
            if ((value - baseline._byModel.GetValueOrDefault(key)).HasTokens)
            {
                return true;
            }
        }

        return false;
    }

    public void Add(ReportUsage usage, ReportModelKey key, ExecutionModes? modes = null)
    {
        if (!usage.IsZero)
        {
            _byModel[key] = _byModel.GetValueOrDefault(key) + usage;
            foreach (var kind in Enum.GetValues<ExecutionModeKind>())
            {
                var mode = (modes ?? ExecutionModes.Empty).Attribute(kind);
                var modeKey = new ReportModeKey(key.ModelId, key.Source, kind, mode.Mode, mode.Evidence, mode.Provider);
                _byMode[modeKey] = _byMode.GetValueOrDefault(modeKey) + usage;
            }
            Version++;
        }
    }

    /// <summary>An immutable copy, for a snapshot.</summary>
    public ReportCounters Copy() => new(new Dictionary<ReportModelKey, ReportUsage>(_byModel), new Dictionary<ReportModeKey, ReportUsage>(_byMode));
}

/// <summary>Agents of the base set of METRICS 6.7 (staleness applied, no ancestor closure) of one source.</summary>
public readonly record struct ReportAgentCounts(int Generating = 0, int Tools = 0, int Active = 0)
{
    public static ReportAgentCounts operator +(ReportAgentCounts a, ReportAgentCounts b) =>
        new(a.Generating + b.Generating, a.Tools + b.Tools, a.Active + b.Active);
}

/// <summary>What each snapshot carries for live reporting (METRICS 11.2, 11.4).</summary>
/// <param name="Epoch">The engine instance the counters belong to; a new monitor session starts them over.</param>
public sealed record ReportLiveFacts(
    IReadOnlyDictionary<SourceKind, ReportAgentCounts> Agents,
    IReadOnlyDictionary<ReportModelKey, int> GeneratingModels,
    ReportCounters Counters,
    long Epoch = 0)
{
    public static ReportLiveFacts Empty { get; } = new(
        new Dictionary<SourceKind, ReportAgentCounts>(), new Dictionary<ReportModelKey, int>(), ReportCounters.Zero);
}

/// <summary>The reserved model ids of REPORTING 6.6.4.</summary>
public static class ReportModelIds
{
    public const string Local = "local";
    public const string Unknown = "unknown";
    public const string Other = "other";

    /// <summary><c>$defs/modelId</c>: <c>^[a-z0-9][a-z0-9._:-]{0,63}$</c>.</summary>
    public static bool IsValid(string id) =>
        id.Length is >= 1 and <= 64 && LowerAlnum(id[0]) && id.All(c => LowerAlnum(c) || c is '.' or '_' or ':' or '-');

    private static bool LowerAlnum(char c) => c is (>= 'a' and <= 'z') or (>= '0' and <= '9');
}

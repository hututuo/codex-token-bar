using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Engine;

/// <summary>Incremental "today" aggregates (METRICS 6.6) that support replacing a response by key.</summary>
internal sealed partial class TodayLedger
{
    private const int IndexCapacity = 65_536;

    /// <summary>Today's unpriced responses kept for re-pricing with a newer table (METRICS 9.7).</summary>
    public const int UnpricedCapacity = 10_000;

    private readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);
    private readonly Queue<string> _order = new();
    private readonly SecondSeries _output = new();
    private readonly SecondSeries _total = new();
    private readonly SourceSeconds _sourceOutput = new();
    private readonly TokenTotals[] _perSource = new TokenTotals[Enum.GetValues<SourceKind>().Length];
    private readonly CostTally[] _costPerSource = new CostTally[Enum.GetValues<SourceKind>().Length];
    private readonly Dictionary<(SourceKind Source, string Model), CostTally> _costPerModel = [];
    private readonly Dictionary<string, ParsedResponse> _unpriced = new(StringComparer.Ordinal);
    private double _validOutput;
    private double _validSeconds;
    private long _validCount;
    private long _unfinalized;

    public TodayLedger(long startMs)
    {
        StartMs = startMs;
    }

    public long StartMs { get; private set; }

    public TokenTotals Totals { get; private set; }

    /// <summary>Σ output / Σ duration over today's measured responses, null when there are none.</summary>
    public double? AverageOutputSpeed => _validCount > 0 && _validSeconds > 0 ? Math.Max(0, _validOutput) / _validSeconds : null;

    /// <summary>Today's responses whose final usage was never written.</summary>
    public int UnfinalizedCount => (int)Math.Clamp(_unfinalized, 0, int.MaxValue);

    public TokenTotals ForSource(SourceKind source) => _perSource[(int)source];

    /// <summary>Today's cost (METRICS 9.6).</summary>
    public CostTally Cost { get; private set; }

    public CostTally CostForSource(SourceKind source) => _costPerSource[(int)source];

    /// <summary>Today's unpriced responses (at most <see cref="UnpricedCapacity"/>), for re-pricing.</summary>
    public IReadOnlyCollection<ParsedResponse> UnpricedResponses => _unpriced.Values;

    /// <summary>A source's models with unpriced responses today, most unpriced first, then by name.</summary>
    public IReadOnlyList<string> UnpricedModels(SourceKind source)
    {
        List<(string Model, long Count)>? models = null;
        foreach (var ((kind, model), tally) in _costPerModel)
        {
            if (kind == source && tally.UnpricedRequests > 0 && model.Length > 0)
            {
                (models ??= []).Add((model, tally.UnpricedRequests));
            }
        }

        if (models is null)
        {
            return [];
        }

        models.Sort(static (a, b) => a.Count != b.Count ? b.Count.CompareTo(a.Count) : string.CompareOrdinal(a.Model, b.Model));
        return models.ConvertAll(m => m.Model);
    }

    /// <summary>Sources with measured buckets today (METRICS 6.6).</summary>
    public SourceSet MeasuredSources => _sourceOutput.Allocated;

    /// <summary>Chunks rescanned for source-set peaks so far (tests).</summary>
    public long SourcePeakChunkScans => _sourceOutput.ChunkScans;

    /// <summary>Today's measured output peak of a source set (METRICS 6.8), without the observed live part.</summary>
    public double MeasuredPeakOutput(SourceSet sources) => _sourceOutput.MeasuredPeak(sources);

    public (double Output, long? OutputAtMs, double Total) Peak()
    {
        var (output, at) = _output.TrailingPeak();
        var (total, _) = _total.TrailingPeak();
        return (output, at, total);
    }

    public void Reset(long startMs)
    {
        StartMs = startMs;
        _entries.Clear();
        _order.Clear();
        _output.Clear();
        _total.Clear();
        _sourceOutput.Clear();
        Array.Clear(_perSource);
        Array.Clear(_costPerSource);
        _costPerModel.Clear();
        _unpriced.Clear();
        ResetModes();
        Cost = default;
        Totals = default;
        _validOutput = 0;
        _validSeconds = 0;
        _validCount = 0;
        _unfinalized = 0;
    }

    public void Upsert(ParsedResponse response)
    {
        var belongs = response.EndMs >= StartMs;
        if (_entries.TryGetValue(response.Key, out var previous))
        {
            Apply(previous, -1);
            if (!belongs)
            {
                _entries.Remove(response.Key);
                _unpriced.Remove(response.Key);
                return;
            }
        }
        else if (!belongs)
        {
            return;
        }
        else
        {
            if (_order.Count >= IndexCapacity && _order.TryDequeue(out var oldest))
            {
                _entries.Remove(oldest);
                _unpriced.Remove(oldest);
            }

            _order.Enqueue(response.Key);
        }

        var entry = new Entry(
            response.Source,
            response.Tokens,
            response.Final,
            response.Final && SpeedMath.TryGetSpeedInterval(response, out var interval) ? interval : null,
            response.Model ?? string.Empty,
            response.CostMicroUsd, response.Requests, response.Modes);
        Apply(entry, 1);
        _entries[response.Key] = entry;
        if (response.CostMicroUsd is not null)
        {
            _unpriced.Remove(response.Key);
        }
        else if (_unpriced.Count < UnpricedCapacity || _unpriced.ContainsKey(response.Key))
        {
            _unpriced[response.Key] = response;
        }
    }

    private void Apply(in Entry entry, int sign)
    {
        Totals = Add(Totals, entry.Tokens, sign, entry.Requests);
        _perSource[(int)entry.Source] = Add(_perSource[(int)entry.Source], entry.Tokens, sign, entry.Requests);
        Cost = Cost.Add(entry.Cost, sign, entry.Requests);
        ApplyModes(entry, sign);
        _costPerSource[(int)entry.Source] = _costPerSource[(int)entry.Source].Add(entry.Cost, sign, entry.Requests);
        var modelKey = (entry.Source, entry.Model);
        var modelCost = _costPerModel.GetValueOrDefault(modelKey).Add(entry.Cost, sign, entry.Requests);
        if (modelCost == default)
        {
            _costPerModel.Remove(modelKey);
        }
        else
        {
            _costPerModel[modelKey] = modelCost;
        }

        if (!entry.Final)
        {
            _unfinalized += sign * entry.Requests;
        }

        if (entry.Measured is not { } interval)
        {
            return;
        }

        _validCount += sign;
        _validOutput += sign * (double)entry.Tokens.Output;
        _validSeconds += sign * (interval.DurationMs / 1000.0);
        _output.AddInterval(interval.StartMs, interval.EndMs, sign * (double)entry.Tokens.Output, StartMs);
        _total.AddInterval(interval.StartMs, interval.EndMs, sign * (double)entry.Tokens.Total, StartMs);
        _sourceOutput.AddInterval(entry.Source, interval.StartMs, interval.EndMs, sign * (double)entry.Tokens.Output, StartMs);
    }

    private static TokenTotals Add(TokenTotals totals, in TokenCounts tokens, int sign, long requests) => new(
        totals.Requests + sign * requests,
        totals.Input + sign * tokens.Input,
        totals.CachedInput + sign * tokens.CachedInput,
        totals.CacheWriteInput + sign * tokens.CacheWriteInput,
        totals.Output + sign * tokens.Output,
        totals.Reasoning + sign * tokens.Reasoning);

    /// <param name="Measured">The speed interval when the response is final and valid (METRICS 3.3).</param>
    private readonly record struct Entry(SourceKind Source, TokenCounts Tokens, bool Final, Interval? Measured, string Model, long? Cost, long Requests, ExecutionModes Modes);
}

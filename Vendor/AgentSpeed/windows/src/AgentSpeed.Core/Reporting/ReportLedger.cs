using AgentSpeed.Core.Engine;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Reporting;

/// <summary>
/// The report ledger of METRICS 11.4: which responses count for live reporting and what each one already added.
/// Increments accumulate in <see cref="Counters"/>; windows are differences of it. Owned by the engine's thread.
/// </summary>
internal sealed class ReportLedger
{
    public const int MaxCountedKeys = 65_536;

    private readonly Dictionary<string, Reported> _counted = new(StringComparer.Ordinal);
    private readonly Queue<string> _order = new();

    public ReportCounters Counters { get; } = new();

    public int CountedKeys => _counted.Count;

    public bool IsCounted(string key) => _counted.ContainsKey(key);

    /// <summary>Counts a response at its first live emission (a key already counted grows instead).</summary>
    public void Count(ParsedResponse response, string modelId)
    {
        if (_counted.ContainsKey(response.Key))
        {
            Grow(response, modelId);
            return;
        }

        var values = Values(response);
        var usage = new ReportUsage(values.Requests, values.Output, values.Input, values.CachedInput, values.CacheWriteInput, values.Reasoning,
            values.MeasuredOutput, values.MeasuredMs, values.CostMicroUsd, values.UnpricedRequests);
        Counters.Add(usage, new ReportModelKey(modelId, response.Source), values.Modes);
        _counted[response.Key] = values;
        _order.Enqueue(response.Key);
        while (_counted.Count > MaxCountedKeys && _order.TryDequeue(out var oldest))
        {
            _counted.Remove(oldest);
        }
    }

    /// <summary>Growth of a counted response (an upsert or a re-pricing): each field adds what exceeds what it already added.</summary>
    public void Grow(ParsedResponse response, string modelId)
    {
        if (!_counted.TryGetValue(response.Key, out var reported))
        {
            return;
        }

        var now = Values(response);
        var usage = new ReportUsage(
            Step(now.Requests, reported.Requests),
            Step(now.Output, reported.Output),
            Step(now.Input, reported.Input),
            Step(now.CachedInput, reported.CachedInput),
            Step(now.CacheWriteInput, reported.CacheWriteInput),
            Step(now.Reasoning, reported.Reasoning),
            Step(now.MeasuredOutput, reported.MeasuredOutput),
            Step(now.MeasuredMs, reported.MeasuredMs),
            Step(now.CostMicroUsd, reported.CostMicroUsd), Step(now.UnpricedRequests, reported.UnpricedRequests));
        _counted[response.Key] = new Reported(
            Math.Max(reported.Output, now.Output), Math.Max(reported.Input, now.Input), Math.Max(reported.CachedInput, now.CachedInput),
            Math.Max(reported.CacheWriteInput, now.CacheWriteInput), Math.Max(reported.Reasoning, now.Reasoning),
            Math.Max(reported.MeasuredOutput, now.MeasuredOutput), Math.Max(reported.MeasuredMs, now.MeasuredMs),
            Math.Max(reported.CostMicroUsd, now.CostMicroUsd), Math.Max(reported.EndMs, now.EndMs),
            Math.Max(reported.Requests, now.Requests), Math.Max(reported.UnpricedRequests, now.UnpricedRequests)) { Modes = reported.Modes };
        Counters.Add(usage, new ReportModelKey(modelId, response.Source), reported.Modes);
    }

    /// <summary>Forgets counted keys whose response left the engine's retention (by its latest end).</summary>
    public void Prune(long cutoffMs)
    {
        List<string>? expired = null;
        foreach (var (key, reported) in _counted)
        {
            if (reported.EndMs < cutoffMs)
            {
                (expired ??= []).Add(key);
            }
        }

        if (expired is null)
        {
            return;
        }

        foreach (var key in expired)
        {
            _counted.Remove(key);
        }

        var kept = _order.Where(_counted.ContainsKey).ToArray();
        _order.Clear();
        foreach (var key in kept)
        {
            _order.Enqueue(key);
        }
    }

    private static long Step(long now, long before) => Math.Max(0, now - before);

    private static Reported Values(ParsedResponse response)
    {
        var tokens = response.Tokens;
        var measured = response.Final && SpeedMath.TryGetSpeedInterval(response, out var interval) ? interval.DurationMs : (long?)null;
        return new Reported(
            tokens.Output, tokens.Input, tokens.CachedInput, tokens.CacheWriteInput, tokens.Reasoning,
            measured is null ? 0 : tokens.Output, measured ?? 0, response.CostMicroUsd ?? 0, response.EndMs,
            response.Requests, response.CostMicroUsd is null ? response.Requests : 0) { Modes = response.Modes };
    }

    /// <summary>The values a counted response has added so far, field by field.</summary>
    private readonly record struct Reported(
        long Output, long Input, long CachedInput, long CacheWriteInput, long Reasoning, long MeasuredOutput, long MeasuredMs,
        long CostMicroUsd, long EndMs, long Requests, long UnpricedRequests)
    {
        public ExecutionModes Modes { get; init; } = ExecutionModes.Empty;
    }
}

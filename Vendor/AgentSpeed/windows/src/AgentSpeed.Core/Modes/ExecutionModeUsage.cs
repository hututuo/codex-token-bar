namespace AgentSpeed.Core;

public sealed record ExecutionModeUsage(
    string Model, SourceKind Source, ExecutionModeKind Kind, string Mode, string Evidence, string? Provider,
    long Requests, long Output, long MeasuredOutput, long MeasuredMs)
{
    public double? AverageSpeed => MeasuredMs > 0 ? MeasuredOutput / (MeasuredMs / 1000.0) : null;

    public static IReadOnlyList<ExecutionModeUsage> Combine(IEnumerable<ExecutionModeUsage> rows) => rows
        .GroupBy(r => (r.Model, r.Source, r.Kind, r.Mode, r.Evidence, r.Provider))
        .Select(g => g.First() with
        {
            Requests = g.Sum(r => r.Requests), Output = g.Sum(r => r.Output),
            MeasuredOutput = g.Sum(r => r.MeasuredOutput), MeasuredMs = g.Sum(r => r.MeasuredMs),
        })
        .OrderBy(r => r.Model, StringComparer.Ordinal).ThenBy(r => r.Source).ThenBy(r => r.Kind)
        .ThenBy(r => r.Mode, StringComparer.Ordinal).ThenBy(r => r.Evidence, StringComparer.Ordinal)
        .ThenBy(r => r.Provider, StringComparer.Ordinal).ToArray();
}

internal readonly record struct ExecutionModeKey(string Model, ExecutionModeKind Kind, string Mode, string Evidence, string Provider)
{
    public static ExecutionModeKey Of(string model, ExecutionModeAttribution value) =>
        new(model, value.Kind, value.Mode, value.Evidence, value.Provider ?? string.Empty);
}

internal readonly record struct ExecutionModeTotals(long Requests, long Output, long MeasuredOutput, long MeasuredMs)
{
    public static ExecutionModeTotals operator +(ExecutionModeTotals a, ExecutionModeTotals b) =>
        new(a.Requests + b.Requests, a.Output + b.Output, a.MeasuredOutput + b.MeasuredOutput, a.MeasuredMs + b.MeasuredMs);
}

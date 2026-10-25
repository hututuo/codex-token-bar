namespace AgentSpeed.Core;

/// <summary>One model's share of a source's day (METRICS 8).</summary>
/// <param name="MeasuredOutput">Output of the model's measured responses.</param>
/// <param name="MeasuredMs">Widened duration of the model's measured responses (METRICS 3.3).</param>
public sealed record ModelUsage(string Model, long Requests, long Output, long MeasuredOutput = 0, long MeasuredMs = 0)
{
    /// <summary>The model's cost on that day (METRICS 9.7); null when it was stored before costs existed.</summary>
    public CostTally? Cost { get; init; }

    /// <summary>Output tok/s over the model's measured responses; null when none was measured.</summary>
    public double? AverageSpeed => MeasuredMs > 0 ? MeasuredOutput / (MeasuredMs / 1000.0) : null;
}

/// <summary>One source's aggregates for one local calendar day (METRICS 8).</summary>
/// <param name="Day">Local calendar date, <c>YYYY-MM-DD</c>.</param>
/// <param name="Peak">Only for days observed live.</param>
public sealed record DailyUsage(
    string Day,
    SourceKind Source,
    TokenTotals Totals,
    long MeasuredOutput,
    long MeasuredMs,
    long Unfinalized,
    int Agents,
    double? Peak,
    IReadOnlyList<ModelUsage> Models)
{
    public IReadOnlyList<ExecutionModeUsage> Modes { get; init; } = [];

    /// <summary>API-equivalent cost (METRICS 9.7); null when the day's logs were gone before costs existed.</summary>
    public CostTally? Cost { get; init; }

    /// <summary>The price table version bound to the day; null without cost data.</summary>
    public int? PriceVersion { get; init; }

    /// <summary>Output tok/s over the day's measured responses.</summary>
    public double? AverageSpeed => MeasuredMs > 0 ? MeasuredOutput / (MeasuredMs / 1000.0) : null;
}

public enum HistoryStateKind
{
    NotLoaded,
    Analyzing,
    Ready,
    Failed,
}

public readonly record struct HistoryState(
    HistoryStateKind Kind,
    double Progress = 0,
    int FilesDone = 0,
    int FilesTotal = 0,
    DateTimeOffset? UpdatedAt = null,
    string? Error = null)
{
    public static HistoryState NotLoaded => new(HistoryStateKind.NotLoaded);

    public static HistoryState Analyzing(double progress, int filesDone, int filesTotal) =>
        new(HistoryStateKind.Analyzing, progress, filesDone, filesTotal);

    public static HistoryState Ready(DateTimeOffset updatedAt) => new(HistoryStateKind.Ready, 1, UpdatedAt: updatedAt);

    public static HistoryState Failed(string error) => new(HistoryStateKind.Failed, Error: error);
}

/// <summary>
/// Hub the history window reads from; the history service and previews publish here. Notifications are raised on the
/// synchronization context captured at construction (the UI thread).
/// </summary>
public sealed class HistoryHub
{
    private readonly SynchronizationContext? _context;

    public HistoryHub(SynchronizationContext? context = null)
    {
        _context = context ?? SynchronizationContext.Current;
    }

    public HistoryState State { get; private set; } = HistoryState.NotLoaded;

    /// <summary>Every stored day of every source, sorted by day then source.</summary>
    public IReadOnlyList<DailyUsage> Days { get; private set; } = [];

    public event EventHandler? Changed;

    public Action? RefreshHandler { get; set; }

    public Action? ClearHandler { get; set; }

    public void Publish(HistoryState state, IReadOnlyList<DailyUsage>? days = null) => Post(() =>
    {
        State = state;
        if (days is not null)
        {
            Days = days;
        }

        Changed?.Invoke(this, EventArgs.Empty);
    });

    public void Refresh() => RefreshHandler?.Invoke();

    public void Clear() => ClearHandler?.Invoke();

    private void Post(Action action)
    {
        if (_context is null || SynchronizationContext.Current == _context)
        {
            action();
        }
        else
        {
            _context.Post(static state => ((Action)state!)(), action);
        }
    }
}

public static class PreviewHistory
{
    /// <summary>Plausible history for previews and UI development.</summary>
    public static IReadOnlyList<DailyUsage> Days(DateTime? end = null, int count = 120)
    {
        var last = (end ?? DateTime.Now).Date;
        var random = new Random(42);
        // Source, base output, speed, models, and how many recent days it has data for (null: every day).
        (SourceKind Source, double Base, double Speed, string[] Models, int? RecentDays)[] profiles =
        [
            (SourceKind.Codex, 180_000, 42, ["gpt-6.1-sol", "gpt-6.1-sol-mini"], null),
            (SourceKind.ClaudeCode, 140_000, 70, ["claude-opus-5-5", "claude-sonnet-5-5"], null),
            (SourceKind.ClaudeDesktop, 260_000, 88, ["claude-opus-5-5"], null),
            (SourceKind.DeepSeek, 90_000, 150, ["deepseek-flash", "deepseek-pro"], null),
            (SourceKind.OpenCode, 60_000, 75, ["claude-opus-5-5"], 20),
            (SourceKind.Gemini, 40_000, 120, ["gemini-3-pro"], 0),
            (SourceKind.Omp, 70_000, 95, ["claude-opus-5-5", "gpt-5.5"], 45),
            (SourceKind.Antigravity, 50_000, 135, ["gemini-3.1-pro", "gemini-3.1-flash"], 30),
            (SourceKind.WorkBuddy, 45_000, 85, ["glm-5.3", "deepseek-v4-pro"], 14),
            (SourceKind.WorkBuddyAi, 30_000, 110, ["gpt-5.5", "hy4-preview"], 10),
        ];
        var result = new List<DailyUsage>();
        for (var offset = count - 1; offset >= 0; offset--)
        {
            var date = last.AddDays(-offset);
            var weekend = date.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday;
            foreach (var (source, baseOutput, speed, models, recentDays) in profiles)
            {
                if (recentDays is { } days && offset > days)
                {
                    continue;
                }

                if (random.NextDouble() < (weekend ? 0.45 : 0.12))
                {
                    continue;
                }

                var trend = 0.6 + 0.8 * (count - offset) / count;
                var output = (long)(baseOutput * trend * (0.4 + random.NextDouble() * 1.2));
                var requests = Math.Max(1, output / (long)(300 + random.NextDouble() * 500));
                var input = output * (long)(60 + random.NextDouble() * 90);
                var daySpeed = speed * (0.75 + random.NextDouble() * 0.5);
                var split = 0.55 + random.NextDouble() * 0.4;
                var measuredMs = (long)(output / daySpeed * 1000);
                // The first model takes a little more than its share of the time, so per-model speeds differ in previews.
                var firstOutput = (long)(output * split);
                var firstMs = (long)(measuredMs * Math.Min(0.98, split * 1.04));
                IReadOnlyList<ModelUsage> usage = models.Length == 1
                    ? [new ModelUsage(models[0], requests, output, output, measuredMs)]
                    : [
                        new ModelUsage(models[0], (long)(requests * split), firstOutput, firstOutput, firstMs),
                        new ModelUsage(models[1], requests - (long)(requests * split), output - firstOutput, output - firstOutput,
                            measuredMs - firstMs),
                    ];
                var totals = new TokenTotals(requests, input, (long)(input * 0.9), input / 40, output, output / 3);
                usage = [.. usage.Select(m => m with { Cost = PreviewCost(m, totals) })];
                var dayCost = usage.Aggregate(CostTally.Zero, (sum, m) => sum + m.Cost!.Value);
                result.Add(new DailyUsage(
                    date.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture),
                    source,
                    totals,
                    output,
                    measuredMs,
                    0,
                    1 + (int)(random.NextDouble() * 6),
                    offset < 30 ? daySpeed * (2 + random.NextDouble() * 3) : null,
                    usage)
                {
                    // A quarter of the oldest days predate costs, as after an upgrade whose logs are gone.
                    Cost = offset > count * 3 / 4 && (offset * 7 + (int)source) % 4 == 0 ? null : dayCost,
                    PriceVersion = Pricing.PriceBook.Bundled.Version,
                });
            }
        }

        return result;
    }

    /// <summary>A model's share of the day priced with the bundled table, one request at a time (METRICS 9.3).</summary>
    private static CostTally PreviewCost(ModelUsage model, TokenTotals totals)
    {
        var share = totals.Output > 0 ? (double)model.Output / totals.Output : 0;
        var requests = Math.Max(1, model.Requests);
        var tokens = new Parsing.TokenCounts(
            (long)(totals.Input * share) / requests,
            (long)(totals.CachedInput * share) / requests,
            (long)(totals.CacheWriteInput * share) / requests,
            model.Output / requests);
        return Pricing.PriceBook.Bundled.Cost(model.Model, null, tokens, null, fast: false) is { } each
            ? new CostTally(each * model.Requests)
            : new CostTally(UnpricedRequests: model.Requests);
    }
}

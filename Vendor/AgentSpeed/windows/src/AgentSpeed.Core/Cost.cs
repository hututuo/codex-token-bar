namespace AgentSpeed.Core;

/// <summary>Cost of today's or a day's responses (METRICS 9.6, 9.7): Σ known costs and the responses without a known price.</summary>
public readonly record struct CostTally(long CostMicroUsd = 0, long UnpricedRequests = 0)
{
    public static CostTally Zero => default;

    /// <summary>Adds (<paramref name="sign"/> 1) or removes (-1) one response's cost; null counts as unpriced.</summary>
    public CostTally Add(long? cost, int sign = 1, long requests = 1) => cost is { } value
        ? this with { CostMicroUsd = CostMicroUsd + sign * value }
        : this with { UnpricedRequests = UnpricedRequests + sign * requests };

    public static CostTally operator +(CostTally a, CostTally b) =>
        new(a.CostMicroUsd + b.CostMicroUsd, a.UnpricedRequests + b.UnpricedRequests);

    /// <summary>Nothing is priced although there were requests.</summary>
    public bool IsUnknown(long requests) => requests > 0 && UnpricedRequests >= requests;
}

/// <summary>
/// The live cost rate of a source, an agent or everything (METRICS 9.5): micro-USD per second, and the live output
/// (tok/s) that carries a known cost. Both are additive over sources.
/// </summary>
public readonly record struct LiveCost(double MicroUsdPerSecond = 0, double KnownOutput = 0)
{
    public static LiveCost Zero => default;

    public static LiveCost operator +(LiveCost a, LiveCost b) =>
        new(a.MicroUsdPerSecond + b.MicroUsdPerSecond, a.KnownOutput + b.KnownOutput);

    /// <summary><c>liveCostKnownShare</c> over <paramref name="liveOutput"/> tok/s: 1 when there is no live output.</summary>
    public double KnownShare(double liveOutput) => liveOutput > 0 ? Math.Min(1, KnownOutput / liveOutput) : 1;
}

public enum CostState
{
    /// <summary>Every live token has a known price (an idle 0 included).</summary>
    Priced,

    /// <summary>Part of the live value is missing: <c>liveCostKnownShare &lt; 0.995</c> and the value is not 0 (<c>≥</c>).</summary>
    Partial,

    /// <summary>Live output without any known price (<c>–</c>).</summary>
    NothingPriced,

    /// <summary>Every available source is a subscription and excluded (value 0).</summary>
    SubscriptionOnly,
}

/// <summary>
/// What a surface shows in the money unit for a source set (METRICS 6.8, 9.4, 9.5; DESIGN 9). Only the billable
/// sources count: the available members not marked as subscriptions (unless subscriptions are included).
/// </summary>
/// <param name="LiveOutput">Live output (tok/s) of the billable sources.</param>
/// <param name="Today">Today's cost of the billable sources.</param>
/// <param name="TodayRequests">Today's requests of the billable sources.</param>
/// <param name="UnpricedModels">Today's unpriced models of the billable sources, most unpriced first.</param>
/// <param name="Excluded">Available members left out as subscriptions, in source order.</param>
public sealed record CostReading(
    double MicroUsdPerSecond,
    double KnownShare,
    double LiveOutput,
    CostTally Today,
    long TodayRequests,
    IReadOnlyList<string> UnpricedModels,
    IReadOnlyList<SourceKind> Excluded,
    CostState State)
{
    public const double PartialThreshold = 0.995;

    public static CostReading Zero { get; } = new(0, 1, 0, CostTally.Zero, 0, [], [], CostState.Priced);
}

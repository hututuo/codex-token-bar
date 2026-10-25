namespace AgentSpeed.Core.Engine;

/// <param name="ParentId">The parent's id when the parent is listed too (METRICS 6.7).</param>
internal sealed record AgentFrame(AgentInfo Info, AgentPhase Phase, Rate Live, double? RecentSpeed, string? ParentId = null)
{
    /// <summary>The agent's live cost rate (METRICS 9.5).</summary>
    public LiveCost LiveCost { get; init; }
}

/// <summary>Everything the engine computes for one instant (METRICS 6).</summary>
/// <param name="SourceLiveEstimated">The estimated part of each <paramref name="SourceLive"/> (METRICS 6.3, 6.8).</param>
internal sealed record EngineFrame(
    long NowMs,
    Rate Live,
    double EstimatedShare,
    Rate[] SourceLive,
    Rate[] SourceLiveEstimated,
    Rate PeakToday,
    long? PeakTodayAtMs,
    double? AverageToday,
    TokenTotals Today,
    TokenTotals[] SourceToday,
    IReadOnlyList<AgentFrame> Agents,
    int GeneratingCount,
    int ToolsCount,
    IReadOnlyList<HistoryPoint> History,
    ResponseSummary? LastResponse,
    IReadOnlyList<SpeedEvent> Events,
    int UnfinalizedToday)
{
    public IReadOnlyList<ExecutionModeUsage> TodayModes { get; init; } = [];

    /// <summary>The live cost rate (METRICS 9.5) in total.</summary>
    public LiveCost LiveCost { get; init; }

    /// <summary>The live cost rate of each source, indexed by <see cref="SourceKind"/>.</summary>
    public LiveCost[] SourceLiveCost { get; init; } = [];

    /// <summary>Today's cost (METRICS 9.6) in total.</summary>
    public CostTally TodayCost { get; init; }

    /// <summary>Today's cost of each source, indexed by <see cref="SourceKind"/>.</summary>
    public CostTally[] SourceTodayCost { get; init; } = [];

    /// <summary>Each source's models with unpriced responses today, most unpriced first, then by name.</summary>
    public IReadOnlyList<string>[] SourceUnpricedModels { get; init; } = [];

    /// <summary>Live reporting's view of this instant (METRICS 11.2, 11.4).</summary>
    public Reporting.ReportLiveFacts Report { get; init; } = Reporting.ReportLiveFacts.Empty;
}

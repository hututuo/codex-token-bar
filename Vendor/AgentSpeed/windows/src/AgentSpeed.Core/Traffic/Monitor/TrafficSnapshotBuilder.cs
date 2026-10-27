using AgentSpeed.Core.Traffic.Engine;

namespace AgentSpeed.Core.Traffic.Monitor;

/// <summary>Builds the published <see cref="TrafficSnapshot"/> from the engine (METRICS 10.7, 10.8).</summary>
internal static class TrafficSnapshotBuilder
{
    private static readonly SourceKind[] AllSources = Enum.GetValues<SourceKind>();

    /// <param name="sourceHistory">Also copy the per-source sparkline buckets (only while something shows them).</param>
    public static TrafficSnapshot Build(TrafficEngine engine, long wallMs, ProcessTrafficState state, bool sourceHistory = false,
        string? processError = null)
    {
        var today = engine.Today();
        var sources = new Dictionary<SourceKind, SourceTraffic>();
        var histories = sourceHistory ? new Dictionary<SourceKind, IReadOnlyList<TrafficPoint>>() : null;
        var agents = new Dictionary<string, AgentTraffic>(StringComparer.Ordinal);
        if (state.IsAvailable)
        {
            foreach (var source in AllSources)
            {
                engine.SourceSeries.TryGetValue(source, out var series);
                today.Sources.TryGetValue(source, out var traffic);
                var live = series?.WithTools;
                if (traffic is null && (live?.Sum ?? 0) <= 0)
                {
                    continue;
                }

                sources[source] = new SourceTraffic(source, traffic?.Split ?? TrafficSplit.Zero, traffic?.Unassigned ?? TrafficBytes.Zero, live,
                    series?.SelfOnly);
                if (histories is not null)
                {
                    histories[source] = engine.SourceBuckets.TryGetValue(source, out var buckets) ? buckets.Points(wallMs) : TrafficBuckets.Empty(wallMs);
                }
            }

            foreach (var (root, split) in today.Agents)
            {
                engine.AgentSeries.TryGetValue(root, out var series);
                agents[root] = new AgentTraffic(root, split, series?.WithTools, series?.SelfOnly);
            }
        }

        return new TrafficSnapshot
        {
            Timestamp = DateTimeOffset.FromUnixTimeMilliseconds(wallMs),
            Enabled = true,
            MachineLive = engine.MachineRate,
            MachineToday = today.Machine,
            MachineSampledMs = today.MachineSampledMs,
            MachineHistory = engine.MachineBuckets.Points(wallMs),
            SourceHistory = histories ?? TrafficSnapshot.NoHistory,
            ProcessState = state,
            ProcessError = state.UnavailableReason is null ? null : processError,
            ProcessSampledMs = today.ProcessSampledMs,
            Sources = sources,
            Agents = agents,
            DayStart = engine.Ledger.Labeler.DayStart(wallMs),
            ReportTotals = engine.ReportTotals,
        };
    }
}

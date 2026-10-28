using AgentSpeed.Core;

namespace CodexTokenBar.AgentSpeedReporter;

internal static class LocalDisplaySnapshotBuilder
{
    private const double MaxTotalRate = 1_000_000_000.0;
    private static readonly TimeSpan AgentFreshness = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan SnapshotFreshness = TimeSpan.FromSeconds(3);

    public static AgentSpeedDisplaySnapshot Build(SpeedSnapshot snapshot, DateTimeOffset now)
    {
        if (snapshot.State.Kind == MonitorStateKind.Starting)
        {
            return AgentSpeedDisplaySnapshot.Empty("starting");
        }
        if (snapshot.State.Kind == MonitorStateKind.NoSources)
        {
            return AgentSpeedDisplaySnapshot.Empty("noSources");
        }
        var snapshotAge = now - snapshot.Timestamp;
        if (snapshotAge > SnapshotFreshness || snapshotAge < TimeSpan.FromSeconds(-2))
        {
            return AgentSpeedDisplaySnapshot.Empty("stale");
        }

        var contributions = new List<(string Model, string Client, double Rate)>();
        foreach (var agent in snapshot.Agents)
        {
            var activityAge = now - agent.LastActivity;
            if (agent.ConfirmedStopped
                || agent.Phase is not (AgentPhase.Generating or AgentPhase.Tools)
                || activityAge >= AgentFreshness
                || activityAge < TimeSpan.FromSeconds(-2)
                || !double.IsFinite(agent.Live.Output)
                || agent.Live.Output <= 0)
            {
                continue;
            }

            contributions.Add((agent.Model ?? string.Empty, "client:" + StatusProtocol.DisplaySourceId(agent.Source),
                Math.Min(agent.Live.Output, MaxTotalRate)));
        }

        var total = contributions.Sum(contribution => contribution.Rate);
        if (!double.IsFinite(total) || total <= 0)
        {
            return AgentSpeedDisplaySnapshot.Empty("idle", available: true);
        }

        var scale = total > MaxTotalRate ? MaxTotalRate / total : 1.0;
        var models = new SortedDictionary<string, double>(StringComparer.Ordinal);
        var clients = new SortedDictionary<string, double>(StringComparer.Ordinal);
        foreach (var contribution in contributions)
        {
            var rate = contribution.Rate * scale;
            models[contribution.Model] = models.GetValueOrDefault(contribution.Model) + rate;
            clients[contribution.Client] = clients.GetValueOrDefault(contribution.Client) + rate;
        }

        static IReadOnlyList<AgentSpeedDisplayRate> Rates(SortedDictionary<string, double> values) =>
            values.Where(pair => pair.Value > 0 && double.IsFinite(pair.Value))
                .Select(pair => new AgentSpeedDisplayRate(pair.Key, pair.Value))
                .ToArray();

        var modelRates = Rates(models);
        var clientRates = Rates(clients);
        var displayedTotal = modelRates.Sum(rate => rate.TokensPerSecond);
        return new AgentSpeedDisplaySnapshot(true, displayedTotal, modelRates, clientRates, "running",
            now.ToUnixTimeMilliseconds());
    }
}

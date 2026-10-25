using AgentSpeed.Core.Traffic.Engine;

namespace AgentSpeed.Core.Traffic.Monitor;

/// <summary>
/// The per-process sampling interval (METRICS 10.10): stopped while no agent process exists; every 5 s while agent
/// processes exist but no agent has been active for 60 s and nothing visible shows per-source or per-agent traffic;
/// else every second.
/// </summary>
internal static class TrafficCadence
{
    public const int FastInterval = 1;
    public const int SlowInterval = 5;
    public const long IdleAfterMs = 60_000;

    /// <summary>The interval in seconds, or null for standby; <paramref name="forced"/> (diagnostics) wins, 0 forcing standby.</summary>
    public static int? DesiredInterval(bool hasAgentProcess, long? lastActiveWallMs, long nowWallMs, bool detailDemand, int? forced)
    {
        if (forced is { } fixedInterval)
        {
            return fixedInterval > 0 ? fixedInterval : null;
        }

        if (!hasAgentProcess)
        {
            return null;
        }

        if (detailDemand)
        {
            return FastInterval;
        }

        return lastActiveWallMs is { } active && nowWallMs - active < IdleAfterMs ? FastInterval : SlowInterval;
    }

    /// <summary>The newest moment any agent was active (METRICS 10.6): working now, or its last line.</summary>
    public static long? LastActive(IEnumerable<TrafficAgent> agents, long nowWallMs)
    {
        long? newest = null;
        foreach (var agent in agents)
        {
            var moment = agent.Working ? nowWallMs : agent.LastLineMs;
            if (moment is { } m && (newest is null || m > newest))
            {
                newest = m;
            }
        }

        return newest;
    }
}

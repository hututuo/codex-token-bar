using AgentSpeed.Core.Traffic.Engine;

namespace AgentSpeed.Core.Traffic.Monitor;

/// <summary>
/// Measures network traffic (METRICS 10) and publishes it to a <see cref="TrafficHub"/>: this computer's interfaces
/// every second, per-process counters from the traffic helper while agent processes run, attributed to sources and
/// agent trees, and the stored daily totals. Thread-safe; the work runs on one background thread.
/// </summary>
public sealed class TrafficMonitor : IDisposable
{
    private readonly TrafficCore _core;

    private TrafficMonitor(TrafficCore core)
    {
        _core = core;
    }

    /// <summary>The Windows monitor (process table, interface counters and the helper connection).</summary>
    /// <param name="storePath">The history database (METRICS 10.9); null for the default.</param>
    public static TrafficMonitor CreateForWindows(TrafficHub hub, string? storePath = null, Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(hub);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("The traffic monitor samples Windows counters.");
        }

        var core = new TrafficCore(
            string.IsNullOrWhiteSpace(storePath) ? HistoryService.DefaultStorePath : Path.GetFullPath(storePath),
            TrafficPlatform.CurrentWindows(),
            new Windows.ProcessReader(),
            new Windows.MachineCounters(),
            Windows.CounterSources.Create(log),
            hub.Publish,
            hub.PublishDays,
            log);
        return new TrafficMonitor(core);
    }

    /// <summary>Loads the stored days and, when <paramref name="enabled"/> (<c>trafficEnabled</c>), starts sampling.</summary>
    public void Start(bool enabled) => _core.Start(enabled);

    /// <summary>Off stops sampling and the helper connection at once and publishes <see cref="TrafficSnapshot.Off"/>.</summary>
    public void SetEnabled(bool enabled) => _core.SetEnabled(enabled);

    /// <summary>The agents of every speed snapshot (METRICS 6.7): candidates for per-agent traffic and the adaptive cadence.</summary>
    public void UpdateAgents(IReadOnlyList<AgentStatus> agents) => _core.UpdateAgents(agents);

    /// <summary>True while a visible surface shows per-source or per-agent traffic (METRICS 10.10: sample every second).</summary>
    public void SetDetailDemand(bool shown) => _core.SetDetailDemand(shown);

    /// <summary>Retry after a helper failure, and after the helper was installed, updated or removed.</summary>
    public void Retry() => _core.Retry();

    /// <summary>
    /// Call right before the history store is deleted: today's totals restart at zero, no write is in flight, and the next
    /// write recreates today's rows in the new file.
    /// </summary>
    public void ClearHistory() => _core.ClearHistory();

    /// <summary>Writes today's totals now (before sleep).</summary>
    public void Flush() => _core.Flush();

    /// <summary>Diagnostics: a fixed per-process interval in seconds, 0 for standby, null for the adaptive cadence.</summary>
    public void SetForcedInterval(int? seconds) => _core.SetForcedInterval(seconds);

    /// <summary>Diagnostics: classified processes, attribution and the average tick cost.</summary>
    public TrafficDiagnostics Diagnostics() => _core.Diagnostics();

    /// <summary>At quit: writes today's totals and releases the helper connection before returning.</summary>
    public void Dispose() => _core.Dispose();
}

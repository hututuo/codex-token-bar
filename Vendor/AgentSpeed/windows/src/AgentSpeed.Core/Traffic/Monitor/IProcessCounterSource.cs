using AgentSpeed.Core.Traffic.Engine;

namespace AgentSpeed.Core.Traffic.Monitor;

/// <summary>Why a process-counter source has no data, or that it has (METRICS 10.3).</summary>
public enum ProcessCounterStatus
{
    /// <summary>Not asked to run (no agent process, or measuring is off).</summary>
    Idle,

    /// <summary>Connecting or starting; no sample yet.</summary>
    Starting,

    /// <summary>Delivering samples.</summary>
    Sampling,

    /// <summary>Windows: the helper service is not installed (or this user is not among its allowed users).</summary>
    HelperNotInstalled,

    /// <summary>Windows: the service could not be started or the connection failed; retried with backoff.</summary>
    HelperStopped,

    /// <summary>Windows: the installed helper is older than <c>minimumHelperVersion</c> or speaks no common protocol.</summary>
    HelperOutdated,

    /// <summary>Windows: the server failed verification (possible pipe squatting) or access was denied.</summary>
    HelperDenied,

    /// <summary>Windows: an unexpected error (see <see cref="IProcessCounterSource.LastError"/>).</summary>
    HelperError,

    /// <summary>macOS: nettop failed too often.</summary>
    SamplerFailed,
}

/// <summary>
/// A per-process counter sampler (macOS nettop, the Windows traffic helper) as the traffic core drives it: once per tick
/// on the traffic thread, never concurrently.
/// </summary>
internal interface IProcessCounterSource : IDisposable
{
    ProcessCounterStatus Status { get; }

    /// <summary>
    /// The current stream (METRICS 10.4.3): a new value whenever the counters start over (a new helper connection, a
    /// restarted sampler); in the first sample of a stream every process is a baseline.
    /// </summary>
    int Stream { get; }

    /// <summary>The last failure's text (Win32 message), for Settings; null when none.</summary>
    string? LastError { get; }

    /// <summary>
    /// One tick. <paramref name="active"/> false releases the source (the helper connection closes; the service stops by
    /// itself after 120 s). With <paramref name="fetch"/> a sample is requested now; returns the rows (a buffer reused by
    /// the next call) or null when there is none this tick.
    /// </summary>
    IReadOnlyList<CounterRow>? Poll(bool active, bool fetch, long nowMs);

    /// <summary>Settings → Retry (or a helper install): forget the backoff and try again at the next tick.</summary>
    void Retry();
}

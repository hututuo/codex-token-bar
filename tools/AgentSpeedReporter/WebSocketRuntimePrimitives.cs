using AgentSpeed.Core;
using AgentSpeed.Core.Reporting;

namespace CodexTokenBar.AgentSpeedReporter;

internal static class ReporterTransportChoice
{
    public static string? StartFailure(string? transport, bool supportsWebSocket) => transport switch
    {
        "http" => null,
        "websocket" when supportsWebSocket => null,
        "websocket" => "websocket_not_supported",
        _ => "reporting_failed",
    };

    public static bool UsesWebSocket(string transport) => transport == "websocket";
}

internal sealed class WebSocketReportWindow(ReportSample baseline)
{
    private ReportWindow _inner = new(baseline);

    public bool HasTokenIncrement(ReportSample sample) => _inner.HasTokenIncrement(sample);

    public void Observe(ReportSample sample, bool peaks = true) => _inner.Observe(sample, peaks);

    public ReportWindowContent Take(ReportSample sample) => _inner.Take(sample);

    public void DropAndRebase(ReportSample sample)
    {
        _inner.Discard(sample, keepingTick: false);
        _inner.Observe(sample, peaks: false);
    }

    public void ResetForReconnectOrResume(ReportSample sample) => _inner = new ReportWindow(sample);
}

/// <summary>One bounded accumulator for source reads that have not yet entered a report body.</summary>
internal sealed class SourceReadObservationBuffer
{
    private readonly object _gate = new();
    private SourceReadObservation? _earliest;

    public void Observe(SourceReadObservation? observation)
    {
        if (observation is null)
        {
            return;
        }

        lock (_gate)
        {
            _earliest = SourceReadObservation.MergeEarliest(_earliest, observation);
        }
    }

    public SourceReadObservation? Take()
    {
        lock (_gate)
        {
            var observation = _earliest;
            _earliest = null;
            return observation;
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            _earliest = null;
        }
    }
}

internal static class WebSocketConnectionGeneration
{
    private static long _current;

    public static long Next() => Interlocked.Increment(ref _current);
}

internal static class WebSocketRetryDelay
{
    private static readonly long[] BackoffMs = [500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000];

    public static long CalculateMilliseconds(int failureCount, int? retryAfterSeconds, double jitter)
    {
        var ordinary = (long)Math.Ceiling(
            BackoffMs[Math.Clamp(failureCount - 1, 0, BackoffMs.Length - 1)]
            * Math.Clamp(jitter, 0.8, 1.2));
        var retryDeadline = retryAfterSeconds is { } seconds
            ? Math.Clamp(seconds, 5, 3_600) * 1_000L
            : 0;
        return Math.Max(ordinary, retryDeadline);
    }
}

internal static class WebSocketAckMatcher
{
    public static bool Matches(
        WebSocketAck ack,
        string expectedRunId,
        int expectedSeq,
        string expectedHash,
        long pendingGeneration,
        long currentGeneration) =>
        pendingGeneration == currentGeneration
        && ack.RunId == expectedRunId
        && ack.Seq == expectedSeq
        && ack.BodySha256 == expectedHash;
}

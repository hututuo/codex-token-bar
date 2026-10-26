using System.IO;
using System.Net.Http;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
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

internal static class WebSocketFallbackPolicy
{
    public static bool ShouldFallbackToHttp(
        Exception error,
        bool cancellationRequested,
        int? retryAfterSeconds,
        bool sleepResumeDetected = false)
    {
        if (cancellationRequested || sleepResumeDetected || retryAfterSeconds is not null
            || Contains<OperationCanceledException>(error)
            || Contains<AuthenticationException>(error)
            || Contains<CryptographicException>(error)
            || Contains<SecurityException>(error)
            || Contains<InvalidDataException>(error)
            || Contains<DecoderFallbackException>(error)
            || Contains<ReporterFailure>(error))
        {
            return false;
        }

        if (error is WebSocketHandshakeException handshake)
        {
            // Retry-After can accompany any handshake response and must never be bypassed by HTTP.
            if (handshake.RetryAfterSeconds is not null)
            {
                return false;
            }

            return (int)handshake.StatusCode is 408 or 502 or 504;
        }

        if (error is HttpRequestException { StatusCode: { } httpStatus })
        {
            var code = (int)httpStatus;
            if (((code is >= 400 and < 500) && code != 408) || code == 503)
            {
                return false;
            }

            return code is 408 or 502 or 504;
        }

        if (error is ReportWebSocketCloseException close)
        {
            var code = (int?)close.CloseStatus;
            if (code is 4004 or 4009 or 4429 or 4503 or 1000 or 1002 or 1003 or 1007 or 1008 or 1009 or 1013)
            {
                return false;
            }

            return code is null or 1001 or 1006;
        }

        return error is TimeoutException or WebSocketException or HttpRequestException or IOException or SocketException;
    }

    private static bool Contains<TException>(Exception error) where TException : Exception
    {
        for (Exception? current = error; current is not null; current = current.InnerException)
        {
            if (current is TException)
            {
                return true;
            }
        }

        return false;
    }
}

internal static class WebSocketSleepResume
{
    public static bool IsDetected(TimeSpan wallElapsed, TimeSpan monotonicElapsed, TimeSpan threshold) =>
        wallElapsed - monotonicElapsed > threshold;
}

internal static class HttpFallbackStatus
{
    public static string MessageCode(bool fallbackOccurred, string currentCode) =>
        fallbackOccurred && (currentCode is "registering" or "reporting") ? "http_fallback" : currentCode;
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

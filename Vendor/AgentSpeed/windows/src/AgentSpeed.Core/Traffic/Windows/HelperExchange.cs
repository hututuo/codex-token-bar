using AgentSpeed.Core.Traffic.Helper;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>
/// The client half of the helper protocol over any transport (WINDOWS-SERVICE 4): one request, then exactly the header,
/// validated before any payload is read, then exactly the payload. Buffers are allocated once and reused.
/// </summary>
internal sealed class HelperExchange
{
    private readonly byte[] _request = new byte[HelperProtocol.RequestSize];
    private readonly byte[] _header = new byte[HelperProtocol.HeaderSize];
    private readonly byte[] _hello = new byte[HelperProtocol.HelloSize];
    private readonly HelperRequestLimiter _limiter = new();
    private byte[]? _snapshot;
    private uint _sequence;

    /// <summary>The Win32 error of the last failed call; 0 when it was a protocol violation.</summary>
    public int LastError { get; private set; }

    /// <summary>A short English description of the last failure, for the log.</summary>
    public string? LastProblem { get; private set; }

    /// <summary>The sequence number of the last request sent.</summary>
    public uint Sequence => _sequence;

    public HelperCallResult Hello(IHelperTransport transport, long nowMs, out HelperHello hello, out ulong epoch)
    {
        hello = default;
        var result = Send(transport, nowMs, HelperRequestType.Hello, out var header);
        epoch = header.Epoch;
        return result is HelperCallResult.Ok or HelperCallResult.UnsupportedVersion
            ? ReadHello(transport, header, out hello, result)
            : result;
    }

    public HelperCallResult Snapshot(IHelperTransport transport, long nowMs, List<HelperEntry> entries, out ulong epoch)
    {
        ArgumentNullException.ThrowIfNull(entries);
        entries.Clear();
        var result = Send(transport, nowMs, HelperRequestType.Snapshot, out var header);
        epoch = header.Epoch;
        if (result == HelperCallResult.UnsupportedVersion)
        {
            return ReadHello(transport, header, out _, result);
        }

        if (result != HelperCallResult.Ok)
        {
            return result;
        }

        var length = (int)header.PayloadLength;
        if (length < HelperProtocol.SnapshotHeaderSize)
        {
            return Fail(0, "snapshot without payload");
        }

        _snapshot ??= new byte[HelperProtocol.MaxSnapshotPayload];
        var payload = _snapshot.AsSpan(0, length);
        var error = transport.ReadExactly(payload);
        if (error != 0)
        {
            return Fail(error, "snapshot payload read failed");
        }

        return HelperSnapshot.TryParse(payload, entries, out _)
            ? HelperCallResult.Ok
            : Fail(0, "malformed snapshot payload");
    }

    private HelperCallResult Send(IHelperTransport transport, long nowMs, HelperRequestType type, out HelperResponseHeader header)
    {
        header = default;
        if (!_limiter.TryAcquire(nowMs))
        {
            LastError = 0;
            LastProblem = "client rate limit";
            return HelperCallResult.RateLimited;
        }

        var sequence = unchecked(++_sequence);
        new HelperRequest(HelperProtocol.Version, type, sequence).Write(_request);
        var error = transport.Write(_request);
        if (error != 0)
        {
            return Fail(error, "request write failed");
        }

        error = transport.ReadExactly(_header);
        if (error != 0)
        {
            return Fail(error, "response header read failed");
        }

        if (!HelperResponseHeader.TryParse(_header, type, sequence, out header))
        {
            return Fail(0, "malformed response header");
        }

        switch (header.Status)
        {
            case HelperStatusCode.Ok:
                return HelperCallResult.Ok;
            case HelperStatusCode.UnsupportedVersion:
                return HelperCallResult.UnsupportedVersion;
            case HelperStatusCode.RateLimited when header.PayloadLength == 0:
                LastError = 0;
                LastProblem = "rate limited by the helper";
                return HelperCallResult.RateLimited;
            default:
                return Fail(0, $"helper answered {header.Status}");
        }
    }

    private HelperCallResult ReadHello(IHelperTransport transport, HelperResponseHeader header, out HelperHello hello, HelperCallResult success)
    {
        hello = default;
        if (header.PayloadLength != HelperProtocol.HelloSize)
        {
            return Fail(0, "hello without payload");
        }

        var error = transport.ReadExactly(_hello);
        if (error != 0)
        {
            return Fail(error, "hello payload read failed");
        }

        return HelperHello.TryParse(_hello, out hello) ? success : Fail(0, "malformed hello payload");
    }

    private HelperCallResult Fail(int error, string problem)
    {
        LastError = error;
        LastProblem = problem;
        return HelperCallResult.Failed;
    }
}

using AgentSpeed.Core.Traffic.Helper;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>The SCM and registry side the sampler needs; <see cref="HelperServiceControl"/> on Windows, fakes in tests.</summary>
internal interface IHelperService
{
    HelperServiceInfo Query();

    /// <summary>Non-blocking start; 0 or the Win32 error.</summary>
    int Start();

    /// <summary>Non-blocking stop; 0 or the Win32 error.</summary>
    int Stop();
}

/// <summary>The outcome of opening and verifying the pipe.</summary>
internal enum HelperConnectResult
{
    Connected,

    /// <summary>The pipe does not exist yet or all instances are busy: try again soon.</summary>
    NotReady,

    /// <summary>Access denied, or the server failed verification (possible pipe squatting).</summary>
    Denied,

    /// <summary>Any other failure (see <see cref="IHelperConnection.LastError"/>).</summary>
    Failed,
}

/// <summary>The outcome of one request.</summary>
internal enum HelperCallResult
{
    Ok,

    /// <summary>The helper does not speak this protocol version; the hello payload says which it does.</summary>
    UnsupportedVersion,

    /// <summary>Too many requests (locally or by the server): try again next tick, the connection stays.</summary>
    RateLimited,

    /// <summary>I/O error, timeout, malformed or refused response: the connection is closed.</summary>
    Failed,
}

/// <summary>One verified connection to the helper (WINDOWS-SERVICE 4); reusable after <see cref="Close"/>.</summary>
internal interface IHelperConnection : IDisposable
{
    bool IsOpen { get; }

    /// <summary>The Win32 error of the last failure (0 for protocol violations).</summary>
    int LastError { get; }

    /// <summary>Opens the pipe and verifies the server before anything is read.</summary>
    HelperConnectResult Connect();

    HelperCallResult Hello(long nowMs, out HelperHello hello, out ulong epoch);

    /// <summary>Fills <paramref name="entries"/> (cleared first) with one snapshot.</summary>
    HelperCallResult Snapshot(long nowMs, List<HelperEntry> entries, out ulong epoch);

    void Close();
}

/// <summary>A byte-mode duplex transport with bounded waits; 0 or a Win32 error.</summary>
internal interface IHelperTransport
{
    int Write(ReadOnlySpan<byte> data);

    /// <summary>Reads exactly <c>data.Length</c> bytes or fails (timeout, broken pipe).</summary>
    int ReadExactly(Span<byte> data);
}

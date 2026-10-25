using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using AgentSpeed.Core.Traffic.Helper;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>
/// A verified connection to the traffic helper (WINDOWS-SERVICE 4): the server must be the running
/// <c>AgentSpeedTraffic</c> service's process, started from the install location, before a single byte is read.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class HelperClient : IHelperConnection
{
    private const int MaxImagePath = 1024;

    private readonly HelperExchange _exchange = new();
    private readonly Action<string>? _log;
    private HelperPipe? _pipe;

    public HelperClient(Action<string>? log = null)
    {
        _log = log;
    }

    public bool IsOpen => _pipe is not null;

    public int LastError { get; private set; }

    /// <summary>The expected server image: <c>%ProgramFiles%\Agent Speed\Traffic Helper\AgentSpeedTrafficHelper.exe</c>.</summary>
    public static string? ExpectedImagePath()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        return string.IsNullOrEmpty(programFiles) ? null : HelperProtocol.InstallPath(programFiles);
    }

    public HelperConnectResult Connect()
    {
        Close();
        var error = HelperPipe.Open(out var pipe);
        if (pipe is null)
        {
            LastError = error;
            return error switch
            {
                HelperNative.ErrorFileNotFound or HelperNative.ErrorPipeBusy => HelperConnectResult.NotReady,
                HelperNative.ErrorAccessDenied => HelperConnectResult.Denied,
                _ => HelperConnectResult.Failed,
            };
        }

        if (!Verify(pipe))
        {
            pipe.Dispose();
            LastError = HelperNative.ErrorAccessDenied;
            return HelperConnectResult.Denied;
        }

        LastError = 0;
        _pipe = pipe;
        return HelperConnectResult.Connected;
    }

    public HelperCallResult Hello(long nowMs, out HelperHello hello, out ulong epoch)
    {
        hello = default;
        epoch = 0;
        return _pipe is null ? NotOpen() : Finish(_exchange.Hello(_pipe, nowMs, out hello, out epoch));
    }

    public HelperCallResult Snapshot(long nowMs, List<HelperEntry> entries, out ulong epoch)
    {
        epoch = 0;
        return _pipe is null ? NotOpen() : Finish(_exchange.Snapshot(_pipe, nowMs, entries, out epoch));
    }

    public void Close()
    {
        _pipe?.Dispose();
        _pipe = null;
    }

    public void Dispose() => Close();

    private HelperCallResult Finish(HelperCallResult result)
    {
        if (result == HelperCallResult.Failed)
        {
            LastError = _exchange.LastError;
            _log?.Invoke($"Traffic helper: {_exchange.LastProblem} (error {_exchange.LastError}).");
            Close();
        }

        return result;
    }

    private HelperCallResult NotOpen()
    {
        LastError = HelperNative.ErrorInvalidHandle;
        return HelperCallResult.Failed;
    }

    private bool Verify(HelperPipe pipe)
    {
        if (!HelperNative.GetNamedPipeServerProcessId(pipe.Handle, out var serverPid))
        {
            _log?.Invoke($"Traffic helper: cannot identify the pipe server (error {Marshal.GetLastPInvokeError()}); possible pipe squatting.");
            return false;
        }

        var (state, servicePid, _) = HelperServiceControl.QueryStatus();
        if (state != HelperServiceState.Running || servicePid <= 0 || (uint)servicePid != serverPid)
        {
            _log?.Invoke($"Traffic helper: pipe server pid {serverPid} is not the service (state {state}, pid {servicePid}); possible pipe squatting.");
            return false;
        }

        var expected = ExpectedImagePath();
        var image = ImagePath(serverPid, out var error);
        if (expected is null || image is null || !string.Equals(image, expected, StringComparison.OrdinalIgnoreCase))
        {
            _log?.Invoke(image is null
                ? $"Traffic helper: cannot read the image of pid {serverPid} (error {error}); possible pipe squatting."
                : $"Traffic helper: pid {serverPid} does not run from the install location; possible pipe squatting.");
            return false;
        }

        var (stateAfter, pidAfter, _) = HelperServiceControl.QueryStatus();
        if (stateAfter != HelperServiceState.Running || pidAfter != servicePid)
        {
            _log?.Invoke($"Traffic helper: the service changed during verification (pid {servicePid} -> {pidAfter}); possible pipe squatting.");
            return false;
        }

        return true;
    }

    private static unsafe string? ImagePath(uint processId, out int error)
    {
        using var process = HelperNative.OpenProcess(HelperNative.ProcessQueryLimitedInformation, inherit: false, processId);
        if (process.IsInvalid)
        {
            error = Marshal.GetLastPInvokeError();
            return null;
        }

        var buffer = stackalloc char[MaxImagePath];
        var size = (uint)MaxImagePath;
        if (!HelperNative.QueryFullProcessImageName(process, 0, buffer, ref size) || size == 0 || size >= MaxImagePath)
        {
            error = Marshal.GetLastPInvokeError();
            return null;
        }

        error = 0;
        return new string(buffer, 0, (int)size);
    }
}

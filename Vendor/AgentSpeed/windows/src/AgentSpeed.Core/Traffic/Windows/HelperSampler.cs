using System.ComponentModel;
using System.Runtime.Versioning;
using AgentSpeed.Core.Traffic.Engine;
using AgentSpeed.Core.Traffic.Helper;
using AgentSpeed.Core.Traffic.Monitor;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>
/// The Windows per-process counter source (METRICS 10.3, WINDOWS-SERVICE 6): one tick at a time it checks the installed
/// helper, starts the service when needed, connects, verifies and says hello (a new stream), then turns snapshots into
/// counter rows. Failures retry after 1, 2, 4 … 60 s. Never concurrent: the traffic core drives it from one thread.
/// </summary>
internal sealed class HelperSampler : IProcessCounterSource
{
    /// <summary>How often the installation is re-read while not sampling (inactive, not installed, outdated).</summary>
    public const long QueryIntervalMs = 30_000;

    /// <summary>How long a start (service state, then the pipe) may take before giving up.</summary>
    public const long StartTimeoutMs = 10_000;

    /// <summary>A hello at least this often while connected but not fetching (the server drops silent clients after 60 s).</summary>
    public const long KeepAliveMs = 30_000;

    public const long FirstBackoffMs = 1_000;
    public const long MaxBackoffMs = 60_000;

    private readonly IHelperService _service;
    private readonly IHelperConnection _connection;
    private readonly Action<string>? _log;
    private readonly List<HelperEntry> _entries = new(256);
    private readonly List<CounterRow> _rows = new(256);

    private bool _connected;
    private ulong _epoch;
    private long _lastRequestMs;
    private long? _retryAtMs;
    private long _backoffMs = FirstBackoffMs;
    private long? _queryAtMs;
    private bool _active;
    private bool _startIssued;
    private long? _pendingSinceMs;
    private bool _stopIssued;

    /// <summary>A hello reported a helper older than the minimum although the registry did not: never start it again.</summary>
    private bool _binaryOutdated;

    internal HelperSampler(IHelperService service, IHelperConnection connection, Action<string>? log = null)
    {
        _service = service;
        _connection = connection;
        _log = log;
    }

    public ProcessCounterStatus Status { get; private set; } = ProcessCounterStatus.Idle;

    public int Stream { get; private set; }

    public string? LastError { get; private set; }

    /// <summary>The real sampler: the SCM, the registry and the verified pipe.</summary>
    [SupportedOSPlatform("windows")]
    public static HelperSampler CreateWindows(Action<string>? log) => new(new WindowsHelperService(), new HelperClient(log), log);

    public IReadOnlyList<CounterRow>? Poll(bool active, bool fetch, long nowMs)
    {
        if (!active)
        {
            PollInactive(nowMs);
            return null;
        }

        if (!_active)
        {
            _active = true;
            _queryAtMs = null;
        }

        if (_connected)
        {
            return PollConnected(fetch, nowMs);
        }

        if (_retryAtMs is { } retryAt && nowMs < retryAt || _queryAtMs is { } queryAt && nowMs < queryAt)
        {
            return null;
        }

        _queryAtMs = null;
        _retryAtMs = null;
        var info = _service.Query();
        if (!IsUsable(info, nowMs))
        {
            return null;
        }

        switch (info.State)
        {
            case HelperServiceState.Running:
                return Connect(fetch, nowMs);
            case HelperServiceState.Stopped:
                StartService(nowMs);
                return null;
            case HelperServiceState.Unknown:
                Fail(info.Win32Error == HelperNative.ErrorAccessDenied ? ProcessCounterStatus.HelperDenied : ProcessCounterStatus.HelperError,
                    info.Win32Error, "the service manager cannot be asked", nowMs);
                return null;
            default:
                WaitForStart(nowMs);
                return null;
        }
    }

    public void Retry()
    {
        _retryAtMs = null;
        _backoffMs = FirstBackoffMs;
        _queryAtMs = null;
        _startIssued = false;
        _pendingSinceMs = null;
        _stopIssued = false;
        _binaryOutdated = false;
    }

    public void Dispose()
    {
        Disconnect();
        _connection.Dispose();
    }

    private void PollInactive(long nowMs)
    {
        if (_active || _connection.IsOpen)
        {
            Disconnect();
            _active = false;
            _queryAtMs = null;
            _startIssued = false;
            _pendingSinceMs = null;
        }

        if (_queryAtMs is { } queryAt && nowMs < queryAt)
        {
            return;
        }

        _queryAtMs = nowMs + QueryIntervalMs;
        var info = _service.Query();
        if (!info.IsInstalledForCurrentUser)
        {
            SetStatus(ProcessCounterStatus.HelperNotInstalled, null);
        }
        else if (info.IsOutdated || _binaryOutdated)
        {
            SetStatus(ProcessCounterStatus.HelperOutdated, null);
            StopOutdated(info);
        }
        else
        {
            SetStatus(ProcessCounterStatus.Idle, null);
        }
    }

    /// <summary>Not installed for this user, or outdated: report it, re-check every 30 s, never start it.</summary>
    private bool IsUsable(HelperServiceInfo info, long nowMs)
    {
        if (!info.IsInstalledForCurrentUser)
        {
            SetStatus(ProcessCounterStatus.HelperNotInstalled, null);
            _queryAtMs = nowMs + QueryIntervalMs;
            return false;
        }

        if (info.IsOutdated || _binaryOutdated)
        {
            SetStatus(ProcessCounterStatus.HelperOutdated, null);
            StopOutdated(info);
            _queryAtMs = nowMs + QueryIntervalMs;
            return false;
        }

        return true;
    }

    private void StopOutdated(HelperServiceInfo info)
    {
        if (info.State is HelperServiceState.Running or HelperServiceState.StartPending)
        {
            StopOnce();
        }
    }

    /// <summary>Stops the outdated service once (the user holds SERVICE_STOP); it is never started again.</summary>
    private void StopOnce()
    {
        if (_stopIssued)
        {
            return;
        }

        _stopIssued = true;
        var error = _service.Stop();
        _log?.Invoke(error == 0
            ? "Traffic helper: stopped the outdated helper service."
            : $"Traffic helper: could not stop the outdated helper service (error {error}).");
    }

    private void StartService(long nowMs)
    {
        if (!_startIssued)
        {
            _startIssued = true;
            _pendingSinceMs ??= nowMs;
            var error = _service.Start();
            if (error != 0)
            {
                Fail(error == HelperNative.ErrorAccessDenied ? ProcessCounterStatus.HelperDenied : ProcessCounterStatus.HelperStopped,
                    error, "the service could not be started", nowMs);
                return;
            }

            SetStatus(ProcessCounterStatus.Starting, null);
            return;
        }

        WaitForStart(nowMs);
    }

    private void WaitForStart(long nowMs)
    {
        _pendingSinceMs ??= nowMs;
        if (nowMs - _pendingSinceMs.Value >= StartTimeoutMs)
        {
            Fail(ProcessCounterStatus.HelperStopped, 0, "the service did not start", nowMs);
            return;
        }

        SetStatus(ProcessCounterStatus.Starting, null);
    }

    private IReadOnlyList<CounterRow>? Connect(bool fetch, long nowMs)
    {
        switch (_connection.Connect())
        {
            case HelperConnectResult.NotReady:
                WaitForStart(nowMs);
                return null;
            case HelperConnectResult.Denied:
                Fail(ProcessCounterStatus.HelperDenied, _connection.LastError, "the helper failed verification or denied access", nowMs);
                return null;
            case HelperConnectResult.Failed:
                Fail(ProcessCounterStatus.HelperError, _connection.LastError, "the helper pipe could not be opened", nowMs);
                return null;
        }

        var result = _connection.Hello(nowMs, out var hello, out var epoch);
        _lastRequestMs = nowMs;
        if (result == HelperCallResult.Ok && !SharesProtocol(hello))
        {
            result = HelperCallResult.UnsupportedVersion;
        }

        if (result == HelperCallResult.Ok && hello.Version < HelperProtocol.MinimumVersion)
        {
            // The running binary is older than its registry entry claims (WINDOWS-SERVICE 5, minimumHelperVersion).
            _binaryOutdated = true;
            _log?.Invoke($"Traffic helper: the running helper is {hello.Version}, older than the minimum {HelperProtocol.MinimumVersion}.");
            Outdated(nowMs);
            StopOnce();
            return null;
        }

        switch (result)
        {
            case HelperCallResult.Ok:
                _connected = true;
                _epoch = epoch;
                Stream++;
                _startIssued = false;
                _pendingSinceMs = null;
                _log?.Invoke($"Traffic helper: connected to helper {hello.Version} (stream {Stream}).");
                SetStatus(ProcessCounterStatus.Starting, null);
                return fetch ? Fetch(nowMs) : null;
            case HelperCallResult.UnsupportedVersion:
                Outdated(nowMs);
                return null;
            default:
                Lost(nowMs);
                return null;
        }
    }

    private IReadOnlyList<CounterRow>? PollConnected(bool fetch, long nowMs)
    {
        if (!_connection.IsOpen)
        {
            Lost(nowMs);
            return null;
        }

        if (fetch)
        {
            return Fetch(nowMs);
        }

        if (nowMs - _lastRequestMs < KeepAliveMs)
        {
            return null;
        }

        var result = _connection.Hello(nowMs, out _, out var epoch);
        _lastRequestMs = nowMs;
        switch (result)
        {
            case HelperCallResult.Ok:
                NoteEpoch(epoch);
                break;
            case HelperCallResult.RateLimited:
                break;
            case HelperCallResult.UnsupportedVersion:
                Outdated(nowMs);
                break;
            default:
                Lost(nowMs);
                break;
        }

        return null;
    }

    private IReadOnlyList<CounterRow>? Fetch(long nowMs)
    {
        var result = _connection.Snapshot(nowMs, _entries, out var epoch);
        _lastRequestMs = nowMs;
        switch (result)
        {
            case HelperCallResult.Ok:
                NoteEpoch(epoch);
                _rows.Clear();
                foreach (var entry in _entries)
                {
                    _rows.Add(new CounterRow(
                        ProcessIdentity.FromFileTime(entry.Pid, entry.CreateTime),
                        new TrafficCounter((long)entry.Rx, (long)entry.Tx)));
                }

                _backoffMs = FirstBackoffMs;
                SetStatus(ProcessCounterStatus.Sampling, null);
                return _rows;
            case HelperCallResult.RateLimited:
                return null;
            case HelperCallResult.UnsupportedVersion:
                Outdated(nowMs);
                return null;
            default:
                Lost(nowMs);
                return null;
        }
    }

    /// <summary>A new epoch means the service started over: its counters are a new stream (METRICS 10.4.3).</summary>
    private void NoteEpoch(ulong epoch)
    {
        if (epoch == _epoch)
        {
            return;
        }

        _epoch = epoch;
        Stream++;
        _log?.Invoke($"Traffic helper: new service epoch (stream {Stream}).");
    }

    private static bool SharesProtocol(HelperHello hello) =>
        Math.Max(hello.MinProtocol, HelperProtocol.MinVersion) <= Math.Min(hello.MaxProtocol, HelperProtocol.MaxVersion);

    private void Outdated(long nowMs)
    {
        Disconnect();
        SetStatus(ProcessCounterStatus.HelperOutdated, null);
        _queryAtMs = nowMs + QueryIntervalMs;
    }

    private void Lost(long nowMs) =>
        Fail(ProcessCounterStatus.HelperStopped, _connection.LastError, "the helper connection failed", nowMs);

    private void Fail(ProcessCounterStatus status, int error, string what, long nowMs)
    {
        Disconnect();
        _startIssued = false;
        _pendingSinceMs = null;
        var detail = error != 0 ? $"{new Win32Exception(error).Message} ({error})" : null;
        SetStatus(status, detail ?? what);
        _retryAtMs = nowMs + _backoffMs;
        _log?.Invoke($"Traffic helper: {what}{(error != 0 ? $" (error {error})" : "")}; retrying in {_backoffMs / 1000} s.");
        _backoffMs = Math.Min(_backoffMs * 2, MaxBackoffMs);
    }

    private void Disconnect()
    {
        _connected = false;
        if (_connection.IsOpen)
        {
            _connection.Close();
        }
    }

    private void SetStatus(ProcessCounterStatus status, string? error)
    {
        LastError = error;
        if (status == Status)
        {
            return;
        }

        Status = status;
        if (status is ProcessCounterStatus.HelperNotInstalled or ProcessCounterStatus.HelperOutdated or ProcessCounterStatus.Sampling)
        {
            _log?.Invoke($"Traffic helper: {status}.");
        }
    }
}

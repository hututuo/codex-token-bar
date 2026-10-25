using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security;
using System.Security.Principal;
using AgentSpeed.Core.Traffic.Helper;
using Microsoft.Win32;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>
/// The helper service as an unprivileged user sees it (WINDOWS-SERVICE 2, 6): the SCM state through
/// <c>SERVICE_QUERY_STATUS</c>, the registry key, and start / stop with the rights each allowed user holds.
/// </summary>
[SupportedOSPlatform("windows")]
public static class HelperServiceControl
{
    private const string ServicesKey = @"SYSTEM\CurrentControlSet\Services\" + HelperProtocol.ServiceName;
    private const int MaxAllowedUsers = 256;
    private const int MaxSidLength = 184;

    /// <summary>Everything the app may show about the installed helper; never throws.</summary>
    public static HelperServiceInfo Query()
    {
        var (state, processId, error) = QueryStatus();
        if (state == HelperServiceState.Missing)
        {
            return HelperServiceInfo.NotInstalled;
        }

        ReadRegistry(out var version, out var protocol, out var allowed, out var imagePath);
        var user = CurrentUserSid();
        var currentAllowed = user is not null && allowed.Any(sid => string.Equals(sid, user, StringComparison.OrdinalIgnoreCase));
        return new HelperServiceInfo(state, processId, imagePath, version, protocol, allowed, currentAllowed, error);
    }

    /// <summary><c>StartService</c> without waiting; returns 0 (also when already running) or the Win32 error.</summary>
    public static int Start()
    {
        using var service = Open(HelperNative.ServiceStart, out var error);
        if (service is null)
        {
            return error;
        }

        if (HelperNative.StartService(service, 0, 0))
        {
            return 0;
        }

        error = Marshal.GetLastPInvokeError();
        return error == HelperNative.ErrorServiceAlreadyRunning ? 0 : error;
    }

    /// <summary><c>ControlService(STOP)</c> without waiting; returns 0 (also when not running) or the Win32 error.</summary>
    public static int Stop()
    {
        using var service = Open(HelperNative.ServiceStop, out var error);
        if (service is null)
        {
            return error;
        }

        if (HelperNative.ControlService(service, HelperNative.ServiceControlStop, out _))
        {
            return 0;
        }

        error = Marshal.GetLastPInvokeError();
        return error == HelperNative.ErrorServiceNotActive ? 0 : error;
    }

    /// <summary>The SCM state and process id only (the client's server verification).</summary>
    internal static (HelperServiceState State, int ProcessId, int Error) QueryStatus()
    {
        using var service = Open(HelperNative.ServiceQueryStatus, out var error);
        if (service is null)
        {
            return error == HelperNative.ErrorServiceDoesNotExist
                ? (HelperServiceState.Missing, 0, 0)
                : (HelperServiceState.Unknown, 0, error);
        }

        if (!HelperNative.QueryServiceStatusEx(
                service, HelperNative.ScStatusProcessInfo, out var status, (uint)Marshal.SizeOf<HelperNative.ServiceStatusProcess>(), out _))
        {
            return (HelperServiceState.Unknown, 0, Marshal.GetLastPInvokeError());
        }

        var state = status.CurrentState switch
        {
            HelperNative.ServiceStopped => HelperServiceState.Stopped,
            HelperNative.ServiceStartPending => HelperServiceState.StartPending,
            HelperNative.ServiceStopPending => HelperServiceState.StopPending,
            HelperNative.ServiceRunning => HelperServiceState.Running,
            _ => HelperServiceState.Other,
        };
        var processId = state == HelperServiceState.Running && status.ProcessId is > 0 and <= int.MaxValue ? (int)status.ProcessId : 0;
        return (state, processId, 0);
    }

    /// <summary>The current user's SID string, or null when it cannot be read.</summary>
    internal static string? CurrentUserSid()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            return identity.User?.Value;
        }
        catch (SecurityException)
        {
            return null;
        }
    }

    private static SafeServiceHandle? Open(uint access, out int error)
    {
        using var manager = HelperNative.OpenSCManager(0, 0, HelperNative.ScManagerConnect);
        if (manager.IsInvalid)
        {
            error = Marshal.GetLastPInvokeError();
            return null;
        }

        var service = HelperNative.OpenService(manager, HelperProtocol.ServiceName, access);
        if (service.IsInvalid)
        {
            error = Marshal.GetLastPInvokeError();
            service.Dispose();
            return null;
        }

        error = 0;
        return service;
    }

    private static void ReadRegistry(out HelperVersion? version, out uint? protocol, out IReadOnlyList<string> allowed, out string? imagePath)
    {
        version = null;
        protocol = null;
        allowed = [];
        imagePath = null;
        try
        {
            using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using (var key = machine.OpenSubKey(HelperProtocol.RegistryKey))
            {
                if (key is not null)
                {
                    if (key.GetValue("Version") is string text && HelperVersion.TryParse(text, out var parsed))
                    {
                        version = parsed;
                    }

                    if (key.GetValue("Protocol") is int value)
                    {
                        protocol = unchecked((uint)value);
                    }

                    if (key.GetValue("AllowedUsers") is string[] users)
                    {
                        allowed = [.. users.Where(IsSidText).Take(MaxAllowedUsers)];
                    }
                }
            }

            using var service = machine.OpenSubKey(ServicesKey);
            imagePath = service?.GetValue("ImagePath") as string;
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or IOException)
        {
        }
    }

    private static bool IsSidText(string? text) =>
        text is { Length: > 4 and <= MaxSidLength } && text.StartsWith("S-1-", StringComparison.OrdinalIgnoreCase)
        && text.AsSpan(4).IndexOfAnyExcept("0123456789-") < 0;
}

using AgentSpeed.Core.Traffic.Helper;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>The SCM state of the helper service.</summary>
public enum HelperServiceState
{
    /// <summary>No such service.</summary>
    Missing,

    Stopped,
    StartPending,
    StopPending,
    Running,

    /// <summary>Paused or a pending pause/continue (the helper never accepts them).</summary>
    Other,

    /// <summary>The SCM could not be asked (see <see cref="HelperServiceInfo.Win32Error"/>).</summary>
    Unknown,
}

/// <summary>What the app can learn about the installed helper without privileges (WINDOWS-SERVICE 2, 6).</summary>
/// <param name="ProcessId">The running service's process id; 0 unless running.</param>
/// <param name="ImagePath">The service's configured ImagePath (registry), for display only.</param>
/// <param name="Version">The installed helper version (<c>Version</c> registry value); null when absent or malformed.</param>
/// <param name="Protocol">The highest protocol version the installed helper speaks (<c>Protocol</c>); null when absent.</param>
/// <param name="AllowedUsers">The SIDs of <c>AllowedUsers</c>; empty when the key is absent.</param>
/// <param name="CurrentUserAllowed">True when the current user's SID is among <paramref name="AllowedUsers"/>.</param>
/// <param name="Win32Error">The SCM error when <paramref name="State"/> is <see cref="HelperServiceState.Unknown"/>, else 0.</param>
public sealed record HelperServiceInfo(
    HelperServiceState State,
    int ProcessId,
    string? ImagePath,
    HelperVersion? Version,
    uint? Protocol,
    IReadOnlyList<string> AllowedUsers,
    bool CurrentUserAllowed,
    int Win32Error)
{
    public static HelperServiceInfo NotInstalled { get; } = new(HelperServiceState.Missing, 0, null, null, null, [], false, 0);

    public bool Exists => State != HelperServiceState.Missing;

    /// <summary>The service exists and this user approved it (is in <c>AllowedUsers</c>).</summary>
    public bool IsInstalledForCurrentUser => Exists && CurrentUserAllowed;

    /// <summary>
    /// Older than <see cref="HelperProtocol.MinimumVersion"/>, speaking no protocol the app supports, or with an unreadable
    /// version: the app never starts it (WINDOWS-SERVICE 5).
    /// </summary>
    public bool IsOutdated => Version is not { } version || version < HelperProtocol.MinimumVersion
        || Protocol is not { } protocol || protocol < HelperProtocol.MinVersion;

    /// <summary>The installed version is older than the one this app bundles (offer <c>traffic.helper.update</c>).</summary>
    public bool IsOlderThanBundled => Version is { } version && version < HelperProtocol.BundledVersion;
}

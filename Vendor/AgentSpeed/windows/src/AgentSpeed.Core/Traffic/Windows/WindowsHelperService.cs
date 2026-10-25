using System.Runtime.Versioning;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary><see cref="IHelperService"/> over the real SCM and registry.</summary>
[SupportedOSPlatform("windows")]
internal sealed class WindowsHelperService : IHelperService
{
    public HelperServiceInfo Query() => HelperServiceControl.Query();

    public int Start() => HelperServiceControl.Start();

    public int Stop() => HelperServiceControl.Stop();
}

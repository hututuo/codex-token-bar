using System.Runtime.Versioning;
using AgentSpeed.Core.Traffic.Monitor;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>Creates the Windows per-process counter source (the traffic helper connection, WINDOWS-SERVICE 4).</summary>
[SupportedOSPlatform("windows")]
internal static class CounterSources
{
    public static IProcessCounterSource? Create(Action<string>? log) => HelperSampler.CreateWindows(log);
}

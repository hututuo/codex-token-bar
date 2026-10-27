namespace AgentSpeed.Core.Traffic.Engine;

/// <summary>A process identity (METRICS 10.3): pid and start time in microseconds since 1970.</summary>
internal readonly record struct ProcessIdentity(int Pid, long StartUs) : IComparable<ProcessIdentity>
{
    /// <summary>FILETIME ticks (100 ns since 1601) of 1970-01-01.</summary>
    public const long UnixEpochFileTime = 116_444_736_000_000_000;

    /// <summary>The identity of a Windows process from its kernel create time (FILETIME), as the helper and <c>GetProcessTimes</c> report it.</summary>
    public static ProcessIdentity FromFileTime(uint pid, ulong createTime) =>
        new(unchecked((int)pid), ((long)Math.Min(createTime, long.MaxValue) - UnixEpochFileTime) / 10);

    public int CompareTo(ProcessIdentity other)
    {
        var byStart = StartUs.CompareTo(other.StartUs);
        return byStart != 0 ? byStart : Pid.CompareTo(other.Pid);
    }
}

/// <summary>One row of a process-table listing: the cheap part read for every process on every refresh.</summary>
internal readonly record struct ProcessEntry(int Pid, int ParentPid, long StartUs)
{
    public ProcessIdentity Identity => new(Pid, StartUs);
}

/// <summary>
/// Reads the expensive details of a process on demand (METRICS 10.5, 10.6). The table asks for the path once per
/// identity, for arguments only when a rule needs them, and attribution asks for the working directory and open files.
/// </summary>
internal interface IProcessInspector
{
    string? ExecutablePath(in ProcessEntry entry);

    IReadOnlyList<string>? Arguments(in ProcessEntry entry);

    string? WorkingDirectory(in ProcessEntry entry);

    /// <summary>macOS: the bundle id of the app whose <c>Contents/MacOS</c> holds the executable (WorkBuddy, METRICS 10.5); Windows: null.</summary>
    string? BundleId(in ProcessEntry entry);

    /// <summary>Open file paths (macOS only; Windows returns none).</summary>
    IReadOnlyCollection<string> OpenFiles(in ProcessEntry entry, long nowMs);
}

/// <summary>A process's role in a source (METRICS 10.5).</summary>
internal enum TrafficRole
{
    /// <summary>A root agent process.</summary>
    Agent,

    /// <summary>Part of an agent process (a wrapper's native child, a relaunch): counted as the root's own traffic.</summary>
    Self,

    /// <summary>A descendant that is not an agent process.</summary>
    Tool,
}

/// <summary>The sticky classification of one process identity.</summary>
internal readonly record struct ProcessClass(SourceKind Source, TrafficRole Role, ProcessIdentity Root)
{
    public bool IsAgentMember => Role != TrafficRole.Tool;
}

/// <summary>Cumulative <c>rx</c>/<c>tx</c> counters of one key at one sample.</summary>
internal readonly record struct TrafficCounter(long Rx, long Tx);

/// <summary>One process-counter row of a sample (METRICS 10.3).</summary>
internal readonly record struct CounterRow(ProcessIdentity Identity, TrafficCounter Counter);

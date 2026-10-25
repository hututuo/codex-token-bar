using AgentSpeed.Core.Traffic.Engine;

namespace AgentSpeed.Core.Traffic.Monitor;

/// <summary>Reads the counted interfaces' cumulative counters (METRICS 10.2).</summary>
internal interface IMachineCounterReader
{
    /// <summary>Fills <paramref name="counters"/> (cleared first) by interface key; false when the read failed.</summary>
    bool Read(Dictionary<ulong, TrafficCounter> counters);

    /// <summary>Diagnostics: the counted interfaces' names.</summary>
    IReadOnlyList<string> CountedNames { get; }
}

/// <summary>Lists the current user's processes (METRICS 10.5) and reads their details on demand.</summary>
internal interface IProcessLister : IProcessInspector
{
    /// <summary>Fills <paramref name="entries"/> (cleared first); false when the listing failed (the table is then left as it is).</summary>
    bool List(List<ProcessEntry> entries);
}

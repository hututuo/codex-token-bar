using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using AgentSpeed.Core.Traffic.Engine;
using AgentSpeed.Core.Traffic.Monitor;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>
/// This computer's interface counters (METRICS 10.2): the counted set comes from <c>GetIfTable2Ex(MibIfTableNormal)</c>
/// (hardware interfaces without NDIS filter duplicates or endpoint interfaces, not loopback or tunnels, up), keyed by
/// <c>InterfaceLuid</c>; between table scans each tick reads only those rows with <c>GetIfEntry2</c>, since the full
/// table asks every adapter and filter driver for its statistics (tens of milliseconds and ≈ 1.5 ms of CPU per call on a
/// typical PC). The table is read again every <see cref="RescanMs"/> and as soon as a counted row fails or goes down.
/// Needs no permission.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed unsafe class MachineCounters : IMachineCounterReader, IDisposable
{
    /// <summary>A new interface (Wi-Fi joined, tethering) is counted within this long.</summary>
    public const long RescanMs = 10_000;

    private readonly List<ulong> _counted = [];
    private readonly Func<long> _clockMs;
    private byte* _row;
    private long? _lastScanMs;
    private string[] _countedNames = [];

    public MachineCounters(Func<long>? clockMs = null)
    {
        _clockMs = clockMs ?? (static () => Environment.TickCount64);
        _row = (byte*)NativeMemory.AllocZeroed(TrafficNative.IfRow2.Size);
    }

    public IReadOnlyList<string> CountedNames => _countedNames;

    public bool Read(Dictionary<ulong, TrafficCounter> counters)
    {
        counters.Clear();
        if (_row == null)
        {
            return false;
        }

        var now = _clockMs();
        if (_lastScanMs is not { } last || now - last >= RescanMs)
        {
            return Scan(counters, now);
        }

        foreach (var luid in _counted)
        {
            NativeMemory.Clear(_row, TrafficNative.IfRow2.Size);
            *(ulong*)(_row + TrafficNative.IfRow2.InterfaceLuid) = luid;
            if (TrafficNative.GetIfEntry2(_row) != 0 || !IsCounted(_row))
            {
                // Gone or down: the table decides the counted set again.
                return Scan(counters, now);
            }

            counters[luid] = Counter(_row);
        }

        return true;
    }

    public void Dispose()
    {
        if (_row != null)
        {
            NativeMemory.Free(_row);
            _row = null;
        }
    }

    private bool Scan(Dictionary<ulong, TrafficCounter> counters, long now)
    {
        counters.Clear();
        _lastScanMs = now;
        if (TrafficNative.GetIfTable2Ex(TrafficNative.MibIfTableNormal, out var table) != 0 || table == IntPtr.Zero)
        {
            _counted.Clear();
            return false;
        }

        try
        {
            var count = *(uint*)table;
            var rows = (byte*)table + 8;
            var names = new List<string>();
            _counted.Clear();
            for (var i = 0; i < count && i < 4096; i++)
            {
                var row = rows + (long)i * TrafficNative.IfRow2.Size;
                if (!IsCounted(row))
                {
                    continue;
                }

                var luid = *(ulong*)(row + TrafficNative.IfRow2.InterfaceLuid);
                if (counters.TryAdd(luid, Counter(row)))
                {
                    _counted.Add(luid);
                    names.Add(Alias(row));
                }
            }

            if (!names.SequenceEqual(_countedNames))
            {
                _countedNames = [.. names];
            }

            return true;
        }
        finally
        {
            TrafficNative.FreeMibTable(table);
        }
    }

    private static TrafficCounter Counter(byte* row)
    {
        var rx = *(ulong*)(row + TrafficNative.IfRow2.InOctets);
        var tx = *(ulong*)(row + TrafficNative.IfRow2.OutOctets);
        return new TrafficCounter((long)Math.Min(rx, long.MaxValue), (long)Math.Min(tx, long.MaxValue));
    }

    private static bool IsCounted(byte* row)
    {
        var flags = row[TrafficNative.IfRow2.StatusFlags];
        var type = *(uint*)(row + TrafficNative.IfRow2.Type);
        var tunnel = *(uint*)(row + TrafficNative.IfRow2.TunnelType);
        var status = *(uint*)(row + TrafficNative.IfRow2.OperStatus);
        return (flags & TrafficNative.IfRow2.HardwareInterface) != 0
            && (flags & (TrafficNative.IfRow2.FilterInterface | TrafficNative.IfRow2.EndPointInterface)) == 0
            && type is not (TrafficNative.IfTypeSoftwareLoopback or TrafficNative.IfTypeTunnel)
            && tunnel == TrafficNative.TunnelTypeNone
            && status == TrafficNative.IfOperStatusUp;
    }

    /// <summary>The interface's alias, for diagnostics only.</summary>
    private static string Alias(byte* row)
    {
        var alias = (char*)(row + TrafficNative.IfRow2.Alias);
        var length = 0;
        while (length < TrafficNative.IfRow2.AliasChars && alias[length] != '\0')
        {
            length++;
        }

        return new string(alias, 0, length);
    }
}

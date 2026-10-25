using System.Globalization;
using AgentSpeed.Core.History;
using AgentSpeed.Core.Monitoring;

namespace AgentSpeed.Core.Traffic.Engine;

/// <summary>One source's bytes of one day (METRICS 10.8).</summary>
internal sealed class SourceDayTraffic
{
    public TrafficSplit Split;

    /// <summary>The part of <see cref="Split"/> (self and tools) not attributed to an agent tree.</summary>
    public TrafficBytes Unassigned;
}

/// <summary>Everything counted on one local date (METRICS 10.8).</summary>
internal sealed class TrafficDayTotals
{
    public TrafficBytes Machine;
    public long MachineSampledMs;
    public long ProcessSampledMs;

    public Dictionary<SourceKind, SourceDayTraffic> Sources { get; } = new();

    /// <summary>Per agent tree, memory only.</summary>
    public Dictionary<string, TrafficSplit> Agents { get; } = new(StringComparer.Ordinal);

    public SourceDayTraffic Source(SourceKind source)
    {
        if (!Sources.TryGetValue(source, out var traffic))
        {
            traffic = new SourceDayTraffic();
            Sources[source] = traffic;
        }

        return traffic;
    }

    /// <summary>The <c>day_traffic</c> rows of this day (METRICS 10.9): <c>machine</c>, then every source with bytes, in source order.</summary>
    public List<TrafficDay> Rows(string day)
    {
        var rows = new List<TrafficDay>(1 + Sources.Count)
        {
            new(day, TrafficDay.MachineKey, Machine.Rx, Machine.Tx, 0, 0, MachineSampledMs),
        };
        foreach (var source in Enum.GetValues<SourceKind>())
        {
            if (Sources.TryGetValue(source, out var traffic))
            {
                rows.Add(new TrafficDay(day, SourceNames.Of(source), traffic.Split.Self.Rx, traffic.Split.Self.Tx,
                    traffic.Split.Tools.Rx, traffic.Split.Tools.Tx, ProcessSampledMs));
            }
        }

        return rows;
    }

    /// <summary>
    /// Today's totals restored from stored rows at launch (METRICS 10.8): machine and sources; restored source bytes count
    /// as unassigned since agent values start at zero.
    /// </summary>
    public static TrafficDayTotals Restoring(IEnumerable<TrafficDay> rows)
    {
        var totals = new TrafficDayTotals();
        foreach (var row in rows)
        {
            if (row.IsMachine)
            {
                totals.Machine = new TrafficBytes(row.Rx, row.Tx);
                totals.MachineSampledMs = row.SampledMs;
            }
            else if (row.Source is { } source)
            {
                var split = new TrafficSplit(new TrafficBytes(row.Rx, row.Tx), new TrafficBytes(row.RxTools, row.TxTools));
                totals.Sources[source] = new SourceDayTraffic { Split = split, Unassigned = split.Self + split.Tools };
                totals.ProcessSampledMs = Math.Max(totals.ProcessSampledMs, row.SampledMs);
            }
        }

        return totals;
    }
}

/// <summary>Local dates (<c>yyyy-MM-dd</c>) of sample times in one time zone, cached per day (METRICS 10.4.6).</summary>
internal sealed class DayLabeler
{
    private readonly TimeZoneInfo _zone;
    private long _dayStartMs = long.MaxValue;
    private long _nextDayStartMs = long.MinValue;
    private string _label = string.Empty;

    public DayLabeler(TimeZoneInfo zone)
    {
        _zone = zone;
    }

    public TimeZoneInfo Zone => _zone;

    public string Label(long ms)
    {
        if (ms >= _dayStartMs && ms < _nextDayStartMs)
        {
            return _label;
        }

        var local = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(ms), _zone);
        _label = local.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        _dayStartMs = LocalDay.StartMs(ms, _zone);
        _nextDayStartMs = LocalDay.StartMs(_dayStartMs + 26 * 3_600_000L, _zone);
        if (_nextDayStartMs <= ms)
        {
            _nextDayStartMs = ms + 1;
        }

        return _label;
    }

    /// <summary>The local midnight of the day <paramref name="ms"/> belongs to.</summary>
    public DateTimeOffset DayStart(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(LocalDay.StartMs(ms, _zone));
}

/// <summary>Day totals by local date (METRICS 10.4.6).</summary>
internal sealed class TrafficLedger
{
    private readonly Dictionary<string, TrafficDayTotals> _days = new(StringComparer.Ordinal);

    public TrafficLedger(TimeZoneInfo zone)
    {
        Labeler = new DayLabeler(zone);
    }

    public DayLabeler Labeler { get; }

    public IReadOnlyDictionary<string, TrafficDayTotals> Days => _days;

    public string Label(long ms) => Labeler.Label(ms);

    public TrafficDayTotals Day(string day)
    {
        if (!_days.TryGetValue(day, out var totals))
        {
            totals = new TrafficDayTotals();
            _days[day] = totals;
        }

        return totals;
    }

    public TrafficDayTotals? Totals(string day) => _days.GetValueOrDefault(day);

    public void Restore(string day, IEnumerable<TrafficDay> rows) => _days[day] = TrafficDayTotals.Restoring(rows);

    public void Reset(string day) => _days[day] = new TrafficDayTotals();

    /// <summary>Forgets every day except <paramref name="keep"/>.</summary>
    public void DropExcept(string keep)
    {
        foreach (var day in _days.Keys.Where(d => d != keep).ToArray())
        {
            _days.Remove(day);
        }
    }

    /// <summary>Every day's rows, oldest first (METRICS 10.9).</summary>
    public List<TrafficDay> History() =>
        [.. _days.Keys.Order(StringComparer.Ordinal).SelectMany(day => _days[day].Rows(day))];
}

using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Pricing;

/// <summary>
/// The price tables a process knows and the day bindings of METRICS 9.7: each local date keeps the table version it
/// was first priced with, and a response that table cannot price takes the current table (late pricing).
/// Thread-safe: the live engine and the daily history share one book.
/// </summary>
public sealed class PriceBook
{
    public const string BundledResourceName = "AgentSpeed.Prices.json";

    private static readonly Lazy<PriceTable> BundledTable = new(LoadBundled);

    private readonly object _gate = new();
    private readonly Dictionary<int, PriceTable> _tables = [];
    private readonly Dictionary<string, int> _bindings = new(StringComparer.Ordinal);
    private readonly HashSet<string> _unsaved = new(StringComparer.Ordinal);
    private int _current;
    private Action? _bindingObserver;

    /// <param name="tables">Not empty; the highest version is current.</param>
    public PriceBook(IEnumerable<PriceTable> tables, IReadOnlyDictionary<string, int>? bindings = null)
    {
        foreach (var table in tables)
        {
            _tables[table.Version] = table;
        }

        if (_tables.Count == 0)
        {
            throw new ArgumentException("A price book needs at least one table.", nameof(tables));
        }

        _current = _tables.Keys.Max();
        if (bindings is not null)
        {
            foreach (var (day, version) in bindings)
            {
                _bindings[day] = version;
            }
        }
    }

    /// <summary>A book with only the bundled table.</summary>
    public PriceBook()
        : this([Bundled])
    {
    }

    /// <summary>The table bundled with this build (<c>spec/assets/prices.json</c>).</summary>
    public static PriceTable Bundled => BundledTable.Value;

    /// <summary>Raised (on the binding thread) whenever a date is bound, so the owner can save it.</summary>
    public event Action? Bound
    {
        add
        {
            lock (_gate)
            {
                _bindingObserver += value;
            }
        }

        remove
        {
            lock (_gate)
            {
                _bindingObserver -= value;
            }
        }
    }

    public PriceTable Current
    {
        get
        {
            lock (_gate)
            {
                return _tables[_current];
            }
        }
    }

    public int CurrentVersion
    {
        get
        {
            lock (_gate)
            {
                return _current;
            }
        }
    }

    public IReadOnlyDictionary<string, int> Bindings
    {
        get
        {
            lock (_gate)
            {
                return new Dictionary<string, int>(_bindings, StringComparer.Ordinal);
            }
        }
    }

    /// <summary>Every known table, by version.</summary>
    public IReadOnlyDictionary<int, PriceTable> Tables
    {
        get
        {
            lock (_gate)
            {
                return new Dictionary<int, PriceTable>(_tables);
            }
        }
    }

    public PriceTable? Table(int version)
    {
        lock (_gate)
        {
            return _tables.GetValueOrDefault(version);
        }
    }

    /// <summary>Adds a table (a synced download or a stored copy). Returns true when it became the current table.</summary>
    public bool Add(PriceTable table)
    {
        lock (_gate)
        {
            _tables.TryAdd(table.Version, table);
            if (table.Version <= _current)
            {
                return false;
            }

            _current = table.Version;
            return true;
        }
    }

    /// <summary>
    /// Takes the stored bindings: a stored date keeps its stored version; a binding whose table is unknown (missing or
    /// invalid copy) is replaced by the current version and saved again (returned). Dates bound in memory but not
    /// stored yet stay as they are.
    /// </summary>
    public IReadOnlyList<string> Restore(IReadOnlyDictionary<string, int> stored)
    {
        lock (_gate)
        {
            var repaired = new List<string>();
            foreach (var (day, version) in stored)
            {
                if (_tables.ContainsKey(version))
                {
                    _bindings[day] = version;
                    _unsaved.Remove(day);
                }
                else
                {
                    if (!_bindings.TryGetValue(day, out var bound) || !_tables.ContainsKey(bound))
                    {
                        _bindings[day] = _current;
                    }

                    _unsaved.Add(day);
                    repaired.Add(day);
                }
            }

            repaired.Sort(StringComparer.Ordinal);
            return repaired;
        }
    }

    /// <summary>Adds the valid stored table copies, then takes the stored bindings. Returns the repaired dates.</summary>
    public IReadOnlyList<string> Restore(IReadOnlyDictionary<string, int> stored, IReadOnlyDictionary<int, byte[]> copies)
    {
        foreach (var (version, data) in copies.OrderBy(c => c.Key))
        {
            if (Table(version) is null && PriceTable.Load(data).Table is { } table && table.Version == version)
            {
                Add(table);
            }
        }

        return Restore(stored);
    }

    /// <summary>"Clear history" deletes every binding (METRICS 9.7).</summary>
    public void ClearBindings()
    {
        lock (_gate)
        {
            _bindings.Clear();
            _unsaved.Clear();
        }
    }

    /// <summary>The version bound to <paramref name="day"/>, binding it to the current table first when it has none.</summary>
    public int VersionForDay(string day)
    {
        Action? observer;
        int version;
        lock (_gate)
        {
            if (_bindings.TryGetValue(day, out version) && _tables.ContainsKey(version))
            {
                return version;
            }

            version = _bindings[day] = _current;
            _unsaved.Add(day);
            observer = _bindingObserver;
        }

        observer?.Invoke();
        return version;
    }

    /// <summary>The version bound to <paramref name="day"/> without binding it.</summary>
    public int? BoundVersion(string day)
    {
        lock (_gate)
        {
            return _bindings.TryGetValue(day, out var version) ? version : null;
        }
    }

    /// <summary>The cost of a response of local date <paramref name="day"/> (METRICS 9.7): the day's table, else the current one.</summary>
    internal long? Cost(ParsedResponse response, string day) =>
        Cost(response.Model, response.Provider, response.Tokens, response.EndMs, response.Fast, day);

    internal long? Cost(string? model, string? provider, in TokenCounts tokens, long? endMs, bool fast, string day)
    {
        var version = VersionForDay(day);
        PriceTable bound, current;
        lock (_gate)
        {
            bound = _tables[version];
            current = _tables[_current];
        }

        if (bound.Cost(model, provider, tokens, endMs, fast) is { } cost)
        {
            return cost;
        }

        return version == current.Version ? null : current.Cost(model, provider, tokens, endMs, fast);
    }

    /// <summary>
    /// <c>cost.priceVersion</c> (METRICS 11.2): the table bound to the local date of <paramref name="ms"/>, else the current one.
    /// Reading it never binds a date.
    /// </summary>
    public int ReportPriceVersion(long ms, TimeZoneInfo? zone = null)
    {
        var local = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(ms), zone ?? TimeZoneInfo.Local);
        return BoundVersion(local.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture)) ?? CurrentVersion;
    }

    /// <summary>Bindings made since the last call, for the history store.</summary>
    public IReadOnlyDictionary<string, int> TakeNewBindings()
    {
        lock (_gate)
        {
            var result = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var day in _unsaved)
            {
                if (_bindings.TryGetValue(day, out var version))
                {
                    result[day] = version;
                }
            }

            _unsaved.Clear();
            return result;
        }
    }

    private static PriceTable LoadBundled()
    {
        using var stream = typeof(PriceBook).Assembly.GetManifestResourceStream(BundledResourceName)
            ?? throw new InvalidOperationException("Missing embedded resource " + BundledResourceName);
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        var result = PriceTable.Load(memory.ToArray());
        return result.Table
            ?? throw new InvalidOperationException("The bundled price table does not validate (" + result.Error + "); run python3 spec/tools/prices.py");
    }
}

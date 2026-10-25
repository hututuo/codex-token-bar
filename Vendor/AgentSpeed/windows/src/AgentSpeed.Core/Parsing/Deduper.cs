namespace AgentSpeed.Core.Parsing;

/// <summary>Which file owns a response key (METRICS 3.4). Implementations are not thread-safe.</summary>
internal interface IDeduper
{
    /// <summary>Claims <paramref name="key"/> for <paramref name="owner"/>; returns false with the first owner when seen.</summary>
    bool TryClaim(string key, string owner, out string firstOwner);

    /// <summary>The file that first claimed <paramref name="key"/>, without claiming it.</summary>
    bool TryGetOwner(string key, out string owner);
}

/// <summary>
/// Global bounded set of response keys shared by all files of all sources, remembering which file saw each key
/// first (METRICS 3.4). Not thread-safe: the monitor applies parsed lines on a single thread.
/// </summary>
internal sealed class Deduper : IDeduper
{
    public const int DefaultCapacity = 65_536;

    private readonly int _capacity;
    private readonly Dictionary<string, string> _owners;
    private readonly Queue<string> _order;

    public Deduper(int capacity = DefaultCapacity)
    {
        _capacity = Math.Max(1, capacity);
        _owners = new Dictionary<string, string>(Math.Min(_capacity, 4096), StringComparer.Ordinal);
        _order = new Queue<string>(Math.Min(_capacity, 4096));
    }

    public int Count => _owners.Count;

    public bool TryGetOwner(string key, out string owner) => _owners.TryGetValue(key, out owner!);

    public bool TryClaim(string key, string owner, out string firstOwner)
    {
        if (_owners.TryGetValue(key, out var existing))
        {
            firstOwner = existing;
            return false;
        }

        if (_owners.Count >= _capacity && _order.TryDequeue(out var oldest))
        {
            _owners.Remove(oldest);
        }

        _owners[key] = owner;
        _order.Enqueue(key);
        firstOwner = owner;
        return true;
    }
}

/// <summary>
/// Unbounded ownership by 64-bit key hash for the daily history (METRICS 8): keys of finished files are settled,
/// keys of the file being read belong to it until <see cref="FinishFile"/>.
/// </summary>
internal sealed class KeyLedger : IDeduper
{
    private const string OtherOwner = "\0settled";

    private readonly HashSet<ulong> _settled = [];
    private readonly HashSet<ulong> _current = [];
    private readonly List<ulong> _currentOrder = [];
    private string? _currentOwner;

    public int Count => _settled.Count + _current.Count;

    public void Settle(ReadOnlySpan<ulong> hashes)
    {
        foreach (var hash in hashes)
        {
            _settled.Add(hash);
        }
    }

    public bool TryGetOwner(string key, out string owner)
    {
        var hash = KeyHash.Fnv1a(key);
        if (_settled.Contains(hash))
        {
            owner = OtherOwner;
            return true;
        }

        owner = _currentOwner ?? string.Empty;
        return _current.Contains(hash);
    }

    public bool TryClaim(string key, string owner, out string firstOwner)
    {
        var hash = KeyHash.Fnv1a(key);
        if (_settled.Contains(hash))
        {
            firstOwner = OtherOwner;
            return false;
        }

        if (_current.Contains(hash))
        {
            firstOwner = _currentOwner ?? owner;
            return false;
        }

        _currentOwner ??= owner;
        if (!string.Equals(_currentOwner, owner, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Finish the current file before claiming keys for another one.");
        }

        _current.Add(hash);
        _currentOrder.Add(hash);
        firstOwner = owner;
        return true;
    }

    /// <summary>Ends the current file: its keys become settled and are returned in claim order.</summary>
    public ulong[] FinishFile()
    {
        var owned = _currentOrder.ToArray();
        foreach (var hash in owned)
        {
            _settled.Add(hash);
        }

        AbandonFile();
        return owned;
    }

    /// <summary>Forgets the keys claimed by the current file (it could not be read completely).</summary>
    public void AbandonFile()
    {
        _current.Clear();
        _currentOrder.Clear();
        _currentOwner = null;
    }
}

/// <summary>64-bit FNV-1a over the UTF-8 bytes of a response key (METRICS 8).</summary>
internal static class KeyHash
{
    private const ulong OffsetBasis = 0xCBF29CE484222325;
    private const ulong Prime = 0x00000100000001B3;

    public static ulong Fnv1a(string key)
    {
        var hash = OffsetBasis;
        Span<byte> encoded = stackalloc byte[4];
        for (var i = 0; i < key.Length; i++)
        {
            var c = key[i];
            if (c < 0x80)
            {
                hash = (hash ^ c) * Prime;
                continue;
            }

            if (!System.Text.Rune.TryGetRuneAt(key, i, out var rune))
            {
                rune = System.Text.Rune.ReplacementChar;
            }
            else if (rune.Utf16SequenceLength == 2)
            {
                i++;
            }

            var written = rune.EncodeToUtf8(encoded);
            for (var j = 0; j < written; j++)
            {
                hash = (hash ^ encoded[j]) * Prime;
            }
        }

        return hash;
    }
}

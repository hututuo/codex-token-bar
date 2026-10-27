using System.Collections;
using System.Numerics;
using System.Runtime.CompilerServices;

namespace AgentSpeed.Core;

/// <summary>
/// An immutable set of sources (METRICS 1, 6.8), for example the sources a floating orb tracks. Enumerates in source
/// order and works as a dictionary key; <c>default</c> is the empty set.
/// </summary>
[CollectionBuilder(typeof(SourceSet), nameof(Create))]
public readonly record struct SourceSet : IReadOnlyCollection<SourceKind>
{
    private static readonly int KindCount = Enum.GetValues<SourceKind>().Length;

    private readonly uint _bits;

    private SourceSet(uint bits)
    {
        _bits = bits;
    }

    public static SourceSet Empty => default;

    /// <summary>Every known source.</summary>
    public static SourceSet Everything { get; } = new((1u << KindCount) - 1);

    public int Count => BitOperations.PopCount(_bits);

    public bool IsEmpty => _bits == 0;

    public static SourceSet Of(SourceKind kind) => new(Bit(kind));

    public static SourceSet Create(ReadOnlySpan<SourceKind> kinds)
    {
        var bits = 0u;
        foreach (var kind in kinds)
        {
            bits |= Bit(kind);
        }

        return new SourceSet(bits);
    }

    public static SourceSet From(IEnumerable<SourceKind> kinds)
    {
        ArgumentNullException.ThrowIfNull(kinds);
        var bits = 0u;
        foreach (var kind in kinds)
        {
            bits |= Bit(kind);
        }

        return new SourceSet(bits);
    }

    public bool Contains(SourceKind kind) => (uint)kind < (uint)KindCount && (_bits & (1u << (int)kind)) != 0;

    public SourceSet With(SourceKind kind) => new(_bits | Bit(kind));

    public SourceSet Without(SourceKind kind) => new(_bits & ~Bit(kind));

    public SourceSet Union(SourceSet other) => new(_bits | other._bits);

    public SourceSet Intersect(SourceSet other) => new(_bits & other._bits);

    public SourceSet Except(SourceSet other) => new(_bits & ~other._bits);

    public bool IsSubsetOf(SourceSet other) => (_bits & ~other._bits) == 0;

    public Enumerator GetEnumerator() => new(_bits);

    IEnumerator<SourceKind> IEnumerable<SourceKind>.GetEnumerator() => GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    public override string ToString() => "{" + string.Join(", ", (IEnumerable<SourceKind>)this) + "}";

    private static uint Bit(SourceKind kind) => (uint)kind < (uint)KindCount
        ? 1u << (int)kind
        : throw new ArgumentOutOfRangeException(nameof(kind), kind, null);

    /// <summary>Members in source order, without allocating.</summary>
    public struct Enumerator : IEnumerator<SourceKind>
    {
        private uint _remaining;

        internal Enumerator(uint bits)
        {
            _remaining = bits;
            Current = default;
        }

        public SourceKind Current { get; private set; }

        readonly object IEnumerator.Current => Current;

        public bool MoveNext()
        {
            if (_remaining == 0)
            {
                return false;
            }

            Current = (SourceKind)BitOperations.TrailingZeroCount(_remaining);
            _remaining &= _remaining - 1;
            return true;
        }

        public readonly void Reset() => throw new NotSupportedException();

        public readonly void Dispose()
        {
        }
    }
}

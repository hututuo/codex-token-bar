using System.Diagnostics.CodeAnalysis;

namespace AgentSpeed.Core.Engine;

/// <summary>
/// Sparse per-second token amounts (tok/s per one-second bucket) with the maximum 3-bucket trailing average
/// (METRICS 6.6). Chunked so that any day start, including 0 in tests, stays cheap.
/// </summary>
internal sealed class SecondSeries
{
    public const int ChunkSeconds = 1024;

    private readonly Dictionary<long, double[]> _chunks = [];
    private bool _dirty;
    private double _peak;
    private long? _peakAtMs;

    /// <summary>Indices of the allocated chunks; chunk <c>c</c> holds the seconds <c>[c * ChunkSeconds, (c + 1) * ChunkSeconds)</c>.</summary>
    public Dictionary<long, double[]>.KeyCollection ChunkKeys => _chunks.Keys;

    public static long ChunkOf(long second) => SpeedMath.FloorDiv(second, ChunkSeconds);

    public bool TryGetChunk(long key, [NotNullWhen(true)] out double[]? chunk) => _chunks.TryGetValue(key, out chunk);

    public void Clear()
    {
        _chunks.Clear();
        _dirty = false;
        _peak = 0;
        _peakAtMs = null;
    }

    /// <summary>Distributes <paramref name="amount"/> uniformly over <c>[startMs, endMs]</c>, dropping parts before the floor.</summary>
    public void AddInterval(long startMs, long endMs, double amount, long floorMs)
    {
        if (endMs <= startMs || amount == 0)
        {
            return;
        }

        var from = Math.Max(startMs, floorMs);
        if (from >= endMs)
        {
            return;
        }

        var duration = (double)(endMs - startMs);
        for (var second = SpeedMath.FloorDiv(from, 1000); second * 1000 < endMs; second++)
        {
            var overlap = SpeedMath.Overlap(from, endMs, second * 1000, second * 1000 + 1000);
            if (overlap > 0)
            {
                Slot(second) += amount * overlap / duration;
            }
        }

        _dirty = true;
    }

    /// <summary>Maximum of <c>(b[k-2] + b[k-1] + b[k]) / 3</c> and the end time of that window.</summary>
    public (double Peak, long? AtMs) TrailingPeak()
    {
        if (!_dirty)
        {
            return (_peak, _peakAtMs);
        }

        var keys = new long[_chunks.Count];
        _chunks.Keys.CopyTo(keys, 0);
        Array.Sort(keys);
        double best = 0, previous1 = 0, previous2 = 0;
        long? bestAt = null;
        var expected = long.MinValue;
        foreach (var key in keys)
        {
            var baseSecond = key * ChunkSeconds;
            if (baseSecond != expected)
            {
                previous1 = 0;
                previous2 = 0;
            }

            var chunk = _chunks[key];
            for (var i = 0; i < ChunkSeconds; i++)
            {
                var value = Math.Max(0, chunk[i]);
                var average = (previous2 + previous1 + value) / 3;
                if (average > best)
                {
                    best = average;
                    bestAt = (baseSecond + i + 1) * 1000;
                }

                previous2 = previous1;
                previous1 = value;
            }

            expected = baseSecond + ChunkSeconds;
        }

        _peak = best;
        _peakAtMs = bestAt;
        _dirty = false;
        return (_peak, _peakAtMs);
    }

    private ref double Slot(long second)
    {
        var key = ChunkOf(second);
        if (!_chunks.TryGetValue(key, out var chunk))
        {
            chunk = new double[ChunkSeconds];
            _chunks[key] = chunk;
        }

        return ref chunk[second - key * ChunkSeconds];
    }
}

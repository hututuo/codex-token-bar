namespace AgentSpeed.Core.Parsing;

/// <summary>Normalized token usage of one response (METRICS 3.2).</summary>
/// <param name="CacheWrite1hInput">The part of <paramref name="CacheWriteInput"/> written with a 1-hour lifetime (Claude only).</param>
internal readonly record struct TokenCounts(
    long Input = 0,
    long CachedInput = 0,
    long CacheWriteInput = 0,
    long Output = 0,
    long Reasoning = 0,
    long CacheWrite1hInput = 0)
{
    /// <summary>Upper bound for any single counter; protects sums against hostile values.</summary>
    public const long MaxValue = 1_000_000_000_000;

    public long Total => Input + Output;

    public static TokenCounts Max(in TokenCounts a, in TokenCounts b) => new(
        Math.Max(a.Input, b.Input),
        Math.Max(a.CachedInput, b.CachedInput),
        Math.Max(a.CacheWriteInput, b.CacheWriteInput),
        Math.Max(a.Output, b.Output),
        Math.Max(a.Reasoning, b.Reasoning),
        Math.Max(a.CacheWrite1hInput, b.CacheWrite1hInput));

    public static long Clamp(long value) => value < 0 ? 0 : Math.Min(value, MaxValue);
}

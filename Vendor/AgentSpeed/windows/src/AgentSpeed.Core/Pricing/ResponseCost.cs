using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Pricing;

/// <summary>Integer cost of one response (METRICS 9.3).</summary>
internal static class ResponseCost
{
    /// <summary>Each billed token class is clamped here, which keeps the sum below 2^63 at 10 000 USD per million tokens.</summary>
    public const long MaxClassTokens = 100_000_000;

    /// <summary>Exact pico-USD and the tier used (null = the base prices).</summary>
    public static (long Pico, int? Tier) PicoUsd(in TokenCounts tokens, TieredPrices pricing)
    {
        var (prices, tier) = pricing.Select(tokens.Input);
        var write = tokens.CacheWriteInput;
        var write1h = Math.Min(tokens.CacheWrite1hInput, write);
        var cached = tokens.CachedInput;
        var uncached = Clamp(Math.Max(0, tokens.Input - cached - write));
        var pico = uncached * prices.Input
            + Clamp(cached) * prices.CachedInput
            + Clamp(write - write1h) * prices.CacheWrite
            + Clamp(write1h) * prices.CacheWrite1h
            + Clamp(tokens.Output) * prices.Output;
        return (pico, tier);
    }

    /// <summary>pico-USD → micro-USD, half up (values are never negative).</summary>
    public static long MicroUsd(long pico) => (pico + 500_000) / 1_000_000;

    private static long Clamp(long value) => Math.Min(value, MaxClassTokens);
}

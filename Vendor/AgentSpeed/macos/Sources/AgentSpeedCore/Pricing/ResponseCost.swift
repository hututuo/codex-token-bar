import Foundation

/// Integer cost of one response (METRICS 9.3).
public enum ResponseCost {
    /// Each billed token class is clamped here, which keeps the sum below 2^63 at 10 000 USD per million tokens.
    public static let maxClassTokens: Int64 = 100_000_000

    /// Disjoint billed token classes of a normalized usage.
    public struct Classes: Equatable, Sendable {
        public var uncached: Int64
        public var cacheRead: Int64
        public var write: Int64
        public var write1h: Int64
        public var output: Int64

        public init(_ usage: TokenUsage) {
            let write = Int64(usage.cacheWriteInput)
            let write1h = min(Int64(usage.cacheWrite1hInput), write)
            let cached = Int64(usage.cachedInput)
            func clamp(_ value: Int64) -> Int64 { min(value, maxClassTokens) }
            uncached = clamp(max(0, Int64(usage.input) - cached - write))
            cacheRead = clamp(cached)
            self.write = clamp(write - write1h)
            self.write1h = clamp(write1h)
            output = clamp(Int64(usage.output))
        }
    }

    /// Exact pico-USD and the tier used (nil = the base prices).
    public static func picoUsd(usage: TokenUsage, pricing: TieredPrices) -> (pico: Int64, tier: Int?) {
        let (prices, tier) = pricing.select(inputTokens: Int64(usage.input))
        let classes = Classes(usage)
        let pico = classes.uncached * prices.input
            + classes.cacheRead * prices.cachedInput
            + classes.write * prices.cacheWrite
            + classes.write1h * prices.cacheWrite1h
            + classes.output * prices.output
        return (pico, tier)
    }

    /// pico-USD → micro-USD, half up (values are never negative).
    public static func microUsd(_ pico: Int64) -> Int64 {
        (pico + 500_000) / 1_000_000
    }
}

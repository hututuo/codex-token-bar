import Foundation

/// Normalized token usage of one response (METRICS 3.2).
public struct TokenUsage: Equatable, Hashable, Sendable {
    public var input: Int
    public var cachedInput: Int
    public var cacheWriteInput: Int
    /// The part of `cacheWriteInput` written with a 1-hour lifetime (Claude only; METRICS 3.2).
    public var cacheWrite1hInput: Int
    public var output: Int
    public var reasoning: Int

    public var total: Int { input + output }

    public init(
        input: Int = 0,
        cachedInput: Int = 0,
        cacheWriteInput: Int = 0,
        cacheWrite1hInput: Int = 0,
        output: Int = 0,
        reasoning: Int = 0
    ) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.cacheWrite1hInput = cacheWrite1hInput
        self.output = output
        self.reasoning = reasoning
    }

    public static let zero = TokenUsage()

    /// Field-wise maximum, used when merging repeated lines of one Claude message.
    func merged(with other: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: max(input, other.input),
            cachedInput: max(cachedInput, other.cachedInput),
            cacheWriteInput: max(cacheWriteInput, other.cacheWriteInput),
            cacheWrite1hInput: max(cacheWrite1hInput, other.cacheWrite1hInput),
            output: max(output, other.output),
            reasoning: max(reasoning, other.reasoning)
        )
    }
}

enum TokenCount {
    /// Upper bound for a single token field; keeps every sum far away from `Int.max`.
    static let ceiling: Int64 = 1_000_000_000_000

    /// Missing values are 0, negative values clamp to 0 and absurd values clamp to `ceiling`.
    static func clamp(_ value: Int64?) -> Int {
        guard let value else { return 0 }
        return Int(min(max(value, 0), ceiling))
    }

    /// A normalized field that adds clamped counts saturates at `ceiling` too (METRICS 3.2).
    static func sum(_ values: Int...) -> Int {
        Int(min(ceiling, values.reduce(Int64(0)) { $0 + Int64($1) }))
    }
}

extension TokenTotals {
    mutating func add(_ usage: TokenUsage, sign: Int, requestCount: Int = 1) {
        requests = requests.saturatingAdd(sign * requestCount)
        input = input.saturatingAdd(sign * usage.input)
        cachedInput = cachedInput.saturatingAdd(sign * usage.cachedInput)
        cacheWriteInput = cacheWriteInput.saturatingAdd(sign * usage.cacheWriteInput)
        output = output.saturatingAdd(sign * usage.output)
        reasoning = reasoning.saturatingAdd(sign * usage.reasoning)
    }
}

extension Int {
    func saturatingAdd(_ other: Int) -> Int {
        let (result, overflow) = addingReportingOverflow(other)
        if overflow { return other > 0 ? .max : .min }
        return result
    }
}

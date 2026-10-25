import Foundation

/// agents-core's `Usage` (`providerData.usage`): the members METRICS 4.9 reads.
struct WorkBuddyAgentsUsage: Equatable, Sendable {
    var inputTokens: JSONNumber?
    var outputTokens: JSONNumber?
    /// Σ `inputTokensDetails[].cached_tokens`, already clamped.
    var cachedTokens = 0
    /// Σ `outputTokensDetails[].reasoning_tokens`, already clamped.
    var reasoningTokens = 0
}

/// The service's OpenAI-style usage of the same call (`providerData.rawUsage`).
struct WorkBuddyRawUsage: Equatable, Sendable {
    var promptTokens: JSONNumber?
    var completionTokens: JSONNumber?
    var cacheReadInputTokens: JSONNumber?
    var cacheCreationInputTokens: JSONNumber?
    var promptCacheHitTokens: JSONNumber?
    var promptCacheWriteTokens: JSONNumber?
    /// `prompt_tokens_details.cached_tokens`
    var detailCachedTokens: JSONNumber?
    /// `completion_tokens_details.reasoning_tokens`
    var detailReasoningTokens: JSONNumber?
}

/// Normalized tokens of one WorkBuddy model call (METRICS 4.9 Tokens): per field the larger of the two records.
enum WorkBuddyTokens {
    static func normalize(_ usage: WorkBuddyAgentsUsage?, _ raw: WorkBuddyRawUsage?) -> TokenUsage {
        let usage = usage ?? WorkBuddyAgentsUsage()
        let raw = raw ?? WorkBuddyRawUsage()
        let cached = max(usage.cachedTokens,
                         firstPositive(raw.cacheReadInputTokens, raw.detailCachedTokens, raw.promptCacheHitTokens))
        // DeepSeek's `prompt_cache_miss_tokens` are uncached input, never cache writes.
        let write = firstPositive(raw.cacheCreationInputTokens, raw.promptCacheWriteTokens)
        return TokenUsage(
            input: max(count(usage.inputTokens), count(raw.promptTokens), add(cached, write)),
            cachedInput: cached,
            cacheWriteInput: write,
            output: max(count(usage.outputTokens), count(raw.completionTokens)),
            reasoning: max(usage.reasoningTokens, count(raw.detailReasoningTokens))
        )
    }

    /// A number truncated and clamped; anything else is 0.
    static func count(_ number: JSONNumber?) -> Int {
        TokenCount.clamp(number?.truncated)
    }

    /// The first value that is a finite number above 0, truncated (so 0.5 gives 0); 0 when none is.
    static func firstPositive(_ numbers: JSONNumber?...) -> Int {
        for case let number? in numbers where number.isFinite && number.isPositive {
            return count(number)
        }
        return 0
    }

    /// Adds clamped token counts without leaving the per-field ceiling.
    static func add(_ lhs: Int, _ rhs: Int) -> Int {
        Int(min(TokenCount.ceiling, Int64(lhs) + Int64(rhs)))
    }
}

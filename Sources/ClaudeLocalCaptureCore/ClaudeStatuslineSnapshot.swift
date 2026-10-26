import Foundation

/// A privacy-filtered schema-1 snapshot from Claude Code statusline stdin.
///
/// The encoded keys are `schema_version`, `captured_at_epoch` (Unix seconds), optional
/// `session_id`, `model.{id,display_name}`, `rate_limits.{five_hour,seven_day,spend_limit}`
/// with `{used_percentage,resets_at}` (epoch seconds), `cost.{total_api_duration_ms,
/// total_duration_ms}`, and `context_window.{context_window_size,total_input_tokens,
/// total_output_tokens,current_usage.{input_tokens,output_tokens,
/// cache_creation_input_tokens,cache_read_input_tokens}}`.
///
/// Only model identifiers, rate-limit windows, cumulative duration counters, context
/// token counters, and the session identifier survive parsing. Paths, prompts, tool
/// content, credentials, monetary cost estimates, and unknown input fields are never
/// represented by this type and therefore cannot be written to the capture cache.
public struct ClaudeStatuslineSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let capturedAtEpoch: Int64
    public let sessionId: String?
    public let model: Model?
    public let rateLimits: RateLimits?
    public let cost: CostCounters?
    public let contextWindow: ContextCounters?

    public init(
        capturedAtEpoch: Int64,
        sessionId: String?,
        model: Model?,
        rateLimits: RateLimits?,
        cost: CostCounters?,
        contextWindow: ContextCounters?
    ) {
        self.schemaVersion = 1
        self.capturedAtEpoch = capturedAtEpoch
        self.sessionId = sessionId
        self.model = model
        self.rateLimits = rateLimits
        self.cost = cost
        self.contextWindow = contextWindow
    }

    public struct Model: Codable, Equatable, Sendable {
        public let id: String?
        public let displayName: String?

        public init(id: String?, displayName: String?) {
            self.id = id
            self.displayName = displayName
        }

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    public struct RateLimits: Codable, Equatable, Sendable {
        public let fiveHour: RateLimitWindow?
        public let sevenDay: RateLimitWindow?
        public let spendLimit: RateLimitWindow?

        public init(fiveHour: RateLimitWindow?, sevenDay: RateLimitWindow?, spendLimit: RateLimitWindow?) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.spendLimit = spendLimit
        }

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case spendLimit = "spend_limit"
        }
    }

    public struct RateLimitWindow: Codable, Equatable, Sendable {
        public let usedPercentage: Double?
        public let resetsAt: Int64?

        public init(usedPercentage: Double?, resetsAt: Int64?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    public struct CostCounters: Codable, Equatable, Sendable {
        public let totalAPIDurationMS: Int64?
        public let totalDurationMS: Int64?

        public init(totalAPIDurationMS: Int64?, totalDurationMS: Int64?) {
            self.totalAPIDurationMS = totalAPIDurationMS
            self.totalDurationMS = totalDurationMS
        }

        enum CodingKeys: String, CodingKey {
            case totalAPIDurationMS = "total_api_duration_ms"
            case totalDurationMS = "total_duration_ms"
        }
    }

    public struct ContextCounters: Codable, Equatable, Sendable {
        public let contextWindowSize: Int64?
        public let totalInputTokens: Int64?
        public let totalOutputTokens: Int64?
        public let currentUsage: CurrentUsage?

        public init(
            contextWindowSize: Int64?,
            totalInputTokens: Int64?,
            totalOutputTokens: Int64?,
            currentUsage: CurrentUsage?
        ) {
            self.contextWindowSize = contextWindowSize
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.currentUsage = currentUsage
        }

        enum CodingKeys: String, CodingKey {
            case contextWindowSize = "context_window_size"
            case totalInputTokens = "total_input_tokens"
            case totalOutputTokens = "total_output_tokens"
            case currentUsage = "current_usage"
        }
    }

    public struct CurrentUsage: Codable, Equatable, Sendable {
        public let inputTokens: Int64?
        public let outputTokens: Int64?
        public let cacheCreationInputTokens: Int64?
        public let cacheReadInputTokens: Int64?

        public init(
            inputTokens: Int64?,
            outputTokens: Int64?,
            cacheCreationInputTokens: Int64?,
            cacheReadInputTokens: Int64?
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case capturedAtEpoch = "captured_at_epoch"
        case sessionId = "session_id"
        case model
        case rateLimits = "rate_limits"
        case cost
        case contextWindow = "context_window"
    }
}

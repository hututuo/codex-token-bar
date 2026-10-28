import Foundation

enum UsageClient: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case claudeDesktop
    case deepseek
    case gemini
    case opencode

    /// These readers account for local transcript or database records. They do not query a provider account.
    var isSupported: Bool { true }
    var supportsLocalUsage: Bool { true }
    var supportsCloudUsage: Bool { false }
    var usesSQLite: Bool { self == .opencode }
}

/// A normalized, locally recorded usage event. Reasoning tokens are a subset of output tokens.
struct ClientUsageEvent: Codable, Equatable, Sendable {
    static let maximumTokenCount: Int64 = 1_000_000_000_000

    var client: UsageClient
    /// Stable within a client and session; normally includes the provider message or request id.
    var eventID: String
    var sessionID: String
    var model: String
    var timestamp: Date
    /// Total prompt usage, including any cache read or write fields reported separately by the source.
    var inputTokens: Int64
    /// Total completion usage, including reasoning when the source reports reasoning separately.
    var outputTokens: Int64
    var cacheReadTokens: Int64?
    var cacheWriteTokens: Int64?
    /// A subset of outputTokens; callers must not add it to outputTokens again.
    var reasoningTokens: Int64?
    /// `recorded` uses a source id; `fallback_identity` hashes normalized metadata because no id was present.
    var quality: String

    init(
        client: UsageClient,
        eventID: String,
        sessionID: String,
        model: String,
        timestamp: Date,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64? = nil,
        cacheWriteTokens: Int64? = nil,
        reasoningTokens: Int64? = nil,
        quality: String = "recorded"
    ) {
        self.client = client
        self.eventID = eventID
        self.sessionID = sessionID
        self.model = model.isEmpty ? "unknown" : model
        self.timestamp = timestamp
        self.inputTokens = Self.clamp(inputTokens)
        self.outputTokens = Self.clamp(outputTokens)
        self.cacheReadTokens = cacheReadTokens.map(Self.clamp)
        self.cacheWriteTokens = cacheWriteTokens.map(Self.clamp)
        self.reasoningTokens = reasoningTokens.map(Self.clamp)
        self.quality = quality
    }

    var totalTokens: Int64 { Self.saturatingSum(inputTokens, outputTokens) }

    /// Streaming transcripts may write the same response more than once. Keep its largest reported counts.
    func mergingUpdate(_ update: ClientUsageEvent) -> ClientUsageEvent {
        precondition(client == update.client && eventID == update.eventID && sessionID == update.sessionID)
        return ClientUsageEvent(
            client: client,
            eventID: eventID,
            sessionID: sessionID,
            model: update.timestamp >= timestamp && update.model != "unknown" ? update.model : model,
            timestamp: max(timestamp, update.timestamp),
            inputTokens: max(inputTokens, update.inputTokens),
            outputTokens: max(outputTokens, update.outputTokens),
            cacheReadTokens: Self.maximum(cacheReadTokens, update.cacheReadTokens),
            cacheWriteTokens: Self.maximum(cacheWriteTokens, update.cacheWriteTokens),
            reasoningTokens: Self.maximum(reasoningTokens, update.reasoningTokens),
            quality: quality == "fallback_identity" || update.quality == "fallback_identity"
                ? "fallback_identity"
                : "recorded"
        )
    }

    private static func clamp(_ value: Int64) -> Int64 {
        min(max(value, 0), maximumTokenCount)
    }

    private static func saturatingSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? maximumTokenCount : min(sum, maximumTokenCount)
    }

    private static func maximum(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (left?, right?): max(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case client, eventID, sessionID, model, timestamp, inputTokens, outputTokens
        case cacheReadTokens, cacheWriteTokens, reasoningTokens, quality
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            client: try values.decode(UsageClient.self, forKey: .client),
            eventID: try values.decode(String.self, forKey: .eventID),
            sessionID: try values.decode(String.self, forKey: .sessionID),
            model: try values.decode(String.self, forKey: .model),
            timestamp: try values.decode(Date.self, forKey: .timestamp),
            inputTokens: try values.decode(Int64.self, forKey: .inputTokens),
            outputTokens: try values.decode(Int64.self, forKey: .outputTokens),
            cacheReadTokens: try values.decodeIfPresent(Int64.self, forKey: .cacheReadTokens),
            cacheWriteTokens: try values.decodeIfPresent(Int64.self, forKey: .cacheWriteTokens),
            reasoningTokens: try values.decodeIfPresent(Int64.self, forKey: .reasoningTokens),
            quality: try values.decodeIfPresent(String.self, forKey: .quality) ?? "recorded"
        )
    }
}

/// Ordering used by the numeric multi-client cache-rankings query.
enum ClientCacheRankingOrder: Sendable {
    case lowestHit
    case latest
}

/// Matches the request admission and low/zero hit rules used by Codex cache rankings.
enum ClientCacheRankingPolicy {
    static let minimumInputTokens: Int64 = 1_000
    static let lowHitMinimumInputTokens: Int64 = 20_000
    static let lowHitRate = 0.3
}

/// Numeric cache-read projection for one locally recorded request event.
/// Cache writes remain available as their own field and are not counted as hits.
struct ClientCacheRankingRequest: Identifiable, Equatable, Sendable {
    var id: String { client.rawValue + ":" + eventID }
    let client: UsageClient
    let eventID: String
    let sessionID: String
    let model: String
    let timestamp: Date
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64?
    let cacheWriteTokens: Int64?

    /// The ranker uses cache reads as cached input; cache creation/write is not a hit.
    var cachedInputTokens: Int64? { cacheReadTokens }

    /// Unknown cache-read fields and zero-input requests do not produce a rate.
    var cacheHitRate: Double? {
        guard inputTokens > 0, let cacheReadTokens else { return nil }
        return Double(cacheReadTokens) / Double(inputTokens)
    }

    var uncachedInputTokens: Int64? {
        guard let cacheReadTokens else { return nil }
        return max(inputTokens - cacheReadTokens, 0)
    }

    /// Requests without cache-read data remain visible but cannot be ranked by hit rate.
    var isRankable: Bool {
        inputTokens >= ClientCacheRankingPolicy.minimumInputTokens && cacheHitRate != nil
    }

    var isZeroHit: Bool {
        inputTokens > 0 && cacheReadTokens == 0
    }

    var isLowHit: Bool {
        guard inputTokens >= ClientCacheRankingPolicy.lowHitMinimumInputTokens,
              let cacheHitRate else { return false }
        return cacheHitRate < ClientCacheRankingPolicy.lowHitRate
    }
}

/// Weighted numeric totals for one client session. Cache totals and the rate stay
/// nil if any request lacks that field, so missing source data is never counted as zero.
struct ClientCacheRankingSession: Identifiable, Equatable, Sendable {
    var id: String { client.rawValue + ":" + sessionID }
    let client: UsageClient
    let sessionID: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64?
    let cacheWriteTokens: Int64?
    let requests: Int
    let firstSeen: Date
    let lastSeen: Date
    let unknownCacheReadRequests: Int
    let unknownCacheWriteRequests: Int
    let lowHitRequests: Int
    let zeroHitRequests: Int
    let modelIDs: [String]

    var cachedInputTokens: Int64? { cacheReadTokens }
    var cacheHitRate: Double? {
        guard inputTokens > 0, let cacheReadTokens else { return nil }
        return Double(cacheReadTokens) / Double(inputTokens)
    }
    var isRankable: Bool {
        inputTokens >= ClientCacheRankingPolicy.minimumInputTokens && cacheHitRate != nil
    }
}

/// Bounded request rows plus complete per-session aggregates from the existing ledger.
struct ClientCacheRankingProjection: Equatable, Sendable {
    let requests: [ClientCacheRankingRequest]
    let sessions: [ClientCacheRankingSession]
    let matchingRequestCount: Int
    let requestLimit: Int

    var hasMoreRequests: Bool { requests.count < matchingRequestCount }

    static let empty = ClientCacheRankingProjection(requests: [], sessions: [], matchingRequestCount: 0, requestLimit: 0)
}

/// Stable keyset cursor for walking an OpenCode database without silently truncating older messages.
struct OpenCodeDatabaseCursor: Codable, Equatable, Sendable {
    var updatedAtMilliseconds: Int64
    var messageID: String
}

/// One bounded page from OpenCode's local message table. Skipped-row counts are page-local diagnostics.
struct OpenCodeDatabasePage: Equatable, Sendable {
    var events: [ClientUsageEvent]
    var nextCursor: OpenCodeDatabaseCursor?
    var isComplete: Bool
    var skippedMalformedRows: Int
    var skippedOversizedRows: Int
}

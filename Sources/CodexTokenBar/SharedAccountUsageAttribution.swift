import CryptoKit
import Foundation

enum SharedAccountRadarTier: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case twentyXPro
    case fiveXPro
    case plus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twentyXPro: "20x Pro"
        case .fiveXPro: "5x Pro"
        case .plus: "Plus"
        }
    }

    static func storedValue(for rawValue: String?) -> SharedAccountRadarTier {
        SharedAccountRadarTier(rawValue: rawValue ?? "") ?? .twentyXPro
    }

    func matches(radarTier rawValue: String) -> Bool {
        let key = Self.normalizedTierKey(rawValue)
        switch self {
        case .twentyXPro:
            return ["20xpro", "pro20x", "chatgptpro20x", "20pro", "pro20"].contains(key)
        case .fiveXPro:
            return ["5xpro", "pro5x", "chatgptpro5x", "5pro", "pro5"].contains(key)
        case .plus:
            return ["plus", "chatgptplus", "plusplan"].contains(key)
        }
    }

    func sevenDayRow(in radar: CodexRadarQuotaRadar) -> CodexRadarQuotaRow? {
        guard radar.isWindowAvailable(.sevenDay) else { return nil }
        return radar.rows.first { row in
            matches(radarTier: row.tier) && (row.sevenD ?? 0) > 0
        }
    }

    private static func normalizedTierKey(_ rawValue: String) -> String {
        CodexRadarJSONKeyMatcher.canonical(
            rawValue
                .replacingOccurrences(of: "×", with: "x")
                .replacingOccurrences(of: "倍", with: "x")
        )
    }
}

enum SharedAccountRadarPriceRevision: String, Codable, Hashable, Sendable {
    case radar20260730
    case currentOfficial
    case unavailable

    var title: String {
        switch self {
        case .radar20260730: "Radar 2026-07-30 价格基准"
        case .currentOfficial: "现行官方 API 价格"
        case .unavailable: "Radar 价格版本未知"
        }
    }

    var isLegacy: Bool { self == .radar20260730 }

    func rates(for model: OfficialAPIPriceModel) -> APIPriceRates? {
        switch self {
        case .currentOfficial:
            return model.currentPriceRates
        case .radar20260730:
            // Public Codex Radar 2026-07-30 price card:
            // https://codexradar.com/
            switch model {
            case .gpt56Sol:
                return APIPriceRates(inputUSDPerMillion: 5.00, cachedInputUSDPerMillion: 0.50, outputUSDPerMillion: 30.00)
            case .gpt56Terra:
                return APIPriceRates(inputUSDPerMillion: 2.00, cachedInputUSDPerMillion: 0.20, outputUSDPerMillion: 12.00)
            case .gpt56Luna:
                return APIPriceRates(inputUSDPerMillion: 0.20, cachedInputUSDPerMillion: 0.02, outputUSDPerMillion: 1.20)
            case .gpt53Codex, .gpt52Codex:
                return APIPriceRates(inputUSDPerMillion: 1.75, cachedInputUSDPerMillion: 0.175, outputUSDPerMillion: 14.00)
            case .gpt54Legacy:
                return APIPriceRates(inputUSDPerMillion: 2.50, cachedInputUSDPerMillion: 0.25, outputUSDPerMillion: 15.00)
            case .gpt54MiniLegacy:
                return APIPriceRates(inputUSDPerMillion: 0.75, cachedInputUSDPerMillion: 0.075, outputUSDPerMillion: 4.50)
            }
        case .unavailable:
            return nil
        }
    }

    static func compatible(with radar: CodexRadarQuotaRadar) -> SharedAccountRadarPriceRevision {
        // `basisDate` is the measurement date, not a fixed pricing revision.
        // Keep the two historical dates that older payloads exposed, then accept
        // later measurements only when Radar explicitly identifies the same
        // direct quota-API pipeline. This avoids breaking the calculation every
        // time a fresh measurement advances the date while still failing closed
        // for an unknown or differently sourced quota table.
        guard let dateKey = Self.dateKey(radar.basisDate) else {
            return .unavailable
        }
        switch dateKey {
        case "2026-07-30": return .radar20260730
        case "2026-07-31": return .currentOfficial
        default:
            guard dateKey > "2026-07-31",
                  CodexRadarJSONKeyMatcher.canonical(radar.sourceKind ?? "") == "quotaapi",
                  CodexRadarJSONKeyMatcher.canonical(radar.sevenDayPolicy ?? "") == "directquotaapi" else {
                return .unavailable
            }
            return .currentOfficial
        }
    }

    private static func dateKey(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let prefix = String(trimmed.prefix(10))
        guard prefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        guard let year = Int(prefix.prefix(4)),
              let month = Int(prefix.dropFirst(5).prefix(2)),
              let day = Int(prefix.suffix(2)) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year, normalized.month == month, normalized.day == day else {
            return nil
        }
        return prefix
    }
}

enum SharedAccountUsageAttributionState: Equatable, Sendable {
    case disabled
    case preciseUsagePending
    case preciseUsageStale
    case attributionStorageUnavailable
    case awaitingAccountSwitchBaseline
    case missingSevenDayQuota
    case missingQuotaReset
    case missingStableAccountIdentity
    case missingRadarTierBaseline
    case missingCompatiblePriceRevision
    case awaitingQuotaRefresh
    case localHistoryAmbiguous
    case withinTolerance
    case suspectedNonLocalUsage
    case localEstimateExceedsAccountDrop
}

struct SharedAccountUsageHighWatermarkKey: Hashable, Codable, Sendable {
    let homeIdentity: String
    let stableAccountKey: String
    let planType: String
    let limitID: String
    let resetAt: Date
    let segmentStart: Date
    let tier: SharedAccountRadarTier
    let model: OfficialAPIPriceModel
    let priceRevision: SharedAccountRadarPriceRevision

    var scopeIdentifier: String {
        let source = [homeIdentity, stableAccountKey, planType, limitID]
            .joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var storageIdentifier: String {
        // Raw token buckets do not depend on the selected tier, model, or price
        // card. Keep those fields for audit/UI context, but deliberately exclude
        // them from persistence identity so changing presentation assumptions
        // cannot discard this segment's local history after sessions are archived.
        // segmentStart separates A -> B -> A switches inside one quota cycle.
        let source = [
            homeIdentity,
            stableAccountKey,
            planType,
            limitID,
            String(format: "%.3f", resetAt.timeIntervalSince1970),
            String(format: "%.3f", segmentStart.timeIntervalSince1970),
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct SharedAccountUsageHighWatermarkBucket: Codable, Equatable, Sendable {
    let start: Date
    let breakdown: TokenCacheBreakdown

    func merging(_ candidate: SharedAccountUsageHighWatermarkBucket) -> SharedAccountUsageHighWatermarkBucket {
        SharedAccountUsageHighWatermarkBucket(
            start: start,
            breakdown: TokenCacheBreakdown(
                inputTokens: max(breakdown.inputTokens, candidate.breakdown.inputTokens),
                cachedInputTokens: max(breakdown.cachedInputTokens, candidate.breakdown.cachedInputTokens),
                outputTokens: max(breakdown.outputTokens, candidate.breakdown.outputTokens),
                reasoningOutputTokens: max(
                    breakdown.reasoningOutputTokens,
                    candidate.breakdown.reasoningOutputTokens
                ),
                totalTokens: max(breakdown.totalTokens, candidate.breakdown.totalTokens),
                calls: max(breakdown.calls, candidate.breakdown.calls)
            )
        )
    }
}

struct SharedAccountUsageHighWatermarkRecord: Codable, Equatable, Sendable {
    let cycleResetAt: Date
    let buckets: [String: SharedAccountUsageHighWatermarkBucket]
    let contributions: [String: TokenCacheAttributionEvent]
    let eventProvenanceComplete: Bool
    let provenanceEpoch: String?
    let priceRevision: SharedAccountRadarPriceRevision
    let observedAt: Date
    let scopeIdentifier: String?
    let coverageStart: Date
    let coverageEnd: Date
    let ambiguityDetected: Bool
    let quotaObservationFresh: Bool

    var breakdown: TokenCacheBreakdown {
        buckets.values.map(\.breakdown).combined
    }

    func breakdown(from start: Date, before end: Date) -> TokenCacheBreakdown {
        buckets.values
            .filter { bucket in
                bucket.start >= start && bucket.start < end
            }
            .map(\.breakdown)
            .combined
    }

    func hasTokenUsage(from start: Date, before end: Date) -> Bool {
        buckets.values.contains { bucket in
            guard bucket.start >= start && bucket.start < end else { return false }
            return Self.hasObservedUsage(bucket.breakdown)
        }
    }

    init(
        cycleResetAt: Date,
        bins: [TokenCacheBucket],
        priceRevision: SharedAccountRadarPriceRevision,
        observedAt: Date,
        scopeIdentifier: String? = nil,
        coverageStart: Date? = nil,
        coverageEnd: Date? = nil,
        ambiguityDetected: Bool = false,
        quotaObservationFresh: Bool = true,
        attributionEvents: [TokenCacheAttributionEvent]? = nil,
        provenanceEpoch: String? = nil,
        sourceMutationDetected: Bool = false
    ) {
        self.cycleResetAt = cycleResetAt
        let observedBuckets: [String: SharedAccountUsageHighWatermarkBucket] = bins.reduce(into: [:]) { values, bin in
            let key = Self.bucketKey(bin.start)
            let candidate = SharedAccountUsageHighWatermarkBucket(
                start: bin.start,
                breakdown: bin.breakdown
            )
            if let existing = values[key] {
                values[key] = SharedAccountUsageHighWatermarkBucket(
                    start: bin.start,
                    breakdown: [existing.breakdown, candidate.breakdown].combined
                )
            } else {
                values[key] = candidate
            }
        }
        self.buckets = observedBuckets.filter { _, bucket in
            Self.hasObservedUsage(bucket.breakdown)
        }
        let inferredStart = bins.map(\.start).min() ?? cycleResetAt
        let inferredEnd = bins.map(\.start).max()?.addingTimeInterval(300) ?? inferredStart
        self.coverageStart = coverageStart ?? inferredStart
        self.coverageEnd = coverageEnd ?? inferredEnd
        var contributionConflict = false
        var observedContributions: [String: TokenCacheAttributionEvent] = [:]
        for event in attributionEvents ?? []
        where event.start >= self.coverageStart && event.start < self.coverageEnd {
            if let existing = observedContributions[event.id], existing != event {
                contributionConflict = true
            } else {
                observedContributions[event.id] = event
            }
        }
        self.contributions = observedContributions
        let contributionBuckets = Self.buckets(from: observedContributions.values)
        self.eventProvenanceComplete = attributionEvents != nil
            && !contributionConflict
            && contributionBuckets == self.buckets
        self.provenanceEpoch = provenanceEpoch
        self.priceRevision = priceRevision
        self.observedAt = observedAt
        self.scopeIdentifier = scopeIdentifier
        self.ambiguityDetected = ambiguityDetected
            || sourceMutationDetected
            || (attributionEvents != nil && !self.eventProvenanceComplete)
        self.quotaObservationFresh = quotaObservationFresh
    }

    private init(
        cycleResetAt: Date,
        buckets: [String: SharedAccountUsageHighWatermarkBucket],
        contributions: [String: TokenCacheAttributionEvent],
        eventProvenanceComplete: Bool,
        provenanceEpoch: String?,
        priceRevision: SharedAccountRadarPriceRevision,
        observedAt: Date,
        scopeIdentifier: String?,
        coverageStart: Date,
        coverageEnd: Date,
        ambiguityDetected: Bool,
        quotaObservationFresh: Bool
    ) {
        self.cycleResetAt = cycleResetAt
        self.buckets = buckets
        self.contributions = contributions
        self.eventProvenanceComplete = eventProvenanceComplete
        self.provenanceEpoch = provenanceEpoch
        self.priceRevision = priceRevision
        self.observedAt = observedAt
        self.scopeIdentifier = scopeIdentifier
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
        self.ambiguityDetected = ambiguityDetected
        self.quotaObservationFresh = quotaObservationFresh
    }

    func merging(_ candidate: SharedAccountUsageHighWatermarkRecord) -> SharedAccountUsageHighWatermarkRecord {
        guard abs(candidate.cycleResetAt.timeIntervalSince(cycleResetAt)) < 0.5 else {
            return self
        }
        if let scopeIdentifier, let candidateScope = candidate.scopeIdentifier,
           scopeIdentifier != candidateScope {
            return self
        }
        var detectedAmbiguity = ambiguityDetected || candidate.ambiguityDetected
        let sameProvenanceEpoch = provenanceEpoch != nil
            && provenanceEpoch == candidate.provenanceEpoch
        let canMergeEventProvenance = eventProvenanceComplete
            && candidate.eventProvenanceComplete
            && sameProvenanceEpoch
        var mergedContributions = contributions
        let mergedBuckets: [String: SharedAccountUsageHighWatermarkBucket]
        if canMergeEventProvenance {
            for (id, contribution) in candidate.contributions {
                if let existing = mergedContributions[id] {
                    if existing.start != contribution.start {
                        detectedAmbiguity = true
                    } else {
                        mergedContributions[id] = Self.merging(
                            existing,
                            contribution
                        )
                    }
                } else {
                    mergedContributions[id] = contribution
                }
            }
            mergedBuckets = Self.buckets(from: mergedContributions.values)
        } else {
            if eventProvenanceComplete || candidate.eventProvenanceComplete {
                detectedAmbiguity = true
            }
            for (key, storedBucket) in buckets
            where storedBucket.start >= candidate.coverageStart
                && storedBucket.start < candidate.coverageEnd {
                let candidateBreakdown = candidate.buckets[key]?.breakdown ?? .empty
                if Self.hasDecrease(from: storedBucket.breakdown, to: candidateBreakdown) {
                    detectedAmbiguity = true
                }
            }
            var aggregateBuckets = buckets
            for (key, candidateBucket) in candidate.buckets {
                aggregateBuckets[key] = aggregateBuckets[key]?.merging(candidateBucket) ?? candidateBucket
            }
            mergedBuckets = aggregateBuckets
        }
        let candidateIsNewer = candidate.observedAt >= observedAt
        let materiallyMerged = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: cycleResetAt,
            buckets: mergedBuckets,
            contributions: mergedContributions,
            eventProvenanceComplete: canMergeEventProvenance,
            provenanceEpoch: provenanceEpoch ?? candidate.provenanceEpoch,
            priceRevision: candidateIsNewer ? candidate.priceRevision : priceRevision,
            observedAt: observedAt,
            scopeIdentifier: scopeIdentifier ?? candidate.scopeIdentifier,
            coverageStart: min(coverageStart, candidate.coverageStart),
            coverageEnd: max(coverageEnd, candidate.coverageEnd),
            ambiguityDetected: detectedAmbiguity,
            quotaObservationFresh: quotaObservationFresh || candidate.quotaObservationFresh
        )
        // A background refresh that only changes the wall-clock observation
        // time must not rewrite the durable ledger. Coverage, raw tokens,
        // provenance, freshness, or price-basis changes still advance it.
        guard materiallyMerged != self else { return self }
        return SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: materiallyMerged.cycleResetAt,
            buckets: materiallyMerged.buckets,
            contributions: materiallyMerged.contributions,
            eventProvenanceComplete: materiallyMerged.eventProvenanceComplete,
            provenanceEpoch: materiallyMerged.provenanceEpoch,
            priceRevision: materiallyMerged.priceRevision,
            observedAt: max(observedAt, candidate.observedAt),
            scopeIdentifier: materiallyMerged.scopeIdentifier,
            coverageStart: materiallyMerged.coverageStart,
            coverageEnd: materiallyMerged.coverageEnd,
            ambiguityDetected: materiallyMerged.ambiguityDetected,
            quotaObservationFresh: materiallyMerged.quotaObservationFresh
        )
    }

    private static func bucketKey(_ start: Date) -> String {
        String(Int64(start.timeIntervalSince1970.rounded()))
    }

    private static func buckets<S>(from contributions: S)
        -> [String: SharedAccountUsageHighWatermarkBucket]
        where S: Sequence, S.Element == TokenCacheAttributionEvent {
        var grouped: [String: SharedAccountUsageHighWatermarkBucket] = [:]
        for contribution in contributions where hasObservedUsage(contribution.breakdown) {
            let key = bucketKey(contribution.start)
            if let existing = grouped[key] {
                grouped[key] = SharedAccountUsageHighWatermarkBucket(
                    start: contribution.start,
                    breakdown: [existing.breakdown, contribution.breakdown].combined
                )
            } else {
                grouped[key] = SharedAccountUsageHighWatermarkBucket(
                    start: contribution.start,
                    breakdown: contribution.breakdown
                )
            }
        }
        return grouped
    }

    private static func merging(
        _ stored: TokenCacheAttributionEvent,
        _ candidate: TokenCacheAttributionEvent
    ) -> TokenCacheAttributionEvent {
        TokenCacheAttributionEvent(
            id: stored.id,
            start: stored.start,
            model: stored.model ?? candidate.model,
            breakdown: TokenCacheBreakdown(
                inputTokens: max(
                    stored.breakdown.inputTokens,
                    candidate.breakdown.inputTokens
                ),
                cachedInputTokens: max(
                    stored.breakdown.cachedInputTokens,
                    candidate.breakdown.cachedInputTokens
                ),
                outputTokens: max(
                    stored.breakdown.outputTokens,
                    candidate.breakdown.outputTokens
                ),
                reasoningOutputTokens: max(
                    stored.breakdown.reasoningOutputTokens,
                    candidate.breakdown.reasoningOutputTokens
                ),
                totalTokens: max(
                    stored.breakdown.totalTokens,
                    candidate.breakdown.totalTokens
                ),
                calls: max(stored.breakdown.calls, candidate.breakdown.calls)
            )
        )
    }

    private static func hasObservedUsage(_ breakdown: TokenCacheBreakdown) -> Bool {
        breakdown.inputTokens > 0
            || breakdown.cachedInputTokens > 0
            || breakdown.outputTokens > 0
            || breakdown.reasoningOutputTokens > 0
            || breakdown.totalTokens > 0
    }

    private static func hasDecrease(
        from stored: TokenCacheBreakdown,
        to candidate: TokenCacheBreakdown
    ) -> Bool {
        candidate.inputTokens < stored.inputTokens
            || candidate.cachedInputTokens < stored.cachedInputTokens
            || candidate.outputTokens < stored.outputTokens
            || candidate.reasoningOutputTokens < stored.reasoningOutputTokens
            || candidate.totalTokens < stored.totalTokens
    }

    static func migratedLegacy(
        cycleResetAt: Date,
        buckets: [String: SharedAccountUsageHighWatermarkBucket],
        priceRevision: SharedAccountRadarPriceRevision,
        observedAt: Date,
        scopeIdentifier: String?,
        coverageStart: Date?,
        coverageEnd: Date?,
        quotaObservationFresh: Bool
    ) -> SharedAccountUsageHighWatermarkRecord {
        let inferredStart = buckets.values.map(\.start).min() ?? cycleResetAt
        let inferredEnd = buckets.values.map(\.start).max()?.addingTimeInterval(300)
            ?? inferredStart
        return SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: cycleResetAt,
            buckets: buckets,
            contributions: [:],
            eventProvenanceComplete: false,
            provenanceEpoch: nil,
            priceRevision: priceRevision,
            observedAt: observedAt,
            scopeIdentifier: scopeIdentifier,
            coverageStart: coverageStart ?? inferredStart,
            coverageEnd: coverageEnd ?? inferredEnd,
            // Aggregate-only records cannot prove what happened when a source
            // disappeared inside a bucket. Preserve their local amount, but
            // never let an upgrade immediately infer positive non-local usage.
            ambiguityDetected: true,
            quotaObservationFresh: quotaObservationFresh
        )
    }
}

private struct LegacySharedAccountUsageHighWatermarkRecord: Decodable {
    let cycleResetAt: Date
    let buckets: [String: SharedAccountUsageHighWatermarkBucket]
    let priceRevision: SharedAccountRadarPriceRevision
    let observedAt: Date
    let scopeIdentifier: String?
    let coverageStart: Date?
    let coverageEnd: Date?
    let quotaObservationFresh: Bool?
}

protocol SharedAccountUsageHighWatermarkStoring {
    func record(for key: SharedAccountUsageHighWatermarkKey) -> SharedAccountUsageHighWatermarkRecord?
    @discardableResult
    func merge(
        _ candidate: SharedAccountUsageHighWatermarkRecord,
        for key: SharedAccountUsageHighWatermarkKey
    ) -> SharedAccountUsageHighWatermarkRecord
}

final class UserDefaultsSharedAccountUsageHighWatermarkStore: SharedAccountUsageHighWatermarkStoring {
    static let defaultStorageKey = "sharedAccountUsageAttributionHighWatermarksV05"
    static let defaultLegacyStorageKeys = [
        "sharedAccountUsageAttributionHighWatermarksV04",
        "sharedAccountUsageAttributionHighWatermarksV03",
    ]
    static var allMigrationStorageKeys: [String] {
        [defaultStorageKey] + defaultLegacyStorageKeys
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let legacyStorageKeys: [String]
    private let safetyDatabase: SharedAccountUsageSafetyDatabase?
    private(set) var persistenceHealthy = true

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = defaultStorageKey,
        legacyStorageKeys: [String] = defaultLegacyStorageKeys,
        safetyDatabase: SharedAccountUsageSafetyDatabase? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.legacyStorageKeys = legacyStorageKeys
        self.safetyDatabase = safetyDatabase
    }

    func record(for key: SharedAccountUsageHighWatermarkKey) -> SharedAccountUsageHighWatermarkRecord? {
        records()?[key.storageIdentifier]
    }

    @discardableResult
    func merge(
        _ candidate: SharedAccountUsageHighWatermarkRecord,
        for key: SharedAccountUsageHighWatermarkKey
    ) -> SharedAccountUsageHighWatermarkRecord {
        if let safetyDatabase {
            // Import any UserDefaults-era payload before the first atomic
            // SQLite read-modify-write. Production never treats a
            // CFPreferences readback as a durable commit.
            guard records() != nil else { return candidate }
            let result = safetyDatabase.mutate(.highWatermarks) { data in
                var values: [String: SharedAccountUsageHighWatermarkRecord]
                if let data {
                    guard let decoded = try? JSONDecoder().decode(
                        [String: SharedAccountUsageHighWatermarkRecord].self,
                        from: data
                    ) else {
                        throw SharedAccountUsageSafetyStorageError.corruptPayload
                    }
                    values = decoded
                } else {
                    values = [:]
                }
                let originalValues = values
                let merged = Self.merge(candidate, for: key, into: &values)
                let nextData = values == originalValues
                    ? data
                    : try JSONEncoder().encode(values)
                return (nextData, merged)
            }
            persistenceHealthy = result != nil && safetyDatabase.persistenceHealthy
            return result ?? candidate
        }

        guard var values = records() else { return candidate }
        let originalValues = values
        let merged = Self.merge(candidate, for: key, into: &values)
        if values != originalValues {
            persist(values)
        }
        return merged
    }

    private func records() -> [String: SharedAccountUsageHighWatermarkRecord]? {
        if let safetyDatabase {
            if let data = safetyDatabase.load(.highWatermarks) {
                guard let values = try? JSONDecoder().decode(
                    [String: SharedAccountUsageHighWatermarkRecord].self,
                    from: data
                ) else {
                    safetyDatabase.reportCorruptPayload(.highWatermarks)
                    persistenceHealthy = false
                    return nil
                }
                guard retireUserDefaultsMigrationSources() else {
                    safetyDatabase.reportRecoveryRequired()
                    return nil
                }
                persistenceHealthy = true
                return values
            }
            guard safetyDatabase.persistenceHealthy else {
                persistenceHealthy = false
                return nil
            }
            guard let migrated = recordsFromUserDefaults() else {
                safetyDatabase.reportRecoveryRequired()
                return nil
            }
            guard let data = try? JSONEncoder().encode(migrated),
                  safetyDatabase.store(data, as: .highWatermarks),
                  safetyDatabase.load(.highWatermarks) == data,
                  retireUserDefaultsMigrationSources() else {
                safetyDatabase.reportRecoveryRequired()
                persistenceHealthy = false
                return nil
            }
            persistenceHealthy = true
            return migrated
        }
        return recordsFromUserDefaults()
    }

    private func recordsFromUserDefaults() -> [String: SharedAccountUsageHighWatermarkRecord]? {
        if let data = defaults.data(forKey: storageKey) {
            guard let values = try? JSONDecoder().decode(
                    [String: SharedAccountUsageHighWatermarkRecord].self,
                    from: data
                  ) else {
                persistenceHealthy = false
                return nil
            }
            persistenceHealthy = true
            return values
        }

        for legacyStorageKey in legacyStorageKeys {
            guard let data = defaults.data(forKey: legacyStorageKey) else { continue }
            guard let legacy = try? JSONDecoder().decode(
                    [String: LegacySharedAccountUsageHighWatermarkRecord].self,
                    from: data
                  ) else {
                persistenceHealthy = false
                return nil
            }
            let migrated = legacy.mapValues { record in
                SharedAccountUsageHighWatermarkRecord.migratedLegacy(
                    cycleResetAt: record.cycleResetAt,
                    buckets: record.buckets,
                    priceRevision: record.priceRevision,
                    observedAt: record.observedAt,
                    scopeIdentifier: record.scopeIdentifier,
                    coverageStart: record.coverageStart,
                    coverageEnd: record.coverageEnd,
                    quotaObservationFresh: record.quotaObservationFresh ?? false
                )
            }
            if safetyDatabase == nil {
                guard persistToUserDefaults(migrated) else { return nil }
            }
            return migrated
        }

        persistenceHealthy = true
        return [:]
    }

    @discardableResult
    private func persist(_ values: [String: SharedAccountUsageHighWatermarkRecord]) -> Bool {
        guard let data = try? JSONEncoder().encode(values) else {
            persistenceHealthy = false
            return false
        }
        if let safetyDatabase {
            let succeeded = safetyDatabase.store(data, as: .highWatermarks)
            persistenceHealthy = succeeded && safetyDatabase.persistenceHealthy
            return persistenceHealthy
        }
        return persistToUserDefaults(values, encoded: data)
    }

    @discardableResult
    private func persistToUserDefaults(
        _ values: [String: SharedAccountUsageHighWatermarkRecord],
        encoded data: Data? = nil
    ) -> Bool {
        guard let data = data ?? (try? JSONEncoder().encode(values)) else {
            persistenceHealthy = false
            return false
        }
        defaults.set(data, forKey: storageKey)
        guard defaults.data(forKey: storageKey) == data,
              let decoded = try? JSONDecoder().decode(
                [String: SharedAccountUsageHighWatermarkRecord].self,
                from: data
              ),
              decoded == values else {
            persistenceHealthy = false
            return false
        }
        persistenceHealthy = true
        return true
    }

    private static func merge(
        _ candidate: SharedAccountUsageHighWatermarkRecord,
        for key: SharedAccountUsageHighWatermarkKey,
        into values: inout [String: SharedAccountUsageHighWatermarkRecord]
    ) -> SharedAccountUsageHighWatermarkRecord {
        let identifier = key.storageIdentifier
        let merged = values[identifier]?.merging(candidate) ?? candidate
        values[identifier] = merged
        if candidate.quotaObservationFresh, let scopeIdentifier = candidate.scopeIdentifier {
            let retainedResets = Set(
                Set(
                    values.values
                        .filter { $0.scopeIdentifier == scopeIdentifier }
                        .map(\.cycleResetAt)
                )
                .sorted(by: >)
                .prefix(2)
            )
            values = values.filter { _, record in
                record.scopeIdentifier != scopeIdentifier
                    || retainedResets.contains(record.cycleResetAt)
            }
        }
        return merged
    }

    private func retireUserDefaultsMigrationSources() -> Bool {
        for key in [storageKey] + legacyStorageKeys
        where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            guard defaults.object(forKey: key) == nil else {
                safetyDatabase?.reportRecoveryRequired()
                persistenceHealthy = false
                return false
            }
        }
        return true
    }
}

enum SharedAccountUsageSafetyStorageError: Error {
    case corruptPayload
}

enum SharedAccountUsageCutoverReason: String, Codable, Equatable, Sendable {
    case none
    case initialActivation
    case accountSwitch
    case continuityGap
    case storageRecovery
    case legacyMigration

    var isContinuityRecovery: Bool {
        self == .continuityGap || self == .storageRecovery
    }
}

struct SharedAccountUsageSegment: Codable, Equatable, Sendable {
    let cycleResetAt: Date
    let start: Date
    let accountUsedBaselinePercent: Double
    let switchedAccountDuringCycle: Bool
    let baselineReady: Bool
    let baselineObservedAt: Date
    /// Latest quota value that materially changed this attribution segment.
    /// Poll timestamps with an unchanged integer percentage do not move this
    /// comparison watermark or force another full local-history refresh.
    let accountUsedObservedPercent: Double
    let comparisonUpdatedAt: Date
    /// A quota percentage first observed inside an open 5-minute bucket cannot
    /// safely be compared until that bucket closes and local exact coverage has
    /// caught up. Keep the movement pending without repeatedly rescanning the
    /// same open bucket.
    let quotaMovementPendingUntil: Date?
    /// When a pending movement is released by a later quota poll, require one
    /// exact local observation at or after that poll. This lets the scan reveal
    /// any local use in the poll's still-open bucket before a positive residual
    /// can be shown, without rescanning for every same-bucket percentage change.
    let requiredLocalObservationAfter: Date?
    /// Optional for forward-compatible decoding of local preview records that
    /// predate explicit cutover reasons.
    let cutoverReason: SharedAccountUsageCutoverReason?
    let cutoverDetectedAt: Date?
    let cutoverRecoveredAt: Date?
    let continuityGapID: UUID?
    /// Exact-index generation that supplied the first clean recovery scan.
    /// Unsafe scans deliberately leave this nil, so the first clean generation
    /// must overwrite any legacy/polluted pending or ready cutover.
    let cutoverRecoveryGeneration: Int64?

    init(
        cycleResetAt: Date,
        start: Date,
        accountUsedBaselinePercent: Double,
        switchedAccountDuringCycle: Bool,
        baselineReady: Bool,
        baselineObservedAt: Date,
        accountUsedObservedPercent: Double,
        comparisonUpdatedAt: Date,
        quotaMovementPendingUntil: Date? = nil,
        requiredLocalObservationAfter: Date? = nil,
        cutoverReason: SharedAccountUsageCutoverReason? = nil,
        cutoverDetectedAt: Date? = nil,
        cutoverRecoveredAt: Date? = nil,
        continuityGapID: UUID? = nil,
        cutoverRecoveryGeneration: Int64? = nil
    ) {
        self.cycleResetAt = cycleResetAt
        self.start = start
        self.accountUsedBaselinePercent = accountUsedBaselinePercent
        self.switchedAccountDuringCycle = switchedAccountDuringCycle
        self.baselineReady = baselineReady
        self.baselineObservedAt = baselineObservedAt
        self.accountUsedObservedPercent = accountUsedObservedPercent
        self.comparisonUpdatedAt = comparisonUpdatedAt
        self.quotaMovementPendingUntil = quotaMovementPendingUntil
        self.requiredLocalObservationAfter = requiredLocalObservationAfter
        self.cutoverReason = cutoverReason
        self.cutoverDetectedAt = cutoverDetectedAt
        self.cutoverRecoveredAt = cutoverRecoveredAt
        self.continuityGapID = continuityGapID
        self.cutoverRecoveryGeneration = cutoverRecoveryGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case cycleResetAt
        case start
        case accountUsedBaselinePercent
        case switchedAccountDuringCycle
        case baselineReady
        case baselineObservedAt
        case accountUsedObservedPercent
        case comparisonUpdatedAt
        case quotaMovementPendingUntil
        case requiredLocalObservationAfter
        case cutoverReason
        case cutoverDetectedAt
        case cutoverRecoveredAt
        case continuityGapID
        case cutoverRecoveryGeneration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cycleResetAt = try container.decode(Date.self, forKey: .cycleResetAt)
        start = try container.decode(Date.self, forKey: .start)
        accountUsedBaselinePercent = try container.decode(Double.self, forKey: .accountUsedBaselinePercent)
        switchedAccountDuringCycle = try container.decode(Bool.self, forKey: .switchedAccountDuringCycle)
        baselineReady = try container.decode(Bool.self, forKey: .baselineReady)
        baselineObservedAt = try container.decode(Date.self, forKey: .baselineObservedAt)
        accountUsedObservedPercent = try container.decode(Double.self, forKey: .accountUsedObservedPercent)
        comparisonUpdatedAt = try container.decode(Date.self, forKey: .comparisonUpdatedAt)
        quotaMovementPendingUntil = try container.decodeIfPresent(Date.self, forKey: .quotaMovementPendingUntil)
        requiredLocalObservationAfter = try container.decodeIfPresent(Date.self, forKey: .requiredLocalObservationAfter)
        cutoverReason = try container.decodeIfPresent(SharedAccountUsageCutoverReason.self, forKey: .cutoverReason)
        cutoverDetectedAt = try container.decodeIfPresent(Date.self, forKey: .cutoverDetectedAt)
        cutoverRecoveredAt = try container.decodeIfPresent(Date.self, forKey: .cutoverRecoveredAt)
        continuityGapID = try container.decodeIfPresent(UUID.self, forKey: .continuityGapID)
        cutoverRecoveryGeneration = try container.decodeIfPresent(
            Int64.self,
            forKey: .cutoverRecoveryGeneration
        )
    }

    var effectiveCutoverReason: SharedAccountUsageCutoverReason {
        cutoverReason ?? (switchedAccountDuringCycle ? .accountSwitch : .none)
    }
}

private struct SharedAccountUsageSegmentRecord: Codable, Equatable {
    let accountScopeIdentifier: String
    let resetAt: Date
    let segment: SharedAccountUsageSegment
    let observerInstanceID: UUID?
}

private struct LegacySharedAccountUsageSegmentRecordHeader: Decodable {
    let resetAt: Date
}

final class UserDefaultsSharedAccountUsageSegmentStore {
    static let defaultStorageKey = "sharedAccountUsageAttributionSegmentsV07"
    static let defaultLegacyStorageKeys = [
        "sharedAccountUsageAttributionSegmentsV06",
        "sharedAccountUsageAttributionSegmentsV05",
        "sharedAccountUsageAttributionSegmentsV04",
        "sharedAccountUsageAttributionSegmentsV03",
        "sharedAccountUsageAttributionSegmentsV02",
    ]
    static var allMigrationStorageKeys: [String] {
        [defaultStorageKey] + defaultLegacyStorageKeys
    }
    static let resetGraceInterval: TimeInterval = 2 * 60

    private let defaults: UserDefaults
    private let storageKey: String
    private let legacyStorageKeys: [String]
    private let safetyDatabase: SharedAccountUsageSafetyDatabase?
    private var observerInstanceID: UUID?
    private(set) var persistenceHealthy = true

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = defaultStorageKey,
        legacyStorageKeys: [String] = defaultLegacyStorageKeys,
        safetyDatabase: SharedAccountUsageSafetyDatabase? = nil,
        observerInstanceID: UUID? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.legacyStorageKeys = legacyStorageKeys
        self.safetyDatabase = safetyDatabase
        self.observerInstanceID = observerInstanceID
    }

    func setObserverInstanceID(_ observerInstanceID: UUID?) {
        self.observerInstanceID = observerInstanceID
    }

    static func attributionSafetyGapID(
        provenanceEpoch: String,
        unsafeSinceGeneration: Int64
    ) -> UUID {
        let digest = Array(SHA256.hash(data: Data(
            "\(provenanceEpoch)\u{1f}\(unsafeSinceGeneration)".utf8
        )))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    static func attributionSafetyGapID(
        provenanceEpoch: String?,
        unsafeSinceGeneration: Int64?,
        currentScanUnsafeCauseDetected: Bool
    ) -> UUID? {
        // A rewrite/lineage conflict still present in the current exact scan is
        // not a recovery snapshot. It must not create or advance a quota
        // baseline. Only the first clean scan carrying the sticky latest
        // episode generation is allowed to materialize a cutover identity.
        guard !currentScanUnsafeCauseDetected,
              let provenanceEpoch,
              let unsafeSinceGeneration else { return nil }
        return attributionSafetyGapID(
            provenanceEpoch: provenanceEpoch,
            unsafeSinceGeneration: unsafeSinceGeneration
        )
    }

    func resolve(
        identity: QuotaHistoryIdentity,
        resetAt: Date,
        cycleStart: Date,
        quotaUpdatedAt: Date,
        accountUsedPercent: Double
    ) -> SharedAccountUsageSegment {
        let homeIdentifier = Self.digest(identity.homeIdentity)
        let accountScopeIdentifier = Self.digest([
            identity.stableAccountKey,
            identity.planType,
            identity.limitID,
        ].joined(separator: "\u{1f}"))
        guard var values = records() else {
            return failClosedSegment(
                resetAt: resetAt,
                cycleStart: cycleStart,
                quotaUpdatedAt: quotaUpdatedAt,
                accountUsedPercent: accountUsedPercent
            )
        }
        let existing = values[homeIdentifier]
        let sameCycle = existing.map {
            abs($0.resetAt.timeIntervalSince(resetAt)) <= Self.resetGraceInterval
        } ?? false
        if sameCycle,
           existing?.accountScopeIdentifier == accountScopeIdentifier,
           let observerInstanceID,
           existing?.observerInstanceID != observerInstanceID {
            // A new process cannot prove that a short-lived local session was
            // not created and deleted while the previous observer was down.
            // Start a fresh synthetic baseline instead of carrying a ready
            // residual across that unobserved interval.
            let canonicalResetAt = existing?.resetAt ?? resetAt
            let alignedObservation = Date(
                timeIntervalSince1970: ceil(quotaUpdatedAt.timeIntervalSince1970 / 300) * 300
            )
            let pending = SharedAccountUsageSegment(
                cycleResetAt: canonicalResetAt,
                start: max(cycleStart, min(alignedObservation, canonicalResetAt)),
                accountUsedBaselinePercent: max(0, accountUsedPercent),
                switchedAccountDuringCycle: false,
                baselineReady: false,
                baselineObservedAt: quotaUpdatedAt,
                accountUsedObservedPercent: max(0, accountUsedPercent),
                comparisonUpdatedAt: quotaUpdatedAt,
                quotaMovementPendingUntil: nil,
                requiredLocalObservationAfter: nil,
                cutoverReason: .continuityGap,
                cutoverDetectedAt: quotaUpdatedAt,
                cutoverRecoveredAt: nil,
                continuityGapID: nil
            )
            values[homeIdentifier] = SharedAccountUsageSegmentRecord(
                accountScopeIdentifier: accountScopeIdentifier,
                resetAt: canonicalResetAt,
                segment: pending,
                observerInstanceID: observerInstanceID
            )
            return persist(values)
                ? pending
                : failClosedSegment(
                    resetAt: canonicalResetAt,
                    cycleStart: cycleStart,
                    quotaUpdatedAt: quotaUpdatedAt,
                    accountUsedPercent: accountUsedPercent
                )
        }
        if sameCycle, existing?.accountScopeIdentifier == accountScopeIdentifier,
           let segment = existing?.segment {
            guard !segment.baselineReady,
                  quotaUpdatedAt >= segment.start,
                  quotaUpdatedAt > segment.baselineObservedAt else {
                if segment.baselineReady,
                   abs(accountUsedPercent - segment.accountUsedObservedPercent) > 0.000_1 {
                    let movementBoundary = Date(
                        timeIntervalSince1970: ceil(
                            quotaUpdatedAt.timeIntervalSince1970 / 300
                        ) * 300
                    )
                    let advanced = SharedAccountUsageSegment(
                        cycleResetAt: segment.cycleResetAt,
                        start: segment.start,
                        accountUsedBaselinePercent: segment.accountUsedBaselinePercent,
                        switchedAccountDuringCycle: segment.switchedAccountDuringCycle,
                        baselineReady: true,
                        baselineObservedAt: segment.baselineObservedAt,
                        accountUsedObservedPercent: max(0, accountUsedPercent),
                        comparisonUpdatedAt: segment.comparisonUpdatedAt,
                        quotaMovementPendingUntil: max(
                            segment.quotaMovementPendingUntil ?? .distantPast,
                            movementBoundary
                        ),
                        requiredLocalObservationAfter: segment.requiredLocalObservationAfter,
                        cutoverReason: segment.cutoverReason,
                        cutoverDetectedAt: segment.cutoverDetectedAt,
                        cutoverRecoveredAt: segment.cutoverRecoveredAt,
                        continuityGapID: segment.continuityGapID,
                        cutoverRecoveryGeneration: segment.cutoverRecoveryGeneration
                    )
                    values[homeIdentifier] = SharedAccountUsageSegmentRecord(
                        accountScopeIdentifier: accountScopeIdentifier,
                        resetAt: segment.cycleResetAt,
                        segment: advanced,
                        observerInstanceID: observerInstanceID
                    )
                    return persist(values)
                        ? advanced
                        : failClosedSegment(
                            resetAt: segment.cycleResetAt,
                            cycleStart: cycleStart,
                            quotaUpdatedAt: quotaUpdatedAt,
                            accountUsedPercent: accountUsedPercent
                        )
                }
                return segment
            }

            // Account switching is detected between two quota snapshots. Wait
            // until the first fresh snapshot beyond the next complete 5-minute
            // boundary, then anchor the quota baseline there while retaining the
            // original token boundary. Pre-boundary usage is excluded from both
            // sides. Usage between that boundary and this baseline remains only
            // on the local side, so the residual is conservatively biased away
            // from falsely assigning it to another user.
            let finalized = SharedAccountUsageSegment(
                cycleResetAt: segment.cycleResetAt,
                start: segment.start,
                accountUsedBaselinePercent: max(0, accountUsedPercent),
                switchedAccountDuringCycle: segment.switchedAccountDuringCycle,
                baselineReady: true,
                baselineObservedAt: quotaUpdatedAt,
                accountUsedObservedPercent: max(0, accountUsedPercent),
                comparisonUpdatedAt: quotaUpdatedAt,
                quotaMovementPendingUntil: nil,
                requiredLocalObservationAfter: quotaUpdatedAt,
                cutoverReason: segment.cutoverReason,
                cutoverDetectedAt: segment.cutoverDetectedAt,
                cutoverRecoveredAt: segment.cutoverRecoveredAt,
                continuityGapID: segment.continuityGapID,
                cutoverRecoveryGeneration: segment.cutoverRecoveryGeneration
            )
            values[homeIdentifier] = SharedAccountUsageSegmentRecord(
                accountScopeIdentifier: accountScopeIdentifier,
                resetAt: segment.cycleResetAt,
                segment: finalized,
                observerInstanceID: observerInstanceID
            )
            return persist(values)
                ? finalized
                : failClosedSegment(
                    resetAt: segment.cycleResetAt,
                    cycleStart: cycleStart,
                    quotaUpdatedAt: quotaUpdatedAt,
                    accountUsedPercent: accountUsedPercent
                )
        }

        let legacySameCycle = existing == nil && legacyStorageKeys.contains { key in
            guard let reset = legacyResetAt(for: homeIdentifier, storageKey: key) else {
                return false
            }
            return abs(reset.timeIntervalSince(resetAt)) <= Self.resetGraceInterval
        }
        // A missing current-cycle record is unsafe whether this is the first
        // launch ever or a restart after reset. We cannot prove that local
        // sessions remained present while Token Bar was not observing them.
        let firstObservation = !sameCycle && !legacySameCycle
        let switchedAccount = sameCycle
            && existing?.accountScopeIdentifier != accountScopeIdentifier
        let needsCutover = firstObservation || legacySameCycle || switchedAccount
        let cutoverReason: SharedAccountUsageCutoverReason = if legacySameCycle {
            .legacyMigration
        } else if firstObservation {
            .initialActivation
        } else if switchedAccount {
            .accountSwitch
        } else {
            .none
        }
        let canonicalResetAt = sameCycle ? (existing?.resetAt ?? resetAt) : resetAt
        let alignedObservation = Date(
            timeIntervalSince1970: ceil(quotaUpdatedAt.timeIntervalSince1970 / 300) * 300
        )
        let segment = SharedAccountUsageSegment(
            cycleResetAt: canonicalResetAt,
            start: needsCutover ? max(cycleStart, min(alignedObservation, canonicalResetAt)) : cycleStart,
            accountUsedBaselinePercent: needsCutover ? max(0, accountUsedPercent) : 0,
            switchedAccountDuringCycle: switchedAccount,
            baselineReady: !needsCutover,
            baselineObservedAt: needsCutover ? quotaUpdatedAt : cycleStart,
            accountUsedObservedPercent: max(0, accountUsedPercent),
            comparisonUpdatedAt: quotaUpdatedAt,
            quotaMovementPendingUntil: needsCutover ? nil : alignedObservation,
            requiredLocalObservationAfter: nil,
            cutoverReason: cutoverReason,
            cutoverDetectedAt: needsCutover ? quotaUpdatedAt : nil,
            cutoverRecoveredAt: nil,
            continuityGapID: nil
        )
        values[homeIdentifier] = SharedAccountUsageSegmentRecord(
            accountScopeIdentifier: accountScopeIdentifier,
            resetAt: canonicalResetAt,
            segment: segment,
            observerInstanceID: observerInstanceID
        )
        return persist(values)
            ? segment
            : failClosedSegment(
                resetAt: canonicalResetAt,
                cycleStart: cycleStart,
                quotaUpdatedAt: quotaUpdatedAt,
                accountUsedPercent: accountUsedPercent
            )
    }

    /// Read the durable segment without advancing any quota baseline. This is
    /// used while the quota snapshot is stale so raw local buckets keep the
    /// same persistence key but no conclusion can move forward.
    func existingSegment(
        identity: QuotaHistoryIdentity,
        resetAt: Date
    ) -> SharedAccountUsageSegment? {
        let homeIdentifier = Self.digest(identity.homeIdentity)
        let accountScopeIdentifier = Self.digest([
            identity.stableAccountKey,
            identity.planType,
            identity.limitID,
        ].joined(separator: "\u{1f}"))
        guard let values = records(),
              let record = values[homeIdentifier],
              record.accountScopeIdentifier == accountScopeIdentifier,
              observerInstanceID == nil || record.observerInstanceID == observerInstanceID,
              abs(record.resetAt.timeIntervalSince(resetAt)) <= Self.resetGraceInterval else {
            return nil
        }
        return record.segment
    }

    /// A failed exact scan creates an interval in which local usage may have
    /// existed and then disappeared before recovery. Start a persisted pending
    /// cutover instead of ever assigning that unknown interval to another user.
    @discardableResult
    func beginContinuityGapCutover(
        identity: QuotaHistoryIdentity,
        resetAt: Date,
        cycleStart: Date,
        quotaUpdatedAt: Date,
        accountUsedPercent: Double,
        gapID: UUID,
        gapDetectedAt: Date,
        recoveredCoverageAt: Date,
        cutoverReason: SharedAccountUsageCutoverReason = .continuityGap,
        cleanRecoveryGeneration: Int64? = nil
    ) -> SharedAccountUsageSegment {
        let homeIdentifier = Self.digest(identity.homeIdentity)
        let accountScopeIdentifier = Self.digest([
            identity.stableAccountKey,
            identity.planType,
            identity.limitID,
        ].joined(separator: "\u{1f}"))
        guard var values = records() else {
            return failClosedSegment(
                resetAt: resetAt,
                cycleStart: cycleStart,
                quotaUpdatedAt: quotaUpdatedAt,
                accountUsedPercent: accountUsedPercent
            )
        }
        let existing = values[homeIdentifier]
        let sameCycle = existing.map {
            abs($0.resetAt.timeIntervalSince(resetAt)) <= Self.resetGraceInterval
        } ?? false

        let sameCleanRecovery = cleanRecoveryGeneration == nil
            || existing?.segment.cutoverRecoveryGeneration == cleanRecoveryGeneration
        if sameCycle,
           existing?.accountScopeIdentifier == accountScopeIdentifier,
           let segment = existing?.segment,
           segment.effectiveCutoverReason == cutoverReason,
           segment.continuityGapID == gapID,
           sameCleanRecovery,
           observerInstanceID == nil || existing?.observerInstanceID == observerInstanceID {
            if !segment.baselineReady {
                let previousCoverage = segment.cutoverRecoveredAt ?? .distantPast
                guard quotaUpdatedAt > segment.baselineObservedAt,
                      recoveredCoverageAt > previousCoverage,
                      recoveredCoverageAt >= quotaUpdatedAt else {
                    return segment
                }
            }
            return resolve(
                identity: identity,
                resetAt: resetAt,
                cycleStart: cycleStart,
                quotaUpdatedAt: quotaUpdatedAt,
                accountUsedPercent: accountUsedPercent
            )
        }

        let canonicalResetAt = sameCycle ? (existing?.resetAt ?? resetAt) : resetAt
        let alignedRecovery = Date(
            timeIntervalSince1970: ceil(recoveredCoverageAt.timeIntervalSince1970 / 300) * 300
        )
        let pending = SharedAccountUsageSegment(
            cycleResetAt: canonicalResetAt,
            start: max(cycleStart, min(alignedRecovery, canonicalResetAt)),
            accountUsedBaselinePercent: max(0, accountUsedPercent),
            switchedAccountDuringCycle: false,
            baselineReady: false,
            baselineObservedAt: quotaUpdatedAt,
            accountUsedObservedPercent: max(0, accountUsedPercent),
            comparisonUpdatedAt: quotaUpdatedAt,
            quotaMovementPendingUntil: nil,
            requiredLocalObservationAfter: nil,
            cutoverReason: cutoverReason,
            cutoverDetectedAt: gapDetectedAt,
            cutoverRecoveredAt: recoveredCoverageAt,
            continuityGapID: gapID,
            cutoverRecoveryGeneration: cleanRecoveryGeneration
        )
        values[homeIdentifier] = SharedAccountUsageSegmentRecord(
            accountScopeIdentifier: accountScopeIdentifier,
            resetAt: canonicalResetAt,
            segment: pending,
            observerInstanceID: observerInstanceID
        )
        return persist(values)
            ? pending
            : failClosedSegment(
                resetAt: canonicalResetAt,
                cycleStart: cycleStart,
                quotaUpdatedAt: quotaUpdatedAt,
                accountUsedPercent: accountUsedPercent
            )
    }

    func advanceComparisonAcrossCompletedBoundaryIfNeeded(
        identity: QuotaHistoryIdentity,
        resetAt: Date,
        quotaUpdatedAt: Date,
        accountUsedPercent: Double
    ) -> SharedAccountUsageSegment? {
        let homeIdentifier = Self.digest(identity.homeIdentity)
        let accountScopeIdentifier = Self.digest([
            identity.stableAccountKey,
            identity.planType,
            identity.limitID,
        ].joined(separator: "\u{1f}"))
        guard var values = records() else { return nil }
        guard let record = values[homeIdentifier],
              record.accountScopeIdentifier == accountScopeIdentifier,
              observerInstanceID == nil || record.observerInstanceID == observerInstanceID,
              abs(record.resetAt.timeIntervalSince(resetAt)) <= Self.resetGraceInterval,
              record.segment.baselineReady,
              quotaUpdatedAt > record.segment.comparisonUpdatedAt else {
            return nil
        }
        let previousBoundary = floor(
            record.segment.comparisonUpdatedAt.timeIntervalSince1970 / 300
        )
        let nextBoundary = floor(quotaUpdatedAt.timeIntervalSince1970 / 300)
        let movementPending = record.segment.quotaMovementPendingUntil != nil
        let pendingMovementMatured = record.segment.quotaMovementPendingUntil.map {
            quotaUpdatedAt >= $0
        } ?? false
        let canAdvance = movementPending
            ? pendingMovementMatured
            : nextBoundary > previousBoundary
        guard canAdvance else {
            return nil
        }

        let advanced = SharedAccountUsageSegment(
            cycleResetAt: record.segment.cycleResetAt,
            start: record.segment.start,
            accountUsedBaselinePercent: record.segment.accountUsedBaselinePercent,
            switchedAccountDuringCycle: record.segment.switchedAccountDuringCycle,
            baselineReady: true,
            baselineObservedAt: record.segment.baselineObservedAt,
            accountUsedObservedPercent: max(0, accountUsedPercent),
            comparisonUpdatedAt: quotaUpdatedAt,
            quotaMovementPendingUntil: nil,
            requiredLocalObservationAfter: quotaUpdatedAt,
            cutoverReason: record.segment.cutoverReason,
            cutoverDetectedAt: record.segment.cutoverDetectedAt,
            cutoverRecoveredAt: record.segment.cutoverRecoveredAt,
            continuityGapID: record.segment.continuityGapID,
            cutoverRecoveryGeneration: record.segment.cutoverRecoveryGeneration
        )
        values[homeIdentifier] = SharedAccountUsageSegmentRecord(
            accountScopeIdentifier: accountScopeIdentifier,
            resetAt: record.segment.cycleResetAt,
            segment: advanced,
            observerInstanceID: observerInstanceID
        )
        return persist(values) ? advanced : nil
    }

    @discardableResult
    private func persist(_ values: [String: SharedAccountUsageSegmentRecord]) -> Bool {
        guard let data = try? JSONEncoder().encode(values) else {
            persistenceHealthy = false
            return false
        }
        if let safetyDatabase {
            let succeeded = safetyDatabase.store(data, as: .segments)
            persistenceHealthy = succeeded && safetyDatabase.persistenceHealthy
            return persistenceHealthy
        }
        defaults.set(data, forKey: storageKey)
        guard defaults.data(forKey: storageKey) == data,
              let decoded = try? JSONDecoder().decode(
                [String: SharedAccountUsageSegmentRecord].self,
                from: data
              ),
              decoded == values else {
            persistenceHealthy = false
            return false
        }
        persistenceHealthy = true
        return true
    }

    private func records() -> [String: SharedAccountUsageSegmentRecord]? {
        if let safetyDatabase {
            if let data = safetyDatabase.load(.segments) {
                guard let values = try? JSONDecoder().decode(
                    [String: SharedAccountUsageSegmentRecord].self,
                    from: data
                ) else {
                    safetyDatabase.reportCorruptPayload(.segments)
                    persistenceHealthy = false
                    return nil
                }
                guard retireUserDefaultsMigrationSources() else {
                    safetyDatabase.reportRecoveryRequired()
                    return nil
                }
                persistenceHealthy = true
                return values
            }
            guard safetyDatabase.persistenceHealthy else {
                persistenceHealthy = false
                return nil
            }
            guard let migrated = recordsFromUserDefaults() else {
                safetyDatabase.reportRecoveryRequired()
                return nil
            }
            guard let data = try? JSONEncoder().encode(migrated),
                  safetyDatabase.store(data, as: .segments),
                  safetyDatabase.load(.segments) == data,
                  retireUserDefaultsMigrationSources() else {
                safetyDatabase.reportRecoveryRequired()
                persistenceHealthy = false
                return nil
            }
            persistenceHealthy = true
            return migrated
        }
        return recordsFromUserDefaults()
    }

    private func recordsFromUserDefaults() -> [String: SharedAccountUsageSegmentRecord]? {
        guard let data = defaults.data(forKey: storageKey) else {
            persistenceHealthy = true
            return [:]
        }
        guard let values = try? JSONDecoder().decode(
                [String: SharedAccountUsageSegmentRecord].self,
                from: data
              ) else {
            persistenceHealthy = false
            return nil
        }
        persistenceHealthy = true
        return values
    }

    private func failClosedSegment(
        resetAt: Date,
        cycleStart: Date,
        quotaUpdatedAt: Date,
        accountUsedPercent: Double
    ) -> SharedAccountUsageSegment {
        let boundary = Date(
            timeIntervalSince1970: ceil(quotaUpdatedAt.timeIntervalSince1970 / 300) * 300
        )
        return SharedAccountUsageSegment(
            cycleResetAt: resetAt,
            start: max(cycleStart, min(boundary, resetAt)),
            accountUsedBaselinePercent: max(0, accountUsedPercent),
            switchedAccountDuringCycle: false,
            baselineReady: false,
            baselineObservedAt: quotaUpdatedAt,
            accountUsedObservedPercent: max(0, accountUsedPercent),
            comparisonUpdatedAt: quotaUpdatedAt,
            cutoverReason: .continuityGap,
            cutoverDetectedAt: quotaUpdatedAt
        )
    }

    private func legacyResetAt(for homeIdentifier: String, storageKey: String) -> Date? {
        guard let data = defaults.data(forKey: storageKey),
              let values = try? JSONDecoder().decode(
                [String: LegacySharedAccountUsageSegmentRecordHeader].self,
                from: data
              ) else { return nil }
        return values[homeIdentifier]?.resetAt
    }

    private func retireUserDefaultsMigrationSources() -> Bool {
        // V06...V02 remain only as reset hints until each legacy Home receives
        // a synthetic cutover. They are never imported as a ready segment, so
        // they cannot revive a positive conclusion. The fully imported V07
        // payload is retired immediately.
        for key in [storageKey] where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            guard defaults.object(forKey: key) == nil else {
                safetyDatabase?.reportRecoveryRequired()
                persistenceHealthy = false
                return false
            }
        }
        return true
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct SharedAccountUsageAttributionResult: Equatable {
    let state: SharedAccountUsageAttributionState
    let tier: SharedAccountRadarTier
    let model: OfficialAPIPriceModel
    let detectedModels: [OfficialAPIPriceModel]
    let fallbackModelCalls: Int
    let excludedModels: [String]
    let excludedCalls: Int
    let priceRevision: SharedAccountRadarPriceRevision
    let cycleStart: Date?
    let cycleEnd: Date?
    let localSegmentStart: Date?
    let accountUsedBaselinePercent: Double
    let switchedAccountDuringCycle: Bool
    let cutoverReason: SharedAccountUsageCutoverReason
    let quotaUpdatedAt: Date?
    let accountUsedPercent: Double?
    let breakdown: TokenCacheBreakdown
    /// Complete aggregate values for the two quota-cycle edge buckets. The
    /// comparable middle range remains separate so an in-bucket reset cannot
    /// mix the previous and current cycle.
    let boundaryBreakdown: QuotaPeriodBoundaryBreakdown
    let scannedBreakdown: TokenCacheBreakdown
    let scannedComparableCostUSD: Double?
    let localComparableCostUSD: Double?
    let localCurrentOfficialCostUSD: Double?
    let radarSevenDayTotalUSD: Double?
    let localSharePercent: Double?
    let nonLocalDifferencePercent: Double?
    let radarBasis: String?
    let radarDate: String?
    let radarPricingBasisDate: String?
    let radarUpdatedAt: String?
    let radarSource: String?
    let quotaDataStale: Bool
    let radarDataStale: Bool
    let usagePendingQuotaRefresh: Bool
    let localHistoryAmbiguous: Bool
    let highWatermarkKey: SharedAccountUsageHighWatermarkKey?
    let highWatermarkCandidate: SharedAccountUsageHighWatermarkRecord?
    let usedHighWatermark: Bool

    var hasComputedAttribution: Bool {
        localSharePercent != nil && nonLocalDifferencePercent != nil
    }

    var usesSegmentBaseline: Bool {
        cutoverReason != .none
    }

    var needsPreciseCatchUp: Bool {
        state == .preciseUsageStale
    }

    var hasFinalAttributionConclusion: Bool {
        switch state {
        case .withinTolerance, .suspectedNonLocalUsage, .localEstimateExceedsAccountDrop:
            true
        default:
            false
        }
    }
}

enum SharedAccountUsageAttributionAutoRefreshPolicy {
    static func shouldRequestPreciseCatchUp(
        result: SharedAccountUsageAttributionResult,
        continuityLossID: UUID?,
        segment: SharedAccountUsageSegment?
    ) -> Bool {
        guard result.needsPreciseCatchUp else { return false }
        guard let continuityLossID else { return true }
        // A recovery cutover may request exactly one post-baseline scan. If it
        // fails, CodexUsageStore publishes a new loss UUID; that no longer
        // matches the segment and therefore cannot self-trigger another scan.
        return segment?.effectiveCutoverReason.isContinuityRecovery == true
            && segment?.continuityGapID == continuityLossID
            && segment?.baselineReady == true
    }
}

enum SharedAccountUsageAttributionSettings {
    static let enabledKey = "sharedAccountUsageAttributionEnabledV01"
    static let tierKey = "sharedAccountUsageAttributionRadarTierV01"
    static let defaultEnabled = true
    static let defaultTier = SharedAccountRadarTier.twentyXPro
    static let priceModelKey = "recentChartQuotaEstimateModel"
}

enum SharedAccountUsageAttributionPersistencePolicy {
    static func shouldMergeHighWatermark(
        attributionUnsafeSinceGeneration: Int64?
    ) -> Bool {
        attributionUnsafeSinceGeneration == nil
    }
}

enum SharedAccountUsageAttributionEstimator {
    static let comparisonTolerancePercent = 2.0
    static let sevenDayDuration: TimeInterval = 7 * 24 * 60 * 60
    static let recentBinDuration: TimeInterval = 5 * 60

    static func estimate(
        enabled: Bool,
        preciseUsageReady: Bool,
        recentBins: [TokenCacheBucket],
        recentAttributionEvents: [TokenCacheAttributionEvent]? = nil,
        attributionProvenanceEpoch: String? = nil,
        attributionSourceMutationDetected: Bool = false,
        sevenDayQuota: AccountQuotaWindow?,
        quotaUpdatedAt: Date?,
        historyIdentity: QuotaHistoryIdentity?,
        radar: CodexRadarQuotaRadar?,
        tier: SharedAccountRadarTier,
        model: OfficialAPIPriceModel,
        now: Date = Date(),
        preciseUsageFresh: Bool = true,
        persistenceHealthy: Bool = true,
        preciseUsageGeneratedAt: Date? = .distantFuture,
        segment: SharedAccountUsageSegment? = nil,
        highWatermark: SharedAccountUsageHighWatermarkRecord? = nil,
        quotaDataStale: Bool = false,
        radarDataStale: Bool = false
    ) -> SharedAccountUsageAttributionResult {
        let empty = TokenCacheBreakdown.empty
        let priceRevision = radar.map {
            SharedAccountRadarPriceRevision.compatible(with: $0)
        } ?? .unavailable
        let radarRow = radar.flatMap { tier.sevenDayRow(in: $0) }
        let radarTotal = radarRow?.sevenD
        guard enabled else {
            return unavailable(
                .disabled,
                tier: tier,
                model: model,
                priceRevision: priceRevision,
                breakdown: empty,
                radarTotalUSD: radarTotal,
                radarRow: radarRow,
                radar: radar
            )
        }
        guard preciseUsageReady else {
            return unavailable(
                .preciseUsagePending,
                tier: tier,
                model: model,
                priceRevision: priceRevision,
                breakdown: empty,
                radarTotalUSD: radarTotal,
                radarRow: radarRow,
                radar: radar
            )
        }
        guard persistenceHealthy else {
            return unavailable(
                .attributionStorageUnavailable,
                tier: tier,
                model: model,
                priceRevision: priceRevision,
                breakdown: empty,
                radarTotalUSD: radarTotal,
                radarRow: radarRow,
                radar: radar
            )
        }
        guard preciseUsageFresh else {
            return unavailable(
                .preciseUsageStale,
                tier: tier,
                model: model,
                priceRevision: priceRevision,
                breakdown: empty,
                radarTotalUSD: radarTotal,
                radarRow: radarRow,
                radar: radar
            )
        }
        guard let sevenDayQuota else {
            return unavailable(
                .missingSevenDayQuota,
                tier: tier,
                model: model,
                priceRevision: priceRevision,
                breakdown: empty,
                radarTotalUSD: radarTotal,
                radarRow: radarRow,
                radar: radar
            )
        }
        guard let observedResetAt = sevenDayQuota.resetsAt else {
            return unavailable(
                .missingQuotaReset,
                tier: tier,
                model: model,
                priceRevision: priceRevision,
                breakdown: empty,
                radarTotalUSD: radarTotal,
                radarRow: radarRow,
                radar: radar
            )
        }
        guard let historyIdentity else {
            return unavailable(
                .missingStableAccountIdentity,
                tier: tier,
                model: model,
                priceRevision: priceRevision,
                cycleStart: observedResetAt.addingTimeInterval(-sevenDayDuration),
                cycleEnd: observedResetAt,
                quotaUpdatedAt: quotaUpdatedAt,
                accountUsedPercent: Double(sevenDayQuota.usedPercent),
                breakdown: empty,
                radarTotalUSD: radarTotal,
                radarRow: radarRow,
                radar: radar
            )
        }

        let resetAt: Date
        if let segment,
           abs(segment.cycleResetAt.timeIntervalSince(observedResetAt))
            <= UserDefaultsSharedAccountUsageSegmentStore.resetGraceInterval {
            resetAt = segment.cycleResetAt
        } else {
            resetAt = observedResetAt
        }
        let cycleStart = resetAt.addingTimeInterval(-sevenDayDuration)
        let resolvedSegment = segment ?? SharedAccountUsageSegment(
            cycleResetAt: resetAt,
            start: cycleStart,
            accountUsedBaselinePercent: 0,
            switchedAccountDuringCycle: false,
            baselineReady: true,
            baselineObservedAt: cycleStart,
            accountUsedObservedPercent: max(0, Double(sevenDayQuota.usedPercent)),
            comparisonUpdatedAt: quotaUpdatedAt ?? cycleStart,
            quotaMovementPendingUntil: nil,
            requiredLocalObservationAfter: nil,
            cutoverReason: SharedAccountUsageCutoverReason.none,
            cutoverDetectedAt: nil,
            cutoverRecoveredAt: nil,
            continuityGapID: nil
        )
        let segmentStart = max(cycleStart, min(resolvedSegment.start, resetAt))
        // The cache projection is five-minute granular and has no event-level
        // timestamp. A bucket straddling a quota boundary cannot be split
        // faithfully, so leave a one-minute margin for the comparable middle
        // range and begin at the next complete bucket. The edge bucket totals
        // are retained separately below. Exact five-minute boundaries remain
        // inclusive.
        let localBucketStart = QuotaPeriodBoundaryPolicy.firstCompleteBucketStart(after: segmentStart)
        if let quotaUpdatedAt {
            // A quota snapshot can only be compared with fixed 5-minute local
            // buckets that ended before its timestamp. Coverage therefore only
            // needs to reach that closed-bucket boundary, not the poll's exact
            // second. This prevents several percentage changes inside one open
            // bucket from repeatedly forcing the same full history scan.
            let comparisonCoverageBoundary = min(
                resetAt,
                max(
                    cycleStart,
                    Date(
                        timeIntervalSince1970: floor(
                            quotaUpdatedAt.timeIntervalSince1970 / recentBinDuration
                        ) * recentBinDuration
                    )
                )
            )
            let requiredCoverage = max(
                comparisonCoverageBoundary,
                resolvedSegment.requiredLocalObservationAfter ?? comparisonCoverageBoundary
            )
            guard let preciseUsageGeneratedAt,
                  preciseUsageGeneratedAt >= requiredCoverage else {
                return unavailable(
                    .preciseUsageStale,
                    tier: tier,
                    model: model,
                    priceRevision: priceRevision,
                    cycleStart: cycleStart,
                    cycleEnd: resetAt,
                    quotaUpdatedAt: quotaUpdatedAt,
                    accountUsedPercent: Double(sevenDayQuota.usedPercent),
                    breakdown: empty,
                    radarTotalUSD: radarTotal,
                    radarRow: radarRow,
                    radar: radar
                )
            }
        }
        let cycleEnd = min(now, resetAt)
        let safeCycleEnd = QuotaPeriodBoundaryPolicy.lastCompleteBucketEnd(before: cycleEnd)
        let preciseCoverageEnd = min(
            cycleEnd,
            preciseUsageGeneratedAt ?? cycleEnd
        )
        let preciseAlignedEnd = max(
            localBucketStart,
            Date(
                timeIntervalSince1970: floor(
                    preciseCoverageEnd.timeIntervalSince1970 / recentBinDuration
                ) * recentBinDuration
            )
        )
        let quotaAlignedEnd = quotaUpdatedAt.map { updatedAt in
            Date(timeIntervalSince1970: floor(updatedAt.timeIntervalSince1970 / recentBinDuration) * recentBinDuration)
        }
        let comparisonEnd = min(
            preciseAlignedEnd,
            min(
                max(localBucketStart, quotaAlignedEnd ?? localBucketStart),
                safeCycleEnd
            )
        )
        let attributionBins = recentAttributionEvents.map(Self.sourceBucketBins)
            ?? recentBins
        let comparisonBins = attributionBins
            .filter { $0.start >= localBucketStart && $0.start < comparisonEnd }
            .sorted { $0.start < $1.start }
        let boundaryBreakdown = QuotaPeriodBoundaryPolicy.boundaryBreakdown(
            buckets: attributionBins,
            periodStart: segmentStart,
            periodEnd: cycleEnd
        )
        let persistenceBins = attributionBins
            // Raw high-water persistence intentionally includes the currently
            // open bucket after the safe period start. It is never compared
            // until the quota passes that bucket's end, but preserving the
            // partial maximum prevents a session archive from erasing known
            // local use.
            .filter { $0.start >= localBucketStart && $0.start < preciseCoverageEnd }
            .sorted { $0.start < $1.start }
        let persistenceAttributionEvents = recentAttributionEvents?.filter {
            $0.start >= localBucketStart && $0.start < preciseCoverageEnd
        }
        let comparisonAttributionEvents = recentAttributionEvents?.filter {
            $0.start >= localBucketStart && $0.start < comparisonEnd
        }
        let scannedBreakdown = comparisonBins.map(\.breakdown).combined
        let scannedHasPendingLocalUsage = attributionBins.contains { bin in
            bin.start >= comparisonEnd
                && bin.start < cycleEnd
                && (bin.breakdown.totalTokens > 0
                    || bin.breakdown.inputTokens > 0
                    || bin.breakdown.cachedInputTokens > 0
                    || bin.breakdown.outputTokens > 0
                    || bin.breakdown.reasoningOutputTokens > 0)
        }

        let highWatermarkKey = makeHighWatermarkKey(
            identity: historyIdentity,
            resetAt: resetAt,
            segmentStart: segmentStart,
            tier: tier,
            model: model,
            priceRevision: priceRevision
        )
        let rawCandidate = resetAt > now && quotaUpdatedAt != nil
            ? SharedAccountUsageHighWatermarkRecord(
                cycleResetAt: resetAt,
                bins: persistenceBins,
                priceRevision: priceRevision,
                observedAt: now,
                scopeIdentifier: highWatermarkKey?.scopeIdentifier,
                coverageStart: localBucketStart,
                coverageEnd: preciseCoverageEnd,
                quotaObservationFresh: !quotaDataStale,
                attributionEvents: persistenceAttributionEvents,
                provenanceEpoch: attributionProvenanceEpoch,
                sourceMutationDetected: attributionSourceMutationDetected
            )
            : nil
        let effectiveHighWatermark = if let highWatermark, let rawCandidate {
            highWatermark.merging(rawCandidate)
        } else {
            highWatermark ?? rawCandidate
        }
        let hasPendingLocalUsage = resolvedSegment.quotaMovementPendingUntil != nil
            || scannedHasPendingLocalUsage
            || (effectiveHighWatermark?.hasTokenUsage(
                from: comparisonEnd,
                before: cycleEnd
            ) ?? false)
        let protectedBreakdown = effectiveHighWatermark?.breakdown(
            from: localBucketStart,
            before: comparisonEnd
        ) ?? scannedBreakdown
        let protectedAttributionEvents: [TokenCacheAttributionEvent]? = if let effectiveHighWatermark,
           effectiveHighWatermark.eventProvenanceComplete {
            effectiveHighWatermark.contributions.values
                .filter { $0.start >= localBucketStart && $0.start < comparisonEnd }
        } else {
            comparisonAttributionEvents
        }
        let shouldUseHighWatermark = protectedBreakdown != scannedBreakdown
        let localHistoryAmbiguous = effectiveHighWatermark?.ambiguityDetected ?? false
        guard resolvedSegment.baselineReady else {
            let pendingCurrentCost = ModelAwareAPIPriceEstimator.estimate(
                events: protectedAttributionEvents,
                fallbackBreakdown: protectedBreakdown,
                fallbackModel: model,
                rates: { $0.currentPriceRates }
            )
            let pendingRadarRow = radar.flatMap { tier.sevenDayRow(in: $0) }
            let pendingRadarTotal = pendingRadarRow?.sevenD
            let pendingComparableCost: ModelAwareAPIPriceEstimate? = if priceRevision != .unavailable {
                ModelAwareAPIPriceEstimator.estimate(
                    events: protectedAttributionEvents,
                    fallbackBreakdown: protectedBreakdown,
                    fallbackModel: model,
                    rates: { priceRevision.rates(for: $0) ?? $0.currentPriceRates }
                )
            } else {
                nil
            }
            let pendingShare: Double? = if let cost = pendingComparableCost?.costUSD,
                                  let total = pendingRadarTotal,
                                  total > 0 {
                cost / total * 100
            } else {
                nil
            }
            if let radar,
               let pendingRadarRow,
               let pendingRadarTotal,
               let pendingComparableCost {
                return SharedAccountUsageAttributionResult(
                    state: .awaitingAccountSwitchBaseline,
                    tier: tier,
                    model: model,
                    detectedModels: pendingComparableCost.detectedModels,
                    fallbackModelCalls: pendingComparableCost.fallbackCalls,
                    excludedModels: pendingComparableCost.excludedModels,
                    excludedCalls: pendingComparableCost.excludedCalls,
                    priceRevision: priceRevision,
                    cycleStart: cycleStart,
                    cycleEnd: resetAt,
                    localSegmentStart: segmentStart,
                    accountUsedBaselinePercent: resolvedSegment.accountUsedBaselinePercent,
                    switchedAccountDuringCycle: resolvedSegment.switchedAccountDuringCycle,
                    cutoverReason: resolvedSegment.effectiveCutoverReason,
                    quotaUpdatedAt: quotaUpdatedAt,
                    accountUsedPercent: nil,
                    breakdown: protectedBreakdown,
                    boundaryBreakdown: boundaryBreakdown,
                    scannedBreakdown: scannedBreakdown,
                    scannedComparableCostUSD: nil,
                    localComparableCostUSD: pendingComparableCost.costUSD,
                    localCurrentOfficialCostUSD: pendingCurrentCost.costUSD,
                    radarSevenDayTotalUSD: pendingRadarTotal,
                    localSharePercent: pendingShare,
                    nonLocalDifferencePercent: nil,
                    radarBasis: pendingRadarRow.basis,
                    radarDate: radar.date,
                    radarPricingBasisDate: radar.basisDate,
                    radarUpdatedAt: radar.updatedAt,
                    radarSource: radar.source,
                    quotaDataStale: quotaDataStale,
                    radarDataStale: radarDataStale,
                    usagePendingQuotaRefresh: hasPendingLocalUsage,
                    localHistoryAmbiguous: localHistoryAmbiguous,
                    highWatermarkKey: highWatermarkKey,
                    highWatermarkCandidate: rawCandidate,
                    usedHighWatermark: shouldUseHighWatermark
                )
            }
            return unavailable(
                .awaitingAccountSwitchBaseline,
                tier: tier,
                model: model,
                priceRevision: priceRevision,
                cycleStart: cycleStart,
                cycleEnd: resetAt,
                localSegmentStart: segmentStart,
                accountUsedBaselinePercent: resolvedSegment.accountUsedBaselinePercent,
                switchedAccountDuringCycle: resolvedSegment.switchedAccountDuringCycle,
                cutoverReason: resolvedSegment.effectiveCutoverReason,
                quotaUpdatedAt: quotaUpdatedAt,
                breakdown: protectedBreakdown,
                scannedBreakdown: scannedBreakdown,
                currentOfficialCostUSD: pendingCurrentCost.costUSD,
                radarTotalUSD: pendingRadarTotal,
                radarRow: pendingRadarRow,
                radar: radar,
                quotaDataStale: quotaDataStale,
                radarDataStale: radarDataStale,
                usagePendingQuotaRefresh: hasPendingLocalUsage,
                localHistoryAmbiguous: localHistoryAmbiguous,
                highWatermarkKey: highWatermarkKey,
                highWatermarkCandidate: rawCandidate,
                usedHighWatermark: shouldUseHighWatermark
            )
        }
        let accountUsed = max(
            0,
            Double(sevenDayQuota.usedPercent) - resolvedSegment.accountUsedBaselinePercent
        )
        let currentOfficialEstimate = ModelAwareAPIPriceEstimator.estimate(
            events: protectedAttributionEvents,
            fallbackBreakdown: protectedBreakdown,
            fallbackModel: model,
            rates: { $0.currentPriceRates }
        )
        let currentOfficialCost = currentOfficialEstimate.costUSD

        guard let radar, let row = tier.sevenDayRow(in: radar), let radarTotal = row.sevenD else {
            return unavailable(
                .missingRadarTierBaseline,
                tier: tier,
                model: model,
                priceRevision: priceRevision,
                cycleStart: cycleStart,
                cycleEnd: resetAt,
                localSegmentStart: segmentStart,
                accountUsedBaselinePercent: resolvedSegment.accountUsedBaselinePercent,
                switchedAccountDuringCycle: resolvedSegment.switchedAccountDuringCycle,
                cutoverReason: resolvedSegment.effectiveCutoverReason,
                quotaUpdatedAt: quotaUpdatedAt,
                accountUsedPercent: accountUsed,
                breakdown: protectedBreakdown,
                boundaryBreakdown: boundaryBreakdown,
                scannedBreakdown: scannedBreakdown,
                currentOfficialCostUSD: currentOfficialCost,
                radar: radar,
                quotaDataStale: quotaDataStale,
                radarDataStale: radarDataStale,
                usagePendingQuotaRefresh: hasPendingLocalUsage,
                localHistoryAmbiguous: localHistoryAmbiguous,
                highWatermarkKey: highWatermarkKey,
                highWatermarkCandidate: rawCandidate,
                usedHighWatermark: shouldUseHighWatermark
            )
        }

        guard priceRevision != .unavailable else {
            return unavailable(
                .missingCompatiblePriceRevision,
                tier: tier,
                model: model,
                priceRevision: priceRevision,
                cycleStart: cycleStart,
                cycleEnd: resetAt,
                localSegmentStart: segmentStart,
                accountUsedBaselinePercent: resolvedSegment.accountUsedBaselinePercent,
                switchedAccountDuringCycle: resolvedSegment.switchedAccountDuringCycle,
                cutoverReason: resolvedSegment.effectiveCutoverReason,
                quotaUpdatedAt: quotaUpdatedAt,
                accountUsedPercent: accountUsed,
                breakdown: protectedBreakdown,
                scannedBreakdown: scannedBreakdown,
                currentOfficialCostUSD: currentOfficialCost,
                radarTotalUSD: radarTotal,
                radarRow: row,
                radar: radar,
                quotaDataStale: quotaDataStale,
                radarDataStale: radarDataStale,
                usagePendingQuotaRefresh: hasPendingLocalUsage,
                localHistoryAmbiguous: localHistoryAmbiguous,
                highWatermarkKey: highWatermarkKey,
                highWatermarkCandidate: rawCandidate,
                usedHighWatermark: shouldUseHighWatermark
            )
        }

        let scannedComparableEstimate = ModelAwareAPIPriceEstimator.estimate(
            events: comparisonAttributionEvents,
            fallbackBreakdown: scannedBreakdown,
            fallbackModel: model,
            rates: { priceRevision.rates(for: $0) ?? $0.currentPriceRates }
        )
        let localComparableEstimate = ModelAwareAPIPriceEstimator.estimate(
            events: protectedAttributionEvents,
            fallbackBreakdown: protectedBreakdown,
            fallbackModel: model,
            rates: { priceRevision.rates(for: $0) ?? $0.currentPriceRates }
        )
        let scannedComparableCost = scannedComparableEstimate.costUSD
        let localComparableCost = localComparableEstimate.costUSD
        let localCurrentOfficialCost = currentOfficialEstimate.costUSD
        let localShare = localComparableCost / radarTotal * 100
        let difference = accountUsed - localShare

        let quotaNeedsRefresh = resetAt <= now
            || quotaUpdatedAt == nil
            || hasPendingLocalUsage
            || quotaDataStale
            || radarDataStale
        let state: SharedAccountUsageAttributionState
        if quotaNeedsRefresh {
            state = .awaitingQuotaRefresh
        } else if localHistoryAmbiguous {
            state = .localHistoryAmbiguous
        } else if abs(difference) <= comparisonTolerancePercent {
            state = .withinTolerance
        } else if difference > comparisonTolerancePercent {
            state = .suspectedNonLocalUsage
        } else {
            state = .localEstimateExceedsAccountDrop
        }

        return SharedAccountUsageAttributionResult(
            state: state,
            tier: tier,
            model: model,
            detectedModels: localComparableEstimate.detectedModels,
            fallbackModelCalls: localComparableEstimate.fallbackCalls,
            excludedModels: localComparableEstimate.excludedModels,
            excludedCalls: localComparableEstimate.excludedCalls,
            priceRevision: priceRevision,
            cycleStart: cycleStart,
            cycleEnd: resetAt,
            localSegmentStart: segmentStart,
            accountUsedBaselinePercent: resolvedSegment.accountUsedBaselinePercent,
            switchedAccountDuringCycle: resolvedSegment.switchedAccountDuringCycle,
            cutoverReason: resolvedSegment.effectiveCutoverReason,
            quotaUpdatedAt: quotaUpdatedAt,
            accountUsedPercent: accountUsed,
            breakdown: protectedBreakdown,
            boundaryBreakdown: boundaryBreakdown,
            scannedBreakdown: scannedBreakdown,
            scannedComparableCostUSD: scannedComparableCost,
            localComparableCostUSD: localComparableCost,
            localCurrentOfficialCostUSD: localCurrentOfficialCost,
            radarSevenDayTotalUSD: radarTotal,
            localSharePercent: localShare,
            nonLocalDifferencePercent: difference,
            radarBasis: row.basis,
            radarDate: radar.date,
            radarPricingBasisDate: radar.basisDate,
            radarUpdatedAt: radar.updatedAt,
            radarSource: radar.source,
            quotaDataStale: quotaDataStale,
            radarDataStale: radarDataStale,
            usagePendingQuotaRefresh: hasPendingLocalUsage,
            localHistoryAmbiguous: localHistoryAmbiguous,
            highWatermarkKey: highWatermarkKey,
            highWatermarkCandidate: rawCandidate,
            usedHighWatermark: shouldUseHighWatermark
        )
    }

    private static func makeHighWatermarkKey(
        identity: QuotaHistoryIdentity?,
        resetAt: Date,
        segmentStart: Date,
        tier: SharedAccountRadarTier,
        model: OfficialAPIPriceModel,
        priceRevision: SharedAccountRadarPriceRevision
    ) -> SharedAccountUsageHighWatermarkKey? {
        guard let identity else { return nil }
        return SharedAccountUsageHighWatermarkKey(
            homeIdentity: identity.homeIdentity,
            stableAccountKey: identity.stableAccountKey,
            planType: identity.planType,
            limitID: identity.limitID,
            resetAt: resetAt,
            segmentStart: segmentStart,
            tier: tier,
            model: model,
            priceRevision: priceRevision
        )
    }

    private static func sourceBucketBins(
        _ contributions: [TokenCacheAttributionEvent]
    ) -> [TokenCacheBucket] {
        var grouped: [Date: [TokenCacheBreakdown]] = [:]
        for contribution in contributions {
            grouped[contribution.start, default: []].append(contribution.breakdown)
        }
        return grouped.map { start, values in
            TokenCacheBucket(start: start, breakdown: values.combined)
        }
        .sorted { $0.start < $1.start }
    }

    private static func unavailable(
        _ state: SharedAccountUsageAttributionState,
        tier: SharedAccountRadarTier,
        model: OfficialAPIPriceModel,
        priceRevision: SharedAccountRadarPriceRevision = .unavailable,
        cycleStart: Date? = nil,
        cycleEnd: Date? = nil,
        localSegmentStart: Date? = nil,
        accountUsedBaselinePercent: Double = 0,
        switchedAccountDuringCycle: Bool = false,
        cutoverReason: SharedAccountUsageCutoverReason = .none,
        quotaUpdatedAt: Date? = nil,
        accountUsedPercent: Double? = nil,
        breakdown: TokenCacheBreakdown,
        boundaryBreakdown: QuotaPeriodBoundaryBreakdown = .empty,
        scannedBreakdown: TokenCacheBreakdown? = nil,
        currentOfficialCostUSD: Double? = nil,
        radarTotalUSD: Double? = nil,
        radarRow: CodexRadarQuotaRow? = nil,
        radar: CodexRadarQuotaRadar? = nil,
        quotaDataStale: Bool = false,
        radarDataStale: Bool = false,
        usagePendingQuotaRefresh: Bool = false,
        localHistoryAmbiguous: Bool = false,
        highWatermarkKey: SharedAccountUsageHighWatermarkKey? = nil,
        highWatermarkCandidate: SharedAccountUsageHighWatermarkRecord? = nil,
        usedHighWatermark: Bool = false
    ) -> SharedAccountUsageAttributionResult {
        SharedAccountUsageAttributionResult(
            state: state,
            tier: tier,
            model: model,
            detectedModels: [],
            fallbackModelCalls: breakdown.calls,
            excludedModels: [],
            excludedCalls: 0,
            priceRevision: priceRevision,
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            localSegmentStart: localSegmentStart ?? cycleStart,
            accountUsedBaselinePercent: accountUsedBaselinePercent,
            switchedAccountDuringCycle: switchedAccountDuringCycle,
            cutoverReason: cutoverReason,
            quotaUpdatedAt: quotaUpdatedAt,
            accountUsedPercent: accountUsedPercent,
            breakdown: breakdown,
            boundaryBreakdown: boundaryBreakdown,
            scannedBreakdown: scannedBreakdown ?? breakdown,
            scannedComparableCostUSD: nil,
            localComparableCostUSD: nil,
            localCurrentOfficialCostUSD: currentOfficialCostUSD,
            radarSevenDayTotalUSD: radarTotalUSD,
            localSharePercent: nil,
            nonLocalDifferencePercent: nil,
            radarBasis: radarRow?.basis,
            radarDate: radar?.date,
            radarPricingBasisDate: radar?.basisDate,
            radarUpdatedAt: radar?.updatedAt,
            radarSource: radar?.source,
            quotaDataStale: quotaDataStale,
            radarDataStale: radarDataStale,
            usagePendingQuotaRefresh: usagePendingQuotaRefresh,
            localHistoryAmbiguous: localHistoryAmbiguous,
            highWatermarkKey: highWatermarkKey,
            highWatermarkCandidate: highWatermarkCandidate,
            usedHighWatermark: usedHighWatermark
        )
    }
}

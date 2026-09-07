import Foundation

/// A small, historical lookup for OpenAI's standard short-context API card.
///
/// This is deliberately separate from quota, subscription/Credits, Radar, and
/// service-tier pricing. It does not apply promotions, Batch/Flex rates, or
/// credits discounts. The UTC midnight cutovers below are an estimation
/// convention for event bucketing, not a claim about billing's exact second.
struct StandardAPIPriceQuote: Equatable, Sendable {
    /// Canonical model key retained by this schedule, independent of the
    /// legacy `OfficialAPIPriceModel` enum used by existing callers.
    let modelKey: String
    let rates: APIPriceRates
    let revision: String

    var inputUSDPerMillion: Double { rates.inputUSDPerMillion }
    var cachedInputUSDPerMillion: Double { rates.cachedInputUSDPerMillion }
    var outputUSDPerMillion: Double { rates.outputUSDPerMillion }
}

/// Historical standard API prices used for event-time cost estimates.
///
/// Callers must pass an event date to `quote(for:at:)`. A missing date is not
/// silently treated as "now"; use `currentQuote(for:)` when current pricing
/// is explicitly intended. Auto-review aliases and the independent Spark
/// quota are intentionally outside this table.
enum StandardAPIPriceSchedule {
    private static let solCutover = utcDate(year: 2026, month: 8, day: 21)
    private static let terraAndLunaCutover = utcDate(year: 2026, month: 7, day: 30)

    static let revision = "standard-api-dated-v1"
    static func sqlPartitionExpression(timestamp: String) -> String {
        "CASE WHEN \(timestamp) >= \(Int(solCutover.timeIntervalSince1970)) THEN 2 WHEN \(timestamp) >= \(Int(terraAndLunaCutover.timeIntervalSince1970)) THEN 1 ELSE 0 END"
    }
    static func partitionStart(at date: Date) -> Date {
        if date >= solCutover { return solCutover }
        if date >= terraAndLunaCutover { return terraAndLunaCutover }
        return Date(timeIntervalSince1970: 0)
    }

    /// Resolve a raw model string to its stable key without migrating it to
    /// the old enum/storage identifiers.
    static func canonicalModelKey(for rawModel: String?) -> String? {
        guard let rawModel else { return nil }
        let key = rawModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")

        switch key {
        case "gpt-6-astra", "gpt6-astra", "gpt6astra":
            return "gpt-6-astra"
        case "gpt-5.6-sol", "gpt5.6-sol", "gpt56-sol", "gpt56sol":
            return "gpt-5.6-sol"
        case "gpt-5.5", "gpt5.5", "gpt55":
            return "gpt-5.5"
        case "gpt-5.6-terra", "gpt5.6-terra", "gpt56-terra", "gpt56terra":
            return "gpt-5.6-terra"
        case "gpt-5.6-luna", "gpt5.6-luna", "gpt56-luna", "gpt56luna":
            return "gpt-5.6-luna"
        case "gpt-5.3-codex", "gpt5.3-codex", "gpt53-codex", "gpt53codex":
            return "gpt-5.3-codex"
        case "gpt-5.2-codex", "gpt5.2-codex", "gpt52-codex", "gpt52codex":
            return "gpt-5.2-codex"
        case "gpt-5.4", "gpt54":
            return "gpt-5.4"
        case "gpt-5.4-mini", "gpt54mini":
            return "gpt-5.4-mini"
        default:
            // In particular, do not price `codex-auto-review` here: its
            // dated routing belongs to its caller and is not a price alias.
            return nil
        }
    }

    /// Return the standard API rates for an event at a UTC date boundary.
    /// Missing or invalid event dates return nil by design.
    static func quote(for rawModel: String?, at eventDate: Date?) -> StandardAPIPriceQuote? {
        guard let eventDate,
              eventDate.timeIntervalSince1970.isFinite,
              let modelKey = canonicalModelKey(for: rawModel) else {
            return nil
        }
        return quote(forCanonicalKey: modelKey, at: eventDate)
    }

    /// Explicit current-price query kept separate from historical lookup.
    static func currentQuote(for rawModel: String?) -> StandardAPIPriceQuote? {
        guard let modelKey = canonicalModelKey(for: rawModel) else { return nil }
        return currentQuote(forCanonicalKey: modelKey)
    }

    private static func quote(
        forCanonicalKey modelKey: String,
        at eventDate: Date
    ) -> StandardAPIPriceQuote? {
        switch modelKey {
        case "gpt-6-astra":
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 10,
                cachedInputUSDPerMillion: 1,
                outputUSDPerMillion: 50
            ), revision: "standard-api-gpt-6-astra")
        case "gpt-5.5":
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 5,
                cachedInputUSDPerMillion: 0.5,
                outputUSDPerMillion: 30
            ), revision: "standard-api-gpt-5.5")
        case "gpt-5.6-sol":
            if eventDate < solCutover {
                return fixedQuote(modelKey, rates: APIPriceRates(
                    inputUSDPerMillion: 5,
                    cachedInputUSDPerMillion: 0.5,
                    outputUSDPerMillion: 30
                ), revision: "standard-api-gpt-5.6-sol-before-2026-08-21")
            }
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 4,
                cachedInputUSDPerMillion: 0.4,
                outputUSDPerMillion: 20
            ), revision: "standard-api-gpt-5.6-sol-from-2026-08-21")
        case "gpt-5.6-terra":
            if eventDate < terraAndLunaCutover {
                return fixedQuote(modelKey, rates: APIPriceRates(
                    inputUSDPerMillion: 2.5,
                    cachedInputUSDPerMillion: 0.25,
                    outputUSDPerMillion: 15
                ), revision: "standard-api-gpt-5.6-terra-before-2026-07-30")
            }
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 2,
                cachedInputUSDPerMillion: 0.2,
                outputUSDPerMillion: 12
            ), revision: "standard-api-gpt-5.6-terra-from-2026-07-30")
        case "gpt-5.6-luna":
            if eventDate < terraAndLunaCutover {
                return fixedQuote(modelKey, rates: APIPriceRates(
                    inputUSDPerMillion: 1,
                    cachedInputUSDPerMillion: 0.1,
                    outputUSDPerMillion: 6
                ), revision: "standard-api-gpt-5.6-luna-before-2026-07-30")
            }
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 0.2,
                cachedInputUSDPerMillion: 0.02,
                outputUSDPerMillion: 1.2
            ), revision: "standard-api-gpt-5.6-luna-from-2026-07-30")
        case "gpt-5.3-codex", "gpt-5.2-codex":
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 1.75,
                cachedInputUSDPerMillion: 0.175,
                outputUSDPerMillion: 14
            ), revision: "standard-api-\(modelKey)")
        case "gpt-5.4":
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 2.5,
                cachedInputUSDPerMillion: 0.25,
                outputUSDPerMillion: 15
            ), revision: "standard-api-gpt-5.4")
        case "gpt-5.4-mini":
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 0.75,
                cachedInputUSDPerMillion: 0.075,
                outputUSDPerMillion: 4.5
            ), revision: "standard-api-gpt-5.4-mini")
        default:
            return nil
        }
    }

    private static func currentQuote(forCanonicalKey modelKey: String) -> StandardAPIPriceQuote? {
        // Current is intentionally independent of the historical API. A
        // future cutover must update this branch without changing old events.
        switch modelKey {
        case "gpt-5.6-sol":
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 4,
                cachedInputUSDPerMillion: 0.4,
                outputUSDPerMillion: 20
            ), revision: "standard-api-gpt-5.6-sol-from-2026-08-21")
        case "gpt-5.6-terra":
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 2,
                cachedInputUSDPerMillion: 0.2,
                outputUSDPerMillion: 12
            ), revision: "standard-api-gpt-5.6-terra-from-2026-07-30")
        case "gpt-5.6-luna":
            return fixedQuote(modelKey, rates: APIPriceRates(
                inputUSDPerMillion: 0.2,
                cachedInputUSDPerMillion: 0.02,
                outputUSDPerMillion: 1.2
            ), revision: "standard-api-gpt-5.6-luna-from-2026-07-30")
        default:
            // For fixed-price rows the current revision is the same stable
            // standard card, while the dated method still requires a date.
            return quote(forCanonicalKey: modelKey, at: Date.distantFuture)
        }
    }

    private static func fixedQuote(
        _ modelKey: String,
        rates: APIPriceRates,
        revision: String
    ) -> StandardAPIPriceQuote {
        StandardAPIPriceQuote(modelKey: modelKey, rates: rates, revision: revision)
    }

    private static func utcDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

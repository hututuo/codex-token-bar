import Foundation
import AgentSpeedCore

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
/// Rates cover input, cached input, and output; local Codex usage does not
/// expose cache writes as a separate token field. GPT-6 rates follow the
/// models' release boundaries (2026-09-22 for Sol/Luna, 2026-09-29 for 6.1 Sol).
/// https://developers.openai.com/api/docs/pricing
///
/// Callers must pass an event date to `quote(for:at:)`. A missing date is not
/// silently treated as "now"; use `currentQuote(for:)` when current pricing
/// is explicitly intended. Auto-review aliases and the independent Spark
/// quota are intentionally outside this table.
enum StandardAPIPriceSchedule {
    private static let gpt61SolCutover = utcDate(year: 2026, month: 9, day: 29)
    private static let gpt6SolAndLunaCutover = utcDate(year: 2026, month: 9, day: 22)
    private static let solCutover = utcDate(year: 2026, month: 8, day: 21)
    private static let terraAndLunaCutover = utcDate(year: 2026, month: 7, day: 30)

    static let revision = "standard-api-dated-v3"
    static func sqlPartitionExpression(timestamp: String) -> String {
        "CASE WHEN \(timestamp) >= \(Int(gpt61SolCutover.timeIntervalSince1970)) THEN 4 WHEN \(timestamp) >= \(Int(gpt6SolAndLunaCutover.timeIntervalSince1970)) THEN 3 WHEN \(timestamp) >= \(Int(solCutover.timeIntervalSince1970)) THEN 2 WHEN \(timestamp) >= \(Int(terraAndLunaCutover.timeIntervalSince1970)) THEN 1 ELSE 0 END"
    }
    static func partitionStart(at date: Date) -> Date {
        if date >= gpt61SolCutover { return gpt61SolCutover }
        if date >= gpt6SolAndLunaCutover { return gpt6SolAndLunaCutover }
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
        case "gpt-6.1-sol", "gpt6.1-sol", "gpt61-sol", "gpt61sol":
            return "gpt-6.1-sol"
        case "gpt-6-sol", "gpt6-sol", "gpt6sol":
            return "gpt-6-sol"
        case "gpt-6-luna", "gpt6-luna", "gpt6luna":
            return "gpt-6-luna"
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

    private struct History: Decodable {
        struct Row: Decodable {
            let modelKey: String
            let fromUnix: Double?
            let revision: String
            let rates: Rates
        }
        struct Rates: Decodable {
            let inputUSDPerMillion: Double
            let cachedInputUSDPerMillion: Double
            let outputUSDPerMillion: Double
            var value: APIPriceRates { APIPriceRates(inputUSDPerMillion: inputUSDPerMillion,
                cachedInputUSDPerMillion: cachedInputUSDPerMillion, outputUSDPerMillion: outputUSDPerMillion) }
        }
        let schema: Int
        let rows: [Row]
    }
    private static let history: History = {
        guard let url = Bundle.module.url(forResource: "standard-api-price-history", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(History.self, from: data),
              value.schema == 1 else { preconditionFailure("Missing or invalid bundled standard price history") }
        return value
    }()

    private static func quote(forCanonicalKey modelKey: String, at eventDate: Date) -> StandardAPIPriceQuote? {
        guard let row = history.rows.last(where: { $0.modelKey == modelKey && ($0.fromUnix ?? -Double.infinity) <= eventDate.timeIntervalSince1970 }) else { return nil }
        return fixedQuote(modelKey, rates: row.rates.value, revision: row.revision)
    }

    private static let currentRatesByModel: [String: APIPriceRates] = {
        var values: [String: APIPriceRates] = [:]
        let unit = 1_000_000.0
        for model in PriceBook.bundled.models {
            guard let base = model.pricing?.base.prices else { continue }
            values[model.id] = APIPriceRates(inputUSDPerMillion: Double(base.input) / unit,
                cachedInputUSDPerMillion: Double(base.cachedInput) / unit, outputUSDPerMillion: Double(base.output) / unit)
        }
        return values
    }()

    private static func currentQuote(forCanonicalKey modelKey: String) -> StandardAPIPriceQuote? {
        // Only exact admitted standard IDs. No fuzzy resolver, network, Fast,
        // long-context or cache-write default is introduced into the old Codex card.
        guard let rates = currentRatesByModel[modelKey],
              let revision = history.rows.last(where: { $0.modelKey == modelKey })?.revision else { return nil }
        return fixedQuote(modelKey, rates: rates, revision: revision)
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

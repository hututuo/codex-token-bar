import Foundation
import Observation

/// One model's share of a day and source (METRICS 8).
public struct ModelUsage: Equatable, Sendable, Identifiable {
    public var id: String { model }
    public var model: String
    public var requests: Int
    public var output: Int
    /// Output and widened duration of the model's measured responses.
    public var measuredOutput: Int
    public var measuredMs: Int64
    /// The model's cost on that day (METRICS 9.7); nil when it was stored before costs existed.
    public var cost: CostTally?

    public init(
        model: String,
        requests: Int,
        output: Int,
        measuredOutput: Int = 0,
        measuredMs: Int64 = 0,
        cost: CostTally? = nil
    ) {
        self.model = model
        self.requests = requests
        self.output = output
        self.measuredOutput = measuredOutput
        self.measuredMs = measuredMs
        self.cost = cost
    }

    /// Output tok/s over the model's measured responses.
    public var averageSpeed: Double? {
        measuredMs > 0 ? Double(measuredOutput) / (Double(measuredMs) / 1000) : nil
    }
}

/// One source's aggregates for one local calendar day (METRICS 8).
public struct DailyUsage: Equatable, Sendable, Identifiable {
    public var id: String { "\(day)/\(source.rawValue)" }
    /// Local calendar date, `YYYY-MM-DD`.
    public var day: String
    public var source: SourceKind
    public var totals: TokenTotals
    public var measuredOutput: Int
    public var measuredMs: Int64
    public var unfinalized: Int
    public var agents: Int
    /// Only for days observed live.
    public var peak: Double?
    public var models: [ModelUsage]
    /// API-equivalent cost (METRICS 9.7); nil when the day's logs were gone before costs existed.
    public var cost: CostTally?
    /// The price table version bound to the day.
    public var priceVersion: Int?
    public var modeUsage: [ExecutionModeUsage]

    public init(
        day: String,
        source: SourceKind,
        totals: TokenTotals,
        measuredOutput: Int,
        measuredMs: Int64,
        unfinalized: Int,
        agents: Int,
        peak: Double?,
        models: [ModelUsage],
        cost: CostTally? = nil,
        priceVersion: Int? = nil,
        modeUsage: [ExecutionModeUsage] = []
    ) {
        self.day = day
        self.source = source
        self.totals = totals
        self.measuredOutput = measuredOutput
        self.measuredMs = measuredMs
        self.unfinalized = unfinalized
        self.agents = agents
        self.peak = peak
        self.models = models
        self.cost = cost
        self.priceVersion = priceVersion
        self.modeUsage = modeUsage
    }

    /// Output tok/s over the day's measured responses.
    public var averageSpeed: Double? {
        measuredMs > 0 ? Double(measuredOutput) / (Double(measuredMs) / 1000) : nil
    }
}

public enum HistoryState: Equatable, Sendable {
    case notLoaded
    case analyzing(progress: Double, filesDone: Int, filesTotal: Int)
    case ready(updatedAt: Date)
    case failed(String)
}

/// Observable hub the history window reads from; the history service and previews publish here.
@MainActor
@Observable
public final class HistoryStore {
    public private(set) var state: HistoryState = .notLoaded
    /// Every stored day of every source, sorted by day then source.
    public private(set) var days: [DailyUsage] = []

    /// Called with whether the run shows its progress (`.analyzing`) regardless of its size.
    @ObservationIgnored public var refreshHandler: (@MainActor (_ showsProgress: Bool) -> Void)?
    @ObservationIgnored public var clearHandler: (@MainActor () -> Void)?

    public init() {}

    public func publish(state: HistoryState, days: [DailyUsage]? = nil) {
        self.state = state
        if let days {
            self.days = days
        }
    }

    /// Analyses new and changed logs now; a quiet refresh (`showsProgress: false`) only reports progress for a large
    /// run, which keeps a live view of today calm.
    public func refresh(showsProgress: Bool = true) {
        refreshHandler?(showsProgress)
    }

    public func clear() {
        clearHandler?()
    }
}

public enum PreviewHistory {
    /// Plausible history for previews and UI development.
    public static func days(endingAt end: Date = Date(), count: Int = 120, calendar: Calendar = .current) -> [DailyUsage] {
        var generator = SplitMix(seed: 42)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // Source, base output, speed, models, and how many recent days it has data for (nil: every day).
        let profiles: [(SourceKind, Double, Double, [String], Int?)] = [
            (.codex, 180_000, 42, ["gpt-6.1-sol", "gpt-6.1-sol-mini"], nil),
            (.claudeCode, 140_000, 70, ["claude-opus-5-5", "claude-sonnet-5-5"], nil),
            (.claudeDesktop, 260_000, 88, ["claude-opus-5-5"], nil),
            (.deepseek, 90_000, 150, ["deepseek-flash", "deepseek-pro"], nil),
            (.opencode, 60_000, 75, ["claude-opus-5-5"], 20),
            (.gemini, 40_000, 120, ["gemini-3-pro"], 0),
            (.omp, 70_000, 95, ["claude-opus-5-5", "gpt-5.5"], 45),
            (.antigravity, 50_000, 135, ["gemini-3.1-pro", "gemini-3.1-flash"], 30),
            (.workbuddy, 55_000, 80, ["glm-5.3", "deepseek-v4-pro"], 25),
            (.workbuddyAi, 35_000, 110, ["gpt-5.5", "kimi-k3"], 12),
        ]
        var result: [DailyUsage] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            let day = formatter.string(from: date)
            let weekday = calendar.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            for profile in profiles {
                let (source, base, speed, models, recentDays) = profile
                if let recentDays, offset > recentDays { continue }
                if generator.unit() < (weekend ? 0.45 : 0.12) { continue }
                let trend = 0.6 + 0.8 * Double(count - offset) / Double(count)
                let output = Int(base * trend * (0.4 + generator.unit() * 1.2))
                let requests = max(1, output / Int(300 + generator.unit() * 500))
                let input = output * Int(60 + generator.unit() * 90)
                let daySpeed = speed * (0.75 + generator.unit() * 0.5)
                let measuredMs = Int64(Double(output) / daySpeed * 1000)
                let split = Double(0.55 + generator.unit() * 0.4)
                // The first model takes a little more than its share of the time, so per-model speeds differ in previews.
                let firstOutput = Int(Double(output) * split)
                let firstMs = Int64(Double(measuredMs) * min(0.98, split * 1.04))
                let usage = models.count == 1
                    ? [ModelUsage(model: models[0], requests: requests, output: output, measuredOutput: output, measuredMs: measuredMs)]
                    : [
                        ModelUsage(model: models[0], requests: Int(Double(requests) * split), output: firstOutput,
                                   measuredOutput: firstOutput, measuredMs: firstMs),
                        ModelUsage(model: models[1], requests: requests - Int(Double(requests) * split), output: output - firstOutput,
                                   measuredOutput: output - firstOutput, measuredMs: measuredMs - firstMs),
                    ]
                let totals = TokenTotals(
                    requests: requests,
                    input: input,
                    cachedInput: Int(Double(input) * 0.9),
                    cacheWriteInput: input / 40,
                    output: output,
                    reasoning: output / 3
                )
                let priced = usage.map { model in
                    var model = model
                    model.cost = Self.cost(of: model, dayTotals: totals)
                    return model
                }
                var dayCost = CostTally()
                for model in priced { dayCost.add(model.cost ?? CostTally()) }
                result.append(DailyUsage(
                    day: day,
                    source: source,
                    totals: totals,
                    measuredOutput: output,
                    measuredMs: measuredMs,
                    unfinalized: 0,
                    agents: 1 + Int(generator.unit() * 6),
                    peak: offset < 30 ? daySpeed * (2 + generator.unit() * 3) : nil,
                    models: priced,
                    // A quarter of the oldest days predate costs, as after an upgrade whose logs are gone.
                    cost: offset > count * 3 / 4 && generator.unit() < 0.25 ? nil : dayCost,
                    priceVersion: PriceBook.bundled.version
                ))
            }
        }
        return result
    }

    /// A model's share of the day priced with the bundled table, one request at a time (METRICS 9.3).
    private static func cost(of model: ModelUsage, dayTotals totals: TokenTotals) -> CostTally {
        let share = totals.output > 0 ? Double(model.output) / Double(totals.output) : 0
        let requests = max(1, model.requests)
        let usage = TokenUsage(
            input: Int(Double(totals.input) * share) / requests,
            cachedInput: Int(Double(totals.cachedInput) * share) / requests,
            cacheWriteInput: Int(Double(totals.cacheWriteInput) * share) / requests,
            output: model.output / requests,
            reasoning: 0
        )
        guard let each = PriceBook.bundled.cost(model: model.model, provider: nil, usage: usage, endMs: nil, fast: false) else {
            return CostTally(unpricedRequests: model.requests)
        }
        return CostTally(costMicroUsd: each * Int64(model.requests))
    }

    private struct SplitMix {
        var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func unit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}

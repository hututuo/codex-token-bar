import Foundation

/// The report ledger of METRICS 11.4: which responses count for live reporting and what each one already added.
/// Increments accumulate in `counters`; windows are differences of it.
struct ReportLedger: Sendable {
    static let maxCountedKeys = 65_536

    /// The values a counted response has added so far, field by field.
    private struct Reported: Sendable {
        var requests: Int64
        var unpricedRequests: Int64
        var output: Int64
        var input: Int64
        var cachedInput: Int64
        var cacheWriteInput: Int64
        var reasoning: Int64
        var measuredOutput: Int64
        var measuredMs: Int64
        var costMicroUsd: Int64
        var endMs: Int64
        var modes: [ExecutionModeAttribution]
    }

    private var counted: [String: Reported] = [:]
    /// Insertion order for the FIFO bound; entries already removed are skipped.
    private var order: [String] = []
    private var head = 0
    private(set) var counters = ReportCounters()

    var countedKeys: Int { counted.count }

    func isCounted(_ key: String) -> Bool { counted[key] != nil }

    /// Counts a response at its first live emission.
    mutating func count(_ record: ResponseRecord, modelId: String) {
        guard counted[record.key] == nil else {
            grow(record, modelId: modelId)
            return
        }
        let values = Self.values(of: record)
        var usage = ReportUsage(
            requests: values.requests, output: values.output, input: values.input, cachedInput: values.cachedInput,
            cacheWriteInput: values.cacheWriteInput, reasoning: values.reasoning, measuredOutput: values.measuredOutput,
            measuredMs: values.measuredMs, costMicroUsd: values.costMicroUsd
        )
        usage.unpricedRequests = values.unpricedRequests
        counters.add(usage, to: ReportModelKey(modelId: modelId, source: record.source), modes: values.modes)
        counted[record.key] = values
        order.append(record.key)
        evictOverflow()
    }

    /// Growth of a counted response (an upsert or a re-pricing): each field adds what exceeds what it already added.
    mutating func grow(_ record: ResponseRecord, modelId: String) {
        guard var reported = counted[record.key] else { return }
        let values = Self.values(of: record)
        var usage = ReportUsage()
        func step(_ new: Int64, _ old: inout Int64) -> Int64 {
            let added = max(0, new - old)
            old = max(old, new)
            return added
        }
        usage.requests = step(values.requests, &reported.requests)
        usage.unpricedRequests = step(values.unpricedRequests, &reported.unpricedRequests)
        usage.output = step(values.output, &reported.output)
        usage.input = step(values.input, &reported.input)
        usage.cachedInput = step(values.cachedInput, &reported.cachedInput)
        usage.cacheWriteInput = step(values.cacheWriteInput, &reported.cacheWriteInput)
        usage.reasoning = step(values.reasoning, &reported.reasoning)
        usage.measuredOutput = step(values.measuredOutput, &reported.measuredOutput)
        usage.measuredMs = step(values.measuredMs, &reported.measuredMs)
        usage.costMicroUsd = step(values.costMicroUsd, &reported.costMicroUsd)
        reported.endMs = max(reported.endMs, record.endMs)
        counted[record.key] = reported
        counters.add(usage, to: ReportModelKey(modelId: modelId, source: record.source), modes: reported.modes)
    }

    /// Forgets counted keys whose response left the engine's retention (by its latest end).
    mutating func prune(before cutoffMs: Int64) {
        guard counted.values.contains(where: { $0.endMs < cutoffMs }) else { return }
        counted = counted.filter { $0.value.endMs >= cutoffMs }
        order = order[head...].filter { counted[$0] != nil }
        head = 0
    }

    private mutating func evictOverflow() {
        while counted.count > Self.maxCountedKeys, head < order.count {
            counted[order[head]] = nil
            head += 1
        }
        if head > 4096, head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
    }

    private static func values(of record: ResponseRecord) -> Reported {
        let usage = record.usage
        let measured = record.isFinal ? TimedResponse(record) : nil
        return Reported(
            requests: Int64(record.requestCount), unpricedRequests: record.costMicroUsd == nil ? Int64(record.requestCount) : 0,
            output: Int64(usage.output), input: Int64(usage.input), cachedInput: Int64(usage.cachedInput),
            cacheWriteInput: Int64(usage.cacheWriteInput), reasoning: Int64(usage.reasoning),
            measuredOutput: measured == nil ? 0 : Int64(usage.output), measuredMs: measured?.durationMs ?? 0,
            costMicroUsd: record.costMicroUsd ?? 0, endMs: record.endMs,
            modes: record.modes.attributed
        )
    }
}

extension PriceTable {
    /// The id a response's model is reported as (METRICS 11.3): a hit on a table entry (priced or free) is that
    /// entry's id, a local runtime (`freeProviders`) is `local`, everything else is `unknown`. Raw names never leave.
    public func reportModelId(model: String?, provider: String?) -> String {
        let (resolution, key) = resolver.resolveWithKey(model: model, provider: provider)
        let id: String?
        switch resolution {
        case .priced(let index, _):
            id = models[index].id
        case .free:
            if let key {
                id = resolver.entryIndex(forKey: key).map { models[$0].id }
            } else {
                id = resolver.isLocalProvider(model: model, provider: provider) ? ReportModelIds.local : nil
            }
        case .unknown:
            id = nil
        }
        guard let id, ReportModelIds.isValid(id) else { return ReportModelIds.unknown }
        return id
    }
}

/// The reserved model ids of REPORTING 6.6.4.
public enum ReportModelIds {
    public static let local = "local"
    public static let unknown = "unknown"
    public static let other = "other"

    /// `$defs/modelId`: `^[a-z0-9][a-z0-9._:-]{0,63}$`.
    public static func isValid(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        func lowerAlnum(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
        guard lowerAlnum(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { lowerAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_")
            || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: "-") }
    }
}

extension PriceBook {
    /// `cost.priceVersion` (METRICS 11.2): the table bound to the local date of `ms`, else the current one. Reading it
    /// never binds a date.
    public func reportPriceVersion(atMs ms: Int64) -> Int {
        var labeler = DayLabeler(timeZone: .current)
        return boundVersion(forDay: labeler.label(forMs: ms)) ?? currentVersion
    }
}

import Foundation

public struct ExecutionModeUsage: Equatable, Codable, Sendable, Identifiable {
    public var model: String
    public var attribution: ExecutionModeAttribution
    public var requests: Int
    public var output: Int
    public var measuredOutput: Int
    public var measuredMs: Int64
    public var id: String { "\(model.utf8.count):" + [model, attribution.kind.rawValue, attribution.provider ?? "", attribution.mode, attribution.evidence].joined(separator: "/") }
    public var averageSpeed: Double? { measuredMs > 0 ? Double(measuredOutput) / (Double(measuredMs) / 1000) : nil }

    public init(model: String, attribution: ExecutionModeAttribution, requests: Int = 0, output: Int = 0,
                measuredOutput: Int = 0, measuredMs: Int64 = 0) {
        self.model = model
        self.attribution = attribution
        self.requests = requests
        self.output = output
        self.measuredOutput = measuredOutput
        self.measuredMs = measuredMs
    }

    mutating func add(_ other: ExecutionModeUsage) {
        requests = requests.saturatingAdd(other.requests)
        output = output.saturatingAdd(other.output)
        measuredOutput = measuredOutput.saturatingAdd(other.measuredOutput)
        let sum = measuredMs.addingReportingOverflow(other.measuredMs)
        measuredMs = sum.overflow ? .max : sum.partialValue
    }
}

struct ExecutionModeUsageKey: Hashable, Sendable {
    var model: String
    var attribution: ExecutionModeAttribution
}

extension DailyUsage {
    /// Independent complete partitions; legacy records stay unknown.
    public var modeBreakdown: [ExecutionModeUsage] {
        var base = models
        let remainder = ModelUsage(
            model: "", requests: max(0, totals.requests - models.reduce(0) { $0.saturatingAdd($1.requests) }),
            output: max(0, totals.output - models.reduce(0) { $0.saturatingAdd($1.output) }),
            measuredOutput: max(0, measuredOutput - models.reduce(0) { $0.saturatingAdd($1.measuredOutput) }),
            measuredMs: max(0, measuredMs - models.reduce(0) { Self.addMs($0, $1.measuredMs) }))
        if remainder.requests > 0 || remainder.output > 0 || remainder.measuredMs > 0 {
            if let index = base.firstIndex(where: { $0.model.isEmpty }) {
                base[index].requests = base[index].requests.saturatingAdd(remainder.requests)
                base[index].output = base[index].output.saturatingAdd(remainder.output)
                base[index].measuredOutput = base[index].measuredOutput.saturatingAdd(remainder.measuredOutput)
                base[index].measuredMs = Self.addMs(base[index].measuredMs, remainder.measuredMs)
            } else { base.append(remainder) }
        }
        let grouped = Dictionary(grouping: modeUsage) { ModePartition(model: $0.model, kind: $0.attribution.kind) }
        var result: [ExecutionModeUsage] = []
        for kind in ExecutionModeKind.allCases {
            for model in base {
                let parts = grouped[ModePartition(model: model.model, kind: kind)] ?? []
                var requests = model.requests, output = model.output
                var measuredOutput = model.measuredOutput, measuredMs = model.measuredMs
                var complete = true
                for part in parts {
                    guard part.requests >= 0, part.output >= 0, part.measuredOutput >= 0, part.measuredMs >= 0,
                          part.requests <= requests, part.output <= output,
                          part.measuredOutput <= measuredOutput, part.measuredMs <= measuredMs else { complete = false; break }
                    requests -= part.requests
                    output -= part.output
                    measuredOutput -= part.measuredOutput
                    measuredMs -= part.measuredMs
                }
                if complete { result += parts } else {
                    requests = model.requests; output = model.output
                    measuredOutput = model.measuredOutput; measuredMs = model.measuredMs
                }
                if requests > 0 || output > 0 || measuredOutput > 0 || measuredMs > 0 {
                    result.append(.init(model: model.model, attribution: .init(kind: kind), requests: requests,
                                        output: output, measuredOutput: measuredOutput, measuredMs: measuredMs))
                }
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    private static func addMs(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? .max : sum.partialValue
    }
}

private struct ModePartition: Hashable {
    var model: String
    var kind: ExecutionModeKind
}

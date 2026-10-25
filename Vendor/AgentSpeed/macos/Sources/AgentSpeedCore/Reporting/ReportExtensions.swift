import Foundation

public struct ReportExtensions: Equatable, Codable, Sendable {
    public var modelHarnessRequests: Bool
    public var executionModes: Bool
    public var profileAvatar: Bool
    public var sharedIdentity: Bool
    public static let none = ReportExtensions()

    public init(modelHarnessRequests: Bool = false, executionModes: Bool = false,
                profileAvatar: Bool = false, sharedIdentity: Bool = false) {
        self.modelHarnessRequests = modelHarnessRequests; self.executionModes = executionModes
        self.profileAvatar = profileAvatar; self.sharedIdentity = sharedIdentity
    }

    init(_ value: JSONValue?) {
        func supported(_ key: String) -> Bool {
            guard let literal = value?[key]?.literal else { return false }
            return literal.isInteger && literal.int64 == 1
        }
        self.init(modelHarnessRequests: supported("modelHarnessRequests"), executionModes: supported("executionModes"),
                  profileAvatar: supported("profileAvatar"), sharedIdentity: supported("sharedIdentity"))
    }

    private enum CodingKeys: CodingKey { case modelHarnessRequests, executionModes, profileAvatar, sharedIdentity }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func supported(_ key: CodingKeys) -> Bool { (try? c.decode(Int.self, forKey: key)) == 1 }
        self.init(modelHarnessRequests: supported(.modelHarnessRequests), executionModes: supported(.executionModes),
                  profileAvatar: supported(.profileAvatar), sharedIdentity: supported(.sharedIdentity))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if modelHarnessRequests { try c.encode(1, forKey: .modelHarnessRequests) }
        if executionModes { try c.encode(1, forKey: .executionModes) }
        if profileAvatar { try c.encode(1, forKey: .profileAvatar) }
        if sharedIdentity { try c.encode(1, forKey: .sharedIdentity) }
    }
}

public struct ReportModeKey: Equatable, Hashable, Sendable {
    public var model: ReportModelKey
    public var attribution: ExecutionModeAttribution
    public init(model: ReportModelKey, attribution: ExecutionModeAttribution) {
        self.model = model; self.attribution = attribution
    }
}

struct ReportModeGroup: Hashable {
    var source: SourceKind
    var attribution: ExecutionModeAttribution
    var order: String { [source.rawValue, attribution.kind.rawValue, attribution.provider ?? "", attribution.mode, attribution.evidence].joined(separator: "/") }
}

enum ReportModelBreakdown {
    static func harness(_ sources: [SourceKind: ReportUsage], total: ReportUsage) -> ReportJSON? {
        let rows = sources.filter { $0.value.requests > 0 }.sorted { $0.key.rawValue < $1.key.rawValue }
        guard rows.count <= 8, rows.reduce(Int64(0), { $0 + $1.value.requests }) == total.requests else { return nil }
        return .array(rows.map { .object(["source": .string($0.key.rawValue), "requests": .int($0.value.requests)]) })
    }

    static func modes(_ sources: [SourceKind: ReportUsage], groups: [ReportModeGroup: ReportUsage]) -> ReportJSON? {
        let observed = Set(groups.filter { !$0.key.attribution.isUnknown }.map { $0.key.attribution.kind })
        let kinds = observed.union([.serviceTier])
        var complete: [ReportModeGroup: ReportUsage] = [:]
        for kind in kinds {
            for (source, total) in sources {
                let parts = groups.filter { $0.key.source == source && $0.key.attribution.kind == kind }
                var remaining = total
                for (key, part) in parts {
                    guard valid(key.attribution), fits(part, within: remaining) else { return nil }
                    remaining = remaining - part
                    complete[key, default: .zero] += part
                }
                if relevant(remaining) {
                    complete[ReportModeGroup(source: source, attribution: .init(kind: kind)), default: .zero] += remaining
                }
            }
        }
        let rows = complete.filter { relevant($0.value) }.sorted { $0.key.order < $1.key.order }
        guard rows.count <= 64 else { return nil }
        return .array(rows.map { key, usage in
            var row: [ReportJSON.Member] = [
                .init("source", .string(key.source.rawValue)), .init("kind", .string(key.attribution.kind.rawValue)),
                .init("mode", .string(key.attribution.mode)), .init("evidence", .string(key.attribution.evidence)),
                .init("requests", .int(usage.requests)), .init("output", .int(usage.output)),
                .init("measuredOutput", .int(usage.measuredOutput)), .init("measuredMs", .int(usage.measuredMs)),
            ]
            if let provider = key.attribution.provider { row.append(.init("provider", .string(provider))) }
            return .object(row)
        })
    }

    private static func relevant(_ value: ReportUsage) -> Bool {
        value.requests != 0 || value.output != 0 || value.measuredOutput != 0 || value.measuredMs != 0
    }
    private static func fits(_ part: ReportUsage, within total: ReportUsage) -> Bool {
        let values = [part.requests, part.output, part.measuredOutput, part.measuredMs]
        return values.allSatisfy { (0...9_007_199_254_740_991).contains($0) }
            && part.requests <= total.requests && part.output <= total.output
            && part.measuredOutput <= total.measuredOutput && part.measuredMs <= total.measuredMs
    }
    private static func valid(_ attribution: ExecutionModeAttribution) -> Bool {
        guard ExecutionModeFact.isIdentifier(attribution.mode, limit: 64),
              attribution.provider.map({ ExecutionModeFact.isIdentifier($0, limit: 32) }) ?? true else { return false }
        if attribution.mode == "unknown" { return attribution.evidence == "unknown" && attribution.provider == nil }
        return ["served", "recorded", "selected"].contains(attribution.evidence)
    }
}

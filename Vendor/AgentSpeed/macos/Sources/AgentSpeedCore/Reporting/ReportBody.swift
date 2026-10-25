import Foundation

/// `client` of every body (REPORTING 6.3).
public struct ReportClientInfo: Equatable, Codable, Sendable {
    public var version: String
    public var platform: String
    public var osMajor: Int

    public init(version: String, platform: String = "macOS", osMajor: Int) {
        self.version = Self.isVersion(version) ? version : "0.0.0"
        self.platform = platform
        self.osMajor = min(max(osMajor, 10), 99)
    }

    /// This Mac: the app version and the macOS major version.
    public static func current(version: String) -> ReportClientInfo {
        ReportClientInfo(version: version, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    var json: ReportJSON {
        .object(["app": .string("CodexTokenBar"), "version": .string(version), "platform": .string(platform),
                 "osMajor": .int(osMajor)])
    }

    /// `MAJOR.MINOR.PATCH[-PRERELEASE]`, at most 32 characters.
    static func isVersion(_ text: String) -> Bool {
        guard text.utf8.count <= 32 else { return false }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return false }
        guard parts.count == 2 else { return true }
        return !parts[1].isEmpty && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Who and when a report is (REPORTING 6.3).
public struct ReportEnvelope: Equatable, Sendable {
    public var client: ReportClientInfo
    public var deviceId: String
    public var username: String
    public var runId: String
    public var seq: Int
    /// Unix ms of the build on the corrected clock (METRICS 11.6).
    public var sentAtMs: Int64
    public var windowMs: Int64
    public var activity: ReportScheduler.Activity
    public var titleLevel: Int

    public init(client: ReportClientInfo, deviceId: String, username: String, runId: String, seq: Int, sentAtMs: Int64,
                windowMs: Int64, activity: ReportScheduler.Activity, titleLevel: Int) {
        self.client = client
        self.deviceId = deviceId
        self.username = username
        self.runId = runId
        self.seq = seq
        self.sentAtMs = sentAtMs
        self.windowMs = windowMs
        self.activity = activity
        self.titleLevel = titleLevel
    }
}

/// What a report may contain and how large it may be (REPORTING 3.2, 6.1, 6.8).
public struct ReportOptions: Equatable, Sendable {
    /// The optional sections both the service lists and the user's switches allow.
    public var sections: Set<ReportSection>
    public var maxModels: Int
    public var bodyLimit: Int
    public var metric: SpeedMetric
    public var redline: Double
    public var priceVersion: Int
    public var extensions: ReportExtensions

    public init(sections: Set<ReportSection>, maxModels: Int = 16, bodyLimit: Int = 16_384, metric: SpeedMetric = .output,
                redline: Double = 2000, priceVersion: Int = 1, extensions: ReportExtensions = .none) {
        self.sections = sections
        self.maxModels = maxModels
        self.bodyLimit = bodyLimit
        self.metric = metric
        self.redline = redline
        self.priceVersion = priceVersion
        self.extensions = extensions
    }
}

/// The report body of REPORTING 6 from a window, the tick's values and the options (METRICS 11.2, 11.7).
public enum ReportBody {
    public static let maxTokS = 1e9
    public static let maxCount = 100_000
    public static let maxWindowMs: Int64 = 900_000

    /// The body as sent: within `bodyLimit`, dropping `models` and then `sources` when it would not fit.
    public static func data(_ envelope: ReportEnvelope, _ content: ReportWindowContent, _ sample: ReportSample,
                            _ options: ReportOptions) -> Data {
        fitted(envelope, content, sample, options).data
    }

    /// The document and its bytes after the size rule (REPORTING 6.8).
    public static func fitted(_ envelope: ReportEnvelope, _ content: ReportWindowContent, _ sample: ReportSample,
                              _ options: ReportOptions) -> (json: ReportJSON, data: Data) {
        var options = options
        var document = json(envelope, content, sample, options)
        var data = document.compactData
        if data.count > options.bodyLimit, options.extensions != .none {
            options.extensions = .none
            document = json(envelope, content, sample, options)
            data = document.compactData
        }
        for section in [ReportSection.models, .sources] where data.count > options.bodyLimit {
            options.sections.remove(section)
            document = json(envelope, content, sample, options)
            data = document.compactData
        }
        return (document, data)
    }

    public static func json(_ envelope: ReportEnvelope, _ content: ReportWindowContent, _ sample: ReportSample,
                            _ options: ReportOptions) -> ReportJSON {
        let total = content.usage.total
        let agents = sample.facts.agents.values.reduce(into: ReportAgentCounts()) {
            $0.generating += $1.generating
            $0.tools += $1.tools
            $0.active += $1.active
        }
        let value = sample.value(for: options.metric)
        var members: [ReportJSON.Member] = [
            .init("schema", .int(1)),
            .init("client", envelope.client.json),
            .init("deviceId", .string(envelope.deviceId)),
            .init("username", .string(envelope.username)),
            .init("run", .object(["id": .string(envelope.runId), "seq": .int(envelope.seq)])),
            .init("sentAt", .string(ReportInstant.format(unixMs: envelope.sentAtMs))),
            .init("windowMs", .int(min(max(envelope.windowMs, 0), maxWindowMs))),
            .init("activity", .string(envelope.activity.rawValue)),
            .init("live", .object([
                "outputTokS": tokS(sample.live.output), "totalTokS": tokS(sample.live.total),
                "estimatedShare": share(sample.estimatedShare), "agents": counts(agents),
            ])),
            .init("peak", .object(["outputTokS": tokS(content.peak.output), "totalTokS": tokS(content.peak.total)])),
            .init("delta", delta(total)),
            .init("title", .object([
                "level": .int(min(max(envelope.titleLevel, 0), ReportTitleTracker.maxLevel)),
                "metric": .string(options.metric.rawValue),
                "redline": .decimal(options.redline, decimals: 1),
                "heat": share(ReportTitleTracker.heat(value: value, redline: options.redline)),
            ])),
        ]
        let sections = options.sections
        if sections.contains(.cost) {
            members.append(.init("cost", .object([
                "liveMicroUsdPerSecond": perSecond(sample.liveCost.microUsdPerSecond),
                "peakMicroUsdPerSecond": perSecond(max(content.peakCost, sample.liveCost.microUsdPerSecond)),
                "knownShare": share(sample.liveCost.knownShare(liveOutput: sample.live.output)),
                "deltaMicroUsd": .int(total.costMicroUsd),
                "unpricedRequests": .int(total.unpricedRequests),
                "priceVersion": .int(max(1, options.priceVersion)),
            ])))
        }
        if sections.contains(.traffic) {
            let bytes = content.agentBytes.values.reduce(TrafficBytes.zero, +)
            members.append(.init("traffic", traffic(
                status: sample.traffic.status, includesTools: sample.traffic.includesTools, rate: sample.traffic.rate,
                peak: content.peakRate, bytes: bytes)))
        }
        if sections.contains(.sources) {
            members.append(.init("sources", .array(sourceEntries(content, sample, sections: sections))))
        }
        if sections.contains(.models), options.maxModels > 0 {
            members.append(.init("models", .array(modelEntries(content, sample, maxModels: options.maxModels,
                                                                withCost: sections.contains(.cost), extensions: options.extensions))))
        }
        return .object(members)
    }

    // MARK: - Sections

    private static func traffic(status: ReportTrafficSample.Status, includesTools: Bool, rate: TrafficRate?,
                                peak: TrafficRate?, bytes: TrafficBytes) -> ReportJSON {
        guard status == .ok else { return .object(["status": .string(status.rawValue)]) }
        let top: TrafficRate? = switch (peak, rate) {
        case let (peak?, rate?): TrafficRate(rx: max(peak.rx, rate.rx), tx: max(peak.tx, rate.tx))
        case let (peak, rate): peak ?? rate
        }
        return .object([
            .init("status", .string("ok")),
            .init("includesTools", .bool(includesTools)),
            .init("rxBytesPerSecond", .optionalInt(rate.map { bytesPerSecond($0.rx) })),
            .init("txBytesPerSecond", .optionalInt(rate.map { bytesPerSecond($0.tx) })),
            .init("peakRxBytesPerSecond", .optionalInt(top.map { bytesPerSecond($0.rx) })),
            .init("peakTxBytesPerSecond", .optionalInt(top.map { bytesPerSecond($0.tx) })),
            .init("rxBytes", .int(max(0, bytes.rx))),
            .init("txBytes", .int(max(0, bytes.tx))),
        ])
    }

    /// One entry per source with activity in the window, in source order (REPORTING 6.6.3, METRICS 11.7).
    private static func sourceEntries(_ content: ReportWindowContent, _ sample: ReportSample,
                                      sections: Set<ReportSection>) -> [ReportJSON] {
        var usage: [SourceKind: ReportUsage] = [:]
        for (key, value) in content.usage.byModel { usage[key.source, default: .zero] += value }
        let trafficOK = sections.contains(.traffic) && sample.traffic.status == .ok
        var entries: [ReportJSON] = []
        for kind in SourceKind.allCases {
            let source = sample.sources[kind] ?? ReportSample.Source()
            let agents = sample.facts.agents[kind] ?? .zero
            let delta = usage[kind] ?? .zero
            let bytes = content.agentBytes[kind] ?? .zero
            let rate = trafficOK ? sample.traffic.sourceRates[kind] ?? (sample.traffic.rate == nil ? nil : .zero) : nil
            // Activity (REPORTING 6.6.3): a number of the entry as sent, other than `agents.active` and the shares,
            // is above 0 — a source whose only increment is a late price included, so the cost sums add up.
            var values: [Double] = [
                rounded(source.live.output, 1), rounded(source.live.total, 1), Double(agents.generating),
                Double(agents.tools), Double(delta.requests), Double(delta.output), Double(delta.input),
                Double(delta.cachedInput), Double(delta.cacheWriteInput), Double(delta.reasoning),
                Double(delta.measuredOutput), Double(delta.measuredMs),
            ]
            if sections.contains(.cost) {
                values += [rounded(source.liveCost.microUsdPerSecond, 0), Double(delta.costMicroUsd),
                           Double(delta.unpricedRequests)]
            }
            if trafficOK {
                values += [rounded(rate?.rx ?? 0, 0), rounded(rate?.tx ?? 0, 0), Double(bytes.rx), Double(bytes.tx)]
            }
            guard values.contains(where: { $0 > 0 }) else { continue }
            let estimated = source.live.output > 0 ? source.liveEstimated.output / source.live.output : 0
            var members: [ReportJSON.Member] = [
                .init("source", .string(kind.rawValue)),
                .init("live", .object(["outputTokS": tokS(source.live.output), "totalTokS": tokS(source.live.total),
                                       "estimatedShare": share(estimated)])),
                .init("agents", counts(agents)),
                .init("delta", self.delta(delta)),
            ]
            if sections.contains(.cost) {
                members.append(.init("cost", .object([
                    "liveMicroUsdPerSecond": perSecond(source.liveCost.microUsdPerSecond),
                    "knownShare": share(source.liveCost.knownShare(liveOutput: source.live.output)),
                    "deltaMicroUsd": .int(delta.costMicroUsd),
                    "unpricedRequests": .int(delta.unpricedRequests),
                ])))
            }
            if trafficOK {
                members.append(.init("traffic", .object([
                    "rxBytesPerSecond": .optionalInt(rate.map { bytesPerSecond($0.rx) }),
                    "txBytesPerSecond": .optionalInt(rate.map { bytesPerSecond($0.tx) }),
                    "rxBytes": .int(bytes.rx), "txBytes": .int(bytes.tx),
                ])))
            }
            entries.append(.object(members))
        }
        return entries
    }

    private struct ModelEntry {
        var id: String
        var sources: Set<SourceKind> = []
        var usage = ReportUsage()
        var generating = 0
        var usageBySource: [SourceKind: ReportUsage] = [:]
        var modes: [ReportModeGroup: ReportUsage] = [:]
    }

    /// One entry per model with any increment in the window (a late price included) or a generating agent, by output
    /// then id, `other` last (REPORTING 6.6.4, METRICS 11.3, 11.7).
    private static func modelEntries(_ content: ReportWindowContent, _ sample: ReportSample, maxModels: Int,
                                     withCost: Bool, extensions: ReportExtensions) -> [ReportJSON] {
        var byId: [String: ModelEntry] = [:]
        for (key, value) in content.usage.byModel {
            byId[key.modelId, default: ModelEntry(id: key.modelId)].usage += value
            byId[key.modelId]?.sources.insert(key.source)
            byId[key.modelId]?.usageBySource[key.source, default: .zero] += value
        }
        for (key, value) in content.usage.byMode {
            let group = ReportModeGroup(source: key.model.source, attribution: key.attribution)
            byId[key.model.modelId]?.modes[group, default: .zero] += value
        }
        for (key, count) in sample.facts.generatingModels where count > 0 {
            byId[key.modelId, default: ModelEntry(id: key.modelId)].generating += count
            byId[key.modelId]?.sources.insert(key.source)
        }
        var entries = byId.values.sorted { lhs, rhs in
            lhs.usage.output != rhs.usage.output ? lhs.usage.output > rhs.usage.output : lhs.id < rhs.id
        }
        if entries.count > maxModels {
            var other = ModelEntry(id: ReportModelIds.other)
            for entry in entries[(maxModels - 1)...] {
                other.usage += entry.usage
                other.generating += entry.generating
                other.sources.formUnion(entry.sources)
                for (source, usage) in entry.usageBySource { other.usageBySource[source, default: .zero] += usage }
                for (key, usage) in entry.modes { other.modes[key, default: .zero] += usage }
            }
            entries = Array(entries.prefix(maxModels - 1)) + [other]
        }
        return entries.map { entry in
            var members: [ReportJSON.Member] = [
                .init("id", .string(entry.id)),
                .init("sources", .array(SourceKind.allCases.filter(entry.sources.contains).map { .string($0.rawValue) })),
                .init("requests", .int(entry.usage.requests)),
                .init("output", .int(entry.usage.output)),
                .init("measuredOutput", .int(entry.usage.measuredOutput)),
                .init("measuredMs", .int(entry.usage.measuredMs)),
                .init("generating", .int(min(entry.generating, maxCount))),
            ]
            if withCost { members.append(.init("deltaMicroUsd", .int(entry.usage.costMicroUsd))) }
            if extensions.modelHarnessRequests, let rows = ReportModelBreakdown.harness(entry.usageBySource, total: entry.usage) {
                members.append(.init("harnessRequests", rows))
            }
            if extensions.executionModes, let rows = ReportModelBreakdown.modes(entry.usageBySource, groups: entry.modes) {
                members.append(.init("modeUsage", rows))
            }
            return .object(members)
        }
    }

    // MARK: - Values

    private static func delta(_ usage: ReportUsage) -> ReportJSON {
        .object([
            "requests": .int(usage.requests), "output": .int(usage.output), "input": .int(usage.input),
            "cachedInput": .int(usage.cachedInput), "cacheWriteInput": .int(usage.cacheWriteInput),
            "reasoning": .int(usage.reasoning), "measuredOutput": .int(usage.measuredOutput),
            "measuredMs": .int(usage.measuredMs),
        ])
    }

    private static func counts(_ agents: ReportAgentCounts) -> ReportJSON {
        .object(["generating": .int(min(agents.generating, maxCount)), "tools": .int(min(agents.tools, maxCount)),
                 "active": .int(min(agents.active, maxCount))])
    }

    static func rounded(_ value: Double, _ decimals: Int) -> Double {
        guard value.isFinite else { return 0 }
        let scale = pow(10, Double(decimals))
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    private static func tokS(_ value: Double) -> ReportJSON {
        .decimal(min(max(value.isFinite ? value : 0, 0), maxTokS), decimals: 1)
    }

    private static func share(_ value: Double) -> ReportJSON {
        .decimal(min(max(value.isFinite ? value : 0, 0), 1), decimals: 3)
    }

    private static func perSecond(_ value: Double) -> ReportJSON {
        .int(Int64(rounded(min(max(0, value), 9e15), 0)))
    }

    private static func bytesPerSecond(_ value: Double) -> Int64 {
        Int64(rounded(min(max(0, value), 1e12), 0))
    }
}

import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Engine fixture cases")
struct EngineCaseTests {
    static let tolerance = 1e-6

    static func cases() throws -> [[String: Any]] {
        try #require(Fixtures.json("engine-cases.json")["cases"] as? [[String: Any]])
    }

    static var caseNames: [String] {
        (try? cases().compactMap { $0["name"] as? String }) ?? []
    }

    @Test(arguments: caseNames)
    func engineCase(_ name: String) throws {
        let spec = try #require(try Self.cases().first { $0["name"] as? String == name })
        let todayStartMs = spec.int64("todayStartMs") ?? 0
        var engine = SpeedEngine()
        for agent in try #require(spec["agents"] as? [[String: Any]]) {
            engine.setAgent(EngineAgent(
                id: try #require(agent.string("id")),
                source: try #require(SourceKind(rawValue: agent.string("source") ?? "")),
                project: "fixture",
                model: agent.string("model"),
                phase: try #require(AgentPhase(rawValue: agent.string("phase") ?? "")),
                inFlightStartMs: agent.int64("inFlightStartMs"),
                lastLineMs: agent.int64("lastLineMs"),
                parentId: agent.string("parentId")
            ))
        }
        for response in try #require(spec["responses"] as? [[String: Any]]) {
            let record = ResponseRecord(
                key: try #require(response.string("key")),
                source: try #require(SourceKind(rawValue: response.string("source") ?? "")),
                agentId: try #require(response.string("agentId")),
                model: response.string("model"),
                startMs: response.int64("startMs"),
                endMs: try #require(response.int64("endMs")),
                usage: TokenUsage(input: response.int("input"), output: response.int("output")),
                isFinal: response["final"] as? Bool ?? true,
                costMicroUsd: response.int64("costMicroUsd")
            )
            engine.upsert(record, project: "fixture", isCompletion: true, emitsEvents: false)
        }
        for query in try #require(spec["queries"] as? [[String: Any]]) {
            let now = try #require(query.int64("nowMs"))
            let subsets = try (query["subsets"] as? [[String: Any]] ?? []).map(Self.subset)
            let output = engine.advance(
                nowMs: now, todayStartMs: todayStartMs, emitsEvents: false, subsets: Set(subsets.map(\.sources))
            )
            let label = "\(name) @ \(now)"
            Self.expectSubsets(subsets, output: output, label: label)
            Self.expectClose(output.live.output, query.double("liveOutput"), "\(label) liveOutput")
            Self.expectClose(output.live.total, query.double("liveTotal"), "\(label) liveTotal")
            Self.expectClose(output.liveEstimatedShare, query.double("estimatedShare"), "\(label) estimatedShare")
            if let order = query["agentsOrder"] as? [String] {
                #expect(output.agents.map(\.agent.id) == order, "\(label) agentsOrder")
                let parents = try #require(query["agentParents"] as? [String: String])
                let actual = output.agents.reduce(into: [String: String]()) { $0[$1.agent.id] = $1.parentId }
                #expect(actual == parents, "\(label) agentParents")
            }
            if let requests = query["todayRequests"] as? NSNumber {
                #expect(output.today.requests == requests.intValue, "\(label) todayRequests")
            }
            if let value = query["todayOutput"] as? NSNumber {
                #expect(output.today.output == value.intValue, "\(label) todayOutput")
            }
            if let value = query["todayInput"] as? NSNumber {
                #expect(output.today.input == value.intValue, "\(label) todayInput")
            }
            if let value = query["todayUnfinalized"] as? NSNumber {
                #expect(output.unfinalizedToday == value.intValue, "\(label) todayUnfinalized")
            }
            if query.keys.contains("averageToday") {
                Self.expectClose(output.averageToday, query.double("averageToday"), "\(label) averageToday")
            }
            if let peak = query.double("peakTodayOutput") {
                Self.expectClose(output.peakToday.output, peak, "\(label) peakTodayOutput")
            }
            if query.keys.contains("liveCost") {
                Self.expectClose(output.liveCost.microUsdPerSecond, query.double("liveCost"), "\(label) liveCost")
                Self.expectClose(
                    output.liveCost.knownShare(liveOutput: output.live.output), query.double("liveCostKnownShare"),
                    "\(label) liveCostKnownShare"
                )
                let snapshot = SnapshotBuilder.running(output, context: .fixture(todayStartMs: output.todayStartMs))
                let reading = OrbSubset.cost(snapshot, sources: nil, billable: .everything)
                Self.expectClose(reading.microUsdPerSecond, query.double("liveCost"), "\(label) reading liveCost")
                Self.expectClose(reading.knownShare, query.double("liveCostKnownShare"), "\(label) reading knownShare")
            }
            if let cost = query["todayCostMicroUsd"] as? NSNumber {
                #expect(output.todayCost.costMicroUsd == cost.int64Value, "\(label) todayCostMicroUsd")
                #expect(output.todayCost.unpricedRequests == query.int("todayUnpricedRequests"), "\(label) todayUnpricedRequests")
            }
            if let buckets = query["historyMeasuredOutput"] as? [String: NSNumber] {
                #expect(output.history.count == SpeedEngine.historySeconds)
                for (startText, value) in buckets {
                    let startMs = try #require(Int64(startText))
                    let point = output.history.first { Int64(($0.time.timeIntervalSince1970 * 1000).rounded()) == startMs }
                    Self.expectClose(point?.measured.output, value.doubleValue, "\(label) bucket \(startText)")
                }
            }
        }
    }

    struct SubsetQuery {
        var sources: SourceSet
        var liveOutput: Double?
        var peakTodayOutput: Double?
        var liveCost: Double?
    }

    static func subset(_ spec: [String: Any]) throws -> SubsetQuery {
        let names = try #require(spec["sources"] as? [String])
        let kinds = try names.map { try #require(SourceKind(rawValue: $0)) }
        return SubsetQuery(
            sources: SourceSet(kinds),
            liveOutput: spec.double("liveOutput"),
            peakTodayOutput: spec.double("peakTodayOutput"),
            liveCost: spec.double("liveCost")
        )
    }

    /// METRICS 6.8: the subset's live value is the sum of its sources' live rates, and a fresh orb's peak combines
    /// the engine's measured subset peak with that live value.
    static func expectSubsets(_ subsets: [SubsetQuery], output: EngineOutput, label: String) {
        guard !subsets.isEmpty else { return }
        let snapshot = SnapshotBuilder.running(output, context: .fixture(todayStartMs: output.todayStartMs))
        for subset in subsets {
            let kinds = subset.sources.kinds.map(\.rawValue).joined(separator: "+")
            let live = subset.sources.kinds.reduce(0) { $0 + (output.sourceLive[$1]?.output ?? 0) }
            expectClose(live, subset.liveOutput, "\(label) [\(kinds)] liveOutput")
            let reading = OrbSubset.reading(snapshot, sources: subset.sources)
            expectClose(reading.live.output, live, "\(label) [\(kinds)] reading.live")
            #expect(reading.state == .available, "\(label) [\(kinds)] state")
            if let peak = subset.peakTodayOutput {
                var tracker = SubsetPeakTracker()
                _ = tracker.update(
                    liveOutput: reading.live.output,
                    measuredPeakOutput: output.subsetPeaks[subset.sources],
                    dayStartMs: output.todayStartMs,
                    nowMs: output.nowMs
                )
                expectClose(tracker.peakTodayOutput, peak, "\(label) [\(kinds)] peakTodayOutput")
            }
            if let liveCost = subset.liveCost {
                let sum = subset.sources.kinds.reduce(0) { $0 + (output.sourceLiveCost[$1]?.microUsdPerSecond ?? 0) }
                expectClose(sum, liveCost, "\(label) [\(kinds)] liveCost")
                let cost = OrbSubset.cost(snapshot, sources: subset.sources, billable: .everything)
                expectClose(cost.microUsdPerSecond, liveCost, "\(label) [\(kinds)] reading liveCost")
            }
        }
    }

    static func expectClose(
        _ actual: Double?,
        _ expected: Double?,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch (actual, expected) {
        case (nil, nil):
            return
        case let (actual?, expected?):
            #expect(abs(actual - expected) <= tolerance, "\(label): \(actual) != \(expected)", sourceLocation: sourceLocation)
        default:
            Issue.record("\(label): \(String(describing: actual)) != \(String(describing: expected))", sourceLocation: sourceLocation)
        }
    }
}

extension SnapshotContext {
    /// Every source enabled with a readable root.
    static func fixture(todayStartMs: Int64) -> SnapshotContext {
        let info = SourceInfo(enabled: true, rootPath: "/fixture", available: true, sessionCount: 0)
        return SnapshotContext(
            sources: Dictionary(uniqueKeysWithValues: SourceKind.allCases.map { ($0, info) }),
            todayStartMs: todayStartMs
        )
    }
}

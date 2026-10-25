import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Orb subsets")
struct OrbSubsetTests {
    static let base: Int64 = 1_800_000_000_000
    static let today = base - 3_600_000

    static func source(
        _ kind: SourceKind,
        enabled: Bool = true,
        available: Bool = true,
        live: Double = 0,
        estimated: Double = 0,
        requests: Int = 0,
        output: Int = 0
    ) -> SourceStatus {
        SourceStatus(kind: kind, enabled: enabled, rootPath: "/\(kind.rawValue)", available: available, sessionCount: 1,
                     live: Rate(output: live, total: live * 2), today: TokenTotals(requests: requests, input: output, output: output),
                     activeAgents: 0, liveEstimated: Rate(output: estimated, total: estimated * 2))
    }

    static func agent(_ id: String, _ source: SourceKind, _ phase: AgentPhase, parent: String? = nil) -> AgentStatus {
        AgentStatus(id: id, source: source, project: "p", model: nil, phase: phase, isSubagent: parent != nil,
                    live: .zero, recentSpeed: nil, lastActivity: Date(timeIntervalSince1970: 0), parentId: parent)
    }

    static var snapshot: SpeedSnapshot {
        var snapshot = SpeedSnapshot.empty
        snapshot.state = .running
        snapshot.live = Rate(output: 90, total: 180)
        snapshot.liveEstimatedShare = 0.25
        snapshot.peakToday = Rate(output: 400, total: 900)
        snapshot.today = TokenTotals(requests: 9, input: 300, output: 300)
        snapshot.sources = SourceKind.allCases.map { kind in
            switch kind {
            case .codex: source(kind, live: 50, estimated: 20, requests: 3, output: 100)
            case .claudeCode: source(kind, live: 30, estimated: 3, requests: 2, output: 50)
            case .claudeDesktop: source(kind, enabled: false)
            case .gemini: source(kind, available: false)
            case .deepseek: source(kind, available: false, requests: 1, output: 9)
            default: source(kind)
            }
        }
        snapshot.agents = [
            agent("codex-root", .codex, .generating),
            agent("claude-child", .claudeCode, .generating, parent: "codex-root"),
            agent("claude-root", .claudeCode, .tools),
            agent("claude-sub", .claudeCode, .generating, parent: "claude-root"),
            agent("codex-idle", .codex, .idle),
        ]
        snapshot.subsetPeaks = [SourceSet([.claudeCode, .claudeDesktop, .gemini]): 42]
        return snapshot
    }

    // MARK: - Readings

    @Test func allSourcesReadingIsTheSnapshot() {
        let snapshot = Self.snapshot
        let reading = OrbSubset.reading(snapshot, sources: nil)
        #expect(reading.live == snapshot.live)
        #expect(reading.estimatedShare == snapshot.liveEstimatedShare)
        #expect(reading.agents == snapshot.agents)
        #expect(reading.generatingSources == [.codex, .claudeCode, .claudeCode])
        #expect(reading.today == snapshot.today)
        #expect(reading.measuredPeakOutput == 400)
        #expect(reading.unavailable.isEmpty)
        #expect(reading.state == .available)
    }

    @Test func subsetReadingFiltersToItsAvailableSources() {
        let set = SourceSet([.claudeCode, .claudeDesktop, .gemini])
        let reading = OrbSubset.reading(Self.snapshot, sources: set)
        #expect(reading.live == Rate(output: 30, total: 60))
        #expect(abs(reading.estimatedShare - 0.1) < 1e-12)
        #expect(reading.agents.map(\.id) == ["claude-child", "claude-root", "claude-sub"])
        #expect(reading.agents.map(\.parentId) == [nil, nil, "claude-root"], "a parent outside the set is cleared")
        #expect(reading.generatingSources == [.claudeCode, .claudeCode])
        #expect(reading.today == TokenTotals(requests: 2, input: 50, output: 50))
        #expect(reading.measuredPeakOutput == 42)
        #expect(reading.unavailable == [.claudeDesktop, .gemini])
        #expect(reading.state == .available)

        let pair = OrbSubset.reading(Self.snapshot, sources: SourceSet([.codex, .claudeCode]))
        #expect(pair.live == Rate(output: 80, total: 160))
        #expect(abs(pair.estimatedShare - 23.0 / 80) < 1e-12)
        #expect(pair.today.requests == 5)
        #expect(pair.measuredPeakOutput == nil, "not requested from the monitor")
        #expect(pair.agents.map(\.parentId) == [nil, "codex-root", nil, "claude-root", nil])
    }

    @Test func unavailableStates() {
        let snapshot = Self.snapshot
        let disabled = OrbSubset.reading(snapshot, sources: SourceSet(.claudeDesktop))
        #expect(disabled.state == .allDisabled)
        #expect(disabled.unavailable == [.claudeDesktop])
        #expect(disabled.live == .zero)
        #expect(disabled.agents.isEmpty)
        #expect(OrbSubset.reading(snapshot, sources: SourceSet([.gemini, .claudeDesktop])).state == .allNotFound)
        #expect(OrbSubset.reading(snapshot, sources: SourceSet(.gemini)).state == .allNotFound)
        #expect(OrbSubset.reading(snapshot, sources: SourceSet(.deepseek)).state == .available, "data today counts as detected")
        #expect(OrbSubset.reading(snapshot, sources: SourceSet()).state == .allNotFound)
        #expect(OrbSubset.reading(.empty, sources: SourceSet(.codex)).state == .available, "not reported yet")

        #expect(OrbSubset.isUnavailable(Self.source(.codex, enabled: false, live: 10, requests: 3)))
        #expect(OrbSubset.isUnavailable(Self.source(.codex, available: false)))
        #expect(!OrbSubset.isUnavailable(Self.source(.codex, available: false, live: 1)))
        #expect(!OrbSubset.isUnavailable(Self.source(.codex, available: false, requests: 1)))
        #expect(!OrbSubset.isUnavailable(Self.source(.codex)))
    }

    @Test func eventsReachTheOrbsOfTheirSources() {
        let completion = SpeedEvent.responseCompleted(ResponseSummary(
            source: .codex, project: "p", model: nil, outputTokens: 1, totalTokens: 1, duration: nil, speed: nil,
            endedAt: Date(timeIntervalSince1970: 0)
        ))
        #expect(OrbSubset.accepts(completion, sources: nil))
        #expect(OrbSubset.accepts(completion, sources: SourceSet([.codex, .gemini])))
        #expect(!OrbSubset.accepts(completion, sources: SourceSet(.claudeCode)))
        #expect(OrbSubset.accepts(.newPeak(120), sources: nil))
        #expect(!OrbSubset.accepts(.newPeak(120), sources: SourceSet(.codex)))
        #expect(!OrbSubset.accepts(.newPeak(120), sources: .everything))
    }

    @Test func placeholdersCarryTheDayStart() {
        let context = SnapshotContext.fixture(todayStartMs: Self.today)
        let snapshot = SnapshotBuilder.placeholder(state: .noSources, context: context, now: Date())
        #expect(snapshot.dayStart == Date(timeIntervalSince1970: TimeInterval(Self.today) / 1000))
        #expect(snapshot.subsetPeaks.isEmpty)
        #expect(SpeedSnapshot.empty.dayStart == .distantPast)
    }

    // MARK: - Engine

    static func record(_ key: String, _ source: SourceKind, agent: String, start: Int64, end: Int64, output: Int) -> ResponseRecord {
        ResponseRecord(key: key, source: source, agentId: agent, model: "m-\(source.rawValue)", startMs: start, endMs: end,
                       usage: TokenUsage(input: 10, output: output))
    }

    /// Codex agent generating with a 100 tok/s reference; Claude Code measured at 100 tok/s in the window.
    static func engineWithInFlightCodex() -> SpeedEngine {
        var engine = SpeedEngine()
        engine.setAgent(EngineAgent(id: "codex", source: .codex, project: "p", model: "m-codex", phase: .generating,
                                    inFlightStartMs: base - 4000, lastLineMs: base - 100))
        engine.setAgent(EngineAgent(id: "claude", source: .claudeCode, project: "p", model: "m-claudeCode", phase: .idle,
                                    lastLineMs: base))
        engine.upsert(record("r1", .codex, agent: "codex", start: base - 10_000, end: base - 4000, output: 600),
                      project: "p", isCompletion: true, emitsEvents: false)
        engine.upsert(record("r2", .claudeCode, agent: "claude", start: base - 3000, end: base, output: 300),
                      project: "p", isCompletion: true, emitsEvents: false)
        return engine
    }

    @Test func estimatedShareAndPeaksPerSubset() {
        var engine = Self.engineWithInFlightCodex()
        let codex = SourceSet(.codex)
        let claude = SourceSet(.claudeCode)
        let both = codex.union(claude)
        let output = engine.advance(nowMs: Self.base, todayStartMs: Self.today, emitsEvents: false, subsets: [codex, claude, both])
        #expect(output.sourceLiveEstimated[.codex]?.output == 100)
        #expect(output.sourceLiveEstimated[.claudeCode] == nil)
        #expect(Set(output.subsetPeaks.keys) == [codex, claude, both])
        #expect(abs((output.subsetPeaks[codex] ?? 0) - 100) < 1e-4)
        #expect(abs((output.subsetPeaks[claude] ?? 0) - 100) < 1e-4)
        #expect(abs((output.subsetPeaks[both] ?? 0) - 100) < 1e-4, "measured only; the observed 200 tok/s is the tracker's")

        let snapshot = SnapshotBuilder.running(output, context: .fixture(todayStartMs: Self.today))
        #expect(snapshot.dayStart == Date(timeIntervalSince1970: TimeInterval(Self.today) / 1000))
        #expect(snapshot.subsetPeaks == output.subsetPeaks)
        let codexReading = OrbSubset.reading(snapshot, sources: codex)
        #expect(codexReading.live.output == 100)
        #expect(codexReading.estimatedShare == 1)
        #expect(codexReading.generatingSources == [.codex])
        #expect(OrbSubset.reading(snapshot, sources: claude).estimatedShare == 0)
        #expect(OrbSubset.reading(snapshot, sources: claude).generatingSources.isEmpty)
        let pair = OrbSubset.reading(snapshot, sources: both)
        #expect(abs(pair.live.output - output.live.output) < 1e-9)
        #expect(abs(pair.estimatedShare - output.liveEstimatedShare) < 1e-12)
        #expect(abs(pair.estimatedShare - 0.5) < 1e-12)
    }

    @Test func emptyLedgerReportsZeroPeaks() {
        var engine = SpeedEngine()
        let output = engine.advance(nowMs: Self.base, todayStartMs: Self.today, emitsEvents: false, subsets: [SourceSet(.codex)])
        #expect(output.subsetPeaks == [SourceSet(.codex): 0])
        #expect(engine.advance(nowMs: Self.base + 500, todayStartMs: Self.today, emitsEvents: false).subsetPeaks.isEmpty)
    }

    @Test func subsetsLeaveTheAllSourcesOutputUnchanged() {
        var plain = Self.engineWithInFlightCodex()
        var asked = Self.engineWithInFlightCodex()
        let subsets: Set<SourceSet> = [SourceSet(.codex), SourceSet([.claudeCode, .codex]), SourceSet(.gemini), .everything]
        for step in 0..<12 {
            let now = Self.base + Int64(step) * 500
            if step == 4 {
                let late = Self.record("r3", .codex, agent: "codex", start: now - 1500, end: now, output: 900)
                plain.upsert(late, project: "p", isCompletion: true, emitsEvents: true, nowMs: now)
                asked.upsert(late, project: "p", isCompletion: true, emitsEvents: true, nowMs: now)
            }
            let a = plain.advance(nowMs: now, todayStartMs: Self.today, emitsEvents: true)
            let b = asked.advance(nowMs: now, todayStartMs: Self.today, emitsEvents: true, subsets: subsets)
            #expect(a.live == b.live)
            #expect(a.liveEstimatedShare == b.liveEstimatedShare)
            #expect(a.sourceLive == b.sourceLive)
            #expect(a.sourceLiveEstimated == b.sourceLiveEstimated)
            #expect(a.agents == b.agents)
            #expect(a.history == b.history)
            #expect(a.today == b.today)
            #expect(a.todayBySource == b.todayBySource)
            #expect(a.averageToday == b.averageToday)
            #expect(a.peakToday == b.peakToday)
            #expect(a.peakTodayAtMs == b.peakTodayAtMs)
            #expect(a.lastResponse == b.lastResponse)
            #expect(a.events == b.events)
            #expect(a.subsetPeaks.isEmpty)
            #expect(Set(b.subsetPeaks.keys) == subsets)
        }
    }

    /// A single-source orb fires exactly when the engine's all-sources `newPeak` does (METRICS 6.4 parity).
    @Test func trackerMatchesTheEngineRuleForOneSource() {
        var engine = SpeedEngine()
        var tracker = SubsetPeakTracker()
        let codex = SourceSet(.codex)
        let steps: [(Int64, ResponseRecord?)] = [
            (0, nil),
            (3000, Self.record("slow", .codex, agent: "a", start: Self.base, end: Self.base + 3000, output: 30)),
            (6000, Self.record("fast", .codex, agent: "a", start: Self.base + 3000, end: Self.base + 6000, output: 300)),
            (9000, Self.record("faster", .codex, agent: "a", start: Self.base + 6000, end: Self.base + 9000, output: 600)),
            (40_000, nil),
            (73_000, Self.record("fastest", .codex, agent: "a", start: Self.base + 70_000, end: Self.base + 73_000, output: 1200)),
            (74_000, nil),
        ]
        var fired: [Int64] = []
        var engineFired: [Int64] = []
        for (offset, record) in steps {
            let now = Self.base + offset
            if let record { engine.upsert(record, project: "p", isCompletion: true, emitsEvents: true, nowMs: now) }
            let output = engine.advance(nowMs: now, todayStartMs: Self.today, emitsEvents: true, subsets: [codex])
            if output.events.contains(where: { if case .newPeak = $0 { true } else { false } }) { engineFired.append(offset) }
            let live = output.sourceLive[.codex]?.output ?? 0
            if tracker.update(liveOutput: live, measuredPeakOutput: output.subsetPeaks[codex], dayStartMs: Self.today, nowMs: now) {
                fired.append(offset)
            }
            #expect(abs(tracker.peakTodayOutput - output.peakToday.output) < 1e-4, "peak @\(offset)")
        }
        #expect(engineFired == [6000, 73_000])
        #expect(fired == engineFired)
    }
}

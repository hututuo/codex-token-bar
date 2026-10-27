import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Engine behavior")
struct EngineBehaviorTests {
    static let base: Int64 = 1_800_000_000_000

    static func record(_ key: String, agent: String = "a1", start: Int64?, end: Int64, input: Int = 0, output: Int) -> ResponseRecord {
        ResponseRecord(key: key, source: .codex, agentId: agent, model: "m", startMs: start, endMs: end,
                       usage: TokenUsage(input: input, output: output))
    }

    @Test func dayRolloverRestartsToday() {
        var engine = SpeedEngine()
        let dayOne = Self.base
        let dayTwo = dayOne + 86_400_000
        engine.upsert(Self.record("r1", start: dayTwo - 5000, end: dayTwo - 1000, input: 50, output: 400), project: "p", isCompletion: true, emitsEvents: false)
        let before = engine.advance(nowMs: dayTwo - 500, todayStartMs: dayOne, emitsEvents: false)
        #expect(before.today.requests == 1)
        #expect(before.peakToday.output > 0)

        engine.upsert(Self.record("r2", start: dayTwo - 200, end: dayTwo + 800, output: 10), project: "p", isCompletion: true, emitsEvents: false)
        let after = engine.advance(nowMs: dayTwo + 1000, todayStartMs: dayTwo, emitsEvents: false)
        #expect(after.today.requests == 1)
        #expect(after.today.output == 10)
        #expect(after.averageToday == 10)
        #expect(after.peakToday.output < before.peakToday.output)
    }

    @Test func completionEventsOnlyWhenLive() {
        var engine = SpeedEngine()
        let seeded = engine.upsert(Self.record("r1", start: Self.base, end: Self.base + 2000, output: 100), project: "p", isCompletion: true, emitsEvents: false)
        #expect(seeded == nil)
        let update = engine.upsert(Self.record("r1", start: Self.base, end: Self.base + 3000, output: 120), project: "p", isCompletion: false, emitsEvents: true)
        #expect(update == nil)
        let live = engine.upsert(Self.record("r2", start: Self.base + 4000, end: Self.base + 6000, output: 100), project: "proj", isCompletion: true, emitsEvents: true)
        guard case .responseCompleted(let summary)? = live else {
            Issue.record("expected a completion event")
            return
        }
        #expect(summary.project == "proj")
        #expect(summary.duration == 2)
        #expect(summary.speed == 50)
    }

    @Test func updatesReplaceTodayTotals() {
        var engine = SpeedEngine()
        engine.upsert(Self.record("r1", start: Self.base, end: Self.base + 1000, input: 10, output: 5), project: "p", isCompletion: true, emitsEvents: false)
        engine.upsert(Self.record("r1", start: Self.base, end: Self.base + 2000, input: 10, output: 40), project: "p", isCompletion: false, emitsEvents: false)
        let output = engine.advance(nowMs: Self.base + 2000, todayStartMs: Self.base - 1000, emitsEvents: false)
        #expect(output.today.requests == 1)
        #expect(output.today.output == 40)
        #expect(output.today.input == 10)
    }

    @Test func newPeakNeedsMarginMinimumAndCooldown() {
        var engine = SpeedEngine()
        let today = Self.base - 3_600_000
        _ = engine.advance(nowMs: Self.base, todayStartMs: today, emitsEvents: true)
        engine.upsert(Self.record("slow", start: Self.base, end: Self.base + 3000, output: 30), project: "p", isCompletion: true, emitsEvents: true)
        let slow = engine.advance(nowMs: Self.base + 3000, todayStartMs: today, emitsEvents: true)
        #expect(slow.events.isEmpty, "10 tok/s is below the 20 tok/s minimum")

        engine.upsert(Self.record("fast", start: Self.base + 3000, end: Self.base + 6000, output: 300), project: "p", isCompletion: true, emitsEvents: true)
        let fast = engine.advance(nowMs: Self.base + 6000, todayStartMs: today, emitsEvents: true)
        #expect(fast.events == [.newPeak(100)])

        engine.upsert(Self.record("faster", start: Self.base + 6000, end: Self.base + 9000, output: 600), project: "p", isCompletion: true, emitsEvents: true)
        let cooling = engine.advance(nowMs: Self.base + 9000, todayStartMs: today, emitsEvents: true)
        #expect(cooling.events.isEmpty, "within the 60-second cooldown")
        #expect(cooling.peakToday.output == 200)

        engine.upsert(Self.record("fastest", start: Self.base + 70_000, end: Self.base + 73_000, output: 1200), project: "p", isCompletion: true, emitsEvents: true)
        let later = engine.advance(nowMs: Self.base + 73_000, todayStartMs: today, emitsEvents: true)
        #expect(later.events == [.newPeak(400)])
    }

    @Test func agentsListAppliesStalenessAndOrdering() {
        var engine = SpeedEngine()
        let now = Self.base
        engine.setAgent(EngineAgent(id: "stale", source: .codex, project: "p", phase: .generating, inFlightStartMs: now - 400_000, lastLineMs: now - 400_000))
        engine.setAgent(EngineAgent(id: "gone", source: .codex, project: "p", phase: .tools, lastLineMs: now - 700_000))
        engine.setAgent(EngineAgent(id: "tools", source: .claudeCode, project: "p", phase: .tools, lastLineMs: now - 1000))
        engine.setAgent(EngineAgent(id: "busy", source: .codex, project: "p", model: "m", phase: .generating, inFlightStartMs: now - 2000, lastLineMs: now - 2000))
        engine.upsert(Self.record("r", agent: "busy", start: now - 10_000, end: now - 6000, output: 200), project: "p", isCompletion: true, emitsEvents: false)
        let output = engine.advance(nowMs: now, todayStartMs: now - 3_600_000, emitsEvents: false)
        #expect(output.agents.map(\.agent.id) == ["busy", "tools", "stale"])
        #expect(output.agents.map(\.phase) == [.generating, .tools, .idle])
        #expect(output.agents.first?.recentSpeed == 50)
        let busyLive = output.agents.first?.live.output ?? 0
        #expect(abs(busyLive - 50.0 * 2 / 3) < 1e-9)
        #expect(output.sourceLive[.codex]?.output == busyLive)
    }

    @Test func subagentsStayUnderTheirInactiveParents() {
        var engine = SpeedEngine()
        let now = Self.base
        engine.setAgent(EngineAgent(id: "main", source: .claudeDesktop, project: "p", phase: .idle, lastLineMs: now - 1_200_000))
        engine.setAgent(EngineAgent(id: "sub", source: .claudeDesktop, project: "p", model: "m", phase: .generating,
                                    inFlightStartMs: now - 2000, lastLineMs: now - 2000, parentId: "main"))
        engine.setAgent(EngineAgent(id: "nested", source: .claudeDesktop, project: "p", phase: .tools, lastLineMs: now - 5000,
                                    parentId: "sub"))
        engine.setAgent(EngineAgent(id: "busy", source: .codex, project: "p", model: "m", phase: .generating,
                                    inFlightStartMs: now - 1000, lastLineMs: now - 1000))
        engine.setAgent(EngineAgent(id: "orphan", source: .codex, project: "p", phase: .tools, lastLineMs: now - 3000,
                                    parentId: "gone"))
        engine.upsert(Self.record("r1", agent: "busy", start: now - 10_000, end: now - 6000, output: 800), project: "p",
                      isCompletion: true, emitsEvents: false)
        engine.upsert(Self.record("r2", agent: "sub", start: now - 10_000, end: now - 6000, output: 200), project: "p",
                      isCompletion: true, emitsEvents: false)
        let output = engine.advance(nowMs: now, todayStartMs: now - 3_600_000, emitsEvents: false)
        #expect(output.agents.map(\.agent.id) == ["busy", "main", "sub", "nested", "orphan"])
        #expect(output.agents.map(\.parentId) == [nil, nil, "main", "sub", nil])
        #expect(output.agents[1].phase == .idle)
    }

    @Test func parentLinksCanBeReplacedAndLoopsStillList() {
        var engine = SpeedEngine()
        let now = Self.base
        engine.setAgent(EngineAgent(id: "a", source: .codex, project: "p", phase: .tools, lastLineMs: now - 1000, parentId: "b"))
        engine.setAgent(EngineAgent(id: "b", source: .codex, project: "p", phase: .tools, lastLineMs: now - 2000, parentId: "a"))
        let looped = engine.advance(nowMs: now, todayStartMs: now - 3_600_000, emitsEvents: false)
        #expect(Set(looped.agents.map(\.agent.id)) == ["a", "b"])
        #expect(looped.agents.filter { $0.parentId == nil }.count == 1)

        engine.setParents(["b": "a"])
        let fixed = engine.advance(nowMs: now, todayStartMs: now - 3_600_000, emitsEvents: false)
        #expect(fixed.agents.map(\.agent.id) == ["a", "b"])
        #expect(fixed.agents.map(\.parentId) == [nil, "a"])
    }

    @Test func historyHasThreeHundredBucketsEndingNow() {
        var engine = SpeedEngine()
        let output = engine.advance(nowMs: Self.base + 1500, todayStartMs: Self.base, emitsEvents: false)
        #expect(output.history.count == 300)
        #expect(output.history.last?.time == Date(timeIntervalSince1970: TimeInterval(Self.base / 1000 + 1)))
        #expect(output.history.first?.time == Date(timeIntervalSince1970: TimeInterval(Self.base / 1000 - 298)))
    }

    @Test func historyEstimatesStartAfterTheAgentsLatestResponse() {
        var engine = SpeedEngine()
        let now = Self.base + 10_000
        engine.setAgent(EngineAgent(id: "a1", source: .claudeCode, project: "p", phase: .generating,
                                    inFlightStartMs: Self.base, lastLineMs: Self.base + 6000))
        engine.upsert(Self.record("r", agent: "a1", start: Self.base, end: Self.base + 6000, output: 300), project: "p",
                      isCompletion: true, emitsEvents: false)
        let output = engine.advance(nowMs: now, todayStartMs: Self.base - 3_600_000, emitsEvents: false)
        let estimated = output.history.filter { $0.estimated.output > 0 }.map { Int64($0.time.timeIntervalSince1970) }
        #expect(estimated.first == (Self.base + 6000) / 1000)
        #expect(output.history.last?.estimated.output == 0)
    }

    @Test func unfinalizedResponsesAreEstimatedNotMeasured() {
        var engine = SpeedEngine()
        let today = Self.base - 3_600_000
        engine.upsert(Self.record("ref", agent: "a1", start: Self.base, end: Self.base + 4000, output: 200), project: "p",
                      isCompletion: true, emitsEvents: false)
        var snapshot = Self.record("snap", agent: "a1", start: Self.base + 5000, end: Self.base + 7000, output: 8)
        snapshot.isFinal = false
        engine.upsert(snapshot, project: "p", isCompletion: true, emitsEvents: false)
        let output = engine.advance(nowMs: Self.base + 8000, todayStartMs: today, emitsEvents: false)
        let second = { (ms: Int64) in output.history.first { Int64($0.time.timeIntervalSince1970) == ms / 1000 } }
        #expect(second(Self.base + 5000)?.measured.output == 0)
        #expect(second(Self.base + 5000)?.estimated.output == 50)
        #expect(output.unfinalizedToday == 1)
        #expect(output.today.output == 208)
        #expect(output.averageToday == 50)
        #expect(output.agents.isEmpty || output.agents.first?.recentSpeed == 50)
    }
    @Test func modelSwitchKeepsSettledTailAndCurrentEstimateSeparate() {
        let now = Self.base + 10_000
        var engine = SpeedEngine()
        var old = Self.record("old", start: now - 3000, end: now - 1000, input: 60, output: 120)
        old.model = "old-model"
        engine.upsert(old, project: "p", isCompletion: true, emitsEvents: false)
        engine.setAgent(EngineAgent(id: "a1", source: .codex, project: "p", model: "new-model",
                                    phase: .generating, inFlightStartMs: now - 1000, lastLineMs: now))
        let output = engine.advance(nowMs: now, todayStartMs: Self.base, emitsEvents: false)
        #expect(output.liveModels.map(\.model) == ["new-model", "old-model"])
        #expect(output.liveModels.first { $0.model == "old-model" }?.rate.output == 40)
        #expect(output.liveModels.first { $0.model == "new-model" }?.rate.output == 20)
        #expect(output.liveModels.reduce(0) { $0 + $1.rate.output } == output.live.output)
        #expect(output.liveModels.reduce(0) { $0 + $1.rate.total } == output.live.total)
    }

    @Test func unknownModelsAndEqualNamesInDifferentSourcesRemainAdditive() {
        let now = Self.base + 3000
        var engine = SpeedEngine()
        for (key, source, model, count) in [("c", SourceKind.codex, "same" as String?, 90),
                                           ("k", .claudeCode, "same", 60), ("u", .claudeCode, nil, 30)] {
            engine.upsert(ResponseRecord(key: key, source: source, agentId: key, model: model,
                startMs: Self.base, endMs: now, usage: TokenUsage(output: count)),
                project: "p", isCompletion: true, emitsEvents: false)
        }
        let output = engine.advance(nowMs: now, todayStartMs: Self.base, emitsEvents: false)
        #expect(output.liveModels.count == 3)
        #expect(output.liveModels.first { $0.model == nil }?.rate.output == 10)
        for source in [SourceKind.codex, .claudeCode] {
            #expect(output.liveModels.filter { $0.source == source }.reduce(0) { $0 + $1.rate.output } == output.sourceLive[source]?.output)
        }
    }

}

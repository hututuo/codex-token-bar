import Foundation
import Testing
@testable import AgentSpeedCore

/// METRICS 11.4: what the report ledger counts, growth of counted responses, attribution and exactly-once windows.
@Suite struct ReportLedgerTests {
    static let base: Int64 = 1_800_000_000_000
    static let today = base - 3_600_000

    static func record(_ key: String, source: SourceKind = .claudeCode, model: String? = "claude-opus-5-5",
                       start: Int64?, end: Int64, input: Int = 1000, cached: Int = 800, output: Int, final: Bool = true,
                       provider: String? = nil) -> ResponseRecord {
        ResponseRecord(key: key, source: source, agentId: "/agents/\(source.rawValue)", model: model, startMs: start,
                       endMs: end, usage: TokenUsage(input: input, cachedInput: cached, output: output, reasoning: 0),
                       isFinal: final, provider: provider)
    }

    static func counters(_ engine: inout SpeedEngine, at now: Int64) -> ReportCounters {
        engine.advance(nowMs: now, todayStartMs: today, emitsEvents: true).report.counters
    }

    @Test func countsOnlyLiveRecentFirstEmissions() {
        var engine = SpeedEngine(pricing: PriceBook())
        let now = Self.base
        engine.upsert(Self.record("seeded", start: now - 9000, end: now - 5000, output: 300), project: "p",
                      isCompletion: true, emitsEvents: false)
        engine.upsert(Self.record("old", start: now - 200_000, end: now - 121_000, output: 50), project: "p",
                      isCompletion: true, emitsEvents: true, nowMs: now)
        engine.upsert(Self.record("live", start: now - 4000, end: now - 1000, output: 120), project: "p",
                      isCompletion: true, emitsEvents: true, nowMs: now)
        engine.upsert(Self.record("seeded", start: now - 9000, end: now - 500, output: 900), project: "p",
                      isCompletion: false, emitsEvents: true, nowMs: now)
        let total = Self.counters(&engine, at: now).total
        #expect(total.requests == 1)
        #expect(total.output == 120)
        #expect(total.input == 1000)
        #expect(total.cachedInput == 800)
        #expect(total.measuredOutput == 120)
        #expect(total.measuredMs == 3000)
        #expect(total.costMicroUsd > 0)
        #expect(total.unpricedRequests == 0)
    }

    /// A streaming Claude message adds its growth where it is seen; becoming measured adds output and time then.
    @Test func growthIsCountedOnceWhereSeen() {
        var engine = SpeedEngine(pricing: PriceBook())
        let now = Self.base
        engine.upsert(Self.record("m", start: now - 3000, end: now - 2000, output: 8, final: false), project: "p",
                      isCompletion: true, emitsEvents: true, nowMs: now)
        let first = Self.counters(&engine, at: now)
        #expect(first.total.output == 8 && first.total.measuredOutput == 0)
        engine.upsert(Self.record("m", start: now - 3000, end: now - 500, output: 400, final: false), project: "p",
                      isCompletion: false, emitsEvents: true, nowMs: now + 500)
        engine.upsert(Self.record("m", start: now - 3000, end: now, output: 420), project: "p",
                      isCompletion: false, emitsEvents: true, nowMs: now + 500)
        let second = Self.counters(&engine, at: now + 500)
        let window = second.since(first).total
        #expect(window.requests == 0)
        #expect(window.output == 412)
        #expect(window.measuredOutput == 420)
        #expect(window.measuredMs == 3000)
        engine.upsert(Self.record("m", start: now - 3000, end: now, output: 300), project: "p",
                      isCompletion: false, emitsEvents: true, nowMs: now + 1000)
        #expect(Self.counters(&engine, at: now + 1000) == second, "shrinking usage adds nothing")
    }

    @Test func modelIdsAreResolvedNeverRaw() {
        var engine = SpeedEngine(pricing: PriceBook())
        let now = Self.base
        engine.upsert(Self.record("a", model: "Claude-Opus-5-5[1m]", start: now - 3000, end: now - 1000, output: 10),
                      project: "p", isCompletion: true, emitsEvents: true, nowMs: now)
        engine.upsert(Self.record("b", source: .opencode, model: "qwen3:32b", start: now - 3000, end: now - 1000,
                                  output: 20, provider: "ollama"), project: "p", isCompletion: true, emitsEvents: true, nowMs: now)
        engine.upsert(Self.record("c", source: .omp, model: "secret-internal-model", start: now - 3000, end: now - 1000,
                                  output: 30), project: "p", isCompletion: true, emitsEvents: true, nowMs: now)
        engine.upsert(Self.record("d", source: .omp, model: "deepseek-v4.1-flash-free", start: now - 3000,
                                  end: now - 1000, output: 5), project: "p", isCompletion: true, emitsEvents: true, nowMs: now)
        let ids = Set(Self.counters(&engine, at: now).byModel.keys.map(\.modelId))
        #expect(ids == ["claude-opus-5-5", "local", "unknown"])
        let unknown = Self.counters(&engine, at: now).byModel[ReportModelKey(modelId: "unknown", source: .omp)]
        #expect(unknown?.unpricedRequests == 1, "the unknown model is unpriced; the free suffix costs a known 0")
    }

    @Test func agentCountsUseTheBaseSet() {
        var engine = SpeedEngine(pricing: PriceBook())
        let now = Self.base
        engine.setAgent(EngineAgent(id: "g", source: .codex, project: "p", model: "gpt-5.5", phase: .generating,
                                    inFlightStartMs: now - 1000, lastLineMs: now - 1000))
        engine.setAgent(EngineAgent(id: "t", source: .codex, project: "p", phase: .tools, lastLineMs: now - 2000))
        engine.setAgent(EngineAgent(id: "stale", source: .codex, project: "p", phase: .tools, lastLineMs: now - 400_000))
        engine.setAgent(EngineAgent(id: "gone", source: .gemini, project: "p", lastLineMs: now - 700_000))
        engine.setAgent(EngineAgent(id: "child", source: .codex, project: "p", lastLineMs: now - 3000, parentId: "gone"))
        let facts = engine.advance(nowMs: now, todayStartMs: Self.today, emitsEvents: true).report
        #expect(facts.agents[.codex] == ReportAgentCounts(generating: 1, tools: 1, active: 4))
        #expect(facts.agents[.gemini] == nil, "an ancestor outside the base set is not counted")
        #expect(facts.generatingModels == [ReportModelKey(modelId: "gpt-5.5", source: .codex): 1])
    }

    /// Σ deltas of built windows + Σ discarded = Σ increments; windows never share an increment.
    @Test func windowsAreExactlyOnce() {
        var engine = SpeedEngine(pricing: PriceBook())
        let now = Self.base
        var window = ReportWindow(ReportSample(facts: engine.advance(nowMs: now, todayStartMs: Self.today, emitsEvents: true).report))
        var built = ReportUsage()
        var discarded = ReportUsage()
        for step in 1...40 {
            let t = now + Int64(step) * 500
            engine.upsert(Self.record("r\(step)", start: t - 2000, end: t, output: step), project: "p",
                          isCompletion: true, emitsEvents: true, nowMs: t)
            let sample = ReportSample(facts: engine.advance(nowMs: t, todayStartMs: Self.today, emitsEvents: true).report)
            if step % 7 == 0 {
                discarded += window.content(sample).usage.total
                window.discard(sample, keepingTick: false)
            } else if step % 3 == 0 {
                built += window.take(sample).usage.total
            }
            window.observe(sample)
        }
        let final = ReportSample(facts: engine.advance(nowMs: now + 30_000, todayStartMs: Self.today, emitsEvents: true).report)
        built += window.take(final).usage.total
        #expect(built.output + discarded.output == (1...40).reduce(0, +))
        #expect(built.requests + discarded.requests == 40)
    }

    @Test func gapKeepsTheTicksOwnIncrements() {
        var counters = ReportCounters()
        let key = ReportModelKey(modelId: "gpt-5.5", source: .codex)
        counters.add(ReportUsage(requests: 1, output: 10), to: key)
        var window = ReportWindow(ReportSample(facts: ReportLiveFacts(counters: counters)))
        counters.add(ReportUsage(requests: 1, output: 5), to: key)
        let before = ReportSample(facts: ReportLiveFacts(counters: counters))
        window.observe(before)
        counters.add(ReportUsage(requests: 1, output: 7), to: key)
        let afterSleep = ReportSample(facts: ReportLiveFacts(counters: counters))
        #expect(window.hasTokenIncrement(afterSleep))
        window.discard(afterSleep, keepingTick: true)
        #expect(window.take(afterSleep).usage.total.output == 7)
    }

    @Test func reportModelIdPattern() {
        #expect(ReportModelIds.isValid("gpt-5.5"))
        #expect(ReportModelIds.isValid("qwen3:32b"))
        #expect(!ReportModelIds.isValid("GPT-5"))
        #expect(!ReportModelIds.isValid("-x"))
        #expect(!ReportModelIds.isValid(String(repeating: "a", count: 65)))
    }

    @Test func titleTrackerFollowsDesign1() {
        var tracker = ReportTitleTracker()
        tracker.update(value: 900, redline: 2000, now: 0)
        #expect(tracker.level == 0, "a change takes effect after 0.8 s")
        tracker.update(value: 900, redline: 2000, now: 0.8)
        #expect(tracker.level == 10)
        tracker.update(value: 650, redline: 2000, now: 1.0)
        tracker.update(value: 650, redline: 2000, now: 2.0)
        #expect(tracker.level == 10, "kept above 90 % of 0.34 × 2000")
        tracker.update(value: 600, redline: 2000, now: 2.0)
        tracker.update(value: 600, redline: 2000, now: 3.0)
        #expect(tracker.level == 9, "left below 90 % of it")
        tracker.update(value: 0, redline: 2000, now: 4.0)
        tracker.update(value: 0, redline: 2000, now: 7.0)
        tracker.update(value: 0, redline: 2000, now: 8.0)
        #expect(tracker.level == 0)
        #expect(abs(ReportTitleTracker.heat(value: 412.6, redline: 2000) - 0.388) < 0.0005)
        #expect(ReportTitleTracker.heat(value: 5000, redline: 2000) == 1)
    }
}

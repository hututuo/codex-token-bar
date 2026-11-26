import Darwin
import Foundation
import XCTest
@testable import AgentSpeedCore

/// Copy unchanged into AgentSpeedCoreTests in each exact revision, then build/run
/// on a hosted macOS runner. Never reads user transcripts, preferences, or DBs.
final class SpeedEngineBenchmarkTests: XCTestCase {
    private let day: Int64 = 1_800_000_000_000
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private struct MemorySample {
        var userMicroseconds: Int64
        var systemMicroseconds: Int64
        var peakRSSBytes: Int64
        var currentRSSBytes: UInt64?
        var currentRSSStatus: kern_return_t
    }

    private func sample() throws -> MemorySample {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        func micros(_ time: timeval) -> Int64 { Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec) }
        return MemorySample(userMicroseconds: micros(usage.ru_utime), systemMicroseconds: micros(usage.ru_stime),
                            peakRSSBytes: Int64(usage.ru_maxrss),
                            currentRSSBytes: result == KERN_SUCCESS ? UInt64(info.resident_size) : nil,
                            currentRSSStatus: result)
    }

    private func emit(_ kind: String, _ body: [String: Any]) throws {
        var record = body
        record["kind"] = kind
        record["source"] = environment["SPEED_BENCHMARK_SOURCE"] ?? "unspecified"
        record["trial"] = Int(environment["SPEED_BENCHMARK_TRIAL"] ?? "0") ?? 0
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("SPEED_ENGINE_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }

    private func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    private func rate(_ value: Rate) -> [Double] { [value.output, value.total] }
    private func cost(_ value: LiveCost) -> [Double] { [value.microUsdPerSecond, value.knownOutput] }
    private func tally(_ value: CostTally) -> [Int64] { [value.costMicroUsd, Int64(value.unpricedRequests)] }
    private func totals(_ value: TokenTotals) -> [Int] {
        [value.requests, value.input, value.cachedInput, value.cacheWriteInput, value.output, value.reasoning]
    }
    private func reportUsage(_ value: ReportUsage) -> [Int64] {
        [value.requests, value.input, value.cachedInput, value.cacheWriteInput, value.output, value.reasoning,
         value.measuredOutput, value.measuredMs, value.costMicroUsd, value.unpricedRequests]
    }

    /// Stable JSON field names and explicitly sorted maps allow a recursive,
    /// tolerance-aware baseline/candidate comparison outside the measured loop.
    private func semanticOutput(_ output: EngineOutput) -> [String: Any] {
        let sourceRows: [[String: Any]] = SourceKind.allCases.map { source in
            ["source": source.rawValue, "today": totals(output.todayBySource[source] ?? .zero),
             "live": rate(output.sourceLive[source] ?? .zero),
             "estimated": rate(output.sourceLiveEstimated[source] ?? .zero),
             "liveCost": cost(output.sourceLiveCost[source] ?? .zero),
             "todayCost": tally(output.todayCostBySource[source] ?? .zero),
             "modelCosts": (output.todayCostByModel[source] ?? [:]).keys.sorted().map { model -> [Any] in
                 [model, tally(output.todayCostByModel[source]![model]!)]
             }]
        }
        let agents: [[String: Any]] = output.agents.map {
            ["id": $0.agent.id, "source": $0.agent.source.rawValue, "phase": $0.phase.rawValue,
             "parent": nullable($0.parentId), "model": nullable($0.agent.model), "live": rate($0.live),
             "recent": nullable($0.recentSpeed), "liveCost": cost($0.liveCost),
             "lastLineMs": nullable($0.agent.lastLineMs), "stopped": $0.agent.localDisplayStopped]
        }
        let reportModels: [[Any]] = output.report.counters.byModel.keys.sorted {
            ($0.source.rawValue, $0.modelId) < ($1.source.rawValue, $1.modelId)
        }.map { [$0.source.rawValue, $0.modelId, reportUsage(output.report.counters.byModel[$0]!)] }
        let reportAgents: [[Any]] = output.report.agents.keys.sorted { $0.rawValue < $1.rawValue }.map {
            let counts = output.report.agents[$0]!
            return [$0.rawValue, counts.generating, counts.tools, counts.active]
        }
        let generatingModels: [[Any]] = output.report.generatingModels.keys.sorted {
            ($0.source.rawValue, $0.modelId) < ($1.source.rawValue, $1.modelId)
        }.map { [$0.source.rawValue, $0.modelId, output.report.generatingModels[$0]!] }
        let last = nullable(output.lastResponse.map { summary -> [String: Any] in
            ["source": summary.source.rawValue, "project": summary.project, "model": nullable(summary.model),
             "output": summary.outputTokens, "total": summary.totalTokens,
             "duration": nullable(summary.duration), "speed": nullable(summary.speed),
             "endMs": Int64((summary.endedAt.timeIntervalSince1970 * 1000).rounded())]
        })
        return [
            "nowMs": output.nowMs, "todayStartMs": output.todayStartMs, "today": totals(output.today),
            "average": nullable(output.averageToday), "unfinalized": output.unfinalizedToday,
            "live": rate(output.live), "estimatedShare": output.liveEstimatedShare,
            "liveCost": cost(output.liveCost), "todayCost": tally(output.todayCost),
            "peak": rate(output.peakToday), "peakAtMs": nullable(output.peakTodayAtMs),
            "sources": sourceRows, "agents": agents,
            "models": output.liveModels.map { [$0.source.rawValue, nullable($0.model), rate($0.rate)] as [Any] },
            "history": output.history.map {
                [Double(Int64(($0.time.timeIntervalSince1970 * 1000).rounded())),
                 $0.measured.output, $0.measured.total, $0.estimated.output, $0.estimated.total]
            },
            "subsets": output.subsetPeaks.keys.sorted { $0.rawValue < $1.rawValue }.map {
                [Double($0.rawValue), output.subsetPeaks[$0]!]
            },
            "lastResponse": last, "reportTotal": reportUsage(output.report.counters.total),
            "reportModels": reportModels, "reportAgents": reportAgents, "generatingModels": generatingModels,
            "eventCount": output.events.count,
        ]
    }

    func testUnchangedSyntheticPublishes() throws {
        let count = Int(environment["SPEED_BENCHMARK_RESPONSES"] ?? "2000") ?? 0
        let ticks = Int(environment["SPEED_BENCHMARK_TICKS"] ?? "200") ?? 0
        let shape = environment["SPEED_BENCHMARK_SHAPE"] ?? "day"
        guard [2000, 20000].contains(count), (1...2000).contains(ticks), ["day", "dense"].contains(shape) else {
            throw NSError(domain: "SpeedEngineBenchmarkInputs", code: 1)
        }
        let beforeFixture = try sample()
        let now = day + 82_000_000
        let span: Int64 = shape == "day" ? 80_000_000 : 1_700_000
        let sources: [SourceKind] = [.codex, .claudeCode, .deepseek, .gemini]
        let subsets: Set<SourceSet> = [SourceSet(.codex), SourceSet([.codex, .claudeCode]), .everything]
        var engine = SpeedEngine()
        var expectedInput = 0
        var expectedOutput = 0
        var expectedUnfinalized = 0
        var expectedCost: Int64 = 0
        var expectedUnpriced = 0
        for index in 0..<count {
            let source = sources[index % sources.count]
            let end = now - Int64(index) * span / Int64(count)
            let input = 100 + index % 17
            // Distinct magnitudes reduce artificial equal-height peak ties in
            // the day ledger's independent dictionary-order accumulation.
            let output = 40 + index
            let final = index % 19 != 0
            let knownCost: Int64? = index % 7 == 0 ? nil : Int64(100 + index % 29)
            let record = ResponseRecord(key: String(format: "r-%08d", index), source: source,
                agentId: "agent-\(index % 32)", model: "model-\(index % 3)",
                startMs: index % 23 == 0 ? nil : end - Int64(1000 + index % 5 * 250), endMs: end,
                usage: TokenUsage(input: input, output: output), isFinal: final, costMicroUsd: knownCost)
            engine.upsert(record, project: "synthetic", isCompletion: true, emitsEvents: false)
            expectedInput += input
            expectedOutput += output
            expectedUnfinalized += final ? 0 : 1
            expectedCost += knownCost ?? 0
            expectedUnpriced += knownCost == nil ? 1 : 0
        }
        for index in 0..<32 {
            engine.setAgent(EngineAgent(id: "agent-\(index)", source: sources[index % sources.count], project: "synthetic",
                model: "model-\(index % 3)", phase: index % 3 == 0 ? .generating : .tools,
                inFlightStartMs: now - 2500, lastLineMs: now))
        }
        let warmed = engine.advance(nowMs: now, todayStartMs: day, emitsEvents: false, subsets: subsets)
        XCTAssertEqual(warmed.today.requests, count)
        XCTAssertEqual(warmed.today.input, expectedInput)
        XCTAssertEqual(warmed.today.output, expectedOutput)
        XCTAssertEqual(warmed.unfinalizedToday, expectedUnfinalized)
        XCTAssertEqual(warmed.todayCost.costMicroUsd, expectedCost)
        XCTAssertEqual(warmed.todayCost.unpricedRequests, expectedUnpriced)
        let before = try sample()
        let start = DispatchTime.now().uptimeNanoseconds
        var checksum = 0.0
        var last = warmed
        for tick in 1...ticks {
            last = engine.advance(nowMs: now + Int64(tick) * 500, todayStartMs: day, emitsEvents: false, subsets: subsets)
            checksum += last.live.output + Double(last.today.requests) + last.history[299].measured.output
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let after = try sample()
        XCTAssertEqual(last.today, warmed.today)
        XCTAssertEqual(last.todayCost, warmed.todayCost)
        XCTAssertEqual(last.unfinalizedToday, warmed.unfinalizedToday)
        XCTAssertTrue(checksum.isFinite && checksum > 0)
        try emit("measurement", [
            "phase": "unchanged", "fixtureResponses": count, "shape": shape, "ticks": ticks,
            "milliseconds": elapsedMs,
            "userMilliseconds": Double(after.userMicroseconds - before.userMicroseconds) / 1000,
            "systemMilliseconds": Double(after.systemMicroseconds - before.systemMicroseconds) / 1000,
            "cpuMilliseconds": Double(after.userMicroseconds + after.systemMicroseconds - before.userMicroseconds - before.systemMicroseconds) / 1000,
            "processPeakRSSBytesBeforeFixture": beforeFixture.peakRSSBytes,
            "processPeakRSSBytesBeforeLoop": before.peakRSSBytes, "processPeakRSSBytesAfterLoop": after.peakRSSBytes,
            "processCurrentRSSBytesBeforeFixture": nullable(beforeFixture.currentRSSBytes),
            "processCurrentRSSBytesBeforeLoop": nullable(before.currentRSSBytes),
            "processCurrentRSSBytesAfterLoop": nullable(after.currentRSSBytes),
            "currentRSSStatusBeforeFixture": beforeFixture.currentRSSStatus,
            "currentRSSStatusBefore": before.currentRSSStatus, "currentRSSStatusAfter": after.currentRSSStatus,
            "checksum": checksum,
        ])
        try emit("correctness", ["phase": "warmed", "fixtureResponses": count, "shape": shape,
                                 "output": semanticOutput(warmed)])
        try emit("correctness", ["phase": "after-unchanged", "fixtureResponses": count, "shape": shape,
                                 "output": semanticOutput(last)])
    }

    func testReplacementAndBoundaryCompatibilityTrace() throws {
        let now = day + 82_000_000
        var engine = SpeedEngine()
        func response(_ key: String, agent: String = "a", end: Int64, output: Int = 100, valid: Bool = true) -> ResponseRecord {
            ResponseRecord(key: key, source: .codex, agentId: agent, model: "model", startMs: valid ? end - 1000 : nil,
                           endMs: end, usage: TokenUsage(input: 10, output: output), costMicroUsd: 123)
        }
        func trace(_ phase: String, at instant: Int64, today: Int64) throws -> EngineOutput {
            let output = engine.advance(nowMs: instant, todayStartMs: today, emitsEvents: false, subsets: [.everything])
            try emit("compatibility", ["phase": phase, "output": semanticOutput(output),
                "storedKeys": engine.storedResponses.map(\.key).sorted()])
            return output
        }
        engine.setAgent(EngineAgent(id: "a", source: .codex, project: "synthetic", model: "model", phase: .generating,
                                   inFlightStartMs: now - 5000, lastLineMs: now))
        for (key, output) in [("d", 120), ("b", 60), ("a", 30), ("c", 90)] {
            engine.upsert(response(key, end: now - 6000, output: output), project: key, isCompletion: true, emitsEvents: false)
        }
        // Equal-ended a,b,c are the three reference responses, independent of insertion order.
        let tied = try trace("equal-end-key-order", at: now, today: day)
        XCTAssertEqual(tied.agents.first?.recentSpeed, 60)
        XCTAssertEqual(tied.lastResponse?.project, "c", "lastResponse intentionally follows >= end arrival order")
        engine.upsert(response("invalid", end: now - 1000, valid: false), project: "invalid", isCompletion: true, emitsEvents: false)
        let invalid = try trace("invalid-interval-still-limits-inflight", at: now, today: day)
        XCTAssertEqual(invalid.live.output, 20, accuracy: 1e-9)
        engine.upsert(response("invalid", end: now - 2000, valid: false), project: "corrected", isCompletion: false, emitsEvents: false)
        let backward = try trace("same-key-end-moves-backward", at: now, today: day)
        XCTAssertEqual(backward.live.output, 40, accuracy: 1e-9)
        XCTAssertEqual(backward.lastResponse?.project, "invalid", "do not retroactively recompute lastResponse")
        engine.upsert(response("invalid", agent: "b", end: now - 1000, valid: false), project: "moved", isCompletion: false, emitsEvents: false)
        let moved = try trace("same-key-agent-changes", at: now, today: day)
        XCTAssertEqual(moved.live.output, 60, accuracy: 1e-9)
        var streaming = response("stream", end: now - 500, output: 1)
        streaming.isFinal = false
        engine.upsert(streaming, project: "stream", isCompletion: true, emitsEvents: false)
        _ = try trace("nonfinal", at: now, today: day)
        streaming.isFinal = true
        streaming.usage.output = 300
        engine.upsert(streaming, project: "stream-final", isCompletion: false, emitsEvents: false)
        _ = try trace("late-final-enrichment", at: now, today: day)
        engine.removeAgent(id: "a")
        _ = try trace("remove-agent-keeps-responses", at: now, today: day)

        // Keep today's older records, but strictly expire yesterday's records only
        // after their end falls below min(todayStart, now - retention).
        let midnight = day + 86_400_000
        for (key, end) in [("before-cutoff", midnight - 1001), ("at-cutoff", midnight - 1000), ("today", midnight)] {
            engine.upsert(response(key, end: end), project: key, isCompletion: true, emitsEvents: false)
        }
        _ = try trace("rollover-retention-equality", at: midnight + SpeedEngine.retentionMs - 1000, today: midnight)
        XCTAssertFalse(engine.storedResponses.contains { $0.key == "before-cutoff" })
        XCTAssertTrue(engine.storedResponses.contains { $0.key == "at-cutoff" })
        _ = try trace("one-millisecond-past-retention", at: midnight + SpeedEngine.retentionMs - 999, today: midnight)
        XCTAssertFalse(engine.storedResponses.contains { $0.key == "at-cutoff" })
        _ = try trace("clock-moves-back-without-resurrection", at: midnight + 1000, today: midnight)
        engine = SpeedEngine()
        let reset = try trace("fresh-engine-reset", at: midnight + 1000, today: midnight)
        XCTAssertEqual(reset.today.requests, 0)
        XCTAssertEqual(reset.live, .zero)
        XCTAssertTrue(engine.storedResponses.isEmpty)
    }
}

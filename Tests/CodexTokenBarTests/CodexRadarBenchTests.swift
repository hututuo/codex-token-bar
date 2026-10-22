import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexRadarBenchTests: XCTestCase {
    func testCapturedV5ScoreStatisticsAndHistoryKeepTheirUnits() throws {
        let binding = try decodeBinding(bindingData())
        let summary = try JSONDecoder().decode(CodexRadarBenchSummary.self, from: fixture("summary-v5.json"))
        let result = try summary.result(binding: binding, selection: .init(model: "gpt-6-astra", effort: "max"))
        XCTAssertEqual(binding.modelEfforts.count, 34)
        XCTAssertTrue(binding.modelEfforts.contains(.init(model: "gpt-6.1-sol", effort: "ultra")))
        XCTAssertEqual(try XCTUnwrap(result.score), 113.67307692307693, accuracy: 0.000_001)
        XCTAssertEqual(result.coverage, 63)
        XCTAssertEqual(result.gradedRunsCount, 63)
        XCTAssertEqual(try XCTUnwrap(result.statistics?.averageMinutes), 16.876103174603177, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.statistics?.averageAPIEquivalentUSD), 4.302995936507937, accuracy: 0.000_001)
        XCTAssertEqual(result.history?.points.first?.at, "2026-10-09T00:00:00.000Z")
        let model = self.model(result: result)
        XCTAssertEqual(model.iq, 113.67307692307693, accuracy: 0.000_001)
        XCTAssertEqual(model.scoreDisplayText, "113.7")
        XCTAssertNil(model.latestGradedAt)
        XCTAssertTrue(model.rankingDetailText.contains("雷达分 113.7"))
        XCTAssertTrue(model.rankingDetailText.contains("63/64 题"))
        XCTAssertTrue(model.rankingDetailText.contains("已判 63"))
        XCTAssertFalse(model.rankingDetailText.contains("IQ"))
        XCTAssertFalse(model.rankingAccessibilityText.contains("通过"))
        XCTAssertFalse(model.rankingAccessibilityText.contains("0/0"))
        let solLabels = ["gpt-6.1-sol", "gpt-6-sol"].map { name in
            CodexCrowdRadarModel(model: name, effort: "high", graded: 0, passed: 0, passRate: 0, cells: 0, radarBench: result).label
        }
        XCTAssertEqual(solLabels, ["gpt-6.1-sol high", "gpt-6-sol high"])
        XCTAssertNotEqual(solLabels[0], solLabels[1])
    }

    func testCapturedV6DetailsPreserveScoreUnitsAndRejectChangedScoringPolicy() throws {
        let binding = try decodeBinding(bindingData())
        let selection = CodexRadarBenchSelection(model: "gpt-6-astra", effort: "max")
        let bytes = try fixture("summary-v6.json")
        let result = try decodeResult(bytes, binding: binding, selection: selection)
        XCTAssertEqual(try XCTUnwrap(result.score), 106.81881009615384, accuracy: 0.000001)
        XCTAssertEqual(result.coverage, 64)
        XCTAssertEqual(result.gradedRunsCount, 116)
        XCTAssertEqual(try XCTUnwrap(result.statistics?.averageMinutes), 19.202378765477054, accuracy: 0.000001)
        XCTAssertNotNil(result.history)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        raw["scoring_policy_version"] = "future-policy"
        XCTAssertThrowsError(try decodeResult(data(raw), binding: binding, selection: selection))
    }

    func testZeroAndMissingScoresStayDistinctAndLowCoverageIsRankable() throws {
        let binding = try decodeBinding(bindingData())
        let selection = CodexRadarBenchSelection(model: "gpt-6-astra", effort: "max")
        let zero = try decodeResult(summaryData(selection: selection, changes: ["score": 0, "coverage": 1]), binding: binding, selection: selection)
        let missing = try decodeResult(summaryData(selection: selection, changes: ["score": NSNull(), "coverage": 0, "graded_runs_count": 0, "score_status": "missing_current_result"]), binding: binding, selection: selection)
        XCTAssertEqual(zero.score, 0)
        XCTAssertNil(missing.score)
        XCTAssertEqual(model(result: zero).scoreDisplayText, "0.0")
        XCTAssertEqual(model(result: missing).scoreDisplayText, "待测")
        let snapshot = self.snapshot(binding: binding, models: [model(result: zero)])
        XCTAssertEqual(snapshot.rankedModels.count, 1)
        XCTAssertEqual(snapshot.rankedModels.first?.scoreSamples, 0, "coverage is not a fabricated legacy sample count")
        XCTAssertEqual(snapshot.rankedModels(for: .recent), snapshot.rankedModels(for: .realtime))
        XCTAssertEqual(snapshot.benchmarkSource, "radar-bench")
        XCTAssertEqual(snapshot.generatedAt, "")
        func tiedRow(effort: String, coverage: Int) -> CodexCrowdRadarModel {
            let result = CodexRadarBenchResult(score: 0, coverage: coverage, requiredTasks: 64, scoreStatus: "provisional",
                gradedRunsCount: coverage, statistics: nil, history: nil, failure: nil)
            return CodexCrowdRadarModel(model: "gpt-6-astra", effort: effort, graded: 0, passed: 0, passRate: 0, cells: 0, radarBench: result)
        }
        let tied = self.snapshot(binding: binding, models: [tiedRow(effort: "xhigh", coverage: 2), tiedRow(effort: "low", coverage: 3), tiedRow(effort: "high", coverage: 3)])
        XCTAssertEqual(tied.rankedModels.map(\.effort), ["high", "low", "xhigh"])
    }

    func testSummaryRejectsWrongIdentityVersionStateAndMissingCounters() throws {
        let binding = try decodeBinding(bindingData())
        let selection = CodexRadarBenchSelection(model: "gpt-6-astra", effort: "max")
        let invalid: [[String: Any]] = [
            ["model": "gpt-6.1-sol"], ["effort": "high"], ["benchmark": "other"],
            ["catalog_version": "other"], ["task_set_sha256": String(repeating: "a", count: 64)],
            ["score_version": "radar-bench-v1"], ["score_max": 100], ["schema": "radar-bench-public-summary-v1"],
            ["scoring_policy_version": "radar-bench-v1-last3-per-task-equal-weight-100"],
            ["required_tasks": 68], ["source_counts": ["deepswe": 64]], ["score": 151],
            ["score": NSNull()], ["coverage": 0], ["score_status": "complete"],
            ["graded_runs_count": 62], ["graded_runs_count": NSNull()]
        ]
        for changes in invalid {
            XCTAssertThrowsError(try decodeResult(summaryData(selection: selection, changes: changes), binding: binding, selection: selection), "\(changes)")
        }
        for key in ["score", "graded_runs_count"] {
            var object = try summaryObject(selection: selection)
            object.removeValue(forKey: key)
            XCTAssertThrowsError(try decodeResult(data(object), binding: binding, selection: selection))
        }
        let doubled = try decodeResult(summaryData(selection: selection, changes: ["graded_runs_count": 126]), binding: binding, selection: selection)
        XCTAssertEqual(doubled.coverage, 63)
        XCTAssertEqual(doubled.gradedRunsCount, 126)
    }

    func testBindingRejectsUntrustedFlagsDuplicateSelectionsAndInvalidIdentifiers() throws {
        let invalid: [[String: Any]] = [
            ["enabled": false], ["interface_confirmed": false], ["production_read_verified": false],
            ["score_version": "unknown"], ["score_max": 100], ["total_tasks": 0], ["total_tasks": 4097],
            ["source_counts": ["deepswe": 63]], ["task_set_sha256": "not-a-hash"],
            ["active_display_selection": ["model": "unlisted", "effort": "high"]],
            ["model_efforts": [["model": "gpt-6-astra", "effort": "max"], ["model": "gpt-6-astra", "effort": "max"]]],
            ["model_efforts": [["model": "bad/model", "effort": "high"]]], ["model_efforts": []]
        ]
        for changes in invalid { XCTAssertThrowsError(try decodeBinding(bindingData(changes: changes)), "\(changes)") }
    }

    func testOptionalStatisticsAndHistoryCannotInventMissingEvidenceOrCrossIdentity() throws {
        let binding = try decodeBinding(bindingData())
        let selection = CodexRadarBenchSelection(model: "gpt-6-astra", effort: "max")
        let unknown = try decodeResult(summaryData(selection: selection, changes: ["statistics": NSNull(), "history": NSNull()]), binding: binding, selection: selection)
        XCTAssertNil(unknown.statistics)
        XCTAssertNil(unknown.history)
        var object = try summaryObject(selection: selection)
        var history = try XCTUnwrap(object["history"] as? [String: Any])
        history["model"] = "gpt-6.1-sol"
        object["history"] = history
        XCTAssertNil(try decodeResult(data(object), binding: binding, selection: selection).history)
        history["model"] = selection.model
        history["updated_bucket"] = "2026-10-10T00:00:00.000Z"
        object["history"] = history
        XCTAssertNil(try decodeResult(data(object), binding: binding, selection: selection).history)
        history["updated_bucket"] = "2026-10-09T00:00:00.000Z"
        var points = try XCTUnwrap(history["points"] as? [[String: Any]])
        var duplicate = points[0]
        duplicate["at"] = "2026-10-09T00:00:00Z"
        points.append(duplicate)
        history["points"] = points
        object["history"] = history
        XCTAssertNil(try decodeResult(data(object), binding: binding, selection: selection).history)
        var statistics = try XCTUnwrap(object["statistics"] as? [String: Any])
        statistics["sample_count"] = 62
        object["statistics"] = statistics
        let invalidStats = try decodeResult(data(object), binding: binding, selection: selection)
        XCTAssertNil(invalidStats.statistics?.averageMinutes)
        XCTAssertNil(invalidStats.statistics?.averageAPIEquivalentUSD)
        XCTAssertNotNil(invalidStats.score)
        statistics["sample_count"] = 63
        statistics["cost_basis"] = "estimated"
        object["statistics"] = statistics
        XCTAssertNil(try decodeResult(data(object), binding: binding, selection: selection).statistics?.averageAPIEquivalentUSD)

        object = try summaryObject(selection: selection)
        statistics = try XCTUnwrap(object["statistics"] as? [String: Any])
        let originalMetrics = try XCTUnwrap(statistics["metrics"] as? [String: Any])
        for missing in ["elapsed_ms", "api_equivalent_usd"] {
            var metrics = originalMetrics
            metrics[missing] = NSNull()
            statistics["metrics"] = metrics
            object["statistics"] = statistics
            let projected = try decodeResult(data(object), binding: binding, selection: selection)
            if missing == "elapsed_ms" {
                XCTAssertNil(projected.statistics?.averageMinutes)
                XCTAssertNotNil(projected.statistics?.averageAPIEquivalentUSD)
            } else {
                XCTAssertNotNil(projected.statistics?.averageMinutes)
                XCTAssertNil(projected.statistics?.averageAPIEquivalentUSD)
            }
        }
    }

    func testReaderUsesFixedPublicURLsAndBoundedConcurrentCatalogRequests() async throws {
        let binding = try decodeBinding(bindingData(changes: ["transport_origin": "https://untrusted.invalid", "endpoint_path": "/private"]))
        let probe = try self.probe(binding: binding)
        await probe.replaceBinding(try bindingData(changes: ["transport_origin": "https://untrusted.invalid", "endpoint_path": "/private"]))
        let reader = LiveCodexRadarBenchReader(transport: { try await probe.read($0) })
        let snapshot = try await reader.readCrowdRadar()
        XCTAssertTrue(snapshot.isRadarBench)
        XCTAssertEqual(snapshot.models.count, 34)
        XCTAssertEqual(snapshot.rankedModels.count, 34)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 35)
        for request in requests {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "codexradar.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertLessThanOrEqual(request.timeoutInterval, 5)
            if request.url?.path == "/api/radar-bench-score" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "view" }?.value, "summary")
                XCTAssertEqual(query.first { $0.name == "selection" }?.value, "user-selected-v1")
            }
        }
        let concurrency = await probe.maximumActive
        XCTAssertGreaterThan(concurrency, 1)
        XCTAssertLessThanOrEqual(concurrency, 6)
    }

    func testPartialFailureRetainsOnlySameBasisRowsAndAllFailureThrows() async throws {
        let selections = [CodexRadarBenchSelection(model: "gpt-6-astra", effort: "max"), .init(model: "gpt-6-astra", effort: "high")]
        let binding = try decodeBinding(bindingData(selections: selections))
        let probe = try self.probe(binding: binding)
        let reader = LiveCodexRadarBenchReader(transport: { try await probe.read($0) })
        _ = try await reader.readCrowdRadar()
        await probe.setFailures([selections[0].id])
        let partial = try await reader.readCrowdRadar()
        XCTAssertNotNil(partial.models.first?.radarBench?.score)
        XCTAssertNotNil(partial.models.first?.radarBench?.failure)
        XCTAssertEqual(partial.rankedModels.count, 1)
        XCTAssertEqual(partial.sourceDiagnostics.count, 1)
        await probe.setFailures(Set(selections.map(\.id)))
        do { _ = try await reader.readCrowdRadar(); XCTFail("all failures must throw") }
        catch { XCTAssertTrue(error is CodexRadarBenchError) }

        let changed = try decodeBinding(bindingData(selections: selections, changes: ["task_set_sha256": String(repeating: "a", count: 64)]))
        await probe.replaceBinding(try data(from: changed))
        do { _ = try await reader.readCrowdRadar(); XCTFail("a failed new binding must not commit its cache identity") }
        catch { XCTAssertTrue(error is CodexRadarBenchError) }

        await probe.replaceBinding(try data(from: binding))
        await probe.setFailures([selections[0].id])
        let rolledBack = try await reader.readCrowdRadar()
        XCTAssertEqual(rolledBack.models.first?.radarBench?.score, partial.models.first?.radarBench?.score,
                       "a failed new binding must not erase the previous binding's trusted score")
        XCTAssertNotNil(rolledBack.models.first?.radarBench?.failure)

        await probe.replaceBinding(try data(from: changed))
        await probe.setFailures([selections[0].id])
        await probe.replaceSummary(selections[1], data: try summaryData(selection: selections[1], changes: ["task_set_sha256": changed.taskSetSHA256]))
        let updated = try await reader.readCrowdRadar()
        XCTAssertNil(updated.models.first?.radarBench?.score, "changed task sets cannot reuse prior scores")
    }

    func testLegalAllMissingScoresReturnAValidSnapshotAndRoundTimeoutIsBounded() async throws {
        let selection = CodexRadarBenchSelection(model: "gpt-6-astra", effort: "max")
        let binding = try decodeBinding(bindingData(selections: [selection]))
        let probe = try self.probe(binding: binding)
        await probe.replaceSummary(selection, data: try summaryData(selection: selection, changes: ["score": NSNull(), "coverage": 0, "graded_runs_count": 0, "score_status": "missing_current_result"]))
        let reader = LiveCodexRadarBenchReader(transport: { try await probe.read($0) })
        let snapshot = try await reader.readCrowdRadar()
        XCTAssertTrue(snapshot.rankedModels.isEmpty)
        XCTAssertEqual(snapshot.models.count, 1)
        XCTAssertTrue(snapshot.sourceDiagnostics.isEmpty)
        XCTAssertEqual(snapshot.emptyRankingText, "暂无成绩 · 待测")
        await probe.setDelay(1_000_000_000)
        let shortReader = LiveCodexRadarBenchReader(transport: { try await probe.read($0) }, roundBudget: 0.05, requestBudget: 0.02)
        let started = Date()
        do { _ = try await shortReader.readCrowdRadar(); XCTFail("deadline must fail") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let active = await probe.active
        XCTAssertEqual(active, 0, "cancelled transport tasks must leave the group")
    }

    @MainActor
    func testWholeRoundFailureTravelsThroughPresentationToFloatingTextAndClearsOnRecovery() async throws {
        let binding = try decodeBinding(bindingData())
        let selection = CodexRadarBenchSelection(model: "gpt-6-astra", effort: "max")
        let official = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: Data(#"{"window":{"action":"wait"}}"#.utf8))
        for missing in [false, true] {
            let changes: [String: Any] = missing ? ["score": NSNull(), "coverage": 0, "graded_runs_count": 0, "score_status": "missing_current_result"] : [:]
            let result = try decodeResult(summaryData(selection: selection, changes: changes), binding: binding, selection: selection)
            let trusted = snapshot(binding: binding, models: [model(result: result)])
            for officialFails in [false, true] {
                let store = CodexRadarStore(
                    reader: RadarBenchStoreOfficialReader([.success(official), officialFails ? .failure(.invalidResponse) : .success(official), .success(official)]),
                    feedReader: RadarBenchStoreEmptyFeedReader(),
                    crowdReader: RadarBenchStoreCrowdReader([.success(trusted), .failure(.invalidResponse), .success(trusted)])
                )
                for step in 0..<3 {
                    store.refresh()
                    for _ in 0..<100 {
                        if !store.isRefreshing { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    XCTAssertFalse(store.isRefreshing)
                    let presentation = CodexRadarPresentationState(snapshot: store.snapshot, crowdSnapshot: store.crowdSnapshot)
                    let displayed = try XCTUnwrap(presentation.crowdSnapshot)
                    XCTAssertEqual(displayed.staleDataDisplayed, step == 1)
                    XCTAssertEqual(displayed.models.first?.radarBench?.score, result.score)
                    let value = displayed.floatingRankingAccessibilityValue(displayed.rankedModels(page: 0), start: 0)
                    XCTAssertEqual(value.contains("陈旧，上次数据"), step == 1)
                    if step == 1 && missing { XCTAssertEqual(displayed.emptyRankingText, "上次数据 · 暂无成绩") }
                    if !missing { XCTAssertTrue(value.contains("雷达分 113.7")); XCTAssertFalse(value.contains("0/0")) }
                }
            }
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RadarBench")
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private func bindingData(selections: [CodexRadarBenchSelection]? = nil, changes: [String: Any] = [:]) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("binding-v5.json")) as? [String: Any])
        if let selections {
            object["model_efforts"] = selections.map { ["model": $0.model, "effort": $0.effort] }
            object["active_display_selection"] = ["model": selections[0].model, "effort": selections[0].effort]
        }
        for (key, value) in changes { object[key] = value }
        return try data(object)
    }

    private func decodeBinding(_ bytes: Data) throws -> CodexRadarBenchBinding {
        let binding = try JSONDecoder().decode(CodexRadarBenchBinding.self, from: bytes)
        try binding.validate()
        return binding
    }

    private func summaryObject(selection: CodexRadarBenchSelection) throws -> [String: Any] {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("summary-v5.json")) as? [String: Any])
        object["model"] = selection.model; object["effort"] = selection.effort
        var history = try XCTUnwrap(object["history"] as? [String: Any])
        history["model"] = selection.model; history["effort"] = selection.effort
        object["history"] = history
        return object
    }

    private func summaryData(selection: CodexRadarBenchSelection, changes: [String: Any] = [:]) throws -> Data {
        var object = try summaryObject(selection: selection)
        for (key, value) in changes { object[key] = value }
        return try data(object)
    }

    private func decodeResult(_ bytes: Data, binding: CodexRadarBenchBinding, selection: CodexRadarBenchSelection) throws -> CodexRadarBenchResult {
        try JSONDecoder().decode(CodexRadarBenchSummary.self, from: bytes).result(binding: binding, selection: selection)
    }

    private func model(result: CodexRadarBenchResult) -> CodexCrowdRadarModel {
        CodexCrowdRadarModel(model: "gpt-6-astra", effort: "max", graded: 0, passed: 0, passRate: 0, cells: 0,
                            scorePassed: 0, scoreSamples: 0, radarBench: result)
    }

    private func snapshot(binding: CodexRadarBenchBinding, models: [CodexCrowdRadarModel]) -> CodexCrowdRadarSnapshot {
        CodexCrowdRadarSnapshot(generatedAt: "", taskCount: binding.totalTasks, cellCount: 0, contributorCount: 0,
                               pendingGrades: 0, errorGrades: 0, models: models, radarBenchBinding: binding)
    }

    private func probe(binding: CodexRadarBenchBinding) throws -> RadarBenchTransportProbe {
        let summaries = try Dictionary(uniqueKeysWithValues: binding.modelEfforts.map { ($0.id, try summaryData(selection: $0)) })
        return RadarBenchTransportProbe(binding: try data(from: binding), summaries: summaries)
    }

    private func data(from binding: CodexRadarBenchBinding) throws -> Data {
        try bindingData(selections: binding.modelEfforts, changes: ["task_set_sha256": binding.taskSetSHA256])
    }
}

private actor RadarBenchTransportProbe {
    private var binding: Data
    private var summaries: [String: Data]
    private var failures: Set<String> = []
    private var delay: UInt64 = 1_000_000
    private(set) var requests: [URLRequest] = []
    private(set) var active = 0
    private(set) var maximumActive = 0

    init(binding: Data, summaries: [String: Data]) { self.binding = binding; self.summaries = summaries }
    func setFailures(_ ids: Set<String>) { failures = ids }
    func setDelay(_ value: UInt64) { delay = value }
    func replaceBinding(_ value: Data) { binding = value }
    func replaceSummary(_ selection: CodexRadarBenchSelection, data: Data) { summaries[selection.id] = data }

    func read(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        if request.url?.path == "/data/radar-bench-binding.json" { return (binding, response) }
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: delay)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let model = query.first { $0.name == "model" }!.value!
        let effort = query.first { $0.name == "effort" }!.value!
        let id = "\(model)|\(effort)"
        if failures.contains(id) { throw CodexRadarReaderError.httpStatus(503) }
        return (summaries[id]!, response)
    }
}

private actor RadarBenchStoreOfficialReader: CodexRadarReading {
    private var responses: [Result<CodexRadarSnapshot, CodexRadarReaderError>]
    init(_ responses: [Result<CodexRadarSnapshot, CodexRadarReaderError>]) { self.responses = responses }
    func readRadar() async throws -> CodexRadarSnapshot { try responses.removeFirst().get() }
}

private actor RadarBenchStoreCrowdReader: CodexCrowdRadarReading {
    private var responses: [Result<CodexCrowdRadarSnapshot, CodexRadarReaderError>]
    init(_ responses: [Result<CodexCrowdRadarSnapshot, CodexRadarReaderError>]) { self.responses = responses }
    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot { try responses.removeFirst().get() }
}

private struct RadarBenchStoreEmptyFeedReader: CodexRadarFeedReading {
    func readFeed(from url: URL) async throws -> [CodexRadarFeedItem] { [] }
}

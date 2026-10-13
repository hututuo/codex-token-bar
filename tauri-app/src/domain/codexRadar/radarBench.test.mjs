import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { parseRadarBenchBinding, parseRadarBenchSummary } from "./radarBench.ts";
import { normalizeCodexCrowdRadarPayload, mergeCodexCrowdRadarSnapshot, rankedCodexCrowdRadarModels, crowdRadarScoreText } from "../../api/codexCrowdRadarClient.ts";

const binding = JSON.parse(readFileSync(new URL("../../../../Tests/Fixtures/RadarBench/binding-v5.json", import.meta.url), "utf8"));
const summary = JSON.parse(readFileSync(new URL("../../../../Tests/Fixtures/RadarBench/summary-v5.json", import.meta.url), "utf8"));
const payload = (summaries = [summary], extra = {}) => ({ benchmarkSource: "radar-bench", benchBinding: structuredClone(binding),
  benchSummaries: structuredClone(summaries), benchErrors: [], observedAt: "2026-10-13T05:00:00Z", ...extra });
const changedSummary = extra => ({ ...structuredClone(summary), ...extra });

test("captured public v5 score stays on 150 points and keeps grade count distinct from coverage", () => {
  const parsedBinding = parseRadarBenchBinding(binding);
  assert.equal(parsedBinding.modelEfforts.length, 34);
  assert.ok(parsedBinding.modelEfforts.some(pair => pair.effort === "ultra"));
  const snapshot = normalizeCodexCrowdRadarPayload(payload());
  const row = rankedCodexCrowdRadarModels(snapshot)[0];
  assert.equal(snapshot.benchmarkSource, "radar-bench");
  assert.equal(row.benchScore, 113.67307692307693);
  assert.equal(crowdRadarScoreText(row), "雷达分 113.7");
  assert.equal(row.benchCoverage, 63);
  assert.equal(row.benchRequiredTasks, 64);
  assert.equal(row.benchGradedRuns, 63);
  assert.ok(Number.isNaN(row.passRate));
  assert.deepEqual(snapshot.recentModels, []);
  assert.equal(snapshot.generatedAt, "2026-10-09T00:00:00.000Z");
  assert.equal(snapshot.provenance.observedAt, "2026-10-13T05:00:00Z");
  const repeated = normalizeCodexCrowdRadarPayload(payload([changedSummary({ graded_runs_count: 189 })]));
  assert.equal(repeated.models[0].benchCoverage, 63);
  assert.equal(repeated.models[0].benchGradedRuns, 189);
});

test("zero score ranks at low coverage; no current result succeeds without a fabricated score", () => {
  const zero = changedSummary({ score: 0, coverage: 1, graded_runs_count: 3, statistics: null, history: null });
  const absent = changedSummary({ effort: "ultra", score: null, coverage: 0, graded_runs_count: 0,
    score_status: "missing_current_result", statistics: null, history: null });
  const snapshot = normalizeCodexCrowdRadarPayload(payload([zero, absent]));
  assert.equal(rankedCodexCrowdRadarModels(snapshot).length, 1);
  assert.equal(rankedCodexCrowdRadarModels(snapshot)[0].benchScore, 0);
  assert.equal(snapshot.models[1].benchScore, null);
  assert.equal(snapshot.models[1].benchStatus, "missing");
  const allAbsent = normalizeCodexCrowdRadarPayload(payload([absent]));
  assert.deepEqual(rankedCodexCrowdRadarModels(allAbsent), []);
  assert.equal(allAbsent.models.length, binding.model_efforts.length);
  assert.equal(allAbsent.generatedAt, "");
  const complete = normalizeCodexCrowdRadarPayload(payload([changedSummary({ score: 150, coverage: 64,
    graded_runs_count: 200, score_status: "complete", history: null })]));
  assert.equal(complete.models[0].benchStatus, "complete");
});

test("wrong binding identity or unknown versions cannot be mistaken for the current benchmark", () => {
  for (const extra of [{ schema: "future-v6" }, { score_version: "v1" }, { score_max: 100 },
    { scoring_policy_version: "unknown" }, { benchmark: "other" }, { catalog_version: "other" },
    { task_set_sha256: "0".repeat(64) }, { required_tasks: 63 }, { model: "unbound" }, { effort: "new-effort" },
    { source_counts: { ...summary.source_counts, science: 18 } }, { coverage: 65 }, { score: 151 },
    { score: null }, { score: undefined }, { score: 0, coverage: 0, score_status: "missing_current_result" }]) {
    assert.throws(() => normalizeCodexCrowdRadarPayload(payload([changedSummary(extra)])), /RadarBench/);
  }
  for (const flag of ["enabled", "interface_confirmed", "production_read_verified"]) {
    assert.throws(() => normalizeCodexCrowdRadarPayload(payload([summary], { benchBinding: { ...binding, [flag]: false } })), /RadarBench/);
  }
  assert.throws(() => normalizeCodexCrowdRadarPayload(payload([summary], { benchmarkSource: "radar-bench-future" })), /Unsupported/);
  assert.throws(() => parseRadarBenchBinding({ ...binding, active_display_selection: { model: "other", effort: "high" } }), /unbound/);
  assert.throws(() => parseRadarBenchBinding({ ...binding, model_efforts: Array(129).fill(binding.model_efforts[0]) }), /bounded/);
  assert.throws(() => parseRadarBenchBinding({ ...binding, model_efforts: [{ model: "../other", effort: "high" }] }), /unsafe/);
});

test("partial failures stay diagnostic and total failure throws instead of replacing the last result", () => {
  const snapshot = normalizeCodexCrowdRadarPayload(payload([summary, changedSummary({ schema: "old" })], { benchErrors: ["gpt-6-sol/high: HTTP 503"] }));
  assert.equal(snapshot.models.filter(row => !row.benchFailure).length, 1);
  assert.ok(snapshot.endpointErrors.some(error => error.includes("HTTP 503")));
  assert.ok(snapshot.endpointErrors.some(error => error.includes("schema mismatch")));
  assert.throws(() => normalizeCodexCrowdRadarPayload(payload([], { benchErrors: ["all requests timed out"] })), /timed out/);
  const duplicate = normalizeCodexCrowdRadarPayload(payload([summary, summary]));
  assert.equal(duplicate.models.filter(row => !row.benchFailure).length, 1);
  assert.ok(duplicate.endpointErrors.some(error => error.includes("duplicate summary")));
});

test("incomplete cost and missing elapsed metrics retain null totals and known sample evidence", () => {
  const value = structuredClone(summary);
  value.statistics.metrics.elapsed_ms = null;
  value.statistics.metrics.api_equivalent_usd = {
    total: null, mean: 4, known_total: 240, known_samples: 60, missing_samples: 3, missing_reason: "usage missing",
  };
  const parsed = parseRadarBenchSummary(value, parseRadarBenchBinding(binding));
  assert.equal(parsed.statistics.elapsedMs, null);
  assert.deepEqual(parsed.statistics.apiEquivalentUSD, { total: null, mean: 4, knownTotal: 240,
    knownSamples: 60, missingSamples: 3, missingReason: "usage missing" });
  value.statistics.metrics.api_equivalent_usd.total = 240;
  const invalid = normalizeCodexCrowdRadarPayload(payload([value]));
  assert.equal(invalid.models[0].benchScore, summary.score);
  assert.equal(invalid.models[0].benchStatistics.apiEquivalentUSD, null);
  assert.ok(invalid.endpointErrors.some(error => error.includes("incomplete metric")));
  value.statistics.cost_basis = "estimated_cash_usd";
  const wrongBasis = normalizeCodexCrowdRadarPayload(payload([value]));
  assert.equal(wrongBasis.models[0].benchScore, summary.score);
  assert.equal(wrongBasis.models[0].benchStatistics.apiEquivalentUSD, null);
  assert.ok(wrongBasis.endpointErrors.some(error => error.includes("cost_basis")));
});

test("invalid metrics do not erase the other valid metric", () => {
  const badElapsed = structuredClone(summary);
  badElapsed.statistics.metrics.elapsed_ms.known_samples = 1;
  const parsed = normalizeCodexCrowdRadarPayload(payload([badElapsed]));
  assert.equal(parsed.models[0].benchStatistics.elapsedMs, null);
  assert.equal(parsed.models[0].benchStatistics.apiEquivalentUSD.knownSamples, 63);
  assert.ok(parsed.endpointErrors.some(error => error.includes("elapsed_ms")));
  const wrongBasis = structuredClone(summary);
  wrongBasis.statistics.cost_basis = "estimated";
  const invalidCost = normalizeCodexCrowdRadarPayload(payload([wrongBasis]));
  assert.equal(invalidCost.models[0].benchStatistics.apiEquivalentUSD, null);
  assert.equal(invalidCost.models[0].benchStatistics.elapsedMs.knownSamples, 63);
});

test("partial refresh keeps each failed lane and retains prior evidence only under the same binding", () => {
  const previous = normalizeCodexCrowdRadarPayload(payload());
  const next = normalizeCodexCrowdRadarPayload(payload([changedSummary({ effort: "ultra", history: null })]));
  const failed = next.models.find(row => row.effort === "max" && row.model === summary.model);
  assert.equal(failed.benchFailure, "读取失败");
  assert.equal(failed.benchCoverage, undefined);
  assert.equal(failed.benchGradedRuns, undefined);
  assert.equal(failed.benchScore, null);
  const merged = mergeCodexCrowdRadarSnapshot(previous, next);
  const retained = merged.models.find(row => row.effort === "max" && row.model === summary.model);
  assert.equal(retained.benchScore, summary.score);
  assert.equal(retained.benchCoverage, summary.coverage);
  assert.equal(retained.benchFailure, "读取失败");
  assert.deepEqual(retained.benchHistory, previous.models[0].benchHistory);
  assert.deepEqual(rankedCodexCrowdRadarModels(merged).map(row => row.effort), ["ultra"]);
  const changed = { ...next, benchBinding: { ...next.benchBinding, taskSetHash: "0".repeat(64) } };
  assert.equal(mergeCodexCrowdRadarSnapshot(previous, changed), changed);
  assert.deepEqual(rankedCodexCrowdRadarModels(merged, 8, "recent"), []);
});

test("Bench ties use direct zero scores, coverage, then raw ASCII model and effort", () => {
  const pairs = [
    { model: "lane-z", effort: "ultra", coverage: 1 },
    { model: "lane-a", effort: "high", coverage: 1 },
    { model: "lane-Z", effort: "high", coverage: 1 },
    { model: "lane-a", effort: "ultra", coverage: 2 },
  ];
  const benchBinding = { ...binding, model_efforts: pairs.map(({ model, effort }) => ({ model, effort })),
    active_display_selection: { model: "lane-z", effort: "ultra" } };
  const summaries = pairs.map(({ model, effort, coverage }) => changedSummary({ model, effort, coverage,
    graded_runs_count: coverage, score: 0, statistics: null, history: null }));
  const snapshot = normalizeCodexCrowdRadarPayload(payload(summaries, { benchBinding }));
  assert.deepEqual(rankedCodexCrowdRadarModels(snapshot).map(row => `${row.model}|${row.effort}`), [
    "lane-a|ultra", "lane-Z|high", "lane-a|high", "lane-z|ultra",
  ]);
});

test("daily history must match identity, score version and a valid UTC grading date", () => {
  for (const mutate of [history => { history.model = "other"; }, history => { history.schema = "v2"; },
    history => { history.score_version = "old"; }, history => { history.time_zone = "local"; },
    history => { history.points[0].at = "2026-02-30T00:00:00.000Z"; },
    history => { history.points[0].at = "2026-10-09T12:00:00.000Z"; },
    history => { history.points.push(history.points[0]); }]) {
    const value = structuredClone(summary); mutate(value.history);
    const snapshot = normalizeCodexCrowdRadarPayload(payload([value]));
    assert.equal(snapshot.models[0].benchScore, summary.score);
    assert.deepEqual(snapshot.models[0].benchHistory, []);
    assert.equal(snapshot.generatedAt, "");
    assert.ok(snapshot.endpointErrors.length > 0);
  }
});

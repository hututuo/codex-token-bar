// Public RadarBench contracts. Score is already on a 150-point scale; coverage
// counts tasks, while graded runs count judgments. Neither is a pass rate.
export const RADAR_BENCH_SUMMARY_SCHEMA = "radar-bench-public-summary-v5-150-daily-graded-count";
export const RADAR_BENCH_SCORE_VERSION = "radar-bench-v2-150";
export const RADAR_BENCH_POLICY = "radar-bench-v2-last3-per-task-equal-weight-150";
export type RadarBenchScoreStatus = "missing" | "provisional" | "complete";
export interface RadarBenchBinding {
  benchmark: string;
  catalogVersion: string;
  taskSetHash: string;
  requiredTasks: number;
  totalCells: number;
  sourceCounts: Record<string, number>;
  modelEfforts: { model: string; effort: string }[];
}
export interface RadarBenchMetric {
  total: number | null;
  mean: number | null;
  knownTotal: number | null;
  knownSamples: number;
  missingSamples: number;
  missingReason: string | null;
}
export interface RadarBenchStatistics {
  sampleCount: number;
  costBasis: string;
  elapsedMs: RadarBenchMetric | null;
  apiEquivalentUSD: RadarBenchMetric | null;
}
export interface RadarBenchHistoryPoint {
  at: string;
  score: number | null;
  coverage: number;
  requiredTasks: number;
  status: RadarBenchScoreStatus;
}
export interface RadarBenchSummary {
  model: string;
  effort: string;
  score: number | null;
  coverage: number;
  requiredTasks: number;
  gradedRuns: number;
  status: RadarBenchScoreStatus;
  statistics: RadarBenchStatistics | null;
  history: RadarBenchHistoryPoint[];
  latestGradedAt: string | null;
  diagnostics: string[];
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`RadarBench ${label} must be an object`);
  return value as Record<string, unknown>;
}
function text(value: unknown, label: string): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`RadarBench ${label} must be a string`);
  return value;
}
function count(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw new Error(`RadarBench ${label} must be a count`);
  return value;
}
function optionalNumber(value: unknown, label: string): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) throw new Error(`RadarBench ${label} must be a nonnegative number or null`);
  return value;
}
function requireEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) throw new Error(`RadarBench ${label} mismatch`);
}
function sources(value: unknown): Record<string, number> {
  const result: Record<string, number> = {};
  for (const [key, valueCount] of Object.entries(record(value, "source_counts"))) result[key] = count(valueCount, key);
  if (!Object.keys(result).length) throw new Error("RadarBench source_counts is empty");
  return result;
}
function sourceKey(value: Record<string, number>): string {
  return JSON.stringify(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)));
}
function identity(model: string, effort: string): string { return JSON.stringify([model, effort]); }
function safePair(raw: Record<string, unknown>): { model: string; effort: string } {
  const model = text(raw.model, "model");
  const effort = text(raw.effort, "effort");
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(model) || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(effort)) {
    throw new Error("RadarBench unsafe model/effort");
  }
  return { model, effort };
}

export function parseRadarBenchBinding(value: unknown): RadarBenchBinding {
  const raw = record(value, "binding");
  for (const flag of ["enabled", "interface_confirmed", "production_read_verified"]) requireEqual(raw[flag], true, flag);
  requireEqual(raw.score_version, RADAR_BENCH_SCORE_VERSION, "score_version");
  requireEqual(raw.score_max, 150, "score_max");
  const requiredTasks = count(raw.total_tasks, "total_tasks");
  if (requiredTasks === 0 || requiredTasks > 4096) throw new Error("RadarBench total_tasks outside bounded range");
  const sourceCounts = sources(raw.source_counts);
  requireEqual(Object.values(sourceCounts).reduce((a, b) => a + b, 0), requiredTasks, "source_counts total");
  const hash = text(raw.task_set_sha256, "task_set_sha256");
  if (!/^[a-f0-9]{64}$/.test(hash)) throw new Error("RadarBench invalid task_set_sha256");
  if (!Array.isArray(raw.model_efforts) || !raw.model_efforts.length || raw.model_efforts.length > 128) throw new Error("RadarBench model_efforts outside bounded range");
  const seen = new Set<string>();
  const modelEfforts = raw.model_efforts.map(value => {
    const pair = record(value, "model_effort");
    const { model, effort } = safePair(pair);
    const key = identity(model, effort);
    if (seen.has(key)) throw new Error("RadarBench duplicate model_effort");
    seen.add(key);
    return { model, effort };
  });
  const active = safePair(record(raw.active_display_selection, "active_display_selection"));
  if (!seen.has(identity(active.model, active.effort))) throw new Error("RadarBench unbound active_display_selection");
  return { benchmark: text(raw.benchmark, "benchmark"), catalogVersion: text(raw.catalog_version, "catalog_version"),
    taskSetHash: hash, requiredTasks, totalCells: count(raw.total_cells, "total_cells"), sourceCounts, modelEfforts };
}

function scoreFields(raw: Record<string, unknown>, required: number) {
  const coverage = count(raw.coverage, "coverage");
  requireEqual(raw.required_tasks, required, "required_tasks");
  if (coverage > required) throw new Error("RadarBench coverage exceeds required_tasks");
  if (raw.score === undefined) throw new Error("RadarBench missing score");
  const rawScore = optionalNumber(raw.score, "score");
  if (rawScore !== null && rawScore > 150) throw new Error("RadarBench score exceeds 150");
  if ((coverage === 0) !== (rawScore === null)) throw new Error("RadarBench score/coverage mismatch");
  const status: RadarBenchScoreStatus = coverage === 0 ? "missing" : coverage === required ? "complete" : "provisional";
  requireEqual(raw.score_status, status === "missing" ? "missing_current_result" : status, "score_status");
  return { score: rawScore, coverage, requiredTasks: required, status };
}
function parseMetric(value: unknown, samples: number): RadarBenchMetric | null {
  if (value === undefined || value === null) return null;
  const raw = record(value, "metric");
  const knownSamples = count(raw.known_samples, "known_samples");
  const missingSamples = count(raw.missing_samples, "missing_samples");
  requireEqual(knownSamples + missingSamples, samples, "metric sample counts");
  const total = optionalNumber(raw.total, "total");
  const mean = optionalNumber(raw.mean, "mean");
  const knownTotal = optionalNumber(raw.known_total, "known_total");
  if (missingSamples > 0 && total !== null) throw new Error("RadarBench incomplete metric has a total");
  if (knownSamples === 0 && mean !== null) throw new Error("RadarBench unsampled metric has a mean");
  return { total, mean, knownTotal, knownSamples, missingSamples,
    missingReason: typeof raw.missing_reason === "string" ? raw.missing_reason : null };
}
function parseStatistics(value: unknown, diagnostics: string[]): RadarBenchStatistics | null {
  if (value === null || value === undefined) return null;
  const raw = record(value, "statistics");
  const sampleCount = count(raw.sample_count, "sample_count");
  const metrics = record(raw.metrics, "metrics");
  const costBasis = typeof raw.cost_basis === "string" ? raw.cost_basis : "unknown";
  const metric = (value: unknown, label: string) => {
    try { return parseMetric(value, sampleCount); }
    catch (error) { diagnostics.push(`${label}: ${String(error)}`); return null; }
  };
  const elapsedMs = metric(metrics.elapsed_ms, "elapsed_ms");
  let apiEquivalentUSD: RadarBenchMetric | null = null;
  if (/^official_standard_api_equivalent(?:;|$)/.test(costBasis)) apiEquivalentUSD = metric(metrics.api_equivalent_usd, "api_equivalent_usd");
  else diagnostics.push("RadarBench unsupported cost_basis");
  return { sampleCount, costBasis,
    elapsedMs, apiEquivalentUSD };
}

export function radarBenchKnownMean(metric: RadarBenchMetric | null | undefined): number | null {
  if (!metric || metric.knownSamples === 0 || metric.knownTotal === null) return null;
  return metric.knownTotal / metric.knownSamples;
}
function utcDay(value: unknown): string {
  const at = text(value, "history date");
  const parsed = Date.parse(at);
  if (!/^\d{4}-\d{2}-\d{2}T00:00:00(?:\.000)?Z$/.test(at) || !Number.isFinite(parsed)
      || new Date(parsed).toISOString().slice(0, 10) !== at.slice(0, 10)) throw new Error("RadarBench invalid UTC grading day");
  return at;
}
function parseHistory(value: unknown, model: string, effort: string, binding: RadarBenchBinding): RadarBenchHistoryPoint[] {
  if (value === null || value === undefined) return [];
  const raw = record(value, "history");
  requireEqual(raw.schema, "radar-bench-public-history-v1-150-daily", "history schema");
  requireEqual(raw.score_version, RADAR_BENCH_SCORE_VERSION, "history score_version");
  requireEqual(raw.score_max, 150, "history score_max");
  requireEqual(raw.model, model, "history model");
  requireEqual(raw.effort, effort, "history effort");
  requireEqual(raw.time_zone, "UTC", "history time_zone");
  requireEqual(raw.bucket, "day", "history bucket");
  for (const [key, expected] of [["benchmark", binding.benchmark], ["catalog_version", binding.catalogVersion], ["task_set_sha256", binding.taskSetHash]] as const) {
    if (raw[key] !== undefined) requireEqual(raw[key], expected, `history ${key}`);
  }
  if (!Array.isArray(raw.points)) throw new Error("RadarBench history points must be an array");
  const dates = new Set<string>();
  const points = raw.points.map(value => {
    const point = record(value, "history point");
    const at = utcDay(point.at);
    const day = at.slice(0, 10);
    if (dates.has(day)) throw new Error("RadarBench duplicate UTC grading day");
    dates.add(day);
    return { at, ...scoreFields(point, binding.requiredTasks) };
  }).sort((a, b) => a.at.localeCompare(b.at));
  if (raw.updated_bucket !== null && raw.updated_bucket !== undefined) {
    const updated = utcDay(raw.updated_bucket);
    if (points.length && updated.slice(0, 10) !== points[points.length - 1].at.slice(0, 10)) throw new Error("RadarBench history updated_bucket mismatch");
  }
  return points;
}

export function parseRadarBenchSummary(value: unknown, binding: RadarBenchBinding): RadarBenchSummary {
  const raw = record(value, "summary");
  for (const [key, expected] of [["schema", RADAR_BENCH_SUMMARY_SCHEMA], ["score_version", RADAR_BENCH_SCORE_VERSION],
    ["score_max", 150], ["scoring_policy_version", RADAR_BENCH_POLICY], ["benchmark", binding.benchmark],
    ["catalog_version", binding.catalogVersion], ["task_set_sha256", binding.taskSetHash]] as const) requireEqual(raw[key], expected, key);
  requireEqual(sourceKey(sources(raw.source_counts)), sourceKey(binding.sourceCounts), "source_counts");
  const model = text(raw.model, "model");
  const effort = text(raw.effort, "effort");
  if (!binding.modelEfforts.some(pair => pair.model === model && pair.effort === effort)) throw new Error("RadarBench unbound model/effort");
  const fields = scoreFields(raw, binding.requiredTasks);
  const gradedRuns = count(raw.graded_runs_count, "graded_runs_count");
  if (gradedRuns < fields.coverage) throw new Error("RadarBench graded_runs_count below coverage");
  const diagnostics: string[] = [];
  let statistics: RadarBenchStatistics | null = null;
  let history: RadarBenchHistoryPoint[] = [];
  try { statistics = parseStatistics(raw.statistics, diagnostics); } catch (error) { diagnostics.push(String(error)); }
  try { history = parseHistory(raw.history, model, effort, binding); } catch (error) { diagnostics.push(String(error)); }
  return { model, effort, ...fields, gradedRuns, statistics, history,
    latestGradedAt: history.length ? history[history.length - 1].at : null, diagnostics };
}

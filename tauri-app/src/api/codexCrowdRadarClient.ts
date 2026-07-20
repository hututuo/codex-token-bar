export interface CodexCrowdRadarModel {
  model: string;
  effort: string;
  graded: number;
  passed: number;
  passRate: number;
  cells: number;
}

export interface CodexCrowdRadarSnapshot {
  generatedAt: string;
  taskCount: number;
  cellCount: number;
  contributorCount: number;
  pendingGrades: number;
  errorGrades: number;
  models: CodexCrowdRadarModel[];
}

const CROWD_RADAR_COMMAND = "read_codex_crowd_radar_payload";
const CROWD_RADAR_COMMAND_TIMEOUT_MS = 22_000;
const WRAPPER_KEYS = ["data", "result", "snapshot", "payload", "response", "body"];

export async function readCodexCrowdRadarSnapshot(): Promise<CodexCrowdRadarSnapshot> {
  // Keep the compatibility parser independently executable in Node tests while
  // loading the Tauri bridge only on the real network-read path.
  const { callCommandStrict } = await import("./command");
  const raw = await callCommandStrict<unknown>(
    CROWD_RADAR_COMMAND,
    undefined,
    CROWD_RADAR_COMMAND_TIMEOUT_MS,
  );
  return normalizeCodexCrowdRadarPayload(raw);
}

export function normalizeCodexCrowdRadarPayload(raw: unknown): CodexCrowdRadarSnapshot {
  const nativePayload = asRecord(raw);
  const table = findPayload(
    valueFor(nativePayload, ["table"]) ?? raw,
    [
      "baselineGeneratedAt", "generatedAt", "updatedAt", "monitoredAt",
      "tasks", "taskRows", "taskList", "taskCount",
      "cells", "cellMap", "cellRows", "cellCount",
    ],
  );
  const leaderboard = findPayload(
    valueFor(nativePayload, ["leaderboard"]) ?? raw,
    [
      "models", "rankings", "modelStats", "modelSummaries", "rows",
      "contributors", "volunteers", "contributorRows", "contributorCount", "volunteerCount",
      "pendingGrades", "pending", "pendingCount", "queuedGrades",
      "errorGrades", "errors", "errorCount", "failedGrades",
    ],
  );
  const models = parseModels(leaderboard);
  if (!models.some((model) => model.graded > 0)) {
    const nativeError = stringValue(valueFor(nativePayload, ["leaderboardError", "error", "message"]));
    throw new Error(nativeError || "众测雷达没有可排名的模型数据");
  }
  return {
    generatedAt: firstString(table, [
      "baselineGeneratedAt",
      "generatedAt",
      "updatedAt",
      "monitoredAt",
    ]) || firstString(leaderboard, ["generatedAt", "updatedAt", "monitoredAt"]),
    taskCount: firstCollectionCount(table, ["tasks", "taskRows", "taskList", "taskCount"])
      ?? firstCollectionCount(leaderboard, ["tasks", "taskRows", "taskList", "taskCount"])
      ?? 0,
    cellCount: firstCollectionCount(table, ["cells", "cellMap", "cellRows", "cellCount"]) ?? 0,
    contributorCount: firstCollectionCount(leaderboard, [
      "contributors",
      "volunteers",
      "contributorRows",
      "contributorCount",
      "volunteerCount",
    ]) ?? 0,
    pendingGrades: firstInteger(leaderboard, [
      "pendingGrades",
      "pending",
      "pendingCount",
      "queuedGrades",
    ]) ?? 0,
    errorGrades: firstInteger(leaderboard, [
      "errorGrades",
      "errors",
      "errorCount",
      "failedGrades",
    ]) ?? 0,
    models,
  };
}

export function bestCodexCrowdRadarModel(snapshot?: CodexCrowdRadarSnapshot | null): CodexCrowdRadarModel | null {
  return rankedCodexCrowdRadarModels(snapshot, 1)[0] ?? null;
}

export function rankedCodexCrowdRadarModels(
  snapshot?: CodexCrowdRadarSnapshot | null,
  limit = Number.MAX_SAFE_INTEGER,
): CodexCrowdRadarModel[] {
  return (snapshot?.models ?? [])
    .filter((row) => row.graded > 0)
    .sort((left, right) => right.passRate - left.passRate || right.graded - left.graded)
    .slice(0, Math.max(0, Math.floor(limit)));
}

export function crowdRadarModelLabel(row: CodexCrowdRadarModel): string {
  const family = row.model.match(/(?:^|-)\s*(sol|terra|luna)(?:$|-)/i)?.[1] ?? row.model;
  return `${family.charAt(0).toUpperCase()}${family.slice(1)} ${row.effort}`.trim();
}

function parseModels(leaderboard: Record<string, unknown> | null): CodexCrowdRadarModel[] {
  const container = valueFor(leaderboard, [
    "models",
    "rankings",
    "modelStats",
    "modelSummaries",
    "rows",
  ]);
  if (Array.isArray(container)) {
    return container.flatMap((row) => {
      const parsed = parseModel(row, "");
      return parsed ? [parsed] : [];
    });
  }
  const rows = asRecord(container);
  return Object.entries(rows ?? {}).flatMap(([key, value]) => {
    const parsed = parseModel(value, key);
    return parsed ? [parsed] : [];
  });
}

function parseModel(value: unknown, fallbackKey: string): CodexCrowdRadarModel | null {
  const row = asRecord(value);
  if (!row) return null;
  let model = firstString(row, ["model", "modelName", "name", "modelId", "modelKey"]);
  let effort = firstString(row, ["effort", "reasoningEffort", "reasoning", "level", "tier"]);
  ({ model, effort } = fillModelIdentity(model, effort, fallbackKey));
  if (!model) return null;

  const taskStats = asRecord(valueFor(row, ["tasks", "taskResults", "results", "samplesByTask"]));
  const derivedVotes = sumNestedIntegers(taskStats, ["votes", "graded", "count", "samples"]);
  const derivedPasses = sumNestedIntegers(taskStats, ["passVotes", "passed", "passes", "successes"]);
  const graded = firstInteger(row, [
    "graded",
    "gradedCount",
    "judged",
    "judgedCount",
    "sampleCount",
    "samples",
    "attempts",
  ]) ?? derivedVotes;
  const passed = firstInteger(row, [
    "passed",
    "passCount",
    "passedCount",
    "successes",
    "successCount",
  ]) ?? derivedPasses;
  const directRate = rateValue(valueFor(row, [
    "passRate",
    "successRate",
    "winRate",
    "rate",
  ]));
  const iq = numberValue(valueFor(row, ["iq", "iqScore"]));
  const passRate = directRate
    ?? (iq !== null && iq >= 0 && iq <= 150 ? iq / 150 : null)
    ?? (graded > 0 && passed >= 0 && passed <= graded ? passed / graded : null);
  if (passRate === null) return null;
  const cells = firstInteger(row, [
    "cells",
    "cellCount",
    "coveredCells",
    "taskCount",
    "coveredTasks",
  ]) ?? Object.keys(taskStats ?? {}).length;
  return {
    model,
    effort,
    graded: Math.max(0, graded),
    passed: Math.max(0, passed),
    passRate,
    cells: Math.max(0, cells),
  };
}

function fillModelIdentity(
  initialModel: string,
  initialEffort: string,
  fallbackKey: string,
): { model: string; effort: string } {
  let model = initialModel.trim();
  let effort = initialEffort.trim();
  const identity = model || fallbackKey.trim();
  const delimited = identity.match(/^(.*?)[|:]([a-z][a-z0-9_-]*)$/i);
  if (!effort && delimited) {
    model = delimited[1].trim();
    effort = delimited[2].trim();
  }
  if (!model) model = identity;
  if (!effort) {
    const knownEffort = model.match(/-(minimal|low|medium|high|xhigh|max|ultra)$/i)?.[1];
    if (knownEffort) {
      effort = knownEffort;
      model = model.slice(0, -(knownEffort.length + 1));
    }
  }
  return { model, effort };
}

function findPayload(
  value: unknown,
  signalKeys: string[],
  depth = 0,
): Record<string, unknown> | null {
  const record = asRecord(value);
  if (!record) return null;
  if (signalKeys.some((key) => valueFor(record, [key]) !== undefined)) return record;
  if (depth >= 5) return record;
  for (const wrapper of WRAPPER_KEYS) {
    const nested = valueFor(record, [wrapper]);
    if (nested === undefined) continue;
    const match = findPayload(nested, signalKeys, depth + 1);
    if (match && signalKeys.some((key) => valueFor(match, [key]) !== undefined)) return match;
  }
  return record;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function valueFor(record: Record<string, unknown> | null, aliases: string[]): unknown {
  if (!record) return undefined;
  for (const alias of aliases) {
    const canonicalAlias = canonicalKey(alias);
    const match = Object.entries(record).find(([key]) => canonicalKey(key) === canonicalAlias);
    if (match) return match[1];
  }
  return undefined;
}

function canonicalKey(value: string): string {
  return value.normalize("NFKC").replace(/[^\p{L}\p{N}]/gu, "").toLocaleLowerCase();
}

function firstString(record: Record<string, unknown> | null, aliases: string[]): string {
  return stringValue(valueFor(record, aliases));
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function numberValue(value: unknown): number | null {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (typeof value !== "string") return null;
  const normalized = value.trim().replace(/,/g, "").replace(/%$/, "");
  if (!normalized) return null;
  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function integerValue(value: unknown): number | null {
  const parsed = numberValue(value);
  return parsed !== null && Number.isInteger(parsed) ? parsed : null;
}

function firstInteger(record: Record<string, unknown> | null, aliases: string[]): number | null {
  return integerValue(valueFor(record, aliases));
}

function rateValue(value: unknown): number | null {
  const parsed = numberValue(value);
  if (parsed === null) return null;
  const wasPercent = typeof value === "string" && value.trim().endsWith("%");
  const normalized = wasPercent || parsed > 1 ? parsed / 100 : parsed;
  return normalized >= 0 && normalized <= 1 ? normalized : null;
}

function firstCollectionCount(
  record: Record<string, unknown> | null,
  aliases: string[],
): number | null {
  const value = valueFor(record, aliases);
  if (Array.isArray(value)) return value.length;
  const object = asRecord(value);
  if (object) return Object.keys(object).length;
  return integerValue(value);
}

function sumNestedIntegers(
  rows: Record<string, unknown> | null,
  aliases: string[],
): number {
  return Object.values(rows ?? {}).reduce<number>((total, value) => {
    const row = asRecord(value);
    return total + (firstInteger(row, aliases) ?? 0);
  }, 0);
}

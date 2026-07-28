export interface CodexCrowdRadarModel {
  model: string;
  effort: string;
  graded: number;
  passed: number;
  passRate: number;
  cells: number;
  scorePassed: number;
  scoreSamples: number;
  latestGradedAt: string | null;
}

export type CodexCrowdRadarMode = "realtime" | "recent";

export interface CodexCrowdRadarSnapshot {
  generatedAt: string;
  taskCount: number;
  cellCount: number;
  contributorCount: number;
  pendingGrades: number;
  errorGrades: number;
  models: CodexCrowdRadarModel[];
  recentModels: CodexCrowdRadarModel[];
  realtimeAvailable: boolean;
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
  const leaderboardModels = parseModels(leaderboard);
  const tableAggregation = parseTableModels(table, leaderboardModels);
  const recentModels = tableAggregation.recentModels.length > 0
    ? tableAggregation.recentModels
    : leaderboardModels;
  const models = tableAggregation.realtimeModels.length > 0
    ? tableAggregation.realtimeModels
    : recentModels;
  if (!models.some((model) => model.scoreSamples > 0)) {
    const nativeError = [
      stringValue(valueFor(nativePayload, ["tableError"])),
      stringValue(valueFor(nativePayload, ["leaderboardError"])),
      stringValue(valueFor(nativePayload, ["error", "message"])),
    ].find(Boolean);
    throw new Error(nativeError || "众测雷达没有可排名的模型数据");
  }
  return {
    generatedAt: tableAggregation.latestGradedAt || firstString(table, [
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
    recentModels,
    realtimeAvailable: tableAggregation.realtimeModels.length > 0,
  };
}

export function bestCodexCrowdRadarModel(
  snapshot?: CodexCrowdRadarSnapshot | null,
  mode: CodexCrowdRadarMode = "realtime",
): CodexCrowdRadarModel | null {
  return rankedCodexCrowdRadarModels(snapshot, 1, mode)[0] ?? null;
}

export function rankedCodexCrowdRadarModels(
  snapshot?: CodexCrowdRadarSnapshot | null,
  limit = Number.MAX_SAFE_INTEGER,
  mode: CodexCrowdRadarMode = "realtime",
): CodexCrowdRadarModel[] {
  const requestedModels = mode === "recent" ? snapshot?.recentModels : snapshot?.models;
  const fallbackModels = requestedModels && requestedModels.length > 0
    ? requestedModels
    : snapshot?.models ?? snapshot?.recentModels ?? [];
  return [...fallbackModels]
    .filter((row) => scoreSampleCount(row) > 0)
    .sort(compareCrowdRadarModels)
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
  const scorePassed = firstInteger(row, [
    "cellsPassed",
    "passedCells",
    "tasksPassed",
    "passedTasks",
  ]) ?? (cells > 0 ? Math.round(passRate * cells) : passed);
  const scoreSamples = cells > 0 ? cells : graded;
  return {
    model,
    effort,
    graded: Math.max(0, graded),
    passed: Math.max(0, passed),
    passRate,
    cells: Math.max(0, cells),
    scorePassed: Math.max(0, scorePassed),
    scoreSamples: Math.max(0, scoreSamples),
    latestGradedAt: firstString(row, [
      "latestGradedAt",
      "gradedAt",
      "updatedAt",
      "monitoredAt",
    ]) || null,
  };
}

interface TableAggregation {
  realtimeModels: CodexCrowdRadarModel[];
  recentModels: CodexCrowdRadarModel[];
  latestGradedAt: string;
}

function parseTableModels(
  table: Record<string, unknown> | null,
  leaderboardModels: CodexCrowdRadarModel[],
): TableAggregation {
  const explicitCombos = collectionRows(valueFor(table, ["combos", "modelCombos", "models"]));
  const combos = explicitCombos.length > 0
    ? explicitCombos
    : leaderboardModels.map((model, index) => ({ key: String(index), value: model }));
  const tasks = collectionRows(valueFor(table, ["tasks", "taskRows", "taskList"]));
  const cells = asRecord(valueFor(table, ["cells", "cellMap", "cellRows"]));
  if (combos.length === 0 || tasks.length === 0 || !cells || Object.keys(cells).length === 0) {
    return { realtimeModels: [], recentModels: [], latestGradedAt: "" };
  }

  const leaderboardByIdentity = new Map(
    leaderboardModels.map((model) => [modelIdentity(model.model, model.effort), model]),
  );
  const realtimeModels: CodexCrowdRadarModel[] = [];
  const recentModels: CodexCrowdRadarModel[] = [];
  let globalLatestGradedAt = "";

  for (const comboEntry of combos) {
    const combo = asRecord(comboEntry.value);
    if (!combo) continue;
    let model = firstString(combo, ["model", "modelName", "name", "modelId", "modelKey"]);
    let effort = firstString(combo, ["effort", "reasoningEffort", "reasoning", "level", "tier"]);
    ({ model, effort } = fillModelIdentity(model, effort, comboEntry.key));
    if (!model || !effort) continue;

    let realtimePassed = 0;
    let realtimeSamples = 0;
    let recentPassed = 0;
    let recentSamples = 0;
    let recentCells = 0;
    let latestGradedAt = "";

    for (const taskEntry of tasks) {
      const task = asRecord(taskEntry.value);
      const taskId = identifierValue(valueFor(task, ["id", "taskId", "taskKey", "name"]))
        || identifierValue(taskEntry.value)
        || nonEmpty(taskEntry.key);
      if (!taskId) continue;
      const cellKey = `${taskId}|${model}|${effort}`;
      const cell = asRecord(cells[cellKey] ?? valueFor(cells, [cellKey]));
      if (!cell) continue;

      const runners = valueFor(cell, ["ranBy", "runners", "runs", "results"]);
      const latestRunner = Array.isArray(runners) ? asRecord(runners[0]) : null;
      if (latestRunner) {
        const passedLatest = booleanValue(valueFor(latestRunner, ["passed", "success", "ok"]));
        if (passedLatest !== null) {
          realtimeSamples += 1;
          if (passedLatest) realtimePassed += 1;
        }
        const gradedAt = firstString(latestRunner, [
          "gradedAt",
          "judgedAt",
          "updatedAt",
          "completedAt",
        ]) || firstString(cell, ["lastGradedAt", "gradedAt", "updatedAt"]);
        if (gradedAt) {
          latestGradedAt = newestTimestamp(latestGradedAt, gradedAt);
          globalLatestGradedAt = newestTimestamp(globalLatestGradedAt, gradedAt);
        }
      }

      const sampleCount = firstInteger(cell, ["n", "recentSamples", "sampleCount", "samples"]);
      const passCount = firstInteger(cell, ["p", "recentPassed", "passCount", "passes"]);
      if (
        sampleCount !== null
        && passCount !== null
        && sampleCount > 0
        && passCount >= 0
        && passCount <= sampleCount
      ) {
        recentSamples += sampleCount;
        recentPassed += passCount;
        recentCells += 1;
      }
    }

    const metadata = leaderboardByIdentity.get(modelIdentity(model, effort));
    if (realtimeSamples > 0) {
      realtimeModels.push(makeTableModel({
        model,
        effort,
        scorePassed: realtimePassed,
        scoreSamples: realtimeSamples,
        coveredCells: realtimeSamples,
        latestGradedAt,
        metadata,
      }));
    }
    if (recentSamples > 0) {
      recentModels.push(makeTableModel({
        model,
        effort,
        scorePassed: recentPassed,
        scoreSamples: recentSamples,
        coveredCells: recentCells,
        latestGradedAt,
        metadata,
      }));
    }
  }

  return {
    realtimeModels,
    recentModels,
    latestGradedAt: globalLatestGradedAt,
  };
}

function makeTableModel({
  model,
  effort,
  scorePassed,
  scoreSamples,
  coveredCells,
  latestGradedAt,
  metadata,
}: {
  model: string;
  effort: string;
  scorePassed: number;
  scoreSamples: number;
  coveredCells: number;
  latestGradedAt: string;
  metadata?: CodexCrowdRadarModel;
}): CodexCrowdRadarModel {
  return {
    model,
    effort,
    graded: metadata?.graded ?? scoreSamples,
    passed: metadata?.passed ?? scorePassed,
    passRate: scorePassed / scoreSamples,
    cells: Math.max(metadata?.cells ?? 0, coveredCells),
    scorePassed,
    scoreSamples,
    latestGradedAt: latestGradedAt || null,
  };
}

function collectionRows(value: unknown): Array<{ key: string; value: unknown }> {
  if (Array.isArray(value)) {
    return value.map((row, index) => ({ key: String(index), value: row }));
  }
  const rows = asRecord(value);
  return Object.keys(rows ?? {})
    .sort()
    .map((key) => ({ key, value: rows?.[key] }));
}

function identifierValue(value: unknown): string {
  if (typeof value === "string") return nonEmpty(value);
  const integer = integerValue(value);
  return integer === null ? "" : String(integer);
}

function nonEmpty(value: string): string {
  return value.trim();
}

function booleanValue(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;
  if (value === 1 || value === "1") return true;
  if (value === 0 || value === "0") return false;
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLocaleLowerCase();
  if (normalized === "true") return true;
  if (normalized === "false") return false;
  return null;
}

function modelIdentity(model: string, effort: string): string {
  return `${model.trim().toLocaleLowerCase()}|${effort.trim().toLocaleLowerCase()}`;
}

function newestTimestamp(current: string, candidate: string): string {
  if (!current) return candidate;
  const currentTime = Date.parse(current);
  const candidateTime = Date.parse(candidate);
  if (Number.isFinite(currentTime) && Number.isFinite(candidateTime)) {
    return candidateTime > currentTime ? candidate : current;
  }
  return candidate > current ? candidate : current;
}

function scoreSampleCount(row: CodexCrowdRadarModel): number {
  return Number.isFinite(row.scoreSamples) ? row.scoreSamples : row.graded;
}

function compareCrowdRadarModels(
  left: CodexCrowdRadarModel,
  right: CodexCrowdRadarModel,
): number {
  const passRateOrder = right.passRate - left.passRate;
  if (passRateOrder !== 0) return passRateOrder;
  const modelOrder = modelRank(left.model) - modelRank(right.model);
  if (modelOrder !== 0) return modelOrder;
  const effortOrder = effortRank(left.effort) - effortRank(right.effort);
  if (effortOrder !== 0) return effortOrder;
  return modelIdentity(left.model, left.effort).localeCompare(
    modelIdentity(right.model, right.effort),
    undefined,
    { numeric: true, sensitivity: "base" },
  );
}

function modelRank(model: string): number {
  const normalized = model.toLocaleLowerCase();
  if (normalized.includes("gpt-5.6-sol")) return 0;
  if (normalized.includes("gpt-5.6-terra")) return 1;
  if (normalized.includes("gpt-5.6-luna")) return 2;
  if (normalized.includes("gpt-5.5")) return 3;
  return 4;
}

function effortRank(effort: string): number {
  const rank = ["ultra", "max", "xhigh", "high", "medium", "low", "minimal"]
    .indexOf(effort.toLocaleLowerCase());
  return rank < 0 ? 7 : rank;
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

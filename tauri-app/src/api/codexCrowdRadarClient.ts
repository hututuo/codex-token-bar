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

const TABLE_ENDPOINT = "https://api.codexradar.com/api/v1/table";
const LEADERBOARD_ENDPOINT = "https://api.codexradar.com/api/v1/leaderboard";

export async function readCodexCrowdRadarSnapshot(): Promise<CodexCrowdRadarSnapshot> {
  const controller = new AbortController();
  const timeoutID = globalThis.setTimeout(() => controller.abort(), 18_000);
  try {
    const [tableResponse, leaderboardResponse] = await Promise.all([
      fetch(TABLE_ENDPOINT, { cache: "no-store", signal: controller.signal }),
      fetch(LEADERBOARD_ENDPOINT, { cache: "no-store", signal: controller.signal }),
    ]);
    if (!tableResponse.ok || !leaderboardResponse.ok) {
      throw new Error(`Crowd Radar HTTP ${tableResponse.status}/${leaderboardResponse.status}`);
    }
    const [table, leaderboard] = await Promise.all([tableResponse.json(), leaderboardResponse.json()]);
    const models = Array.isArray(leaderboard?.models)
      ? leaderboard.models.map((row: Record<string, unknown>) => ({
        model: String(row.model ?? ""),
        effort: String(row.effort ?? ""),
        graded: finiteNumber(row.graded),
        passed: finiteNumber(row.passed),
        passRate: finiteNumber(row.pass_rate),
        cells: finiteNumber(row.cells),
      }))
      : [];
    return {
      generatedAt: String(table?.baseline_generated_at ?? ""),
      taskCount: Array.isArray(table?.tasks) ? table.tasks.length : 0,
      cellCount: table?.cells && typeof table.cells === "object" ? Object.keys(table.cells).length : 0,
      contributorCount: Array.isArray(leaderboard?.contributors) ? leaderboard.contributors.length : 0,
      pendingGrades: finiteNumber(leaderboard?.pending_grades),
      errorGrades: finiteNumber(leaderboard?.error_grades),
      models,
    };
  } finally {
    globalThis.clearTimeout(timeoutID);
  }
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
  return `${family.charAt(0).toUpperCase()}${family.slice(1)} ${row.effort}`;
}

function finiteNumber(value: unknown): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

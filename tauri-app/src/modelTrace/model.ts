import type { Candidate, TracePlan, TraceRun } from "./types";

export const DEFAULT_MODEL = "gpt-5.6-sol";
const labels: Record<string, string> = {
  candidate_matches: "候选相符", candidate_differs: "候选不符", sampling_failed: "采样失败",
  reference_missing: "参考缺失", inconclusive: "无法判断", cancelled: "已取消", interrupted: "已中断", missed: "缺测",
  waiting: "等待下一轮", running: "正在检测", cancelling: "正在停止", completed: "计划已结束", failed: "计划失败",
};
export const statusLabel = (status: string) => labels[status] ?? "未知状态";
export const modelLabel = (model: string) => model.replace(/^gpt-/, "GPT ");
export const activePlan = (plan: TracePlan | null | undefined) => !!plan && ["waiting", "running", "cancelling"].includes(plan.status);
export function percent(value: number): string {
  if (!Number.isFinite(value) || value < 0 || value > 1) return "—";
  if (value > 0 && value < 0.0001) return "<0.01%";
  return `${(value * 100).toFixed(2)}%`;
}
export function topCandidates(candidates: Candidate[], count: 3 | 5): Candidate[] {
  return [...candidates].sort((a, b) => b.probability - a.probability || a.model.localeCompare(b.model)).slice(0, count);
}
export function dateKey(unix: number): string {
  const date = new Date(unix * 1000);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
export function summarize(runs: TraceRun[]) {
  const matches = runs.filter(r => r.status === "candidate_matches").length;
  const differs = runs.filter(r => r.status === "candidate_differs").length;
  const other = runs.length - matches - differs;
  const judged = matches + differs;
  const ratio = judged ? `${matches}/${judged} = ${(matches / judged * 100).toFixed(1)}%` : "暂无可判定记录";
  const state = matches && differs ? "mixed" : differs ? "differs" : matches ? "matches" : other ? "other" : "empty";
  const label = runs.length ? `相符 ${matches} 轮，不符 ${differs} 轮，其他 ${other} 轮` : "未检测";
  return {matches, differs, other, judged, ratio, state, label};
}
export function dayPresentation(runs: TraceRun[]) {
  const summary = summarize(runs);
  const colors: Record<string, string> = {matches: "var(--green)", differs: "var(--orange)", mixed: "linear-gradient(135deg,var(--green) 50%,var(--orange) 50%)", other: "var(--muted)", empty: "var(--heatmap-empty)"};
  return { label: summary.label, background: colors[summary.state], className: summary.other ? "modeltrace-day-warning" : "" };
}

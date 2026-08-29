import { modelUsageColor, modelUsageLabel } from "../components/modelUsagePresentation";
import type {
  RunningThreadModelBreakdown,
  RunningThreadSummary,
} from "../types/threadActivity";

export interface RunningThreadModelDisplayRow {
  id: string;
  model: string | null;
  title: string;
  count: number;
}

export function runningThreadModelDisplayRows(
  breakdowns: RunningThreadModelBreakdown[],
  expectedCount: number,
): RunningThreadModelDisplayRow[] {
  const rows = breakdowns
    .filter((row) => Number.isFinite(row.count) && row.count > 0)
    .map((row) => {
      const modelLabel = row.model ? modelUsageLabel(row.model) : "配置待读取";
      const effort = row.reasoningEffort?.trim();
      return {
        id: `${row.model ?? "unknown"}|${effort ?? "unknown"}`,
        model: row.model,
        title: effort ? `${modelLabel} · ${effort}` : modelLabel,
        count: Math.trunc(row.count),
      };
    });
  const represented = rows.reduce((sum, row) => sum + row.count, 0);
  if (expectedCount > represented) {
    rows.push({
      id: `unresolved|${expectedCount - represented}`,
      model: null,
      title: "配置待读取",
      count: expectedCount - represented,
    });
  }
  return rows.sort((left, right) => (
    right.count - left.count || left.title.localeCompare(right.title)
  ));
}

export function runningThreadModelStatusLabel(
  summary: RunningThreadSummary,
  demo: boolean,
): string {
  if (demo) return "示例";
  switch (summary.status) {
    case "ready": return "实时";
    case "stale": return "上次";
    case "scanning": return "读取中";
    case "unavailable": return "不可用";
  }
}

export function FloatingRunningThreadModelDetails({
  summary,
  demo = false,
  className = "",
}: {
  summary: RunningThreadSummary;
  demo?: boolean;
  className?: string;
}) {
  return (
    <section
      aria-label={demo ? "运行模型详情示例" : "运行模型详情"}
      className={`floating-running-model-details${className ? ` ${className}` : ""}`}
      onDoubleClick={(event) => event.stopPropagation()}
      onMouseDown={(event) => event.stopPropagation()}
    >
      <header>
        <strong>运行模型详情</strong>
        <small>{runningThreadModelStatusLabel(summary, demo)}</small>
      </header>
      <div className="floating-running-model-columns">
        <RunningModelSection
          count={summary.mainThreads ?? 0}
          status={summary.status}
          rows={runningThreadModelDisplayRows(summary.mainModels ?? [], summary.mainThreads ?? 0)}
          title="主线程"
        />
        <RunningModelSection
          count={summary.subagents ?? 0}
          status={summary.status}
          rows={runningThreadModelDisplayRows(summary.subagentModels ?? [], summary.subagents ?? 0)}
          title="子 Agent"
        />
      </div>
    </section>
  );
}

function RunningModelSection({
  count,
  rows,
  status,
  title,
}: {
  count: number;
  rows: RunningThreadModelDisplayRow[];
  status: RunningThreadSummary["status"];
  title: string;
}) {
  return (
    <section className="floating-running-model-section">
      <h3>{title} <b>{count}</b></h3>
      {rows.length === 0 ? (
        <p>{status === "scanning"
          ? "读取中…"
          : (status === "unavailable" ? "暂不可用" : "暂无运行")}</p>
      ) : (
        <div className="floating-running-model-list">
          {rows.map((row) => (
            <span aria-label={`${row.title}，${row.count} 个`} key={row.id}>
              <i aria-hidden="true" style={{ backgroundColor: modelUsageColor(row.model) }} />
              <em>{row.title}</em>
              <b>×{row.count}</b>
            </span>
          ))}
        </div>
      )}
    </section>
  );
}

export const FLOATING_RUNNING_MODEL_GUIDE_DEMO: RunningThreadSummary = {
  total: 5,
  mainThreads: 3,
  subagents: 2,
  mainModels: [
    { model: "gpt-5.6-sol", reasoningEffort: "ultra", count: 2 },
    { model: "gpt-5.6-luna", reasoningEffort: "max", count: 1 },
  ],
  subagentModels: [
    { model: "gpt-5.6-luna", reasoningEffort: "max", count: 2 },
  ],
  status: "ready",
  updatedAt: null,
  detail: "引导示例",
  livenessLeaseHours: 24,
};

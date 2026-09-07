import { useEffect, useRef } from "react";
import { modelUsageColor, modelUsageLabel } from "../components/modelUsagePresentation";
import type {
  RunningThreadGroup,
  RunningThreadMember,
  RunningThreadModelBreakdown,
  RunningThreadSummary,
} from "../types/threadActivity";
import type { FloatingGuidePage } from "./floatingSettings";

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
      const modelLabel = row.model ? modelUsageLabel(row.model) : "配置同步中";
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
      title: "配置同步中",
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
  if (hasPendingRunningModelConfiguration(summary)) return "同步中";
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
  onClose,
  onHeightChange,
}: {
  summary: RunningThreadSummary;
  demo?: boolean;
  className?: string;
  onClose?: () => void;
  onHeightChange?: (height: number) => void;
}) {
  const detailsRef = useRef<HTMLElement>(null);
  const groups = summary.groups ?? [];
  const unassignedSubagents = summary.unassignedSubagents ?? [];

  useEffect(() => {
    const element = detailsRef.current;
    if (!element || !onHeightChange) {
      return undefined;
    }
    const reportHeight = () => {
      const table = element.querySelector<HTMLElement>(".floating-running-model-table");
      const style = getComputedStyle(element);
      const children = [...element.children] as HTMLElement[];
      const tableHeight = table ? [...table.children].reduce((sum, child) => sum + child.getBoundingClientRect().height, 0) : 0;
      const height = Math.ceil(children.reduce((sum, child) => sum + (child === table ? tableHeight : child.getBoundingClientRect().height), 0)
        + parseFloat(style.paddingTop || "0") + parseFloat(style.paddingBottom || "0")
        + Math.max(0, children.length - 1) * parseFloat(style.rowGap || "0") + 2);
      if (height > 0) onHeightChange(height);
    };
    reportHeight();
    if (typeof ResizeObserver === "undefined") {
      return undefined;
    }
    const observer = new ResizeObserver(reportHeight);
    observer.observe(element);
    return () => observer.disconnect();
  }, [groups, onHeightChange, unassignedSubagents]);

  const rowCount = groups.length + (unassignedSubagents.length > 0 ? 1 : 0);
  return (
    <section
      aria-label={demo ? "运行模型详情示例" : "运行模型详情"}
      className={`floating-running-model-details${className ? ` ${className}` : ""}`}
      onDoubleClick={(event) => event.stopPropagation()}
      onMouseDown={(event) => event.stopPropagation()}
      onKeyDown={(event) => {
        if (event.key === "Escape" && onClose) { event.preventDefault(); event.stopPropagation(); onClose(); }
      }}
      ref={detailsRef}
    >
      <header>
        <strong>运行模型详情</strong>
        <span className="floating-running-model-header-actions">
          <small>{runningThreadModelStatusLabel(summary, demo)}</small>
          <button
            aria-hidden={onClose ? undefined : true}
            aria-label={onClose ? "关闭运行模型详情" : undefined}
            disabled={!onClose}
            onClick={onClose}
            tabIndex={onClose ? 0 : -1}
            type="button"
          >×</button>
        </span>
      </header>
      {onClose ? <small className="floating-running-model-close-hint">Esc 或 × 关闭 · 再次点击主／子数字也可收起</small> : null}
      <div className="floating-running-model-table">
        <div aria-hidden="true" className="floating-running-model-column-labels">
          <span>主线程 <b>{summary.mainThreads ?? 0}</b></span>
          <span>子 Agent <b>{summary.subagents ?? 0}</b></span>
        </div>
        {groups.map((group) => (
          <RunningThreadGroupRow group={group} key={group.mainThread.threadId} />
        ))}
        {unassignedSubagents.length > 0 ? (
          <div className="floating-running-model-group-row floating-running-model-group-row--unassigned">
            <span className="floating-running-model-unassigned-label">未关联</span>
            <RunningSubagentModels members={unassignedSubagents} />
          </div>
        ) : null}
        {rowCount === 0 ? (
          <p className="floating-running-model-empty">{summary.status === "scanning"
            ? "正在读取运行线程…"
            : (summary.status === "unavailable" ? "运行线程暂不可用" : "暂无运行线程")}</p>
        ) : null}
      </div>
    </section>
  );
}

function RunningThreadGroupRow({ group }: { group: RunningThreadGroup }) {
  const title = group.mainThread.title?.trim() || "会话标题暂未读取";
  const tooltipId = `floating-main-title-${group.mainThread.threadId.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
  return (
    <div className="floating-running-model-group-row">
      <span
        aria-describedby={tooltipId}
        className="floating-running-model-main"
        title={title}
        tabIndex={0}
      >
        <ModelDot model={group.mainThread.model} />
        <em>{runningThreadMemberLabel(group.mainThread)}</em>
        <span className="floating-running-model-title-tooltip" id={tooltipId} role="tooltip">
          {title}
        </span>
      </span>
      <RunningSubagentModels members={group.subagents} />
    </div>
  );
}

function RunningSubagentModels({ members }: { members: RunningThreadMember[] }) {
  const rows = groupedRunningThreadMembers(members);
  if (rows.length === 0) {
    return <span className="floating-running-model-no-subagents">暂无子 Agent</span>;
  }
  return (
    <span className="floating-running-model-subagent-group">
      {rows.map((row) => (
        <span aria-label={`${row.title}，${row.count} 个`} className="floating-running-model-badge" key={row.id}>
          <ModelDot model={row.model} />
          <em>{row.title}</em>
          {row.count > 1 ? <b>×{row.count}</b> : null}
        </span>
      ))}
    </span>
  );
}

function ModelDot({ model }: { model: string | null }) {
  return <i aria-hidden="true" style={{ backgroundColor: modelUsageColor(model) }} />;
}

function runningThreadMemberLabel(member: RunningThreadMember): string {
  const model = member.model ? modelUsageLabel(member.model) : "配置同步中";
  const effort = member.reasoningEffort?.trim();
  return effort ? `${model} · ${effort}` : model;
}

function groupedRunningThreadMembers(members: RunningThreadMember[]): RunningThreadModelDisplayRow[] {
  const grouped = new Map<string, RunningThreadModelDisplayRow>();
  for (const member of members) {
    const title = runningThreadMemberLabel(member);
    const key = `${member.model ?? "unknown"}|${member.reasoningEffort?.trim() || "unknown"}`;
    const existing = grouped.get(key);
    if (existing) {
      existing.count += 1;
    } else {
      grouped.set(key, {
        id: key,
        model: member.model,
        title,
        count: 1,
      });
    }
  }
  return Array.from(grouped.values()).sort((left, right) => (
    right.count - left.count || left.title.localeCompare(right.title)
  ));
}

function hasPendingRunningModelConfiguration(summary: RunningThreadSummary): boolean {
  const resolvedMain = (summary.mainModels ?? [])
    .filter((row) => Boolean(row.model))
    .reduce((sum, row) => sum + Math.max(0, Math.trunc(row.count)), 0);
  const resolvedSubagents = (summary.subagentModels ?? [])
    .filter((row) => Boolean(row.model))
    .reduce((sum, row) => sum + Math.max(0, Math.trunc(row.count)), 0);
  return resolvedMain < (summary.mainThreads ?? 0)
    || resolvedSubagents < (summary.subagents ?? 0);
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
  groups: [
    {
      mainThread: {
        threadId: "guide-main-one",
        title: "整理本周模型使用情况",
        model: "gpt-5.6-sol",
        reasoningEffort: "ultra",
      },
      subagents: [
        {
          threadId: "guide-sub-one",
          title: null,
          model: "gpt-5.6-luna",
          reasoningEffort: "max",
        },
        {
          threadId: "guide-sub-two",
          title: null,
          model: "gpt-5.6-luna",
          reasoningEffort: "max",
        },
      ],
    },
    {
      mainThread: {
        threadId: "guide-main-two",
        title: "检查悬浮窗视觉细节",
        model: "gpt-5.6-sol",
        reasoningEffort: "ultra",
      },
      subagents: [],
    },
    {
      mainThread: {
        threadId: "guide-main-three",
        title: "更新使用说明",
        model: "gpt-5.6-luna",
        reasoningEffort: "max",
      },
      subagents: [],
    },
  ],
  unassignedSubagents: [],
  status: "ready",
  updatedAt: null,
  detail: "引导示例",
  livenessLeaseHours: 24,
};

export function floatingRunningThreadSummaryForPresentation(
  live: RunningThreadSummary,
  guidePresented: boolean,
  page: FloatingGuidePage,
): RunningThreadSummary {
  return guidePresented && page === "runningModels"
    ? FLOATING_RUNNING_MODEL_GUIDE_DEMO
    : live;
}

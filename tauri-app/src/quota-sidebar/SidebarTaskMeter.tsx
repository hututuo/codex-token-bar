import { modelUsageColor, modelUsageKey, modelUsageLabel } from "../components/modelUsagePresentation";
import type { RunningThreadModelBreakdown, RunningThreadSummary, RunningThreadSummaryStatus } from "../types/threadActivity";
import { sidebarCombinedTaskCounts } from "./sidebarLayoutPresentation";

export interface SidebarTaskMeterPresentation {
  cells: (string | null)[];
  colors: string[];
  status: RunningThreadSummaryStatus;
  label: string;
}

export function sidebarTaskMeterForSources(codex: RunningThreadSummary, includesCodex: boolean,
  claudeReady: boolean, mainAgents: readonly {model:string|null}[], subagents: readonly {model:string|null}[]) {
  const counts = sidebarCombinedTaskCounts(codex.status, includesCodex, true, claudeReady,
    codex.mainThreads ?? 0, codex.subagents ?? 0, mainAgents.length, subagents.length);
  const useCodex = includesCodex && (codex.status === "ready" || (counts.status === "stale" && codex.status === "stale"));
  const rows = [...(useCodex ? [...(codex.mainModels ?? []), ...(codex.subagentModels ?? [])] : []),
    ...(claudeReady ? [...mainAgents,...subagents].map(agent=>({model:agent.model,reasoningEffort:null,count:1})) : [])];
  return {...counts, meter:sidebarTaskMeter(counts.main,counts.subagents,counts.status,rows)};
}

export function sidebarTaskMeter(main: number, subagents: number, status: RunningThreadSummaryStatus,
  rows: readonly RunningThreadModelBreakdown[]): SidebarTaskMeterPresentation {
  const integer = (value: number) => Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0;
  const hasCounts = status === "ready" || status === "stale";
  const total = hasCounts ? integer(main) + integer(subagents) : 0;
  const counts = new Map<string, number>();
  for (const row of rows) {
    const key = modelUsageKey(row.model);
    counts.set(key, (counts.get(key) ?? 0) + integer(row.count));
  }
  const keys = [...counts.keys()].sort().filter(key=>key!=="unknown");
  if(counts.has("unknown")) keys.push("unknown");
  let remaining = total;
  const cells: (string|null)[] = [], details: string[] = [];
  for (const key of keys) {
    const count = Math.min(remaining, counts.get(key) ?? 0);
    if (!count) continue;
    remaining -= count;
    cells.push(...Array(Math.min(count, 10-cells.length)).fill(key));
    details.push(`${modelUsageLabel(key)} ×${count}`);
  }
  if (remaining) {
    cells.push(...Array(Math.min(remaining, 10-cells.length)).fill("unknown"));
    details.push(`模型同步中 ×${remaining}`);
  }
  while (cells.length < 10) cells.push(null);
  const label = !hasCounts ? (status === "scanning" ? "运行任务：正在读取" : "运行任务：状态未知")
    : `运行任务：${total} 个（主 ${integer(main)} · 子 ${integer(subagents)}）；每格 1 个`
      + (details.length ? "；" + details.join("、") : "") + (total > 10 ? "；超过 10 个，亮条已满" : "")
      + (status === "stale" ? "；上次数据，已过期" : "");
  return { cells, status, label, colors: cells.map(model=>model===null ? "rgba(255,255,255,0.12)"
    : status==="stale" ? "rgba(122,135,150,0.55)" : modelUsageColor(model)) };
}

export function taskMeterSegments(meter: SidebarTaskMeterPresentation) {
  return meter.colors.map((color,index)=>({id:`cell-${index}`,start:index/10,end:(index+1)/10,color}));
}

export function SidebarTaskCells({ meter }: { meter: SidebarTaskMeterPresentation }) {
  return <>{meter.cells.map((model,index)=><i key={index} aria-hidden="true" data-task-cell={index}
    data-model={model ?? undefined} data-occupied={model!==null}
    style={{bottom:index===0?0:`calc(${index*10}% + 0.3px)`,
      height:`calc(10% - ${index===0||index===9?0.3:0.6}px)`,background:meter.colors[index]}}/>)}</>;
}

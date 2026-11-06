import type { ClaudeRuntimeAgent, ClaudeRuntimeSnapshot } from "../multiClient/ClaudeLocalRuntime";
import type { RunningThreadMember, RunningThreadModelBreakdown, RunningThreadSummary } from "../types/threadActivity";
import { sidebarCombinedTaskCounts } from "./sidebarLayoutPresentation";

const localTaskClients = ["claudeCode", "claudeDesktop", "antigravity"];
export const taskClientLabel = (client: string) => ({
  codex: "Codex", claudeCode: "Claude Code", claudeDesktop: "Claude Desktop", antigravity: "Antigravity",
}[client] ?? client);

export interface TaskDetailMember extends RunningThreadMember {
  client?: string;
  phase?: string;
}
export interface TaskDetailSummary extends Omit<RunningThreadSummary, "groups" | "unassignedSubagents"> {
  groups: { mainThread: TaskDetailMember; subagents: TaskDetailMember[] }[];
  unassignedSubagents: TaskDetailMember[];
  sourceIssues?: string[];
}

const taskKey = (client: string, id: string) => JSON.stringify([client, id]);
const localMember = (agent: ClaudeRuntimeAgent): TaskDetailMember => ({
  threadId: taskKey(agent.client, agent.id), client: agent.client, phase: agent.phase,
  title: agent.title?.trim() || null, model: agent.model, reasoningEffort: null,
});

function modelCounts(agents: readonly ClaudeRuntimeAgent[]): RunningThreadModelBreakdown[] {
  const counts = new Map<string | null, number>();
  for (const agent of agents) counts.set(agent.model, (counts.get(agent.model) ?? 0) + 1);
  return [...counts].map(([model, count]) => ({ model, reasoningEffort: null, count }));
}

/** Adapt observed local agents into the existing task-card shape. Parent IDs are source-scoped. */
export function localTaskSummary(mainAgents: readonly ClaudeRuntimeAgent[], subagents: readonly ClaudeRuntimeAgent[]): TaskDetailSummary {
  const unique = (agents: readonly ClaudeRuntimeAgent[]) => [...new Map(agents.map(agent => [taskKey(agent.client, agent.id), agent])).values()];
  const main = unique(mainAgents), parents = new Set(main.map(agent => taskKey(agent.client, agent.id)));
  const children = unique(subagents).filter(agent => !parents.has(taskKey(agent.client, agent.id)));
  const childrenByParent = new Map<string, TaskDetailMember[]>(), unassigned: TaskDetailMember[] = [];
  for (const child of children) {
    const parent = child.parentId === null ? null : taskKey(child.client, child.parentId);
    if (parent && parents.has(parent)) {
      childrenByParent.set(parent, [...(childrenByParent.get(parent) ?? []), localMember(child)]);
    } else unassigned.push(localMember(child));
  }
  return {
    total: main.length + children.length, mainThreads: main.length, subagents: children.length,
    mainModels: modelCounts(main), subagentModels: modelCounts(children),
    groups: main.map(agent => ({mainThread: localMember(agent), subagents: childrenByParent.get(taskKey(agent.client, agent.id)) ?? []})),
    unassignedSubagents: unassigned, status: "ready", updatedAt: null, detail: "", livenessLeaseHours: 0,
  };
}

type LocalTaskRuntime = Pick<ClaudeRuntimeSnapshot,
  "enabled" | "capturedAt" | "sourceAvailable" | "mainAgents" | "subagents" | "configurationIssue"> & {configuredClients: readonly string[]};

/** One projection for the compact meter, summary counts and existing detail cards. */
export function combinedRunningTasks(
  codex: RunningThreadSummary, runtime: LocalTaskRuntime, allowed: readonly string[], now = Date.now(),
): TaskDetailSummary {
  const includesCodex = allowed.includes("codex");
  const selected = [...new Set(allowed)].filter(client => localTaskClients.includes(client) && runtime.configuredClients.includes(client));
  const captured = Date.parse(runtime.capturedAt ?? "");
  const fresh = runtime.enabled && Number.isFinite(captured) && Math.abs(now - captured) <= 10000;
  const available = new Set(selected.filter(client => fresh && runtime.sourceAvailable[client]));
  const active = (agent: ClaudeRuntimeAgent) => available.has(agent.client) && !agent.displayStopped
    && ["generating", "tools"].includes(agent.phase)
    && Date.parse(agent.lastActivity) >= now - 300000 && Date.parse(agent.lastActivity) <= now + 5000;
  const local = localTaskSummary(runtime.mainAgents.filter(active), runtime.subagents.filter(active));
  const counts = sidebarCombinedTaskCounts(codex.status, includesCodex, selected.length > 0, available.size > 0,
    codex.mainThreads ?? 0, codex.subagents ?? 0, local.mainThreads ?? 0, local.subagents ?? 0);
  const useCodex = includesCodex && (codex.status === "ready" || (counts.status === "stale" && codex.status === "stale"));
  const codexMember = (member: RunningThreadMember): TaskDetailMember => ({...member, client: "codex", threadId: taskKey("codex", member.threadId)});
  const issues: string[] = [];
  if (includesCodex && codex.status !== "ready") {
    issues.push(`Codex · ${codex.status === "stale" ? "上次任务数据已过期" : codex.status === "scanning" ? "任务读取中" : "暂无任务数据"}`);
  }
  for (const client of selected) if (!available.has(client)) issues.push(`${taskClientLabel(client)} · 暂无任务数据`);
  const hasCounts = counts.status === "ready" || counts.status === "stale";
  return {
    total: hasCounts ? counts.main + counts.subagents : null,
    mainThreads: hasCounts ? counts.main : null, subagents: hasCounts ? counts.subagents : null,
    mainModels: [...(useCodex ? codex.mainModels ?? [] : []), ...local.mainModels],
    subagentModels: [...(useCodex ? codex.subagentModels ?? [] : []), ...local.subagentModels],
    groups: [...(useCodex ? codex.groups.map(group => ({mainThread: codexMember(group.mainThread), subagents: group.subagents.map(codexMember)})) : []), ...local.groups],
    unassignedSubagents: [...(useCodex ? codex.unassignedSubagents.map(codexMember) : []), ...local.unassignedSubagents],
    status: counts.status, updatedAt: available.size ? captured / 1000 : useCodex ? codex.updatedAt : null,
    detail: [includesCodex ? codex.detail : "", selected.length ? runtime.configurationIssue : ""].filter(Boolean).join("；"),
    livenessLeaseHours: includesCodex ? codex.livenessLeaseHours : 0, sourceIssues: issues,
  };
}

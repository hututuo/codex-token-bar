export type RunningThreadSummaryStatus = "scanning" | "ready" | "stale" | "unavailable";

export interface RunningThreadModelBreakdown {
  model: string | null;
  reasoningEffort: string | null;
  count: number;
}

export interface RunningThreadMember {
  threadId: string;
  title: string | null;
  model: string | null;
  reasoningEffort: string | null;
}

export interface RunningThreadGroup {
  mainThread: RunningThreadMember;
  subagents: RunningThreadMember[];
}

export interface RunningThreadSummary {
  total: number | null;
  mainThreads: number | null;
  subagents: number | null;
  mainModels: RunningThreadModelBreakdown[];
  subagentModels: RunningThreadModelBreakdown[];
  groups: RunningThreadGroup[];
  unassignedSubagents: RunningThreadMember[];
  status: RunningThreadSummaryStatus;
  updatedAt: number | null;
  detail: string;
  livenessLeaseHours: number;
}

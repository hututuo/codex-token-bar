export type RunningThreadSummaryStatus = "scanning" | "ready" | "stale" | "unavailable";

export interface RunningThreadModelBreakdown {
  model: string | null;
  reasoningEffort: string | null;
  count: number;
}

export interface RunningThreadSummary {
  total: number | null;
  mainThreads: number | null;
  subagents: number | null;
  mainModels: RunningThreadModelBreakdown[];
  subagentModels: RunningThreadModelBreakdown[];
  status: RunningThreadSummaryStatus;
  updatedAt: number | null;
  detail: string;
  livenessLeaseHours: number;
}

export type RunningThreadSummaryStatus = "scanning" | "ready" | "stale" | "unavailable";

export interface RunningThreadSummary {
  total: number | null;
  mainThreads: number | null;
  subagents: number | null;
  status: RunningThreadSummaryStatus;
  updatedAt: number | null;
  detail: string;
  livenessLeaseHours: number;
}

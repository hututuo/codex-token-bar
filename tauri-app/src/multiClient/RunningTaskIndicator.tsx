import { useClaudeLocalRuntime } from "./ClaudeLocalRuntime";
import { combinedRunningTasks } from "../quota-sidebar/runningTaskPresentation";
import type { TaskDetailSummary } from "../quota-sidebar/runningTaskPresentation";
import type { RunningThreadSummary } from "../types/threadActivity";
import { runningThreadHeaderText } from "../components/DashboardHeader";

/** The header observes the same source quality and parent/child projection as
 * the sidebar, without rerendering the full dashboard on each local sample. */
export function RunningTaskIndicator({codex,allowed}:{codex:RunningThreadSummary;allowed:readonly string[]}) {
  const runtime=useClaudeLocalRuntime(allowed);
  const summary=combinedRunningTasks(codex,runtime,allowed);
  return <RunningTaskSummaryIndicator summary={summary}/>;
}
export function RunningTaskSummaryIndicator({summary}:{summary:TaskDetailSummary}) {
  return <small data-testid="scoped-running-tasks" title={[summary.detail,...summary.sourceIssues??[]].filter(Boolean).join("；")}>
    所选客户端 · {runningThreadHeaderText(summary)}
  </small>;
}

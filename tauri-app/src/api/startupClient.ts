import { callCommand } from "./command";

export function recordStartupEvent(label: string): Promise<boolean> {
  return callCommand("record_startup_event", false, { label }, 1_000);
}

export function recordPerformanceEvent(label: string): Promise<boolean> {
  return callCommand("record_performance_event", false, { label }, 1_000);
}

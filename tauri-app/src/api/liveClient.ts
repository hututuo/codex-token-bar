import type {
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  UnreadSummary,
} from "../types/dashboard";
import {
  emptyFloatingPanelSnapshot,
  emptyLiveRateSnapshot,
  emptyUnreadSummary,
} from "./fallback";
import { callCommand } from "./command";

export function readLiveRateSnapshot(selectedThreadId?: string | null): Promise<LiveRateSnapshot> {
  return callCommand(
    "read_live_rate_snapshot",
    emptyLiveRateSnapshot(selectedThreadId),
    { selectedThreadId: selectedThreadId || null },
    1_500,
  );
}

export function readLiveThreadOptions(): Promise<LiveThreadOption[]> {
  return callCommand("read_live_thread_options", [], undefined, 1_500);
}

export function readFloatingPanelSnapshot(): Promise<FloatingPanelSnapshot> {
  return callCommand("read_floating_snapshot", emptyFloatingPanelSnapshot, undefined, 1_500);
}

export function readUnreadSummary(): Promise<UnreadSummary> {
  return callCommand("read_unread_summary", emptyUnreadSummary, undefined, 1_500);
}

export function acknowledgeUnreadSummary(): Promise<UnreadSummary> {
  return callCommand("acknowledge_current_unread", emptyUnreadSummary, undefined, 1_500);
}

export function resetLiveRateMonitor(): Promise<boolean> {
  return callCommand("reset_live_rate_monitor", false, undefined, 1_500);
}

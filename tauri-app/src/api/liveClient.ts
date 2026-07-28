import type {
  CodexHomeSourceToken,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  RunningThreadSummary,
  UnreadSummary,
} from "../types/dashboard";
import {
  emptyFloatingPanelSnapshot,
  emptyLiveRateSnapshot,
} from "./fallback";
import { callCommand, callCommandOptional, callCommandStrict } from "./command";

export function readLiveRateSnapshot(
  selectedThreadId?: string | null,
  sourceToken: CodexHomeSourceToken | null = null,
): Promise<LiveRateSnapshot> {
  return callCommand(
    "read_live_rate_snapshot",
    emptyLiveRateSnapshot(selectedThreadId),
    { selectedThreadId: selectedThreadId || null, sourceToken },
    1_500,
  );
}

export function readLiveRateSnapshotStrict(
  selectedThreadId?: string | null,
  sourceToken: CodexHomeSourceToken | null = null,
): Promise<LiveRateSnapshot> {
  return callCommandStrict<LiveRateSnapshot>(
    "read_live_rate_snapshot",
    { selectedThreadId: selectedThreadId || null, sourceToken },
    1_500,
  );
}

export function readLiveThreadOptions(): Promise<LiveThreadOption[]> {
  return callCommand("read_live_thread_options", [], undefined, 1_500);
}

export function readFloatingPanelSnapshot(
  sourceToken: CodexHomeSourceToken | null = null,
): Promise<FloatingPanelSnapshot> {
  return callCommand("read_floating_snapshot", emptyFloatingPanelSnapshot, { sourceToken }, 1_500);
}

export function readUnreadSummary(
  sourceToken: CodexHomeSourceToken | null = null,
): Promise<UnreadSummary> {
  return callCommandStrict<UnreadSummary>("read_unread_summary", { sourceToken }, 1_500);
}

export function readRunningThreadSummary(
  sourceToken: CodexHomeSourceToken,
): Promise<RunningThreadSummary> {
  return callCommandStrict<RunningThreadSummary>(
    "read_running_thread_summary",
    { sourceToken },
    1_500,
  );
}

export function acknowledgeUnreadSummary(
  sourceToken: CodexHomeSourceToken | null = null,
): Promise<UnreadSummary | null> {
  return callCommandOptional(
    "acknowledge_current_unread",
    { sourceToken },
    1_500,
  );
}

export function resetLiveRateMonitor(): Promise<boolean> {
  return callCommand("reset_live_rate_monitor", false, undefined, 1_500);
}

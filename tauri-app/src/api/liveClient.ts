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

export const INITIAL_LIVE_RATE_IPC_TIMEOUT_MS = 1_500;

class InitialLiveRateIpcTimeoutError extends Error {}

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

export async function readInitialLiveRateSnapshot(
  selectedThreadId?: string | null,
  sourceToken: CodexHomeSourceToken | null = null,
): Promise<LiveRateSnapshot> {
  // Keep the native invocation alive after the UI budget expires. A JS-only
  // timeout cannot cancel Tauri work, so recording it as a command failure
  // would create a false banner that disappears when the same invocation
  // eventually succeeds. Native rejections still flow through the strict
  // command path and remain diagnostic.
  const invocation = callCommandStrict<LiveRateSnapshot>(
    "read_live_rate_snapshot",
    { selectedThreadId: selectedThreadId || null, sourceToken },
    null,
  );
  try {
    return await withInitialLiveRateIpcBudget(invocation);
  } catch (error) {
    if (!(error instanceof InitialLiveRateIpcTimeoutError)) {
      throw error;
    }
    return {
      ...emptyLiveRateSnapshot(selectedThreadId),
      threadTitle: "实时速率正在连接",
    };
  }
}

async function withInitialLiveRateIpcBudget<T>(invocation: Promise<T>): Promise<T> {
  let timer: number | undefined;
  const timeout = new Promise<T>((_, reject) => {
    timer = window.setTimeout(() => {
      reject(new InitialLiveRateIpcTimeoutError(
        `Initial live-rate IPC remained pending after ${INITIAL_LIVE_RATE_IPC_TIMEOUT_MS}ms`,
      ));
    }, INITIAL_LIVE_RATE_IPC_TIMEOUT_MS);
  });
  try {
    return await Promise.race([invocation, timeout]);
  } finally {
    if (timer !== undefined) {
      window.clearTimeout(timer);
    }
  }
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

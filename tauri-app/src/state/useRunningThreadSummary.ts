import { useEffect, useMemo, useState } from "react";
import { readRunningThreadSummary } from "../api/liveClient";
import type {
  CodexHomeSourceToken,
  RunningThreadSummary,
} from "../types/dashboard";

export const PENDING_RUNNING_THREAD_SUMMARY: RunningThreadSummary = {
  total: null,
  mainThreads: null,
  subagents: null,
  status: "scanning",
  updatedAt: null,
  detail: "正在读取当前数据源的会话生命周期",
  livenessLeaseHours: 24,
};

interface UseRunningThreadSummaryOptions {
  active?: boolean;
  intervalMs?: number;
  sourceToken: CodexHomeSourceToken | null;
}

const DEFAULT_INTERVAL_MS = 1_000;

export function useRunningThreadSummary({
  active = true,
  intervalMs = DEFAULT_INTERVAL_MS,
  sourceToken,
}: UseRunningThreadSummaryOptions): RunningThreadSummary {
  const [summary, setSummary] = useState<RunningThreadSummary>(
    PENDING_RUNNING_THREAD_SUMMARY,
  );
  const sourceKey = useMemo(
    () => sourceToken === null
      ? null
      : JSON.stringify([
          sourceToken.transitionGeneration,
          sourceToken.canonicalHomeKey,
          sourceToken.physicalHomeKey,
        ]),
    [sourceToken],
  );

  useEffect(() => {
    if (!active || sourceToken === null || sourceKey === null) {
      setSummary(PENDING_RUNNING_THREAD_SUMMARY);
      return;
    }
    const activeSourceToken = sourceToken;
    let disposed = false;
    let requestInFlight = false;

    async function refresh() {
      if (requestInFlight) {
        return;
      }
      requestInFlight = true;
      try {
        const next = await readRunningThreadSummary(activeSourceToken);
        if (!disposed) {
          setSummary(next);
        }
      } catch (error) {
        if (!disposed) {
          setSummary((current) => current.total === null
            ? {
                ...PENDING_RUNNING_THREAD_SUMMARY,
                status: "unavailable",
                detail: `运行线程暂不可用：${errorMessage(error)}`,
              }
            : {
                ...current,
                status: "stale",
                detail: `沿用最近一次成功结果：${errorMessage(error)}`,
              });
        }
      } finally {
        requestInFlight = false;
      }
    }

    setSummary(PENDING_RUNNING_THREAD_SUMMARY);
    void refresh();
    const interval = window.setInterval(() => {
      void refresh();
    }, Math.max(500, intervalMs));
    return () => {
      disposed = true;
      window.clearInterval(interval);
    };
  }, [active, intervalMs, sourceKey, sourceToken]);

  return summary;
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim()) {
    return error.message;
  }
  if (typeof error === "string" && error.trim()) {
    return error;
  }
  return "读取失败";
}

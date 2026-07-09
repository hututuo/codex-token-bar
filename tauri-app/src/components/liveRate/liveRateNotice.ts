import type { LiveRateSnapshot } from "../../types/dashboard";

const LIVE_RATE_STREAM_WARNING_SOURCE = "live_rate_stream";
const LIVE_RATE_SUMMARY_WARNING_SOURCE = "live_rate_summary";

export interface LiveRateNoticeContext {
  liveRateEnabled: boolean;
  refreshing: boolean;
  usageCacheInitializing: boolean;
}

export interface LiveRateNotice {
  kind: "failure" | "pending";
  title: string;
  message: string;
  retryable: boolean;
}

export function liveRateNotice(
  snapshot: LiveRateSnapshot,
  context: LiveRateNoticeContext,
): LiveRateNotice | null {
  if (!context.liveRateEnabled) {
    return null;
  }

  const streamWarnings = snapshot.warnings.filter(
    (warning) => warning.source === LIVE_RATE_STREAM_WARNING_SOURCE,
  );
  if (streamWarnings.length > 0) {
    return {
      kind: "failure",
      title: "实时速率降级",
      message: streamWarnings.map((warning) => warning.message).join("；"),
      retryable: true,
    };
  }

  const hasSummaryCacheWarning = snapshot.warnings.some(isPreciseSummaryCacheWarning);
  if (!hasSummaryCacheWarning) {
    return null;
  }

  return {
    kind: "pending",
    title: "用量统计重建中",
    message:
      context.refreshing || context.usageCacheInitializing
        ? "刷新仍在扫描本地会话文件，完成后会恢复总/今/次。"
        : "正在重新扫描本地会话文件，完成后会恢复总/今/次。",
    retryable: false,
  };
}

function isPreciseSummaryCacheWarning(warning: { source: string; message: string }): boolean {
  return warning.source === LIVE_RATE_SUMMARY_WARNING_SOURCE;
}

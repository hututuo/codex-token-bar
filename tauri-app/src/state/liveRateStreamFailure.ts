import { emptyLiveRateSnapshot } from "../api/fallback/liveFallback";
import type { PlatformCommandResult } from "../platform/desktopBridge";
import type { LiveRateSnapshot } from "../types/dashboard";

export const LIVE_RATE_STREAM_WARNING_SOURCE = "live_rate_stream";

export function liveRateStreamFailureSnapshot(
  selectedThreadId: string | null,
  result: PlatformCommandResult<unknown>,
): LiveRateSnapshot {
  return {
    ...emptyLiveRateSnapshot(selectedThreadId),
    scopeLabel: "实时速率",
    threadTitle: "实时速率启动失败",
    selectedThreadTitle: selectedThreadId ? "选中会话实时速率启动失败" : "选择会话查看单会话速率",
    warnings: [
      {
        source: LIVE_RATE_STREAM_WARNING_SOURCE,
        message: liveRateStreamFailureMessage(result),
      },
    ],
  };
}

export function liveRateStreamFailureMessage(result: PlatformCommandResult<unknown>): string {
  if (result.ok) {
    return "";
  }
  const reason = result.error.trim();
  return reason
    ? `实时速率流启动失败：${reason}。可点击重试重新连接。`
    : "实时速率流启动失败。可点击重试重新连接。";
}

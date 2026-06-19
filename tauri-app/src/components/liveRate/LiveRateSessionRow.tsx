import type { LiveRateSnapshot, LiveThreadOption } from "../../types/dashboard";
import { formatTokens } from "../../utils/format";

interface LiveRateSessionRowProps {
  liveThreadOptions: LiveThreadOption[];
  onLiveThreadSelect: (threadId: string) => void;
  selectedLiveThreadId: string;
  snapshot: LiveRateSnapshot;
}

export function LiveRateSessionRow({
  liveThreadOptions,
  onLiveThreadSelect,
  selectedLiveThreadId,
  snapshot,
}: LiveRateSessionRowProps) {
  const hasSelectedThread = selectedLiveThreadId.length > 0;
  const selectedThreadLabel = hasSelectedThread
    ? snapshot.selectedThreadTitle
    : "选择一个会话后显示单会话速度";
  const selectedRateLabel = hasSelectedThread ? `${snapshot.selectedTokensPerSecond.toFixed(1)} tok/s` : "未选择";

  return (
    <div className="session-row">
      <label className="session-picker">
        <span>单会话</span>
        <select onChange={(event) => onLiveThreadSelect(event.currentTarget.value)} value={selectedLiveThreadId}>
          <option value="">选择会话</option>
          {liveThreadOptions.map((thread) => (
            <option key={thread.id} value={thread.id}>
              {thread.title} · {thread.updatedAt} · {formatTokens(thread.tokensUsed)}
            </option>
          ))}
        </select>
      </label>
      <div className="session-title">
        <span>{selectedThreadLabel}</span>
        <em>{snapshot.threadTitle}</em>
      </div>
      <strong>{selectedRateLabel}</strong>
    </div>
  );
}

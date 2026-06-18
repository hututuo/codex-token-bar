import type { FloatingPanelSnapshot } from "../types/dashboard";

interface FloatingPanelPreviewProps {
  snapshot: FloatingPanelSnapshot;
}

export function FloatingPanelPreview({ snapshot }: FloatingPanelPreviewProps) {
  return (
    <aside className="floating-preview" aria-label="悬浮窗预览">
      {snapshot.unread ? <span className="unread-ripple" /> : null}
      <div className="floating-topline">
        <strong>{snapshot.tokensPerSecond.toFixed(1)}</strong>
        <span>tok/s</span>
        <em>{snapshot.trendLabel}</em>
        <button type="button">×</button>
      </div>
      <div className="floating-metrics">
        <span>{snapshot.totalTokensLabel}</span>
        <span>{snapshot.todayTokensLabel}</span>
        <span>{snapshot.requestsLabel}</span>
      </div>
      <div className="floating-quota">
        <strong>{snapshot.fiveHourLabel}</strong>
        <strong>{snapshot.sevenDayLabel}</strong>
      </div>
    </aside>
  );
}

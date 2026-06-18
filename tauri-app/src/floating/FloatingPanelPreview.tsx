import type { FloatingPanelSnapshot } from "../types/dashboard";

interface FloatingPanelSurfaceProps {
  snapshot: FloatingPanelSnapshot;
  onClose?: () => void;
  onDragStart?: () => void;
}

export function FloatingPanelSurface({ snapshot, onClose, onDragStart }: FloatingPanelSurfaceProps) {
  return (
    <aside className="floating-panel-surface" aria-label="悬浮窗" onMouseDown={onDragStart}>
      {snapshot.unread ? <span className="unread-ripple" /> : null}
      <div className="floating-topline">
        <strong>{snapshot.tokensPerSecond.toFixed(1)}</strong>
        <span>tok/s</span>
        <em>{snapshot.trendLabel}</em>
        <button
          type="button"
          aria-label="关闭悬浮窗"
          onMouseDown={(event) => event.stopPropagation()}
          onClick={onClose}
        >
          ×
        </button>
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

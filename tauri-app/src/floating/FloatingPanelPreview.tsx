import type { FloatingPanelSnapshot, FloatingUnreadEffect } from "../types/dashboard";

interface FloatingPanelSurfaceProps {
  snapshot: FloatingPanelSnapshot;
  unreadEffect?: FloatingUnreadEffect;
  onClose?: () => void;
  onDragStart?: () => void;
}

export function FloatingPanelSurface({
  snapshot,
  unreadEffect = "ripple",
  onClose,
  onDragStart,
}: FloatingPanelSurfaceProps) {
  const shouldShowUnreadEffect = snapshot.unread && unreadEffect !== "off";

  return (
    <aside className="floating-panel-surface" aria-label="悬浮窗" onMouseDown={onDragStart}>
      {shouldShowUnreadEffect ? <span className={`unread-effect unread-effect--${unreadEffect}`} /> : null}
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

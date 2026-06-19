import type { CSSProperties } from "react";
import type { FloatingPanelSnapshot, FloatingUnreadEffect } from "../types/dashboard";

interface FloatingPanelSurfaceProps {
  snapshot: FloatingPanelSnapshot;
  unreadEffect?: FloatingUnreadEffect;
  onClose?: () => void;
  onDragStart?: () => void;
}

function clampPercent(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.min(100, Math.max(0, value * 100));
}

function FloatingQuotaBar({ label, remainingPercent }: { label: string; remainingPercent: number }) {
  const fillPercent = clampPercent(remainingPercent);

  return (
    <span
      className="floating-quota-bar"
      role="meter"
      aria-label={`${label}，剩余 ${Math.round(fillPercent)}%`}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(fillPercent)}
      style={{ "--quota-fill": `${fillPercent}%` } as CSSProperties}
    >
      <span className="floating-quota-track" aria-hidden="true">
        <span className="floating-quota-fill" />
      </span>
      <span className="floating-quota-label">{label}</span>
    </span>
  );
}

export function FloatingPanelSurface({
  snapshot,
  unreadEffect = "ripple",
  onClose,
  onDragStart,
}: FloatingPanelSurfaceProps) {
  const shouldShowUnreadEffect = snapshot.unreadSummary.active && unreadEffect !== "off";

  return (
    <aside
      className="floating-panel-surface"
      aria-label={`悬浮窗，${snapshot.unreadSummary.label}`}
      onMouseDown={onDragStart}
      title={snapshot.unreadSummary.detail}
    >
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
        <FloatingQuotaBar label={snapshot.fiveHourLabel} remainingPercent={snapshot.fiveHourRemainingPercent} />
        <FloatingQuotaBar label={snapshot.sevenDayLabel} remainingPercent={snapshot.sevenDayRemainingPercent} />
      </div>
    </aside>
  );
}

import type { KeyboardEvent } from "react";

export interface StatusPanelCompactItem {
  id: string;
  shortLabel: string;
}

export interface StatusPanelCompactIndicatorProps {
  items: StatusPanelCompactItem[];
  onExpand(): void;
  tooltip: string;
}

export function StatusPanelCompactIndicator({
  items,
  onExpand,
  tooltip,
}: StatusPanelCompactIndicatorProps) {
  function handleKeyDown(event: KeyboardEvent<HTMLElement>) {
    if (event.key !== "Enter" && event.key !== " ") {
      return;
    }
    event.preventDefault();
    onExpand();
  }

  return (
    <main className="status-window-shell status-window-shell--compact">
      <section
        aria-label="状态栏紧凑指标"
        className="status-panel-card status-panel-card--compact"
        onClick={onExpand}
        onKeyDown={handleKeyDown}
        role="button"
        tabIndex={0}
        title={tooltip}
      >
        <div className="status-indicator-compact-items">
          {items.map((item) => (
            <strong key={item.id}>{item.shortLabel}</strong>
          ))}
        </div>
      </section>
    </main>
  );
}

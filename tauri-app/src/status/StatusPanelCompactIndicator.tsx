import type { KeyboardEvent } from "react";
import type { StatusIndicatorTrayColumn } from "./statusIndicatorPresentation";

export interface StatusPanelCompactIndicatorProps {
  columns: StatusIndicatorTrayColumn[];
  onExpand(): void;
  tooltip: string;
}

export function StatusPanelCompactIndicator({
  columns,
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
        aria-label={tooltip}
        className="status-panel-card status-panel-card--compact"
        onClick={onExpand}
        onKeyDown={handleKeyDown}
        role="button"
        tabIndex={0}
        title={tooltip}
      >
        <StatusPanelCompactItems ariaHidden columns={columns} />
      </section>
    </main>
  );
}

export function StatusPanelCompactItems({
  ariaHidden = false,
  columns,
}: {
  ariaHidden?: boolean;
  columns: StatusIndicatorTrayColumn[];
}) {
  return (
    <div aria-hidden={ariaHidden || undefined} className="status-indicator-compact-columns">
      {columns.map((column, index) => (
        <span className="status-indicator-column" key={`${column.top.text}-${column.bottom.text}-${index}`}>
          <span className={column.top.secondary ? "is-secondary" : undefined}>{column.top.text}</span>
          <span className={column.bottom.secondary ? "is-secondary" : undefined}>{column.bottom.text}</span>
        </span>
      ))}
    </div>
  );
}

import type { KeyboardEvent } from "react";

export interface StatusPanelCompactItem {
  compactMarker?: {
    bottom: "H" | "D";
    top: "5" | "7";
  };
  compactRows?: [string, string];
  id: string;
  shortLabel: string;
  value: string;
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
        aria-label={tooltip}
        className="status-panel-card status-panel-card--compact"
        onClick={onExpand}
        onKeyDown={handleKeyDown}
        role="button"
        tabIndex={0}
        title={tooltip}
      >
        <StatusPanelCompactItems ariaHidden items={items} />
      </section>
    </main>
  );
}

export function StatusPanelCompactItems({
  ariaHidden = false,
  items,
}: {
  ariaHidden?: boolean;
  items: StatusPanelCompactItem[];
}) {
  return (
    <div aria-hidden={ariaHidden || undefined} className="status-indicator-compact-items">
      {items.map((item) => <CompactItem item={item} key={item.id} />)}
    </div>
  );
}

function CompactItem({ item }: { item: StatusPanelCompactItem }) {
  if (item.compactRows) {
    return (
      <strong aria-label={item.shortLabel} className="status-indicator-ranking">
        <span aria-hidden="true">{item.compactRows[0]}</span>
        <span aria-hidden="true">{item.compactRows[1]}</span>
      </strong>
    );
  }

  if (item.compactMarker) {
    return (
      <strong aria-label={item.shortLabel} className="status-indicator-quota-item">
        <span aria-hidden="true" className="status-indicator-quota-marker">
          <span>{item.compactMarker.top}</span>
          <span>{item.compactMarker.bottom}</span>
        </span>
        <span aria-hidden="true" className="status-indicator-quota-value">{item.value}</span>
      </strong>
    );
  }

  return <strong>{item.shortLabel}</strong>;
}

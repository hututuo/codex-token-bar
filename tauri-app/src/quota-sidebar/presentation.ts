/** Hidden details retain the newest reference without serializing/broadcasting it. */
export function createSidebarPublisher<T>(send: (value: T) => void) {
  let latest: T | null = null;
  let visible = false;
  let sent: T | null = null;
  return {
    update(value: T, nextVisible: boolean) {
      latest = value;
      if (!nextVisible) { visible = false; sent = null; return; }
      const changed = !visible || sent !== value;
      visible = true;
      if (changed) { sent = value; send(value); }
    },
    ready() { if (visible && latest !== null) { sent = latest; send(latest); } },
  };
}
export function sidebarVisualPercent(percent: number | null): number | null {
  return percent === null || !Number.isFinite(percent) ? null : Math.min(100, Math.max(0, Math.round(percent)));
}

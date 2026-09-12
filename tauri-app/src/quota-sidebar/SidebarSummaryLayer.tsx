import { useEffect, useState, type ReactNode } from "react";
import { flashSidebarButton } from "./meterFeedback";

// CSS fades the outer layer for 220ms. Keep outgoing children until it ends;
// the bounded fallback also retires them when WebKit suppresses transitionend.
export const SIDEBAR_SUMMARY_RETIRE_MS = 320;

export function SidebarSummaryLayer({ visible, children }: {
  visible: boolean;
  children: () => ReactNode;
}) {
  const [retained, setRetained] = useState(visible);
  useEffect(() => {
    if (visible) {
      setRetained(true);
      return;
    }
    if (!retained) return;
    const timer = setTimeout(() => setRetained(false), SIDEBAR_SUMMARY_RETIRE_MS);
    return () => clearTimeout(timer);
  }, [visible, retained]);

  return <div className="qs-summary" data-visible={visible} aria-hidden={!visible} inert={!visible}
    onClickCapture={event => flashSidebarButton(event.target)}
    onTransitionEnd={event => {
      if (!visible && event.target === event.currentTarget && event.propertyName === "opacity") {
        setRetained(false);
      }
    }}>
    {/* Render lazily: hidden snapshots never build or reconcile the ring tree.
        Reopening mounts current values in the same commit as revealing it. */}
    {(visible || retained) ? children() : null}
  </div>;
}

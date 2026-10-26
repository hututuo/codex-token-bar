import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import type { SidebarContentMeasurement } from "./contentSizing";
import { flashSidebarButton } from "./meterFeedback";

export function measureSidebarSummary(root: HTMLElement): SidebarContentMeasurement {
  const intrinsicHeight = (container: HTMLElement) => {
    const children = [...container.children] as HTMLElement[];
    const visible = children.filter(child => getComputedStyle(child).display !== "none");
    const gap = Number.parseFloat(getComputedStyle(container).rowGap) || 0;
    return visible.reduce((sum, child) => sum + child.getBoundingClientRect().height, 0) + gap * Math.max(0, visible.length - 1);
  };
  const stack = root.querySelector<HTMLElement>(".qs-module-stack");
  const contentHeight = stack
    ? intrinsicHeight(stack) + (root.querySelector(".qs-rail-actions")?.getBoundingClientRect().height ?? 0)
      + (root.querySelector(".qs-settings-trigger")?.getBoundingClientRect().height ?? 0)
      + 2 * (Number.parseFloat(getComputedStyle(root).rowGap) || 0)
    : intrinsicHeight(root);
  const row = root.querySelector<HTMLElement>(".qs-model-speed-block");
  return { contentHeight, speedRowHeight: row ? row.getBoundingClientRect().height + 4 : 40 };
}

// CSS fades in over the 440ms reveal and out over the 180ms collapse. Keep outgoing children until it ends;
// the bounded fallback also retires them when WebKit suppresses transitionend.
export const SIDEBAR_SUMMARY_RETIRE_MS = 320;

export function SidebarSummaryLayer({ visible, scrollable = false, reminder = false, onMeasure, children }: {
  visible: boolean;
  scrollable?: boolean;
  reminder?: boolean;
  children: () => ReactNode;
  onMeasure?: (measurement: SidebarContentMeasurement) => void;
}) {
  const [retained, setRetained] = useState(visible);
  const element = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const root = element.current;
    if (!root || !visible || reminder || !onMeasure) return;
    let frame: number | undefined;
    const measure = () => {
      frame = undefined;
      const measurement = measureSidebarSummary(root);
      if (measurement.contentHeight > 0) onMeasure(measurement);
    };
    const schedule = () => { if (frame === undefined) frame = requestAnimationFrame(measure); };
    const resize = new ResizeObserver(schedule);
    const observe = () => {
      resize.disconnect(); [...root.children].forEach(child => resize.observe(child));
      const stack = root.querySelector(".qs-module-stack"); if (stack) resize.observe(stack);
      schedule();
    };
    const mutations = new MutationObserver(observe);
    mutations.observe(root, { childList: true });
    const stack = root.querySelector(".qs-module-stack"); if (stack) mutations.observe(stack, { childList: true });
    observe();
    return () => { resize.disconnect(); mutations.disconnect(); if (frame !== undefined) cancelAnimationFrame(frame); };
  }, [visible, reminder, onMeasure]);
  useEffect(() => {
    if (visible) {
      setRetained(true);
      return;
    }
    if (!retained) return;
    const timer = setTimeout(() => setRetained(false), SIDEBAR_SUMMARY_RETIRE_MS);
    return () => clearTimeout(timer);
  }, [visible, retained]);

  return <div ref={element} className="qs-summary" data-scrollable={scrollable} data-reminder={reminder} data-visible={visible} aria-hidden={!visible} inert={!visible}
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

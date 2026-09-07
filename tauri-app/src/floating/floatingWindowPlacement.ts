import type { DockRect } from "./floatingEdgeDock";

export type FloatingRunningModelDetailsPlacement = "above" | "below";
export interface FloatingDetailsDrawerLayout {
  placement: FloatingRunningModelDetailsPlacement;
  frame: DockRect;
  detailsHeight: number;
  surfaceOffsetY: number;
}

/** All inputs use one coordinate space (physical pixels in the native caller). */
export function resolveFloatingDetailsDrawer({ base, workArea, detailsHeight, gap = 8, inset = 4, margin = 0, minimumDetailsHeight = 96 }: {
  base: DockRect; workArea: DockRect; detailsHeight: number; gap?: number; inset?: number; margin?: number; minimumDetailsHeight?: number;
}): FloatingDetailsDrawerLayout {
  const below = Math.max(0, workArea.y + workArea.height - margin - base.y - base.height);
  const above = Math.max(0, base.y - workArea.y - margin);
  const wanted = Math.max(0, detailsHeight) + gap + inset;
  const placement = below >= wanted ? "below" : above >= wanted ? "above" : below >= above ? "below" : "above";
  // Preserve the original card whenever either side can fit a usable drawer.
  // On very short displays allow a clamped shift and keep the details scrollable.
  const available = Math.max(above, below);
  const extra = Math.min(wanted, Math.max(0, workArea.height - 2 * margin - base.height),
    Math.max(Math.min(wanted, minimumDetailsHeight + gap + inset), available));
  const height = base.height + extra;
  const minY = workArea.y + margin;
  const maxY = Math.max(minY, workArea.y + workArea.height - margin - height);
  const y = Math.min(maxY, Math.max(minY, base.y - (placement === "above" ? extra : 0)));
  return {
    placement,
    frame: { x: base.x, y, width: base.width, height },
    detailsHeight: Math.max(0, extra - gap - inset),
    surfaceOffsetY: placement === "above" ? extra : 0,
  };
}

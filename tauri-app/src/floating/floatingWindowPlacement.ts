import type { DockRect } from "./floatingEdgeDock";

export function floatingDockShellMetrics({ width, mainHeight, scale }: {
  width: number; mainHeight: number; scale: number;
}) {
  const paddingY = 6 * scale;
  const height = mainHeight + 2 * paddingY;
  const contentScale = Math.max(0.8, (width - 10) / width);
  const insetX = (width - (width - 2) * contentScale) / 2;
  const insetY = (height - mainHeight * contentScale) / 2;
  const innerRadius = 14 * scale * contentScale;
  return { height, paddingY, contentScale,
    contentOffsetY: height * (1 - contentScale) / 2,
    radiusX: innerRadius + insetX, radiusY: innerRadius + insetY };
}

export type FloatingRunningModelDetailsPlacement = "above" | "below" | "leading" | "trailing";
export interface FloatingDetailsDrawerLayout {
  placement: FloatingRunningModelDetailsPlacement;
  frame: DockRect;
  detailsHeight: number;
  surfaceOffsetY: number;
  surfaceOffsetX: number;
}

/** All inputs use one coordinate space (physical pixels in the native caller). */
export function resolveFloatingDetailsDrawer({ base, workArea, detailsHeight, gap = 8, inset = 4, margin = 0, minimumDetailsHeight = 96, attached = true, detailsWidth = 260 }: {
  base: DockRect; workArea: DockRect; detailsHeight: number; gap?: number; inset?: number; margin?: number; minimumDetailsHeight?: number; attached?: boolean; detailsWidth?: number;
}): FloatingDetailsDrawerLayout {
  if (!attached) {
    const extra = detailsWidth + gap + inset;
    const right = Math.max(0, workArea.x + workArea.width - margin - base.x - base.width);
    const left = Math.max(0, base.x - workArea.x - margin);
    const placement = right >= extra ? "trailing" : left >= extra ? "leading" : right >= left ? "trailing" : "leading";
    const width = base.width + extra;
    const height = Math.min(workArea.height - 2 * margin, Math.max(base.height, detailsHeight));
    const x = Math.min(Math.max(workArea.x + margin, workArea.x + workArea.width - margin - width),
      Math.max(workArea.x + margin, base.x - (placement === "leading" ? extra : 0)));
    const y = Math.min(Math.max(workArea.y + margin, workArea.y + workArea.height - margin - height), Math.max(workArea.y + margin, base.y));
    return { placement, frame: { x, y, width, height }, detailsHeight: height,
      surfaceOffsetY: 0, surfaceOffsetX: placement === "leading" ? extra : 0 };
  }
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
    surfaceOffsetX: 0,
  };
}

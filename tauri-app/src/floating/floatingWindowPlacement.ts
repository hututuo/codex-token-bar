export type FloatingRunningModelDetailsPlacement = "leading" | "trailing";

export interface FloatingDetailsPlacementInput {
  windowLeft: number;
  surfaceWidth: number;
  expandedWidth: number;
  workAreaLeft: number;
  workAreaRight: number;
  margin?: number;
}

export function runningModelDetailsPlacement({
  windowLeft,
  surfaceWidth,
  expandedWidth,
  workAreaLeft,
  workAreaRight,
  margin = 8,
}: FloatingDetailsPlacementInput): FloatingRunningModelDetailsPlacement {
  const extraWidth = Math.max(0, expandedWidth - surfaceWidth);
  if (extraWidth === 0) return "trailing";

  const windowRight = windowLeft + surfaceWidth;
  const trailingAvailable = Math.max(0, workAreaRight - windowRight);
  const leadingAvailable = Math.max(0, windowLeft - workAreaLeft);
  if (trailingAvailable >= extraWidth + margin) return "trailing";
  if (leadingAvailable >= extraWidth + margin) return "leading";
  return trailingAvailable >= leadingAvailable ? "trailing" : "leading";
}

export function floatingWindowLeftForDetails({
  baseLeft,
  surfaceWidth,
  expandedWidth,
  placement,
}: {
  baseLeft: number;
  surfaceWidth: number;
  expandedWidth: number;
  placement: FloatingRunningModelDetailsPlacement;
}): number {
  const extraWidth = Math.max(0, expandedWidth - surfaceWidth);
  return placement === "leading" ? baseLeft - extraWidth : baseLeft;
}

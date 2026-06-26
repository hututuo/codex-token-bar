export interface CalloutAnchorRect {
  left: number;
  top: number;
  bottom: number;
}

export interface CalloutViewport {
  width: number;
  height: number;
}

export interface CalloutPlacementOptions {
  width: number;
  estimatedHeight: number;
  margin?: number;
  gap?: number;
}

export interface CalloutFrame {
  left: number;
  top: number;
  width: number;
  maxHeight: number;
}

export function computeBoundedSettingsCalloutFrame(
  anchor: CalloutAnchorRect,
  viewport: CalloutViewport,
  options: CalloutPlacementOptions,
): CalloutFrame {
  const margin = options.margin ?? 16;
  const gap = options.gap ?? 8;
  const availableWidth = Math.max(180, viewport.width - margin * 2);
  const width = Math.min(options.width, availableWidth);
  const maxLeft = Math.max(margin, viewport.width - width - margin);
  const left = clamp(anchor.left - 4, margin, maxLeft);

  const belowTop = anchor.bottom + gap;
  const aboveTop = anchor.top - options.estimatedHeight - gap;
  const fitsBelow = belowTop + options.estimatedHeight <= viewport.height - margin;
  const fitsAbove = aboveTop >= margin;
  const preferredTop = fitsBelow || !fitsAbove ? belowTop : aboveTop;
  const maxTop = Math.max(margin, viewport.height - options.estimatedHeight - margin);
  const top = clamp(preferredTop, margin, maxTop);
  const maxHeight = Math.max(180, viewport.height - top - margin);

  return {
    left,
    top,
    width,
    maxHeight,
  };
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}

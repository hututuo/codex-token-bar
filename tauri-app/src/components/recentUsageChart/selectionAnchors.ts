import { clickQuotaSelection, type QuotaSelectionState } from "./model";

interface SelectionAxis {
  bucketSeconds: number;
  points: readonly { startUnix: number }[];
}

/** Pin dates, not rolling-array offsets: equal-length refreshes can move the axis. */
export interface QuotaSelectionAnchors {
  startUnix: number | null;
  fixedEndUnix: number | null;
  bucketSeconds: number | null;
}

export const EMPTY_QUOTA_SELECTION: QuotaSelectionAnchors = {
  startUnix: null, fixedEndUnix: null, bucketSeconds: null,
};

function indexAtTime(axis: SelectionAxis, unix: number): number | null {
  let low = 0, high = axis.points.length - 1;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2), value = axis.points[middle].startUnix;
    if (value === unix) return middle;
    if (value < unix) low = middle + 1;
    else high = middle - 1;
  }
  return null;
}

export function quotaSelectionIndices(anchors: QuotaSelectionAnchors, axis: SelectionAxis): QuotaSelectionState {
  const empty = { startIndex: null, fixedEndIndex: null };
  if (anchors.startUnix === null || anchors.bucketSeconds !== axis.bucketSeconds) return empty;
  const startIndex = indexAtTime(axis, anchors.startUnix);
  const fixedEndIndex = anchors.fixedEndUnix === null ? null : indexAtTime(axis, anchors.fixedEndUnix);
  if (startIndex === null || (anchors.fixedEndUnix !== null && fixedEndIndex === null)) return empty;
  return { startIndex, fixedEndIndex };
}

export function clickQuotaSelectionAnchor(anchors: QuotaSelectionAnchors, index: number,
  axis: SelectionAxis): QuotaSelectionAnchors {
  if (!Number.isInteger(index) || index < 0 || index >= axis.points.length) return anchors;
  const next = clickQuotaSelection(quotaSelectionIndices(anchors, axis), index, axis.points.length);
  return { startUnix: next.startIndex === null ? null : axis.points[next.startIndex].startUnix,
    fixedEndUnix: next.fixedEndIndex === null ? null : axis.points[next.fixedEndIndex].startUnix,
    bucketSeconds: axis.bucketSeconds };
}

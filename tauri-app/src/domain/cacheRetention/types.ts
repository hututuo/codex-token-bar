/**
 * A qualified cache-retention pair. Integer fields stay in microseconds or
 * token counts; callers must provide values that JavaScript can represent
 * exactly as safe integers.
 */
export interface CacheRetentionPoint {
  id: string;
  sourceKey: string;
  sessionKey: string;
  model: string;
  gapMicroseconds: number;
  startedAtMicroseconds: number;
  previousInput: number;
  previousCached: number;
  input: number;
  cached: number;
}

export type CacheRetentionState =
  | "insufficient"
  | "range_too_large"
  | "small_sample"
  | "ready"
  | "not_detected";

export interface CacheRetentionSegment {
  count: number;
  highCount: number;
  rate: number;
}

export interface CacheRetentionEarlierDecline {
  microseconds: number;
  leftMicroseconds: number;
  rightMicroseconds: number;
  count: number;
  segments: CacheRetentionSegment[];
  searchMode: string;
}

/** The JSON-compatible shape of Swift CacheRetentionAnalysis. */
export interface CacheRetentionAnalysis {
  count: number;
  highCount: number;
  p95Microseconds: number | null;
  p95CoverageCount: number | null;
  dropMicroseconds: number | null;
  dropLeftMicroseconds: number | null;
  dropRightMicroseconds: number | null;
  p95State: CacheRetentionState;
  dropState: CacheRetentionState;
  segments: CacheRetentionSegment[];
  bestSegments: number | null;
  searchMode: string;
  earlierDecline: CacheRetentionEarlierDecline | null;
}

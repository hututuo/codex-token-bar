import type {
  CacheRetentionAnalysis,
  CacheRetentionEarlierDecline,
  CacheRetentionPoint,
  CacheRetentionSegment,
  CacheRetentionState,
} from "./types.ts";

const MAXIMUM_COUNT = 100_000;
const MINIMUM_HIGH_COUNT = 20;
const MINIMUM_SEGMENT_COUNT = 20;
const EXACT_CUT_LIMIT = 512;
const CANDIDATE_GRID_DIVISOR = 513;

interface TieGroup {
  gap: number;
  count: number;
  highCount: number;
}

interface Fit {
  logLikelihood: number;
  cuts: number[];
}

interface SegmentStats {
  count: number;
  highCount: number;
  rate: number;
  logLikelihood: number;
}

function isHighReuse(point: CacheRetentionPoint): boolean {
  // Keep the native integer threshold: for a positive input, at least 80%
  // reuse means cached >= input - floor(input / 5), without floating point.
  return point.cached >= point.input - Math.floor(point.input / 5);
}

function validatePoints(points: CacheRetentionPoint[]): void {
  if (!Array.isArray(points)) {
    throw new TypeError("cache-retention points must be an array");
  }

  const integerFields = [
    "gapMicroseconds",
    "startedAtMicroseconds",
    "previousInput",
    "previousCached",
    "input",
    "cached",
  ] as const;
  for (const point of points) {
    if (point === null || typeof point !== "object") {
      throw new TypeError("each cache-retention point must be an object");
    }
    for (const field of integerFields) {
      if (!Number.isSafeInteger(point[field])) {
        throw new RangeError(`${field} must be a safe integer`);
      }
    }
  }
}

/** Pure, deterministic analysis of already-qualified cache-retention pairs. */
export function calculateCacheRetention(points: CacheRetentionPoint[]): CacheRetentionAnalysis {
  validatePoints(points);
  const result = fit(points);
  if (result.dropMicroseconds === null || result.dropLeftMicroseconds === null) {
    return result;
  }

  const prefix = points.filter((point) => point.gapMicroseconds <= result.dropLeftMicroseconds!);
  const earlier = fit(prefix, true);
  if (
    earlier.dropMicroseconds !== null
    && earlier.dropMicroseconds < result.dropMicroseconds
    && earlier.dropLeftMicroseconds !== null
    && earlier.dropRightMicroseconds !== null
  ) {
    const earlierDecline: CacheRetentionEarlierDecline = {
      microseconds: earlier.dropMicroseconds,
      leftMicroseconds: earlier.dropLeftMicroseconds,
      rightMicroseconds: earlier.dropRightMicroseconds,
      count: prefix.length,
      segments: earlier.segments,
      searchMode: earlier.searchMode,
    };
    result.earlierDecline = earlierDecline;
  }
  return result;
}

function fit(points: CacheRetentionPoint[], earlierSearch = false): CacheRetentionAnalysis {
  const count = points.length;
  const highCount = points.reduce((total, point) => total + (isHighReuse(point) ? 1 : 0), 0);

  if (count > MAXIMUM_COUNT) {
    return emptyAnalysis(count, highCount, "range_too_large", "range_too_large", "not_run");
  }

  let p95Microseconds: number | null = null;
  let p95CoverageCount: number | null = null;
  let p95State: CacheRetentionState = "insufficient";
  if (highCount >= MINIMUM_HIGH_COUNT) {
    const highGaps = points
      .filter(isHighReuse)
      .map((point) => point.gapMicroseconds)
      .sort((left, right) => left - right);
    // Nearest rank: ceil(0.95 * k), expressed with integer math.
    const rank = Math.floor((95 * highCount + 99) / 100);
    const value = highGaps[rank - 1];
    p95Microseconds = value;
    p95CoverageCount = upperBound(value, highGaps);
    p95State = highCount < 100 ? "small_sample" : "ready";
  }

  if (count < 40) {
    return {
      ...emptyAnalysis(count, highCount, p95State, "insufficient", "not_run"),
      p95Microseconds,
      p95CoverageCount,
    };
  }

  const groupsByGap = new Map<number, TieGroup>();
  for (const point of points) {
    const group = groupsByGap.get(point.gapMicroseconds);
    if (group) {
      group.count += 1;
      if (isHighReuse(point)) group.highCount += 1;
    } else {
      groupsByGap.set(point.gapMicroseconds, {
        gap: point.gapMicroseconds,
        count: 1,
        highCount: isHighReuse(point) ? 1 : 0,
      });
    }
  }
  const groups = [...groupsByGap.values()].sort((left, right) => left.gap - right.gap);
  const groupCount = groups.length;
  const prefixCounts = Array<number>(groupCount + 1).fill(0);
  const prefixHighCounts = Array<number>(groupCount + 1).fill(0);
  for (let index = 0; index < groupCount; index += 1) {
    prefixCounts[index + 1] = prefixCounts[index] + groups[index].count;
    prefixHighCounts[index + 1] = prefixHighCounts[index] + groups[index].highCount;
  }

  let searchMode = "exact";
  let candidateCuts = Array.from({ length: Math.max(0, groupCount - 1) }, (_, index) => index + 1);
  // Early advice searches every two-segment boundary; only its quadratic
  // three-segment search is bounded for unusually large histories.
  const fullResolutionLimit = earlierSearch ? 2_048 : EXACT_CUT_LIMIT;
  if (candidateCuts.length > fullResolutionLimit) {
    searchMode = earlierSearch ? "exact_two_bounded_three" : "bounded_candidate_grid";
    const candidates = new Set<number>();
    for (let gridIndex = 1; gridIndex <= EXACT_CUT_LIMIT; gridIndex += 1) {
      // ceil(gridIndex * n / 513), equivalent to the native lower bound
      // search without floating-point boundary drift.
      const targetCount = Math.floor(
        (gridIndex * count + CANDIDATE_GRID_DIVISOR - 1) / CANDIDATE_GRID_DIVISOR,
      );
      const insertion = lowerBound(targetCount, prefixCounts);
      candidates.add(Math.min(Math.max(insertion, 1), groupCount - 1));
    }
    candidateCuts = [...candidates].sort((left, right) => left - right);
  }

  function segmentStats(start: number, end: number): SegmentStats | null {
    const segmentCount = prefixCounts[end] - prefixCounts[start];
    if (segmentCount < MINIMUM_SEGMENT_COUNT) return null;
    const segmentHighCount = prefixHighCounts[end] - prefixHighCounts[start];
    const rate = segmentHighCount / segmentCount;
    let logLikelihood = 0;
    if (segmentHighCount > 0) {
      logLikelihood += segmentHighCount * Math.log(rate);
    }
    if (segmentCount > segmentHighCount) {
      logLikelihood += (segmentCount - segmentHighCount) * Math.log1p(-rate);
    }
    return {
      count: segmentCount,
      highCount: segmentHighCount,
      rate,
      logLikelihood,
    };
  }

  // The full range has at least 40 points, so the one-segment fit exists.
  const whole = segmentStats(0, groupCount)!;
  const fits = new Map<number, Fit>([[1, { logLikelihood: whole.logLikelihood, cuts: [] }]]);
  let hasSupportedTwoSegmentSplit = false;
  const twoSegmentCuts = earlierSearch
    ? Array.from({ length: Math.max(0, groupCount - 1) }, (_, index) => index + 1)
    : candidateCuts;

  for (const cut of twoSegmentCuts) {
    const left = segmentStats(0, cut);
    const right = segmentStats(cut, groupCount);
    if (!left || !right) continue;
    hasSupportedTwoSegmentSplit = true;
    if (left.rate < right.rate) continue;
    const logLikelihood = left.logLikelihood + right.logLikelihood;
    const current = fits.get(2);
    if (current && logLikelihood <= current.logLikelihood + 1e-12) continue;
    fits.set(2, { logLikelihood, cuts: [cut] });
  }

  for (let firstIndex = 0; firstIndex < candidateCuts.length; firstIndex += 1) {
    const firstCut = candidateCuts[firstIndex];
    const first = segmentStats(0, firstCut);
    if (!first) continue;
    for (let secondIndex = firstIndex + 1; secondIndex < candidateCuts.length; secondIndex += 1) {
      const secondCut = candidateCuts[secondIndex];
      const middle = segmentStats(firstCut, secondCut);
      const last = segmentStats(secondCut, groupCount);
      if (!middle || !last || first.rate < middle.rate || middle.rate < last.rate) continue;
      const logLikelihood = first.logLikelihood + middle.logLikelihood + last.logLikelihood;
      const current = fits.get(3);
      if (current && logLikelihood <= current.logLikelihood + 1e-12) continue;
      fits.set(3, { logLikelihood, cuts: [firstCut, secondCut] });
    }
  }

  if (!hasSupportedTwoSegmentSplit) {
    return {
      ...emptyAnalysis(count, highCount, p95State, "insufficient", searchMode),
      p95Microseconds,
      p95CoverageCount,
    };
  }

  const scores = new Map<number, number>();
  for (const [segmentCount, fitResult] of fits) {
    scores.set(
      segmentCount,
      -2 * fitResult.logLikelihood + (2 * fitResult.cuts.length + 1) * Math.log(count),
    );
  }
  const minimumScore = Math.min(...scores.values());
  const bestSegments = [...scores.keys()].sort((left, right) => left - right)
    .find((segmentCount) => scores.get(segmentCount)! <= minimumScore + 1e-10)!;
  let bestFit = fits.get(bestSegments)!;
  if (earlierSearch && bestSegments === 2) {
    // Equivalent-support profile: ΔBIC <= 2, then the largest rate decline.
    // This changes neither the sample minimum nor model selection penalties.
    const optimum = bestFit.logLikelihood;
    let largest = Number.NEGATIVE_INFINITY;
    for (const cut of twoSegmentCuts) {
      const left = segmentStats(0, cut), right = segmentStats(cut, groupCount);
      if (!left || !right || left.rate < right.rate) continue;
      const logLikelihood = left.logLikelihood + right.logLikelihood;
      if (2 * (optimum - logLikelihood) > 2 + 1e-10) continue;
      const decline = left.rate - right.rate;
      if (decline > largest + 1e-12) {
        largest = decline;
        bestFit = { logLikelihood, cuts: [cut] };
      }
    }
  }
  const boundaries = [0, ...bestFit.cuts, groupCount];
  const fittedSegments = boundaries.slice(0, -1).flatMap((start, index) => {
    const stats = segmentStats(start, boundaries[index + 1]);
    return stats ? [toSegment(stats)] : [];
  });

  let dropMicroseconds: number | null = null;
  let dropLeftMicroseconds: number | null = null;
  let dropRightMicroseconds: number | null = null;
  let dropState: CacheRetentionState = "not_detected";
  if (bestSegments > 1) {
    let largestDropIndex = 0;
    let largestDrop = fittedSegments[0].rate - fittedSegments[1].rate;
    for (let index = 1; index < fittedSegments.length - 1; index += 1) {
      const drop = fittedSegments[index].rate - fittedSegments[index + 1].rate;
      // Strict comparison preserves the earliest cut on a tie.
      if (drop > largestDrop) {
        largestDrop = drop;
        largestDropIndex = index;
      }
    }
    const cut = bestFit.cuts[largestDropIndex];
    const left = groups[cut - 1].gap;
    const right = groups[cut].gap;
    dropLeftMicroseconds = left;
    dropRightMicroseconds = right;
    dropMicroseconds = midpoint(left, right);
    dropState = "ready";
  }

  return {
    count,
    highCount,
    p95Microseconds,
    p95CoverageCount,
    dropMicroseconds,
    dropLeftMicroseconds,
    dropRightMicroseconds,
    p95State,
    dropState,
    segments: fittedSegments,
    bestSegments,
    searchMode,
    earlierDecline: null,
  };
}

function emptyAnalysis(
  count: number,
  highCount: number,
  p95State: CacheRetentionState,
  dropState: CacheRetentionState,
  searchMode: string,
): CacheRetentionAnalysis {
  return {
    count,
    highCount,
    p95Microseconds: null,
    p95CoverageCount: null,
    dropMicroseconds: null,
    dropLeftMicroseconds: null,
    dropRightMicroseconds: null,
    p95State,
    dropState,
    segments: [],
    bestSegments: null,
    searchMode,
    earlierDecline: null,
  };
}

function toSegment(stats: SegmentStats): CacheRetentionSegment {
  return { count: stats.count, highCount: stats.highCount, rate: stats.rate };
}

function upperBound(value: number, sortedValues: number[]): number {
  let lower = 0;
  let upper = sortedValues.length;
  while (lower < upper) {
    const middle = lower + Math.floor((upper - lower) / 2);
    if (sortedValues[middle] <= value) lower = middle + 1;
    else upper = middle;
  }
  return lower;
}

function lowerBound(value: number, sortedValues: number[]): number {
  let lower = 0;
  let upper = sortedValues.length;
  while (lower < upper) {
    const middle = lower + Math.floor((upper - lower) / 2);
    if (sortedValues[middle] < value) lower = middle + 1;
    else upper = middle;
  }
  return lower;
}

/** Computes the midpoint without adding the two microsecond values first. */
function midpoint(left: number, right: number): number {
  return left / 2 + right / 2;
}

export function formatRetentionMinutes(microseconds: number): string {
  const minutes = microseconds / 60_000_000;
  if (minutes < 1) {
    const seconds = microseconds / 1_000_000;
    // Swift's String(format: "%.0f") follows printf's default ties-to-even
    // rounding. Keep that detail separate from Swift Double.rounded() below,
    // which intentionally rounds the recommendation to a tenth away from 0.
    const absoluteSeconds = Math.abs(seconds);
    const wholeSeconds = Math.floor(absoluteSeconds);
    const fraction = absoluteSeconds - wholeSeconds;
    const roundedMagnitude = fraction < 0.5
      ? wholeSeconds
      : fraction > 0.5 || wholeSeconds % 2 === 1
        ? wholeSeconds + 1
        : wholeSeconds;
    const roundedSeconds = seconds < 0 ? -roundedMagnitude : roundedMagnitude;
    const secondsText = seconds < 0 && roundedMagnitude === 0
      ? "-0"
      : String(roundedSeconds);
    return `${secondsText} 秒`;
  }

  const roundedTenths = minutes * 10;
  const tenths = roundedTenths < 0
    ? Math.ceil(roundedTenths - 0.5)
    : Math.floor(roundedTenths + 0.5);
  return `${(tenths / 10).toFixed(1)} 分钟`;
}

export function formatRetentionRecommendation(analysis: CacheRetentionAnalysis): string {
  if (analysis.earlierDecline === null) {
    return analysis.dropMicroseconds === null
      ? "暂未找到可靠的续问时间建议"
      : "暂未找到更早的下降点";
  }
  return `建议尽量在约 ${formatRetentionMinutes(analysis.earlierDecline.microseconds)}内续问`;
}

export function formatRetentionCoverage(analysis: CacheRetentionAnalysis): string {
  if (analysis.p95State === "range_too_large") return "历史记录较多，请在图表中缩小范围";
  if (analysis.p95Microseconds === null) return "正在积累高命中历史";
  return `过去高命中的续问，95% 在约 ${formatRetentionMinutes(analysis.p95Microseconds)}内`;
}

export function formatRetentionRisk(analysis: CacheRetentionAnalysis): string {
  if (analysis.dropMicroseconds === null) return "暂未找到明显风险分界";
  return `超过约 ${formatRetentionMinutes(analysis.dropMicroseconds)}后，低命中更常见`;
}

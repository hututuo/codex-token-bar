import type { OfficialAPIPriceModel } from "../../settings/quotaPriceModel";
import type { SharedAccountRadarTier } from "../../settings/sharedAccountAttribution";
import type { RecentUsagePoint, RecentUsageSourceContribution } from "../../types/dashboard";

export const ATTRIBUTION_BUCKET_SECONDS = 5 * 60;
const STORAGE_PREFIX = "sharedAccountAttributionBuckets:v4";

export interface AttributionTokenContribution {
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  totalTokens: number;
  calls: number;
}

export interface AttributionTokenBucket extends AttributionTokenContribution {
  startUnix: number;
  sourceContributions?: Record<string, AttributionTokenContribution> | null;
  sourceTrackingComplete?: boolean;
}

export interface StoredAttributionBucketHighWater {
  buckets: Record<string, AttributionTokenBucket>;
  updatedAt: string;
  provenanceEpoch: string | null;
  metadataObservedAtUnix: number;
  coverageStartUnix: number;
  coverageEndUnix: number;
  ambiguityDetected: boolean;
  quotaObservationFresh: boolean;
}

export interface AttributionHighWaterIdentity {
  scopeKey: string;
  plan: string;
  limit: string;
  resetAtUnix: number;
  segmentStartUnix: number;
  tier: SharedAccountRadarTier;
  priceModel: OfficialAPIPriceModel;
}

export interface AttributionBucketMergeOptions {
  segmentStartUnix: number;
  resetAtUnix: number;
  /** Exclusive raw coverage cutoff, which may fall inside an open 5m bucket. */
  persistenceCutoffUnix: number;
  /** Exclusive aligned end that both exact usage and the quota snapshot cover. */
  comparisonEndUnix: number;
  metadataObservedAtUnix?: number;
  preciseCoveredAt?: string;
  quotaObservationFresh?: boolean;
}

export interface AttributionBucketMergeResult {
  record: StoredAttributionBucketHighWater;
  effectiveBuckets: AttributionTokenBucket[];
  scannedBuckets: AttributionTokenBucket[];
  hasPendingUsage: boolean;
  usedHistoricalHighWater: boolean;
  ambiguityDetected: boolean;
  quotaObservationFresh: boolean;
  changed: boolean;
}

export interface AttributionHighWaterReadState {
  healthy: boolean;
  record: StoredAttributionBucketHighWater | null;
}

export interface AttributionHighWaterPruneResult {
  healthy: boolean;
  removed: string[];
}

export function attributionHighWaterStorageKey(identity: AttributionHighWaterIdentity): string {
  return [
    STORAGE_PREFIX,
    encodeURIComponent(identity.scopeKey),
    encodeURIComponent(identity.plan),
    encodeURIComponent(identity.limit),
    Math.round(identity.resetAtUnix),
    Math.round(identity.segmentStartUnix),
  ].join(":");
}

export function completedBucketEndBoundary(unix: number): number {
  return Math.floor(unix / ATTRIBUTION_BUCKET_SECONDS) * ATTRIBUTION_BUCKET_SECONDS;
}

export function readAttributionHighWater(
  key: string,
  storage?: Pick<Storage, "getItem"> | null,
): StoredAttributionBucketHighWater | null {
  return readAttributionHighWaterState(key, storage).record;
}

export function readAttributionHighWaterState(
  key: string,
  storage?: Pick<Storage, "getItem"> | null,
): AttributionHighWaterReadState {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target) return { healthy: true, record: null };
  try {
    const stored = target.getItem(key);
    if (stored === null) return { healthy: true, record: null };
    const raw = JSON.parse(stored) as Partial<StoredAttributionBucketHighWater> | null;
    if (!raw || !raw.buckets || typeof raw.buckets !== "object" || Array.isArray(raw.buckets)) {
      return { healthy: false, record: null };
    }
    const buckets: Record<string, AttributionTokenBucket> = {};
    for (const [bucketKey, candidate] of Object.entries(raw.buckets)) {
      const normalized = normalizeStoredBucket(candidate);
      if (!normalized || String(normalized.startUnix) !== bucketKey) {
        return { healthy: false, record: null };
      }
      buckets[bucketKey] = normalized;
    }
    const starts = Object.values(buckets).map((bucket) => bucket.startUnix);
    const inferredStart = starts.length > 0 ? Math.min(...starts) : 0;
    const inferredEnd = starts.length > 0
      ? Math.max(...starts) + ATTRIBUTION_BUCKET_SECONDS
      : inferredStart;
    if ((raw.updatedAt !== undefined && typeof raw.updatedAt !== "string")
      || (raw.provenanceEpoch !== undefined
        && raw.provenanceEpoch !== null
        && (typeof raw.provenanceEpoch !== "string" || !raw.provenanceEpoch.trim()))
      || !optionalFiniteNonnegative(raw.metadataObservedAtUnix)
      || !optionalFinite(raw.coverageStartUnix)
      || !optionalFinite(raw.coverageEndUnix)
      || (raw.ambiguityDetected !== undefined && typeof raw.ambiguityDetected !== "boolean")
      || (raw.quotaObservationFresh !== undefined && typeof raw.quotaObservationFresh !== "boolean")) {
      return { healthy: false, record: null };
    }
    const record: StoredAttributionBucketHighWater = {
      buckets,
      updatedAt: typeof raw.updatedAt === "string" ? raw.updatedAt : "",
      provenanceEpoch: typeof raw.provenanceEpoch === "string" ? raw.provenanceEpoch : null,
      metadataObservedAtUnix: finiteNonnegative(raw.metadataObservedAtUnix ?? 0),
      coverageStartUnix: finiteNumber(raw.coverageStartUnix, inferredStart),
      coverageEndUnix: finiteNumber(raw.coverageEndUnix, inferredEnd),
      ambiguityDetected: raw.ambiguityDetected === true,
      quotaObservationFresh: raw.quotaObservationFresh === true,
    };
    if (record.coverageStartUnix > record.coverageEndUnix) {
      return { healthy: false, record: null };
    }
    return { healthy: true, record };
  } catch {
    return { healthy: false, record: null };
  }
}

export function writeAttributionHighWater(
  key: string,
  record: StoredAttributionBucketHighWater,
  storage?: Pick<Storage, "getItem" | "setItem"> | null,
): boolean {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target) return false;
  try {
    target.setItem(key, JSON.stringify(record));
    return JSON.stringify(readAttributionHighWaterState(key, target).record) === JSON.stringify(record);
  } catch {
    return false;
  }
}

/** Retains every segment belonging to only the newest two reset cycles per scope. */
export function pruneAttributionHighWaterCycles(
  identity: Pick<AttributionHighWaterIdentity, "scopeKey" | "plan" | "limit">,
  storage?: Pick<Storage, "key" | "length" | "removeItem"> | null,
): AttributionHighWaterPruneResult {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target) return { healthy: false, removed: [] };
  const scopePrefix = [
    STORAGE_PREFIX,
    encodeURIComponent(identity.scopeKey),
    encodeURIComponent(identity.plan),
    encodeURIComponent(identity.limit),
  ].join(":") + ":";
  let scoped: { key: string; resetAtUnix: number }[];
  try {
    scoped = Array.from({ length: target.length }, (_, index) => target.key(index))
      .filter((key): key is string => key !== null && key.startsWith(scopePrefix))
      .map((key) => ({ key, resetAtUnix: resetAtUnixFromStorageKey(key) }))
      .filter((item): item is { key: string; resetAtUnix: number } => item.resetAtUnix !== null);
  } catch {
    return { healthy: false, removed: [] };
  }
  const retainedResets = new Set(
    [...new Set(scoped.map((item) => item.resetAtUnix))]
      .sort((left, right) => right - left)
      .slice(0, 2),
  );
  const removed: string[] = [];
  let healthy = true;
  for (const item of scoped) {
    if (retainedResets.has(item.resetAtUnix)) continue;
    try {
      target.removeItem(item.key);
      removed.push(item.key);
    } catch {
      healthy = false;
    }
  }
  return { healthy, removed };
}

export function mergeAttributionBucketHighWater(
  stored: StoredAttributionBucketHighWater | null,
  points: RecentUsagePoint[],
  options: AttributionBucketMergeOptions,
  now: Date = new Date(),
): AttributionBucketMergeResult {
  // A provider reset is not guaranteed to align to our fixed five-minute
  // buckets. Include the whole bucket that straddles the lower cycle/segment
  // boundary: assigning the overlap to this machine is deliberately
  // conservative (never understates local use and therefore never inflates the
  // inferred "other" share). Synthetic account-switch cutovers are already
  // rounded upward, so they do not pull pre-switch usage back in.
  const conservativeStartUnix = Math.floor(
    options.segmentStartUnix / ATTRIBUTION_BUCKET_SECONDS,
  ) * ATTRIBUTION_BUCKET_SECONDS;
  const existing = stored?.buckets ?? {};
  const nextBuckets = { ...existing };
  const observedByStart = new Map<number, AttributionTokenBucket>();
  let hasPendingUsage = false;
  let bucketChanged = false;
  let ambiguityDetected = stored?.ambiguityDetected ?? false;
  const observedEpochs = new Set(points
    .map((point) => point.sourceContributionEpoch?.trim() ?? "")
    .filter(Boolean));
  const observedProvenanceEpoch = observedEpochs.size === 1
    ? [...observedEpochs][0]
    : null;
  const storedHasUsage = Object.values(existing).some(bucketHasUsage);
  const provenanceCompatible = observedEpochs.size <= 1
    && (!storedHasUsage
      || (stored?.provenanceEpoch !== null
        && stored?.provenanceEpoch !== undefined
        && observedProvenanceEpoch === stored.provenanceEpoch));
  if (observedEpochs.size > 1
    || (storedHasUsage && !provenanceCompatible)) {
    ambiguityDetected = true;
  }

  for (const point of points) {
    const bucket = tokenBucketFromPoint(point);
    if (!bucket
      || bucket.startUnix < conservativeStartUnix
      || bucket.startUnix >= options.resetAtUnix) continue;
    if (bucket.startUnix >= options.persistenceCutoffUnix) {
      if (bucketHasUsage(bucket)) hasPendingUsage = true;
      continue;
    }
    observedByStart.set(bucket.startUnix, bucket);
    const key = String(bucket.startUnix);
    const previous = existing[key] ?? null;
    if (!bucketHasUsage(bucket) && !previous) continue;
    const merged = mergeBucketContributions(previous, bucket, provenanceCompatible);
    ambiguityDetected ||= merged.ambiguityDetected;
    if (!sameBucket(previous, merged.bucket)) {
      if (bucketHasUsage(merged.bucket)) nextBuckets[key] = merged.bucket;
      bucketChanged = true;
    }
  }

  const effectiveBuckets: AttributionTokenBucket[] = [];
  let usedHistoricalHighWater = false;
  for (const bucket of Object.values(nextBuckets).sort((left, right) => left.startUnix - right.startUnix)) {
    if (bucket.startUnix < conservativeStartUnix || bucket.startUnix >= options.resetAtUnix) continue;
    if (bucket.startUnix >= options.comparisonEndUnix) {
      if (bucketHasUsage(bucket)) hasPendingUsage = true;
      continue;
    }
    effectiveBuckets.push(bucket);
    if (!sameBucket(observedByStart.get(bucket.startUnix) ?? null, bucket)) {
      usedHistoricalHighWater = true;
    }
  }

  const metadataObservedAtUnix = finiteNonnegative(options.metadataObservedAtUnix ?? 0);
  const quotaObservationFresh = options.quotaObservationFresh === true;
  const updatedAt = latestTimestamp(
    stored?.updatedAt ?? "",
    options.preciseCoveredAt ?? now.toISOString(),
  );
  const coverageStartUnix = stored === null
    ? options.segmentStartUnix
    : Math.min(stored.coverageStartUnix, options.segmentStartUnix);
  const coverageEndUnix = stored === null
    ? options.persistenceCutoffUnix
    : Math.max(stored.coverageEndUnix, options.persistenceCutoffUnix);
  const previousMetadataObservedAtUnix = stored?.metadataObservedAtUnix ?? 0;
  const quotaFreshnessAtLatestObservation = stored === null
    || metadataObservedAtUnix > previousMetadataObservedAtUnix
    ? quotaObservationFresh
    : metadataObservedAtUnix === previousMetadataObservedAtUnix
      ? stored.quotaObservationFresh || quotaObservationFresh
      : stored.quotaObservationFresh;
  const record: StoredAttributionBucketHighWater = {
    buckets: nextBuckets,
    updatedAt,
    provenanceEpoch: storedHasUsage
      ? stored?.provenanceEpoch ?? observedProvenanceEpoch
      : observedProvenanceEpoch ?? stored?.provenanceEpoch ?? null,
    metadataObservedAtUnix: Math.max(stored?.metadataObservedAtUnix ?? 0, metadataObservedAtUnix),
    coverageStartUnix,
    coverageEndUnix,
    ambiguityDetected,
    quotaObservationFresh: quotaFreshnessAtLatestObservation,
  };
  const metadataChanged = stored === null
    ? true
    : !sameRecordMetadata(stored, record);

  return {
    record,
    effectiveBuckets,
    scannedBuckets: [...observedByStart.values()]
      .filter((bucket) => bucketHasUsage(bucket) && bucket.startUnix < options.comparisonEndUnix)
      .sort((left, right) => left.startUnix - right.startUnix),
    hasPendingUsage,
    usedHistoricalHighWater,
    ambiguityDetected,
    quotaObservationFresh,
    changed: bucketChanged || metadataChanged,
  };
}

function tokenBucketFromPoint(point: RecentUsagePoint): AttributionTokenBucket | null {
  if (!Number.isFinite(point.startUnix)) return null;
  const inputTokens = finiteNonnegative(point.inputTokens);
  const bucket: AttributionTokenBucket = {
    startUnix: Math.round(point.startUnix),
    inputTokens,
    cachedInputTokens: Math.min(finiteNonnegative(point.cachedInputTokens), inputTokens),
    outputTokens: finiteNonnegative(point.outputTokens),
    totalTokens: finiteNonnegative(point.tokens),
    calls: finiteNonnegative(point.calls),
    sourceContributions: null,
    sourceTrackingComplete: false,
  };
  if (!Array.isArray(point.sourceContributions)) return bucket;
  if (typeof point.sourceContributionEpoch !== "string"
    || !point.sourceContributionEpoch.trim()) return bucket;
  const sourceContributions = normalizePointContributions(point.sourceContributions);
  if (sourceContributions === null) return bucket;
  const aggregate = aggregateContributions(sourceContributions);
  // The durable ledger may legitimately exceed the current chart after a
  // source file is deleted, but it must never be smaller than the chart built
  // from the currently visible events. A smaller sparse aggregate proves that
  // source coverage is incomplete, so retain the chart total as a diagnostic
  // high-water and fail closed through the aggregate-only path.
  if (!contributionDominates(aggregate, bucket)) return bucket;
  return {
    startUnix: bucket.startUnix,
    ...aggregate,
    sourceContributions,
    sourceTrackingComplete: true,
  };
}

function contributionDominates(
  candidate: AttributionTokenContribution,
  lowerBound: AttributionTokenContribution,
): boolean {
  return candidate.inputTokens >= lowerBound.inputTokens
    && candidate.cachedInputTokens >= lowerBound.cachedInputTokens
    && candidate.outputTokens >= lowerBound.outputTokens
    && candidate.totalTokens >= lowerBound.totalTokens
    && candidate.calls >= lowerBound.calls;
}

function normalizePointContributions(
  values: RecentUsageSourceContribution[],
): Record<string, AttributionTokenContribution> | null {
  const result: Record<string, AttributionTokenContribution> = {};
  for (const value of values) {
    if (!value || typeof value.sourceId !== "string" || !value.sourceId.trim()) return null;
    if (!validNonnegative(value.inputTokens)
      || !validNonnegative(value.cachedInputTokens)
      || !validNonnegative(value.outputTokens)
      || !validNonnegative(value.tokens)
      || !validNonnegative(value.calls)) return null;
    const inputTokens = value.inputTokens;
    const contribution: AttributionTokenContribution = {
      inputTokens,
      cachedInputTokens: Math.min(value.cachedInputTokens, inputTokens),
      outputTokens: value.outputTokens,
      totalTokens: value.tokens,
      calls: value.calls,
    };
    result[value.sourceId] = result[value.sourceId]
      ? addContributions(result[value.sourceId], contribution)
      : contribution;
  }
  return result;
}

function normalizeStoredBucket(value: unknown): AttributionTokenBucket | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<AttributionTokenBucket>;
  if (typeof candidate.startUnix !== "number" || !Number.isFinite(candidate.startUnix)
    || !validNonnegative(candidate.inputTokens)
    || !validNonnegative(candidate.cachedInputTokens)
    || !validNonnegative(candidate.outputTokens)
    || !validNonnegative(candidate.totalTokens)
    || !validNonnegative(candidate.calls)) return null;
  const inputTokens = candidate.inputTokens;
  const sourceContributions = normalizeStoredContributions(candidate.sourceContributions);
  const sourceTrackingComplete = candidate.sourceTrackingComplete === true
    && sourceContributions !== null;
  if (candidate.sourceTrackingComplete !== undefined
    && typeof candidate.sourceTrackingComplete !== "boolean") return null;
  if (candidate.sourceTrackingComplete === true && sourceContributions === null) return null;
  if (candidate.sourceTrackingComplete !== true
    && candidate.sourceContributions !== undefined
    && candidate.sourceContributions !== null) return null;
  const normalized: AttributionTokenBucket = {
    startUnix: Math.round(candidate.startUnix),
    inputTokens,
    cachedInputTokens: Math.min(candidate.cachedInputTokens, inputTokens),
    outputTokens: candidate.outputTokens,
    totalTokens: candidate.totalTokens,
    calls: candidate.calls,
    sourceContributions: sourceTrackingComplete ? sourceContributions : null,
    sourceTrackingComplete,
  };
  if (sourceTrackingComplete
    && !sameContribution(aggregateContributions(sourceContributions), normalized)) return null;
  return normalized;
}

function normalizeStoredContributions(
  value: unknown,
): Record<string, AttributionTokenContribution> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const result: Record<string, AttributionTokenContribution> = {};
  for (const [sourceID, raw] of Object.entries(value)) {
    if (!sourceID || !raw || typeof raw !== "object") return null;
    const candidate = raw as Partial<AttributionTokenContribution>;
    if (!validNonnegative(candidate.inputTokens)
      || !validNonnegative(candidate.cachedInputTokens)
      || !validNonnegative(candidate.outputTokens)
      || !validNonnegative(candidate.totalTokens)
      || !validNonnegative(candidate.calls)) return null;
    const inputTokens = candidate.inputTokens;
    result[sourceID] = {
      inputTokens,
      cachedInputTokens: Math.min(candidate.cachedInputTokens, inputTokens),
      outputTokens: candidate.outputTokens,
      totalTokens: candidate.totalTokens,
      calls: candidate.calls,
    };
  }
  return result;
}

function mergeBucketContributions(
  previous: AttributionTokenBucket | null,
  current: AttributionTokenBucket,
  provenanceCompatible: boolean,
): { bucket: AttributionTokenBucket; ambiguityDetected: boolean } {
  if (!provenanceCompatible) {
    return {
      bucket: {
        startUnix: current.startUnix,
        ...(previous ? maxContribution(previous, current) : current),
        sourceContributions: null,
        sourceTrackingComplete: false,
      },
      ambiguityDetected: bucketHasUsage(previous ?? current) || bucketHasUsage(current),
    };
  }
  if (!previous) {
    return {
      bucket: current,
      ambiguityDetected: bucketHasUsage(current) && current.sourceTrackingComplete !== true,
    };
  }
  const previousComplete = previous.sourceTrackingComplete === true
    && previous.sourceContributions !== null && previous.sourceContributions !== undefined;
  const currentComplete = current.sourceTrackingComplete === true
    && current.sourceContributions !== null && current.sourceContributions !== undefined;
  if (previousComplete && currentComplete) {
    const previousSources = previous.sourceContributions!;
    const currentSources = current.sourceContributions!;
    const mergedSources = { ...previousSources };
    let ambiguityDetected = false;
    for (const [sourceID, contribution] of Object.entries(currentSources)) {
      const stored = previousSources[sourceID] ?? null;
      if (stored && contributionDecreased(stored, contribution)) ambiguityDetected = true;
      mergedSources[sourceID] = stored ? maxContribution(stored, contribution) : contribution;
    }
    const aggregate = aggregateContributions(mergedSources);
    return {
      bucket: {
        startUnix: current.startUnix,
        ...aggregate,
        sourceContributions: mergedSources,
        sourceTrackingComplete: true,
      },
      ambiguityDetected,
    };
  }

  return {
    bucket: {
      startUnix: current.startUnix,
      ...maxContribution(previous, current),
      sourceContributions: null,
      sourceTrackingComplete: false,
    },
    // Once a nonempty legacy/aggregate-only bucket is rescanned, source loss
    // cannot be distinguished from same-bucket replacement. Preserve its max
    // but fail closed instead of presenting a non-local conclusion.
    ambiguityDetected: bucketHasUsage(previous) || bucketHasUsage(current),
  };
}

function resetAtUnixFromStorageKey(key: string): number | null {
  const prefix = `${STORAGE_PREFIX}:`;
  if (!key.startsWith(prefix)) return null;
  const components = key.slice(prefix.length).split(":");
  if (components.length !== 5) return null;
  const resetAtUnix = Number(components[3]);
  return Number.isFinite(resetAtUnix) && resetAtUnix > 0 ? resetAtUnix : null;
}

function aggregateContributions(
  values: Record<string, AttributionTokenContribution>,
): AttributionTokenContribution {
  return Object.values(values).reduce(addContributions, emptyContribution());
}

function addContributions(
  left: AttributionTokenContribution,
  right: AttributionTokenContribution,
): AttributionTokenContribution {
  return {
    inputTokens: left.inputTokens + right.inputTokens,
    cachedInputTokens: left.cachedInputTokens + right.cachedInputTokens,
    outputTokens: left.outputTokens + right.outputTokens,
    totalTokens: left.totalTokens + right.totalTokens,
    calls: left.calls + right.calls,
  };
}

function maxContribution(
  left: AttributionTokenContribution,
  right: AttributionTokenContribution,
): AttributionTokenContribution {
  const inputTokens = Math.max(left.inputTokens, right.inputTokens);
  return {
    inputTokens,
    cachedInputTokens: Math.min(inputTokens, Math.max(left.cachedInputTokens, right.cachedInputTokens)),
    outputTokens: Math.max(left.outputTokens, right.outputTokens),
    totalTokens: Math.max(left.totalTokens, right.totalTokens),
    calls: Math.max(left.calls, right.calls),
  };
}

function contributionDecreased(
  previous: AttributionTokenContribution,
  current: AttributionTokenContribution,
): boolean {
  return current.inputTokens < previous.inputTokens
    || current.cachedInputTokens < previous.cachedInputTokens
    || current.outputTokens < previous.outputTokens
    || current.totalTokens < previous.totalTokens
    || current.calls < previous.calls;
}

function sameBucket(
  left: AttributionTokenBucket | null,
  right: AttributionTokenBucket | null,
): boolean {
  return left !== null && right !== null
    && left.startUnix === right.startUnix
    && sameContribution(left, right)
    && (left.sourceTrackingComplete === true) === (right.sourceTrackingComplete === true)
    && sameSourceContributions(left.sourceContributions, right.sourceContributions);
}

function sameSourceContributions(
  left: Record<string, AttributionTokenContribution> | null | undefined,
  right: Record<string, AttributionTokenContribution> | null | undefined,
): boolean {
  if (!left || !right) return !left && !right;
  const leftKeys = Object.keys(left).sort();
  const rightKeys = Object.keys(right).sort();
  return leftKeys.length === rightKeys.length
    && leftKeys.every((key, index) => key === rightKeys[index]
      && sameContribution(left[key], right[key]));
}

function sameContribution(
  left: AttributionTokenContribution,
  right: AttributionTokenContribution,
): boolean {
  return left.inputTokens === right.inputTokens
    && left.cachedInputTokens === right.cachedInputTokens
    && left.outputTokens === right.outputTokens
    && left.totalTokens === right.totalTokens
    && left.calls === right.calls;
}

function sameRecordMetadata(
  left: StoredAttributionBucketHighWater,
  right: StoredAttributionBucketHighWater,
): boolean {
  return left.updatedAt === right.updatedAt
    && left.provenanceEpoch === right.provenanceEpoch
    && left.metadataObservedAtUnix === right.metadataObservedAtUnix
    && left.coverageStartUnix === right.coverageStartUnix
    && left.coverageEndUnix === right.coverageEndUnix
    && left.ambiguityDetected === right.ambiguityDetected
    && left.quotaObservationFresh === right.quotaObservationFresh;
}

function bucketHasUsage(bucket: AttributionTokenContribution): boolean {
  return bucket.totalTokens > 0
    || bucket.inputTokens > 0
    || bucket.cachedInputTokens > 0
    || bucket.outputTokens > 0;
}

function emptyContribution(): AttributionTokenContribution {
  return { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, totalTokens: 0, calls: 0 };
}

function finiteNonnegative(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}

function finiteNumber(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function validNonnegative(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function optionalFinite(value: unknown): boolean {
  return value === undefined || (typeof value === "number" && Number.isFinite(value));
}

function optionalFiniteNonnegative(value: unknown): boolean {
  return value === undefined || validNonnegative(value);
}

function latestTimestamp(left: string, right: string): string {
  const leftTime = Date.parse(left);
  const rightTime = Date.parse(right);
  if (!Number.isFinite(leftTime)) return right;
  if (!Number.isFinite(rightTime)) return left;
  return rightTime >= leftTime ? right : left;
}

import type { QuotaAttributionIdentity } from "../../types/dashboard";
import { ATTRIBUTION_BUCKET_SECONDS } from "./highWater.ts";

const SEGMENT_STORAGE_PREFIX = "sharedAccountAttributionSegment:v7";
const LEGACY_SEGMENT_STORAGE_PREFIXES = [
  "sharedAccountAttributionSegment:v6",
  "sharedAccountAttributionSegment:v5",
  "sharedAccountAttributionSegment:v4",
  "sharedAccountAttributionSegment:v3",
  "sharedAccountAttributionSegment:v2",
] as const;
const SEVEN_DAYS_SECONDS = 7 * 24 * 60 * 60;
const RESET_JITTER_SECONDS = 5;
const NEW_CYCLE_RESET_DELTA_SECONDS = 5 * 60;
const ACCOUNT_USED_CHANGE_EPSILON = 0.000_1;

export type AttributionSegmentStatus =
  | "disabled"
  | "identityUnavailable"
  | "quotaTimestampUnavailable"
  | "awaitingAccountSwitchBaseline"
  | "ready";

export type AttributionCutoverReason =
  | "none"
  | "initialActivation"
  | "accountSwitch"
  | "legacyMigration"
  | "continuityGap";

export interface StoredAttributionSegment {
  resetAtUnix: number;
  cycleId?: string | null;
  scopeKey: string;
  plan: string;
  limit: string;
  segmentStartUnix: number;
  baselineAccountUsedPercent: number | null;
  baselineReady: boolean;
  baselineObservedAtUnix: number | null;
  /** Set only after the matching raw high-water record was durably read back. */
  highWaterInitialized: boolean;
  /** Latest quota value that materially changed this segment. */
  accountUsedObservedPercent: number;
  /** Poll timestamps with unchanged quota do not advance this watermark. */
  comparisonUpdatedAtUnix: number;
  /** Quota movement waits for a later poll beyond this open-bucket boundary. */
  quotaMovementPendingUntilUnix: number | null;
  quotaMovementObservedAtUnix: number | null;
  /** Boundary release requires a precise observation at/after this exact poll. */
  requiredLocalObservationAfterUnix: number | null;
  cutoverReason: AttributionCutoverReason;
  cutoverDetectedAtUnix: number | null;
  cutoverRecoveredAtUnix: number | null;
  continuityGapID: string | null;
  /** Quota observation that detected this account/reset segment. */
  observedAtUnix: number;
}

export interface LegacyAttributionSegment {
  resetAtUnix: number;
  segmentStartUnix: number | null;
}

export interface AttributionStorageRead<T> {
  healthy: boolean;
  value: T | null;
}

export interface LegacyAttributionResidueState {
  healthy: boolean;
  keys: string[];
}

export interface LegacyAttributionRetirementResult {
  healthy: boolean;
  removed: string[];
}

export interface AttributionSegmentResolution {
  status: AttributionSegmentStatus;
  storageKey: string | null;
  segment: StoredAttributionSegment | null;
  changed: boolean;
  scopeChanged: boolean;
  pendingAlignmentAdvanced: boolean;
}

export interface AttributionSegmentInput {
  enabled: boolean;
  sourceHomeIdentity: string;
  identity: QuotaAttributionIdentity | null | undefined;
  quotaDataFresh: boolean;
  resetAtUnix: number | null | undefined;
  quotaUpdatedAtUnix: number | null;
  accountUsedPercent: number | null;
  cycleId?: string | null;
  /** One-shot liveness escape hatch, allowed only after raw pending usage is proven. */
  pendingRawCanAdvanceComparison?: boolean;
}

export function attributionSegmentStorageKey(
  sourceHomeIdentity: string,
): string {
  return [
    SEGMENT_STORAGE_PREFIX,
    stableIdentityHash(sourceHomeIdentity),
  ].join(":");
}

export function resolveAttributionSegment(
  stored: StoredAttributionSegment | null,
  input: AttributionSegmentInput,
  legacyStored: LegacyAttributionSegment | null = null,
): AttributionSegmentResolution {
  const unavailable = inputUnavailableResolution(input);
  if (unavailable) return unavailable;
  assertValidatedInput(input);

  const storageKey = attributionSegmentStorageKey(input.sourceHomeIdentity);
  const accountUsedPercent = Math.max(0, input.accountUsedPercent);
  const cycleId = normalizedCycleId(input.cycleId);
  if (!stored && legacyStored
    && Math.abs(legacyStored.resetAtUnix - input.resetAtUnix) <= RESET_JITTER_SECONDS) {
    const canonicalResetAtUnix = legacyStored.resetAtUnix;
    const segment: StoredAttributionSegment = {
      resetAtUnix: canonicalResetAtUnix,
      cycleId,
      scopeKey: input.identity.scopeKey,
      plan: input.identity.plan,
      limit: input.identity.limit,
      segmentStartUnix: Math.max(
        canonicalResetAtUnix - SEVEN_DAYS_SECONDS,
        Math.min(
          legacyStored.segmentStartUnix
            ?? completedBucketBoundary(input.quotaUpdatedAtUnix),
          canonicalResetAtUnix,
        ),
      ),
      baselineAccountUsedPercent: null,
      baselineReady: false,
      baselineObservedAtUnix: null,
      highWaterInitialized: false,
      accountUsedObservedPercent: accountUsedPercent,
      comparisonUpdatedAtUnix: input.quotaUpdatedAtUnix,
      quotaMovementPendingUntilUnix: null,
      quotaMovementObservedAtUnix: null,
      requiredLocalObservationAfterUnix: null,
      cutoverReason: "legacyMigration",
      cutoverDetectedAtUnix: input.quotaUpdatedAtUnix,
      cutoverRecoveredAtUnix: null,
      continuityGapID: null,
      observedAtUnix: input.quotaUpdatedAtUnix,
    };
    return {
      status: "awaitingAccountSwitchBaseline",
      storageKey,
      segment,
      changed: true,
      scopeChanged: true,
      pendingAlignmentAdvanced: false,
    };
  }

  const sameCycle = stored !== null && sameQuotaCycle(stored, input);
  const sameScope = stored !== null
    && sameCycle
    && stored.scopeKey === input.identity.scopeKey
    && stored.plan === input.identity.plan
    && stored.limit === input.identity.limit;
  if (sameScope) {
    const currentStored = stored.cycleId === (cycleId ?? normalizedCycleId(stored.cycleId))
      ? stored
      : { ...stored, cycleId: cycleId ?? normalizedCycleId(stored.cycleId) };
    if (!stored.baselineReady) {
      const canFinalizeBaseline = input.quotaUpdatedAtUnix >= stored.segmentStartUnix
        && input.quotaUpdatedAtUnix > stored.observedAtUnix;
      if (!canFinalizeBaseline) {
        return {
          status: "awaitingAccountSwitchBaseline",
          storageKey,
          segment: currentStored,
          changed: currentStored !== stored,
          scopeChanged: false,
          pendingAlignmentAdvanced: false,
        };
      }
      return {
        status: "ready",
        storageKey,
        segment: {
          ...currentStored,
          baselineAccountUsedPercent: accountUsedPercent,
          baselineReady: true,
          baselineObservedAtUnix: input.quotaUpdatedAtUnix,
          accountUsedObservedPercent: accountUsedPercent,
          comparisonUpdatedAtUnix: input.quotaUpdatedAtUnix,
          quotaMovementPendingUntilUnix: null,
          quotaMovementObservedAtUnix: null,
          requiredLocalObservationAfterUnix: input.quotaUpdatedAtUnix,
        },
        changed: true,
        scopeChanged: false,
        pendingAlignmentAdvanced: true,
      };
    }
    const accountUsedChanged = input.quotaUpdatedAtUnix >= stored.comparisonUpdatedAtUnix
      && Math.abs(accountUsedPercent - stored.accountUsedObservedPercent)
        > ACCOUNT_USED_CHANGE_EPSILON;
    if (accountUsedChanged) {
      return {
        status: "ready",
        storageKey,
        segment: {
          ...currentStored,
          accountUsedObservedPercent: accountUsedPercent,
          quotaMovementPendingUntilUnix: Math.max(
            stored.quotaMovementPendingUntilUnix ?? Number.NEGATIVE_INFINITY,
            completedBucketBoundary(input.quotaUpdatedAtUnix),
          ),
          quotaMovementObservedAtUnix: input.quotaUpdatedAtUnix,
        },
        changed: true,
        scopeChanged: false,
        pendingAlignmentAdvanced: false,
      };
    }
    const movementMatured = stored.quotaMovementPendingUntilUnix !== null
      && stored.quotaMovementObservedAtUnix !== null
      && input.quotaUpdatedAtUnix >= stored.quotaMovementPendingUntilUnix
      && input.quotaUpdatedAtUnix > stored.quotaMovementObservedAtUnix;
    if (movementMatured) {
      return {
        status: "ready",
        storageKey,
        segment: {
          ...currentStored,
          accountUsedObservedPercent: accountUsedPercent,
          comparisonUpdatedAtUnix: input.quotaUpdatedAtUnix,
          quotaMovementPendingUntilUnix: null,
          quotaMovementObservedAtUnix: null,
          requiredLocalObservationAfterUnix: input.quotaUpdatedAtUnix,
        },
        changed: true,
        scopeChanged: false,
        pendingAlignmentAdvanced: true,
      };
    }
    const nextCompletedBoundary = completedBucketBoundary(
      stored.comparisonUpdatedAtUnix + 1,
    );
    if (input.pendingRawCanAdvanceComparison === true
      && stored.quotaMovementPendingUntilUnix === null
      && input.quotaUpdatedAtUnix > stored.comparisonUpdatedAtUnix
      && input.quotaUpdatedAtUnix >= nextCompletedBoundary) {
      return {
        status: "ready",
        storageKey,
        segment: {
          ...currentStored,
          accountUsedObservedPercent: accountUsedPercent,
          comparisonUpdatedAtUnix: input.quotaUpdatedAtUnix,
          requiredLocalObservationAfterUnix: input.quotaUpdatedAtUnix,
        },
        changed: true,
        scopeChanged: false,
        pendingAlignmentAdvanced: true,
      };
    }
    return {
      status: "ready",
      storageKey,
      segment: currentStored,
      changed: currentStored !== stored,
      scopeChanged: false,
      pendingAlignmentAdvanced: false,
    };
  }

  // A missing durable record is unsafe even after a natural reset: local
  // sessions could have been archived before this first observation. Start a
  // synthetic cutover instead of assuming a whole-cycle zero baseline.
  const scopeChanged = stored !== null
    && sameCycle
    && !sameIdentityScope(stored, input.identity);
  const firstObservation = !sameCycle;
  const canonicalResetAtUnix = sameCycle ? stored.resetAtUnix : input.resetAtUnix;
  const resolvedCycleId = cycleId
    ?? (sameCycle ? normalizedCycleId(stored?.cycleId) : null);
  const segment: StoredAttributionSegment = {
    resetAtUnix: canonicalResetAtUnix,
    cycleId: resolvedCycleId,
    scopeKey: input.identity.scopeKey,
    plan: input.identity.plan,
    limit: input.identity.limit,
    segmentStartUnix: Math.max(
      canonicalResetAtUnix - SEVEN_DAYS_SECONDS,
      Math.min(completedBucketBoundary(input.quotaUpdatedAtUnix), canonicalResetAtUnix),
    ),
    baselineAccountUsedPercent: null,
    baselineReady: false,
    baselineObservedAtUnix: null,
    highWaterInitialized: false,
    accountUsedObservedPercent: accountUsedPercent,
    comparisonUpdatedAtUnix: input.quotaUpdatedAtUnix,
    quotaMovementPendingUntilUnix: null,
    quotaMovementObservedAtUnix: null,
    requiredLocalObservationAfterUnix: null,
    cutoverReason: scopeChanged ? "accountSwitch" : firstObservation ? "initialActivation" : "none",
    cutoverDetectedAtUnix: input.quotaUpdatedAtUnix,
    cutoverRecoveredAtUnix: null,
    continuityGapID: null,
    observedAtUnix: input.quotaUpdatedAtUnix,
  };
  return {
    status: "awaitingAccountSwitchBaseline",
    storageKey,
    segment,
    changed: true,
    scopeChanged,
    pendingAlignmentAdvanced: false,
  };
}

/** Holds the last durable segment unchanged while exact-read continuity is unknown. */
export function holdAttributionSegmentDuringContinuityGap(
  stored: StoredAttributionSegment | null,
  input: AttributionSegmentInput,
): AttributionSegmentResolution {
  const unavailable = holdInputUnavailableResolution(input);
  if (unavailable) return unavailable;
  assertValidatedHoldInput(input);
  const storageKey = attributionSegmentStorageKey(input.sourceHomeIdentity);
  if (!stored
    || !sameQuotaCycleWithoutUsage(stored, input)
    || !sameIdentityScope(stored, input.identity)) {
    return {
      status: "quotaTimestampUnavailable",
      storageKey,
      segment: null,
      changed: false,
      scopeChanged: false,
      pendingAlignmentAdvanced: false,
    };
  }
  return {
    status: stored.baselineReady ? "ready" : "awaitingAccountSwitchBaseline",
    storageKey,
    segment: stored,
    changed: false,
    scopeChanged: false,
    pendingAlignmentAdvanced: false,
  };
}

/** Replaces an unknown exact-read interval with a persisted pending safe cutover. */
export function beginContinuityGapCutover(
  stored: StoredAttributionSegment | null,
  input: AttributionSegmentInput,
  gapID: string,
  gapDetectedAtUnix: number,
  recoveredCoverageAtUnix: number,
): AttributionSegmentResolution {
  const unavailable = inputUnavailableResolution(input);
  if (unavailable) return unavailable;
  assertValidatedInput(input);
  if (!validUUID(gapID)
    || !Number.isFinite(gapDetectedAtUnix)
    || gapDetectedAtUnix <= 0
    || !Number.isFinite(recoveredCoverageAtUnix)
    || recoveredCoverageAtUnix <= 0) {
    return unavailableResolution("quotaTimestampUnavailable");
  }
  const storageKey = attributionSegmentStorageKey(input.sourceHomeIdentity);
  const sameCycle = stored !== null && sameQuotaCycle(stored, input);
  const sameScope = stored !== null && sameCycle && sameIdentityScope(stored, input.identity);
  if (sameScope
    && stored.cutoverReason === "continuityGap"
    && stored.continuityGapID === gapID) {
    return resolveAttributionSegment(stored, input);
  }
  const canonicalResetAtUnix = sameCycle ? stored.resetAtUnix : input.resetAtUnix;
  const cycleStartUnix = canonicalResetAtUnix - SEVEN_DAYS_SECONDS;
  const accountUsedPercent = Math.max(0, input.accountUsedPercent);
  const resolvedCycleId = normalizedCycleId(input.cycleId)
    ?? (sameCycle ? normalizedCycleId(stored?.cycleId) : null);
  return {
    status: "awaitingAccountSwitchBaseline",
    storageKey,
    segment: {
      resetAtUnix: canonicalResetAtUnix,
      cycleId: resolvedCycleId,
      scopeKey: input.identity.scopeKey,
      plan: input.identity.plan,
      limit: input.identity.limit,
      segmentStartUnix: Math.max(
        cycleStartUnix,
        Math.min(completedBucketBoundary(recoveredCoverageAtUnix), canonicalResetAtUnix),
      ),
      baselineAccountUsedPercent: null,
      baselineReady: false,
      baselineObservedAtUnix: null,
      highWaterInitialized: false,
      accountUsedObservedPercent: accountUsedPercent,
      comparisonUpdatedAtUnix: input.quotaUpdatedAtUnix,
      quotaMovementPendingUntilUnix: null,
      quotaMovementObservedAtUnix: null,
      requiredLocalObservationAfterUnix: null,
      cutoverReason: "continuityGap",
      cutoverDetectedAtUnix: gapDetectedAtUnix,
      cutoverRecoveredAtUnix: recoveredCoverageAtUnix,
      continuityGapID: gapID,
      observedAtUnix: input.quotaUpdatedAtUnix,
    },
    changed: true,
    scopeChanged: false,
    pendingAlignmentAdvanced: false,
  };
}

/**
 * Converts one native exact-index safety episode into a durable pending
 * cutover. Re-observing the same still-unacknowledged episode deliberately
 * stays pending; only a later precise snapshot after native acknowledgement
 * may let a newer quota observation establish the baseline.
 */
export function beginAttributionUnsafeEpisodeCutover(
  stored: StoredAttributionSegment | null,
  input: AttributionSegmentInput,
  unsafeID: string,
  unsafeDetectedAtUnix: number,
  recoveredCoverageAtUnix: number,
): AttributionSegmentResolution {
  const unavailable = inputUnavailableResolution(input);
  if (unavailable) return unavailable;
  assertValidatedInput(input);
  if (!validUUID(unsafeID)
    || !Number.isFinite(unsafeDetectedAtUnix)
    || unsafeDetectedAtUnix <= 0
    || !Number.isFinite(recoveredCoverageAtUnix)
    || recoveredCoverageAtUnix <= 0) {
    return unavailableResolution("quotaTimestampUnavailable");
  }
  const storageKey = attributionSegmentStorageKey(input.sourceHomeIdentity);
  const sameCycle = stored !== null && sameQuotaCycle(stored, input);
  const sameScope = stored !== null && sameCycle && sameIdentityScope(stored, input.identity);
  if (sameScope
    && stored.cutoverReason === "continuityGap"
    && stored.continuityGapID === unsafeID
    && !stored.baselineReady) {
    return {
      status: "awaitingAccountSwitchBaseline",
      storageKey,
      segment: stored,
      changed: false,
      scopeChanged: false,
      pendingAlignmentAdvanced: false,
    };
  }
  return beginContinuityGapCutover(
    stored,
    input,
    unsafeID,
    unsafeDetectedAtUnix,
    recoveredCoverageAtUnix,
  );
}

export function readLegacyAttributionSegment(
  sourceHomeIdentity: string,
  storage?: Pick<Storage, "getItem"> | null,
): LegacyAttributionSegment | null {
  return readLegacyAttributionSegmentState(sourceHomeIdentity, storage).value;
}

export function readLegacyAttributionSegmentState(
  sourceHomeIdentity: string,
  storage?: Pick<Storage, "getItem"> | null,
): AttributionStorageRead<LegacyAttributionSegment> {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target || !sourceHomeIdentity.trim()) return { healthy: true, value: null };
  const identityHash = stableIdentityHash(sourceHomeIdentity);
  for (const prefix of LEGACY_SEGMENT_STORAGE_PREFIXES) {
    try {
      const raw = target.getItem(`${prefix}:${identityHash}`);
      if (raw === null) continue;
      const candidate = JSON.parse(raw) as unknown;
      if (candidate && typeof candidate === "object") {
        const resetAtUnix = (candidate as { resetAtUnix?: unknown }).resetAtUnix;
        if (typeof resetAtUnix === "number" && Number.isFinite(resetAtUnix) && resetAtUnix > 0) {
          const segmentStart = (candidate as { segmentStartUnix?: unknown }).segmentStartUnix;
          return {
            healthy: true,
            value: {
              resetAtUnix,
              segmentStartUnix: typeof segmentStart === "number" && Number.isFinite(segmentStart)
                ? segmentStart
                : null,
            },
          };
        }
      }
      return { healthy: false, value: null };
    } catch {
      return { healthy: false, value: null };
    }
  }
  return { healthy: true, value: null };
}

export function readLegacyAttributionResidueState(
  sourceHomeIdentity: string,
  storage?: Pick<Storage, "getItem"> | null,
): LegacyAttributionResidueState {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target || !sourceHomeIdentity.trim()) return { healthy: true, keys: [] };
  const identityHash = stableIdentityHash(sourceHomeIdentity);
  const keys: string[] = [];
  try {
    for (const prefix of LEGACY_SEGMENT_STORAGE_PREFIXES) {
      const key = `${prefix}:${identityHash}`;
      if (target.getItem(key) !== null) keys.push(key);
    }
    return { healthy: true, keys };
  } catch {
    return { healthy: false, keys: [] };
  }
}

/**
 * Retires every predecessor key only after the v7 segment is durable. Keeping
 * even one old key would let a later missing v7 row resurrect stale state.
 */
export function retireLegacyAttributionSegments(
  sourceHomeIdentity: string,
  storage?: Pick<Storage, "getItem" | "removeItem"> | null,
): LegacyAttributionRetirementResult {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target || !sourceHomeIdentity.trim()) return { healthy: false, removed: [] };
  const residue = readLegacyAttributionResidueState(sourceHomeIdentity, target);
  if (!residue.healthy) return { healthy: false, removed: [] };
  const removed: string[] = [];
  try {
    for (const key of residue.keys) {
      target.removeItem(key);
      if (target.getItem(key) !== null) return { healthy: false, removed };
      removed.push(key);
    }
    return { healthy: true, removed };
  } catch {
    return { healthy: false, removed };
  }
}

export function readAttributionSegment(
  key: string,
  storage?: Pick<Storage, "getItem"> | null,
): StoredAttributionSegment | null {
  return readAttributionSegmentState(key, storage).value;
}

export function readAttributionSegmentState(
  key: string,
  storage?: Pick<Storage, "getItem"> | null,
): AttributionStorageRead<StoredAttributionSegment> {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target) return { healthy: true, value: null };
  try {
    const raw = target.getItem(key);
    if (raw === null) return { healthy: true, value: null };
    const value = normalizeStoredSegment(JSON.parse(raw));
    return value === null
      ? { healthy: false, value: null }
      : { healthy: true, value };
  } catch {
    return { healthy: false, value: null };
  }
}

export function writeAttributionSegment(
  key: string,
  segment: StoredAttributionSegment,
  storage?: Pick<Storage, "getItem" | "setItem"> | null,
): boolean {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target) return false;
  try {
    target.setItem(key, JSON.stringify(segment));
    return JSON.stringify(readAttributionSegmentState(key, target).value) === JSON.stringify(segment);
  } catch {
    // Callers fail closed until the durable record can be read back exactly.
    return false;
  }
}

export function completedBucketBoundary(unix: number): number {
  return Math.ceil(unix / ATTRIBUTION_BUCKET_SECONDS) * ATTRIBUTION_BUCKET_SECONDS;
}

function unavailableResolution(
  status: Exclude<AttributionSegmentStatus, "ready" | "awaitingAccountSwitchBaseline">,
): AttributionSegmentResolution {
  return {
    status,
    storageKey: null,
    segment: null,
    changed: false,
    scopeChanged: false,
    pendingAlignmentAdvanced: false,
  };
}

function inputUnavailableResolution(
  input: AttributionSegmentInput,
): AttributionSegmentResolution | null {
  if (!input.enabled) return unavailableResolution("disabled");
  if (!validIdentity(input.identity) || !input.sourceHomeIdentity.trim()) {
    return unavailableResolution("identityUnavailable");
  }
  if (!input.quotaDataFresh
    || typeof input.resetAtUnix !== "number"
    || !Number.isFinite(input.resetAtUnix)
    || input.resetAtUnix <= 0
    || input.quotaUpdatedAtUnix === null
    || !Number.isFinite(input.quotaUpdatedAtUnix)
    || input.accountUsedPercent === null
    || !Number.isFinite(input.accountUsedPercent)) {
    return unavailableResolution("quotaTimestampUnavailable");
  }
  return null;
}

function holdInputUnavailableResolution(
  input: AttributionSegmentInput,
): AttributionSegmentResolution | null {
  if (!input.enabled) return unavailableResolution("disabled");
  if (!validIdentity(input.identity) || !input.sourceHomeIdentity.trim()) {
    return unavailableResolution("identityUnavailable");
  }
  if (typeof input.resetAtUnix !== "number"
    || !Number.isFinite(input.resetAtUnix)
    || input.resetAtUnix <= 0) {
    return unavailableResolution("quotaTimestampUnavailable");
  }
  return null;
}

type ValidAttributionSegmentInput = AttributionSegmentInput & {
  identity: QuotaAttributionIdentity;
  resetAtUnix: number;
  quotaUpdatedAtUnix: number;
  accountUsedPercent: number;
};

type ValidAttributionSegmentHoldInput = AttributionSegmentInput & {
  identity: QuotaAttributionIdentity;
  resetAtUnix: number;
};

function assertValidatedInput(
  input: AttributionSegmentInput,
): asserts input is ValidAttributionSegmentInput {
  // Validation is centralized in inputUnavailableResolution immediately before
  // every call. This assertion only carries that runtime proof into TypeScript.
}

function assertValidatedHoldInput(
  input: AttributionSegmentInput,
): asserts input is ValidAttributionSegmentHoldInput {
  // Validation is centralized in holdInputUnavailableResolution immediately
  // before every call. This assertion only carries that proof into TypeScript.
}

function validIdentity(identity: QuotaAttributionIdentity | null | undefined): identity is QuotaAttributionIdentity {
  return Boolean(identity?.scopeKey.trim() && identity.plan.trim() && identity.limit.trim());
}

function sameIdentityScope(
  stored: StoredAttributionSegment,
  identity: QuotaAttributionIdentity,
): boolean {
  return stored.scopeKey === identity.scopeKey
    && stored.plan === identity.plan
    && stored.limit === identity.limit;
}

function normalizeStoredSegment(value: unknown): StoredAttributionSegment | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<StoredAttributionSegment>;
  if (typeof candidate.resetAtUnix !== "number" || !Number.isFinite(candidate.resetAtUnix)
    || (candidate.cycleId !== undefined
      && candidate.cycleId !== null
      && (typeof candidate.cycleId !== "string" || !candidate.cycleId.trim()))
    || typeof candidate.scopeKey !== "string" || !candidate.scopeKey
    || typeof candidate.plan !== "string" || !candidate.plan
    || typeof candidate.limit !== "string" || !candidate.limit
    || typeof candidate.segmentStartUnix !== "number" || !Number.isFinite(candidate.segmentStartUnix)
    || (candidate.baselineAccountUsedPercent !== null
      && (typeof candidate.baselineAccountUsedPercent !== "number"
        || !Number.isFinite(candidate.baselineAccountUsedPercent)))
    || typeof candidate.baselineReady !== "boolean"
    || (candidate.baselineObservedAtUnix !== null
      && (typeof candidate.baselineObservedAtUnix !== "number"
        || !Number.isFinite(candidate.baselineObservedAtUnix)))
    || typeof candidate.highWaterInitialized !== "boolean"
    || typeof candidate.accountUsedObservedPercent !== "number"
    || !Number.isFinite(candidate.accountUsedObservedPercent)
    || typeof candidate.comparisonUpdatedAtUnix !== "number"
    || !Number.isFinite(candidate.comparisonUpdatedAtUnix)
    || !nullableFinite(candidate.quotaMovementPendingUntilUnix)
    || !nullableFinite(candidate.quotaMovementObservedAtUnix)
    || !nullableFinite(candidate.requiredLocalObservationAfterUnix)
    || !validCutoverReason(candidate.cutoverReason)
    || !nullableFinite(candidate.cutoverDetectedAtUnix)
    || !nullableFinite(candidate.cutoverRecoveredAtUnix)
    || (candidate.continuityGapID !== null
      && (typeof candidate.continuityGapID !== "string" || !validUUID(candidate.continuityGapID)))
    || typeof candidate.observedAtUnix !== "number" || !Number.isFinite(candidate.observedAtUnix)) {
    return null;
  }
  const baselineFieldsConsistent = candidate.baselineReady
    ? candidate.baselineAccountUsedPercent !== null && candidate.baselineObservedAtUnix !== null
    : candidate.baselineAccountUsedPercent === null && candidate.baselineObservedAtUnix === null;
  const continuityFieldsConsistent = candidate.cutoverReason === "continuityGap"
    ? candidate.continuityGapID !== null
      && candidate.cutoverDetectedAtUnix !== null
      && candidate.cutoverRecoveredAtUnix !== null
    : candidate.continuityGapID === null && candidate.cutoverRecoveredAtUnix === null;
  if (!baselineFieldsConsistent
    || !continuityFieldsConsistent
    || candidate.resetAtUnix <= 0
    || candidate.segmentStartUnix > candidate.resetAtUnix
    || candidate.observedAtUnix <= 0
    || candidate.comparisonUpdatedAtUnix <= 0) {
    return null;
  }
  return candidate as StoredAttributionSegment;
}

function nullableFinite(value: unknown): value is number | null {
  return value === null || (typeof value === "number" && Number.isFinite(value));
}

function validCutoverReason(value: unknown): value is AttributionCutoverReason {
  return value === "none"
    || value === "initialActivation"
    || value === "accountSwitch"
    || value === "legacyMigration"
    || value === "continuityGap";
}

function validUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function sameQuotaCycle(
  stored: StoredAttributionSegment,
  input: ValidAttributionSegmentInput,
): boolean {
  const storedCycleId = normalizedCycleId(stored.cycleId);
  const inputCycleId = normalizedCycleId(input.cycleId);
  if (storedCycleId !== null && inputCycleId !== null) {
    return storedCycleId === inputCycleId;
  }
  return !(Math.abs(stored.resetAtUnix - input.resetAtUnix)
      > NEW_CYCLE_RESET_DELTA_SECONDS
    && input.accountUsedPercent === 0);
}

function sameQuotaCycleWithoutUsage(
  stored: StoredAttributionSegment,
  input: ValidAttributionSegmentHoldInput,
): boolean {
  const storedCycleId = normalizedCycleId(stored.cycleId);
  const inputCycleId = normalizedCycleId(input.cycleId);
  if (storedCycleId !== null && inputCycleId !== null) {
    return storedCycleId === inputCycleId;
  }
  return Math.abs(stored.resetAtUnix - input.resetAtUnix) <= RESET_JITTER_SECONDS;
}

function normalizedCycleId(value: string | null | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
}

function stableIdentityHash(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

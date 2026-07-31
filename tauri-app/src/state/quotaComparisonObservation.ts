import type { QuotaAttributionIdentity } from "../types/dashboard.ts";

const RESET_GRACE_SECONDS = 2 * 60;
const BUCKET_SECONDS = 5 * 60;
const USED_CHANGE_EPSILON = 0.000_001;

export interface QuotaComparisonObservationInput {
  quotaDataFresh: boolean;
  updatedAt: string;
  resetAtUnix: number | null | undefined;
  usedPercent: number | null;
  identity: QuotaAttributionIdentity | null | undefined;
}

export interface QuotaComparisonObservationState {
  canonicalResetAtUnix: number;
  scopeKey: string;
  plan: string;
  limit: string;
  observedUsedPercent: number;
  comparisonUpdatedAt: string;
  comparisonUpdatedAtUnix: number;
  pendingBoundaryUnix: number | null;
  pendingObservedAtUnix: number | null;
  movementPendingUntilUnix: number | null;
  movementObservedAtUnix: number | null;
  requiredLocalObservationAfterUnix: number | null;
}

export interface QuotaComparisonObservationResult {
  state: QuotaComparisonObservationState | null;
  shouldRefreshPreciseUsage: boolean;
  reason:
    | "unavailable"
    | "initial"
    | "reset"
    | "identity"
    | "baseline"
    | "usagePending"
    | "movementBoundary"
    | "unchanged";
}

/**
 * Converts frequent quota polls into a substantive comparison watermark.
 * A new poll timestamp alone never schedules an exact usage read.
 */
export function advanceQuotaComparisonObservation(
  previous: QuotaComparisonObservationState | null,
  input: QuotaComparisonObservationInput,
): QuotaComparisonObservationResult {
  const updatedAtUnix = parsedUnix(input.updatedAt);
  if (!input.quotaDataFresh
    || updatedAtUnix === null
    || typeof input.resetAtUnix !== "number"
    || !Number.isFinite(input.resetAtUnix)
    || input.resetAtUnix <= 0
    || input.usedPercent === null
    || !Number.isFinite(input.usedPercent)
    || !validIdentity(input.identity)) {
    return { state: previous, shouldRefreshPreciseUsage: false, reason: "unavailable" };
  }

  const nextIdentity = input.identity;
  if (previous === null) {
    return changedState({
      canonicalResetAtUnix: input.resetAtUnix,
      scopeKey: nextIdentity.scopeKey,
      plan: nextIdentity.plan,
      limit: nextIdentity.limit,
      observedUsedPercent: input.usedPercent,
      comparisonUpdatedAt: input.updatedAt,
      comparisonUpdatedAtUnix: updatedAtUnix,
      pendingBoundaryUnix: null,
      pendingObservedAtUnix: null,
      movementPendingUntilUnix: alignedCeil(updatedAtUnix),
      movementObservedAtUnix: updatedAtUnix,
      requiredLocalObservationAfterUnix: null,
    }, "initial");
  }

  const sameCycle = Math.abs(previous.canonicalResetAtUnix - input.resetAtUnix)
    <= RESET_GRACE_SECONDS;
  if (!sameCycle) {
    return changedState({
      canonicalResetAtUnix: input.resetAtUnix,
      scopeKey: nextIdentity.scopeKey,
      plan: nextIdentity.plan,
      limit: nextIdentity.limit,
      observedUsedPercent: input.usedPercent,
      comparisonUpdatedAt: input.updatedAt,
      comparisonUpdatedAtUnix: updatedAtUnix,
      pendingBoundaryUnix: null,
      pendingObservedAtUnix: null,
      movementPendingUntilUnix: alignedCeil(updatedAtUnix),
      movementObservedAtUnix: updatedAtUnix,
      requiredLocalObservationAfterUnix: null,
    }, "reset");
  }

  const sameIdentity = previous.scopeKey === nextIdentity.scopeKey
    && previous.plan === nextIdentity.plan
    && previous.limit === nextIdentity.limit;
  if (!sameIdentity) {
    return changedState({
      canonicalResetAtUnix: previous.canonicalResetAtUnix,
      scopeKey: nextIdentity.scopeKey,
      plan: nextIdentity.plan,
      limit: nextIdentity.limit,
      observedUsedPercent: input.usedPercent,
      comparisonUpdatedAt: input.updatedAt,
      comparisonUpdatedAtUnix: updatedAtUnix,
      pendingBoundaryUnix: alignedCeil(updatedAtUnix),
      pendingObservedAtUnix: updatedAtUnix,
      movementPendingUntilUnix: null,
      movementObservedAtUnix: null,
      requiredLocalObservationAfterUnix: null,
    }, "identity");
  }

  if (previous.pendingBoundaryUnix !== null) {
    const canFinalize = updatedAtUnix >= previous.pendingBoundaryUnix
      && previous.pendingObservedAtUnix !== null
      && updatedAtUnix > previous.pendingObservedAtUnix;
    if (!canFinalize) {
      return { state: previous, shouldRefreshPreciseUsage: false, reason: "unchanged" };
    }
    return changedState({
      ...previous,
      observedUsedPercent: input.usedPercent,
      comparisonUpdatedAt: input.updatedAt,
      comparisonUpdatedAtUnix: updatedAtUnix,
      pendingBoundaryUnix: null,
      pendingObservedAtUnix: null,
      movementPendingUntilUnix: null,
      movementObservedAtUnix: null,
      requiredLocalObservationAfterUnix: null,
    }, "baseline");
  }

  const accountUsedChanged = updatedAtUnix >= previous.comparisonUpdatedAtUnix
    && Math.abs(input.usedPercent - previous.observedUsedPercent) > USED_CHANGE_EPSILON;
  if (accountUsedChanged) {
    return updatedWithoutRefresh({
      ...previous,
      observedUsedPercent: input.usedPercent,
      movementPendingUntilUnix: Math.max(
        previous.movementPendingUntilUnix ?? Number.NEGATIVE_INFINITY,
        alignedCeil(updatedAtUnix),
      ),
      movementObservedAtUnix: updatedAtUnix,
    }, "usagePending");
  }

  const movementMatured = previous.movementPendingUntilUnix !== null
    && previous.movementObservedAtUnix !== null
    && updatedAtUnix >= previous.movementPendingUntilUnix
    && updatedAtUnix > previous.movementObservedAtUnix;
  if (movementMatured) {
    return changedState({
      ...previous,
      observedUsedPercent: input.usedPercent,
      comparisonUpdatedAt: input.updatedAt,
      comparisonUpdatedAtUnix: updatedAtUnix,
      movementPendingUntilUnix: null,
      movementObservedAtUnix: null,
      requiredLocalObservationAfterUnix: updatedAtUnix,
    }, "movementBoundary");
  }

  return { state: previous, shouldRefreshPreciseUsage: false, reason: "unchanged" };
}

/** Mirrors the UI's proven-pending 5m liveness advancement into hook state. */
export function alignQuotaComparisonObservation(
  state: QuotaComparisonObservationState | null,
  comparisonUpdatedAt: string,
): QuotaComparisonObservationState | null {
  const comparisonUpdatedAtUnix = parsedUnix(comparisonUpdatedAt);
  if (state === null || state.pendingBoundaryUnix !== null || comparisonUpdatedAtUnix === null) {
    return state;
  }
  const movementCanRelease = state.movementPendingUntilUnix !== null
    && state.movementObservedAtUnix !== null
    && comparisonUpdatedAtUnix >= state.movementPendingUntilUnix
    && comparisonUpdatedAtUnix > state.movementObservedAtUnix;
  const rawPendingCanRelease = state.movementPendingUntilUnix === null
    && comparisonUpdatedAtUnix >= alignedCeil(state.comparisonUpdatedAtUnix + 1);
  if (!movementCanRelease && !rawPendingCanRelease) return state;
  return {
    ...state,
    comparisonUpdatedAt,
    comparisonUpdatedAtUnix,
    movementPendingUntilUnix: null,
    movementObservedAtUnix: null,
    requiredLocalObservationAfterUnix: comparisonUpdatedAtUnix,
  };
}

function changedState(
  state: QuotaComparisonObservationState,
  reason: Exclude<QuotaComparisonObservationResult["reason"], "unavailable" | "unchanged">,
): QuotaComparisonObservationResult {
  return { state, shouldRefreshPreciseUsage: true, reason };
}

function updatedWithoutRefresh(
  state: QuotaComparisonObservationState,
  reason: "usagePending",
): QuotaComparisonObservationResult {
  return { state, shouldRefreshPreciseUsage: false, reason };
}

function parsedUnix(value: string): number | null {
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed / 1_000 : null;
}

function alignedCeil(unix: number): number {
  return Math.ceil(unix / BUCKET_SECONDS) * BUCKET_SECONDS;
}

function validIdentity(
  identity: QuotaAttributionIdentity | null | undefined,
): identity is QuotaAttributionIdentity {
  return Boolean(identity?.scopeKey.trim() && identity.plan.trim() && identity.limit.trim());
}

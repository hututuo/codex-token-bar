import type { QuotaAttributionIdentity } from "../types/dashboard.ts";

const NEW_CYCLE_RESET_DELTA_SECONDS = 5 * 60;
const BUCKET_SECONDS = 5 * 60;
const USED_CHANGE_EPSILON = 0.000_001;

export interface QuotaComparisonObservationInput {
  quotaDataFresh: boolean;
  updatedAt: string;
  resetAtUnix: number | null | undefined;
  usedPercent: number | null;
  cycleId?: string | null;
  identity: QuotaAttributionIdentity | null | undefined;
}

export interface QuotaComparisonObservationState {
  canonicalResetAtUnix: number;
  cycleId: string | null;
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
 * The first quota observation is only a baseline. If an exact owner is
 * already running for the same source, that owner will establish coverage and
 * the post-publication catch-up check can decide whether anything newer is
 * needed. Starting a second React generation here would unsubscribe the only
 * publisher from the active native flight.
 */
export function quotaComparisonNeedsPreciseRequest(
  result: QuotaComparisonObservationResult,
  preciseFlightInProgress: boolean,
): boolean {
  return result.shouldRefreshPreciseUsage
    && !(result.reason === "initial" && preciseFlightInProgress);
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
  const nextCycleId = normalizedCycleId(input.cycleId);
  if (previous === null) {
    return changedState({
      canonicalResetAtUnix: input.resetAtUnix,
      cycleId: nextCycleId,
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

  const sameIdentity = previous.scopeKey === nextIdentity.scopeKey
    && previous.plan === nextIdentity.plan
    && previous.limit === nextIdentity.limit;
  if (!sameIdentity) {
    return changedState({
      canonicalResetAtUnix: input.resetAtUnix,
      cycleId: nextCycleId,
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

  const previousCycleId = normalizedCycleId(previous.cycleId);
  const authoritativeCycleChanged = previousCycleId !== null
    && nextCycleId !== null
    && previousCycleId !== nextCycleId;
  const legacyCycleChanged = (previousCycleId === null || nextCycleId === null)
    && Math.abs(previous.canonicalResetAtUnix - input.resetAtUnix)
      > NEW_CYCLE_RESET_DELTA_SECONDS
    && input.usedPercent === 0;
  if (authoritativeCycleChanged || legacyCycleChanged) {
    return changedState({
      canonicalResetAtUnix: input.resetAtUnix,
      cycleId: nextCycleId,
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

  // Adopt an authoritative ID as soon as the backend starts publishing it,
  // without turning that schema transition into a synthetic quota reset.
  const sameCycleState = previous.cycleId === (nextCycleId ?? previousCycleId)
    ? previous
    : { ...previous, cycleId: nextCycleId ?? previousCycleId };

  if (sameCycleState.pendingBoundaryUnix !== null) {
    const canFinalize = updatedAtUnix >= sameCycleState.pendingBoundaryUnix
      && sameCycleState.pendingObservedAtUnix !== null
      && updatedAtUnix > sameCycleState.pendingObservedAtUnix;
    if (!canFinalize) {
      return { state: sameCycleState, shouldRefreshPreciseUsage: false, reason: "unchanged" };
    }
    return changedState({
      ...sameCycleState,
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

  const accountUsedChanged = updatedAtUnix >= sameCycleState.comparisonUpdatedAtUnix
    && Math.abs(input.usedPercent - sameCycleState.observedUsedPercent) > USED_CHANGE_EPSILON;
  if (accountUsedChanged) {
    return updatedWithoutRefresh({
      ...sameCycleState,
      observedUsedPercent: input.usedPercent,
      movementPendingUntilUnix: Math.max(
        sameCycleState.movementPendingUntilUnix ?? Number.NEGATIVE_INFINITY,
        alignedCeil(updatedAtUnix),
      ),
      movementObservedAtUnix: updatedAtUnix,
    }, "usagePending");
  }

  const movementMatured = sameCycleState.movementPendingUntilUnix !== null
    && sameCycleState.movementObservedAtUnix !== null
    && updatedAtUnix >= sameCycleState.movementPendingUntilUnix
    && updatedAtUnix > sameCycleState.movementObservedAtUnix;
  if (movementMatured) {
    return changedState({
      ...sameCycleState,
      observedUsedPercent: input.usedPercent,
      comparisonUpdatedAt: input.updatedAt,
      comparisonUpdatedAtUnix: updatedAtUnix,
      movementPendingUntilUnix: null,
      movementObservedAtUnix: null,
      requiredLocalObservationAfterUnix: updatedAtUnix,
    }, "movementBoundary");
  }

  return { state: sameCycleState, shouldRefreshPreciseUsage: false, reason: "unchanged" };
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

function normalizedCycleId(value: string | null | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
}

function validIdentity(
  identity: QuotaAttributionIdentity | null | undefined,
): identity is QuotaAttributionIdentity {
  return Boolean(identity?.scopeKey.trim() && identity.plan.trim() && identity.limit.trim());
}

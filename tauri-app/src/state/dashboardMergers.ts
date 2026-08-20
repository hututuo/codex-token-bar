import type {
  AccountQuotaBundle,
  ActivityDay,
  DashboardSnapshot,
  DashboardCoverageKind,
  DashboardLineageScalar,
  LiveRateSnapshot,
  LiveThreadOption,
  QuotaHistoryDailyPoint,
  QuotaHistoryPoint,
  RecentUsagePoint,
  UsageSummarySnapshot,
} from "../types/dashboard";
import type { ResetCreditBundle } from "../types/quota";
import type { DashboardAppState } from "./dashboardState";
import {
  mergeQuotaDiagnostics,
  mergeWarnings,
  removeUsagePrecisionWarnings,
  replaceAccountQuotaDiagnostics,
  replaceAccountQuotaWarnings,
  replaceResetCreditDiagnostics,
  replaceResetCreditWarnings,
} from "./dashboardWarnings";

type LineagePayload = {
  homeIdentity?: string | null;
  usageRevision?: DashboardLineageScalar;
  coverageKind?: DashboardCoverageKind | null;
  observedThrough?: DashboardLineageScalar;
  settledThrough?: DashboardLineageScalar;
  exactGeneration?: DashboardLineageScalar;
  dashboardRevision?: DashboardLineageScalar;
  aggregateBoundaryUnix?: DashboardLineageScalar;
  generatedAt?: string | null;
  preciseRecentUsageCoveredAt?: string | null;
  preciseRecentUsageFresh?: boolean;
  /** Pre-lineage exact owner used attribution generation as its receipt. */
  preciseAttributionGeneration?: DashboardLineageScalar;
};

interface NormalizedDashboardLineage {
  homeIdentity: string | null;
  usageRevision: string | null;
  coverageKind: DashboardCoverageKind | null;
  observedThrough: string | null;
  settledThrough: string | null;
  exactGeneration: string | null;
  generatedAt: string | null;
  hasComparableLineage: boolean;
}

type LineageRelation = "incoming-newer" | "incoming-older" | "equal" | "incomparable" | "unknown" | "source-mismatch";

/**
 * Normalize the small cross-owner lineage tuple at the frontend boundary.
 * Numeric revisions stay as decimal strings so a large native u64 is never
 * rounded by JavaScript before it reaches the merge decision.
 */
function normalizeDashboardLineage(
  payload: LineagePayload,
  role: "summary" | "full",
): NormalizedDashboardLineage {
  const homeIdentity = nonEmptyText(payload.homeIdentity);
  const usageRevision = normalizeScalar(payload.usageRevision ?? payload.dashboardRevision);
  const exactGeneration = normalizeScalar(
    payload.exactGeneration
      ?? (role === "full" ? payload.preciseAttributionGeneration : undefined),
  );
  const aggregateBoundary = normalizeBoundaryValue(payload.aggregateBoundaryUnix);
  const fallbackCoveredAt = nonEmptyText(payload.preciseRecentUsageCoveredAt);
  const explicitCoverage = payload.coverageKind === "summary"
    || payload.coverageKind === "settled"
    || payload.coverageKind === "full"
    ? payload.coverageKind
    : null;
  const coverageKind = explicitCoverage
    ?? (role === "summary"
      ? "summary"
      : fallbackCoveredAt !== null || normalizeBoundaryValue(payload.settledThrough) !== null
        ? "settled"
        : null);
  const observedThrough = normalizeBoundaryValue(payload.observedThrough)
    ?? (role === "summary" ? aggregateBoundary : null);
  const settledThrough = normalizeBoundaryValue(payload.settledThrough)
    ?? (role === "summary" ? aggregateBoundary : fallbackCoveredAt ?? aggregateBoundary);
  const generatedAt = nonEmptyText(payload.generatedAt);
  return {
    homeIdentity,
    usageRevision,
    coverageKind,
    observedThrough,
    settledThrough,
    exactGeneration,
    generatedAt,
    hasComparableLineage: homeIdentity !== null
      || usageRevision !== null
      || coverageKind !== null
      || observedThrough !== null
      || settledThrough !== null
      || exactGeneration !== null,
  };
}

function normalizeSummaryLineage(
  dashboard: DashboardSnapshot,
  summary: UsageSummarySnapshot,
): NormalizedDashboardLineage {
  // Do not spread the full dashboard into this object: a full snapshot's
  // coverage kind must not silently become the summary lane's coverage kind.
  return normalizeDashboardLineage({
    homeIdentity: summary.homeIdentity ?? dashboard.homeIdentity,
    usageRevision: summary.usageRevision
      ?? summary.dashboardRevision
      ?? dashboard.usageRevision
      ?? dashboard.dashboardRevision,
    coverageKind: summary.coverageKind ?? "summary",
    observedThrough: summary.observedThrough,
    settledThrough: summary.settledThrough ?? summary.aggregateBoundaryUnix,
    exactGeneration: summary.exactGeneration ?? dashboard.exactGeneration,
    generatedAt: summary.generatedAt ?? dashboard.usageSummaryUpdatedAt,
  }, "summary");
}

function normalizeFullLineage(snapshot: DashboardSnapshot): NormalizedDashboardLineage {
  return normalizeDashboardLineage(snapshot, "full");
}

function nonEmptyText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text.length > 0 ? text : null;
}

function normalizeScalar(value: DashboardLineageScalar | undefined): string | null {
  if (typeof value === "number") {
    return Number.isFinite(value) ? String(value) : null;
  }
  const text = nonEmptyText(value);
  if (text === null) return null;
  if (/^-?\d+$/.test(text)) {
    try {
      return BigInt(text).toString();
    } catch {
      return text;
    }
  }
  return text;
}

function normalizeBoundaryValue(value: DashboardLineageScalar | undefined): string | null {
  return normalizeScalar(value);
}

/**
 * Return the independently meaningful part of the lightweight summary.
 *
 * `aggregateBoundaryUnix` is a cadence/checkpoint receipt, not a change to
 * today's token totals or model rows. `generatedAt` is likewise a native
 * publication timestamp. Keeping both out of this signature prevents a
 * five-minute boundary tick from manufacturing a new summary publication.
 * Exact/usage lineage remains included so a genuinely newer source revision
 * can still advance the summary.
 */
function lightweightUsageSummarySignature(
  dashboard: DashboardSnapshot,
  summary: UsageSummarySnapshot,
): string {
  const coverageKind = summary.coverageKind === "summary"
    || summary.coverageKind === "settled"
    || summary.coverageKind === "full"
    ? summary.coverageKind
    : "summary";
  const modelBreakdowns = (summary.todayModelBreakdowns ?? []).map((item) => [
    item.model ?? null,
    item.eventStartUnix ?? null,
    item.breakdown.inputTokens,
    item.breakdown.cachedInputTokens,
    item.breakdown.outputTokens,
    item.breakdown.totalTokens,
    item.breakdown.calls,
  ]);
  return JSON.stringify([
    summary.totalTokens,
    summary.todayTokens,
    summary.todayRequests,
    modelBreakdowns,
    nonEmptyText(summary.homeIdentity) ?? nonEmptyText(dashboard.homeIdentity),
    normalizeScalar(
      summary.usageRevision
        ?? summary.dashboardRevision
        ?? dashboard.usageRevision
        ?? dashboard.dashboardRevision,
    ),
    coverageKind,
    normalizeBoundaryValue(summary.observedThrough),
    normalizeBoundaryValue(summary.settledThrough),
    normalizeScalar(summary.exactGeneration ?? dashboard.exactGeneration),
  ]);
}

function compareScalar(left: string | null, right: string | null): number | null {
  if (left === null || right === null) return null;
  if (left === right) return 0;
  if (/^-?\d+$/.test(left) && /^-?\d+$/.test(right)) {
    try {
      const a = BigInt(left);
      const b = BigInt(right);
      return a < b ? -1 : 1;
    } catch {
      return null;
    }
  }
  // Non-numeric revisions are opaque. Equality is safe; ordering is not.
  return null;
}

function boundaryRank(value: string): bigint | null {
  if (/^-?\d+$/.test(value)) {
    try {
      // Unix boundaries in payloads are seconds; timestamps are milliseconds.
      return BigInt(value) * 1_000n;
    } catch {
      return null;
    }
  }
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) ? BigInt(Math.trunc(milliseconds)) : null;
}

function compareBoundary(left: string | null, right: string | null): number | null {
  if (left === null || right === null) return null;
  if (left === right) return 0;
  const a = boundaryRank(left);
  const b = boundaryRank(right);
  if (a === null || b === null) return null;
  return a < b ? -1 : 1;
}

function compareGeneratedAt(left: string | null, right: string | null): number | null {
  if (left === null || right === null) return null;
  if (left === right) return 0;
  const a = Date.parse(left);
  const b = Date.parse(right);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return null;
  return a < b ? -1 : 1;
}

/** Compare source lineage first; publication time is only the final tie-break. */
function compareDashboardLineage(
  previous: NormalizedDashboardLineage,
  incoming: NormalizedDashboardLineage,
): LineageRelation {
  if (previous.homeIdentity !== null
    && incoming.homeIdentity !== null
    && previous.homeIdentity !== incoming.homeIdentity) {
    return "source-mismatch";
  }

  const comparisons = [
    compareScalar(previous.exactGeneration, incoming.exactGeneration),
    compareScalar(previous.usageRevision, incoming.usageRevision),
    compareBoundary(previous.observedThrough, incoming.observedThrough),
    compareBoundary(previous.settledThrough, incoming.settledThrough),
  ].filter((value): value is number => value !== null && value !== 0);
  if (comparisons.length > 0) {
    const hasPositive = comparisons.some((value) => value > 0);
    const hasNegative = comparisons.some((value) => value < 0);
    if (hasPositive && hasNegative) return "incomparable";
    return hasPositive ? "incoming-older" : "incoming-newer";
  }

  if (previous.coverageKind !== null
    && incoming.coverageKind !== null
    && previous.coverageKind !== incoming.coverageKind) {
    const rank: Record<DashboardCoverageKind, number> = { summary: 0, settled: 1, full: 2 };
    return rank[incoming.coverageKind] > rank[previous.coverageKind]
      ? "incoming-newer"
      : "incoming-older";
  }

  // generatedAt is intentionally consulted only after every available
  // lineage component tied. It can never establish freshness by itself when
  // one side carries a revision/boundary that the other side lacks.
  if (previous.hasComparableLineage && incoming.hasComparableLineage) {
    const generated = compareGeneratedAt(previous.generatedAt, incoming.generatedAt);
    if (generated !== null && generated !== 0) {
      return generated > 0 ? "incoming-older" : "incoming-newer";
    }
    return "equal";
  }
  return "unknown";
}

function summaryLineageIsNewerThanSettledFull(
  summary: NormalizedDashboardLineage,
  full: NormalizedDashboardLineage,
): boolean {
  if (full.coverageKind !== "settled" || summary.coverageKind !== "summary") {
    return false;
  }
  if (summary.observedThrough === null) {
    // An explicitly settled-only full cannot prove it supersedes a summary
    // with no open-boundary receipt. Keep the summary conservatively.
    return !summary.hasComparableLineage || full.settledThrough === null;
  }
  const comparison = compareBoundary(summary.observedThrough, full.settledThrough);
  return comparison === null || comparison >= 0;
}

function shouldRetainSummaryForFull(
  dashboard: DashboardSnapshot,
  precise: DashboardSnapshot,
): boolean {
  const summary = dashboard.usageSummary;
  if (summary === null || summary === undefined) return false;
  const previousSummaryLineage = normalizeSummaryLineage(dashboard, summary);
  const incomingFullLineage = normalizeFullLineage(precise);
  if (summaryLineageIsNewerThanSettledFull(previousSummaryLineage, incomingFullLineage)) {
    return true;
  }
  const relation = compareDashboardLineage(previousSummaryLineage, incomingFullLineage);
  if (relation === "incoming-older" || relation === "incomparable" || relation === "source-mismatch") {
    return true;
  }
  if (relation === "unknown") {
    // A full snapshot with no receipt cannot displace a summary that already
    // carries a receipt. A trusted full snapshot may replace a legacy summary
    // only when that summary has no comparable lineage at all.
    return previousSummaryLineage.hasComparableLineage
      || incomingFullLineage.coverageKind !== "full";
  }
  return false;
}

function hasMaterializedDashboard(snapshot: DashboardSnapshot): boolean {
  const values = [
    snapshot.stats.totalTokens,
    snapshot.stats.peakDayTokens,
    snapshot.stats.peakThreadTokens,
    snapshot.stats.totalCalls,
    snapshot.stats.totalThreads,
  ];
  return snapshot.usageSummary !== null
    && snapshot.usageSummary !== undefined
    || values.some((value) => Number.isFinite(value) && value > 0)
    || [snapshot.recentUsage24h, snapshot.recentUsage7d, snapshot.recentUsage30d]
      .some((points) => points.some((point) => point.tokens > 0 || point.calls > 0));
}

function validBoundary(value: string | null): boolean {
  return value !== null && boundaryRank(value) !== null;
}

export function mergePreciseDashboard(
  state: DashboardAppState,
  precise: DashboardSnapshot,
): DashboardAppState {
  const previous = state.dashboard;
  const incomingLineage = normalizeFullLineage(precise);
  const incomingCoverageAt = nonEmptyText(precise.preciseRecentUsageCoveredAt)
    ?? incomingLineage.settledThrough;
  const incomingCoverageIsTrusted = precise.preciseRecentUsageFresh === true
    && validBoundary(incomingCoverageAt);
  const previousCoverageAt = previous === null
    ? null
    : nonEmptyText(previous.preciseRecentUsageCoveredAt) ?? normalizeFullLineage(previous).settledThrough;
  const previousCoverageIsTrusted = previous !== null
    && previous.preciseRecentUsageFresh === true
    && validBoundary(previousCoverageAt);

  if (previous !== null) {
    if (previousLineageHomeMismatch(previous, precise)) {
      return state;
    }

    // A successful but older exact result is still not new truth. This guard
    // is separate from the failure path so a late native completion cannot
    // roll the settled canvas back even when both reads report fresh=true.
    const previousFullLineage = normalizeFullLineage(previous);
    const fullRelation = compareDashboardLineage(previousFullLineage, incomingLineage);
    if (incomingCoverageIsTrusted
      && previousFullLineage.hasComparableLineage
      && (fullRelation === "incoming-older" || fullRelation === "incomparable")) {
      return state;
    }
  }

  const previousHasLastGood = previous !== null
    && (previousCoverageIsTrusted || hasMaterializedDashboard(previous));
  if (previous !== null && !incomingCoverageIsTrusted && previousHasLastGood) {
    // A failed/incomplete owner result is a status update, not a new usage
    // truth. Keep every last-good payload field and only publish status and
    // diagnostics from the failed attempt.
    return {
      ...state,
      dashboard: {
        ...previous,
        preciseRecentUsageFresh: false,
        preciseAttributionCurrentScanUnsafe: previous.preciseAttributionCurrentScanUnsafe
          || precise.preciseAttributionCurrentScanUnsafe,
        warnings: mergeWarnings(
          removeUsagePrecisionWarnings(previous.warnings),
          precise.warnings,
        ),
        diagnostics: mergeQuotaDiagnostics(
          previous.diagnostics ?? [],
          precise.diagnostics ?? [],
        ),
      },
    };
  }

  const incomingLightSummary = precise.usageSummary ?? null;
  const retainLightSummaryForLineage = previous !== null && incomingCoverageIsTrusted
    && shouldRetainSummaryForFull(previous, precise);
  // Native full dashboard payloads intentionally do not carry the independent
  // lightweight summary lane. A successful chart publish must not erase the
  // already trusted today-model summary or reset its freshness to false.
  const retainLightSummaryBecauseIncomingIsAbsent = previous?.usageSummary != null
    && incomingLightSummary === null;
  const retainedLightSummary = previous !== null
    && (retainLightSummaryForLineage || retainLightSummaryBecauseIncomingIsAbsent)
    ? previous.usageSummary ?? null
    : null;
  const nextLightSummary = retainedLightSummary ?? incomingLightSummary;
  const summaryUpdatedAt = retainedLightSummary?.generatedAt
    ?? (retainedLightSummary !== null ? previous?.usageSummaryUpdatedAt : null)
    ?? precise.usageSummaryUpdatedAt
    ?? (nextLightSummary === null ? precise.generatedAt : nextLightSummary.generatedAt)
    ?? null;
  return {
    ...state,
    dashboard:
      previous === null
        ? precise
        : {
            ...precise,
            homeIdentity: precise.homeIdentity ?? previous.homeIdentity ?? null,
            usageRevision: precise.usageRevision ?? previous.usageRevision ?? null,
            coverageKind: precise.coverageKind ?? previous.coverageKind ?? null,
            observedThrough: precise.observedThrough ?? previous.observedThrough ?? null,
            settledThrough: precise.settledThrough
              ?? (incomingCoverageIsTrusted ? incomingCoverageAt : null)
              ?? previous.settledThrough
              ?? null,
            exactGeneration: precise.exactGeneration ?? previous.exactGeneration ?? null,
            dashboardRevision: precise.dashboardRevision ?? previous.dashboardRevision ?? null,
            aggregateBoundaryUnix: precise.aggregateBoundaryUnix
              ?? previous.aggregateBoundaryUnix
              ?? null,
            usageSummary: nextLightSummary,
            usageSummaryUpdatedAt: summaryUpdatedAt,
            usageSummaryFresh: retainedLightSummary !== null
              ? previous.usageSummaryFresh !== false
              : incomingLightSummary !== null
                ? precise.usageSummaryFresh !== false
                : false,
            stats: retainedLightSummary === null || !retainLightSummaryForLineage
              ? precise.stats
              : {
                  ...precise.stats,
                  totalTokens: Math.max(0, retainedLightSummary.totalTokens),
                },
            // An incomplete scan intentionally publishes no new coverage
            // watermark. Keep the previous trusted watermark so the UI can
            // continue showing last-good data with a stale indicator instead
            // of falling back to the all-zero startup canvas.
            preciseRecentUsageCoveredAt: incomingCoverageIsTrusted
              ? incomingCoverageAt
              : previous.preciseRecentUsageCoveredAt ?? null,
            preciseRecentUsageFresh: incomingCoverageIsTrusted,
            preciseObserverEpoch: incomingCoverageIsTrusted
              ? precise.preciseObserverEpoch
              : previous.preciseObserverEpoch ?? null,
            preciseObserverStartedAtUnixMicros: incomingCoverageIsTrusted
              ? precise.preciseObserverStartedAtUnixMicros
              : previous.preciseObserverStartedAtUnixMicros ?? null,
            preciseObserverSequence: incomingCoverageIsTrusted
              ? precise.preciseObserverSequence
              : previous.preciseObserverSequence ?? null,
            preciseAttributionProvenanceEpoch: incomingCoverageIsTrusted
              ? precise.preciseAttributionProvenanceEpoch
              : previous.preciseAttributionProvenanceEpoch ?? null,
            preciseAttributionGeneration: incomingCoverageIsTrusted
              ? precise.preciseAttributionGeneration
              : previous.preciseAttributionGeneration ?? null,
            preciseAttributionUnsafeSinceGeneration: incomingCoverageIsTrusted
              ? precise.preciseAttributionUnsafeSinceGeneration
              : previous.preciseAttributionUnsafeSinceGeneration ?? null,
            preciseAttributionUnsafeId: incomingCoverageIsTrusted
              ? precise.preciseAttributionUnsafeId
              : previous.preciseAttributionUnsafeId ?? null,
            preciseAttributionCurrentScanUnsafe: incomingCoverageIsTrusted
              ? precise.preciseAttributionCurrentScanUnsafe
              : true,
            quotaUpdatedAt: previous.quotaUpdatedAt ?? null,
            attributionIdentity: previous.attributionIdentity ?? null,
            account: previous.account,
            quota: previous.quota,
            activityDays: mergeActivityQuotaHistory(precise.activityDays, previous.activityDays),
            recentUsage24h: mergeQuotaHistory(precise.recentUsage24h, previous.recentUsage24h),
            recentUsage7d: mergeQuotaHistory(precise.recentUsage7d, previous.recentUsage7d),
            recentUsage30d: mergeQuotaHistory(precise.recentUsage30d, previous.recentUsage30d),
            warnings: mergeWarnings(removeUsagePrecisionWarnings(previous.warnings), precise.warnings),
            diagnostics: mergeQuotaDiagnostics(previous.diagnostics ?? [], precise.diagnostics ?? []),
          },
  };
}

function previousLineageHomeMismatch(
  previous: DashboardSnapshot,
  incoming: DashboardSnapshot,
): boolean {
  const previousHome = normalizeFullLineage(previous).homeIdentity;
  const incomingHome = normalizeFullLineage(incoming).homeIdentity;
  return previousHome !== null && incomingHome !== null && previousHome !== incomingHome;
}

/**
 * Apply the lightweight exact-index summary without touching charts,
 * rankings, quota history, or the last settled aggregate watermark.
 */
export function mergeUsageSummary(
  state: DashboardAppState,
  summary: UsageSummarySnapshot,
  generatedAt?: string,
): DashboardAppState {
  const dashboard = state.dashboard;
  if (dashboard === null) return state;

  const publicationAt = nonEmptyText(generatedAt) ?? nonEmptyText(summary.generatedAt);
  const incomingSummary = publicationAt === null || summary.generatedAt === publicationAt
    ? summary
    : { ...summary, generatedAt: publicationAt };
  const incomingLineage = normalizeSummaryLineage(dashboard, incomingSummary);
  const previousSummary = dashboard.usageSummary;
  if (previousSummary !== null && previousSummary !== undefined) {
    const previousLineage = normalizeSummaryLineage(dashboard, previousSummary);
    const relation = compareDashboardLineage(previousLineage, incomingLineage);
    if (relation === "incoming-older") {
      // A cache-only native read can legitimately return an older publication
      // while the dashboard already holds a newer summary from the same
      // source. Do not roll the payload back, but do finish the lightweight
      // refresh: the retained payload is strictly newer than the successful
      // read and remains the best trusted summary.
      return dashboard.usageSummaryFresh !== false
        ? state
        : {
            ...state,
            dashboard: {
              ...dashboard,
              usageSummaryFresh: true,
            },
          };
    }
    if (relation === "source-mismatch"
      || relation === "incomparable"
      || (relation === "unknown"
        && previousLineage.hasComparableLineage
        && !incomingLineage.hasComparableLineage)) {
      return state;
    }

    const summarySignature = lightweightUsageSummarySignature(dashboard, incomingSummary);
    const previousSignature = lightweightUsageSummarySignature(dashboard, previousSummary);
    if (summarySignature === previousSignature
      && dashboard.stats.totalTokens === incomingSummary.totalTokens) {
      // Boundary receipts and native publication clocks are intentionally not
      // UI changes. Returning the existing state also keeps StatsStrip's
      // memoized props referentially stable during a quiet cadence tick.
      if (dashboard.usageSummaryFresh !== false) {
        return state;
      }
      return {
        ...state,
        dashboard: {
          ...dashboard,
          usageSummaryFresh: true,
        },
      };
    }
  }

  return {
    ...state,
    dashboard: {
      ...dashboard,
      usageSummaryUpdatedAt: publicationAt ?? dashboard.usageSummaryUpdatedAt ?? null,
      usageSummary: {
        ...incomingSummary,
      },
      usageSummaryFresh: true,
      stats: {
        ...dashboard.stats,
        totalTokens: Math.max(0, incomingSummary.totalTokens),
      },
    },
  };
}

/**
 * Mark only the lightweight summary as in flight. Chart buckets and their
 * precise coverage remain untouched; the model card can keep showing the last
 * trusted rows with its own stale state while the compact owner retries.
 */
export function markUsageSummaryStale(state: DashboardAppState): DashboardAppState {
  if (state.dashboard === null || state.dashboard.usageSummaryFresh === false) {
    return state;
  }
  return {
    ...state,
    dashboard: {
      ...state.dashboard,
      usageSummaryFresh: false,
    },
  };
}

export function markPreciseRecentUsageStale(state: DashboardAppState): DashboardAppState {
  if (state.dashboard === null || state.dashboard.preciseRecentUsageFresh === false) {
    return state;
  }
  return {
    ...state,
    dashboard: {
      ...state.dashboard,
      preciseRecentUsageFresh: false,
    },
  };
}

/**
 * The native safety acknowledgement only removes an already-reviewed
 * attribution episode marker. It does not change token usage or quota data,
 * so the UI can clear the marker locally and wait for the next scheduled
 * source probe instead of forcing a second full exact scan immediately.
 */
export function clearPreciseAttributionSafety(
  state: DashboardAppState,
): DashboardAppState {
  const dashboard = state.dashboard;
  if (dashboard === null
    || (dashboard.preciseAttributionUnsafeSinceGeneration == null
      && dashboard.preciseAttributionUnsafeId == null
      && dashboard.preciseAttributionCurrentScanUnsafe !== true)) {
    return state;
  }
  return {
    ...state,
    dashboard: {
      ...dashboard,
      preciseAttributionUnsafeSinceGeneration: null,
      preciseAttributionUnsafeId: null,
      preciseAttributionCurrentScanUnsafe: false,
    },
  };
}

export function mergeQuota(state: DashboardAppState, quota: AccountQuotaBundle): DashboardAppState {
  const dashboard =
    state.dashboard === null
      ? null
      : {
          ...state.dashboard,
          quotaUpdatedAt: quota.updatedAt,
          attributionIdentity: quota.attributionIdentity ?? null,
          account: quota.account,
          quota: {
            ...quota.quota,
            resetCredit: state.dashboard.quota.resetCredit,
          },
          activityDays: mergeActivityQuotaHistory(state.dashboard.activityDays, quota.quotaHistoryDaily),
          recentUsage24h: mergeQuotaHistory(state.dashboard.recentUsage24h, quota.quotaHistory24h),
          recentUsage7d: mergeQuotaHistory(state.dashboard.recentUsage7d, quota.quotaHistory7d),
          recentUsage30d: mergeQuotaHistory(state.dashboard.recentUsage30d, quota.quotaHistory30d),
          warnings: replaceAccountQuotaWarnings(state.dashboard.warnings, quota.warnings),
          diagnostics: replaceAccountQuotaDiagnostics(
            state.dashboard.diagnostics ?? [],
            quota.diagnostics ?? [],
          ),
        };
  return {
    ...state,
    dashboard,
  };
}

export function mergeResetCredits(
  state: DashboardAppState,
  reset: ResetCreditBundle,
): DashboardAppState {
  if (state.dashboard === null) {
    return state;
  }
  const previous = state.dashboard.quota.resetCredit;
  const resetCredit = reset.successful
    ? { ...reset.resetCredit, updatedAt: reset.updatedAt }
    : {
        ...previous,
        status: reset.resetCredit.status,
        updatedAt: previous.updatedAt ?? null,
      };
  return {
    ...state,
    dashboard: {
      ...state.dashboard,
      quota: {
        ...state.dashboard.quota,
        resetCredit,
      },
      warnings: replaceResetCreditWarnings(state.dashboard.warnings, reset.warnings),
      diagnostics: replaceResetCreditDiagnostics(
        state.dashboard.diagnostics ?? [],
        reset.diagnostics ?? [],
      ),
    },
  };
}

export function mergeLiveRate(
  state: DashboardAppState,
  liveRate: LiveRateSnapshot,
): DashboardAppState {
  return {
    ...state,
    liveRate,
  };
}

export function mergeLiveThreadOptions(
  state: DashboardAppState,
  liveThreadOptions: LiveThreadOption[],
): DashboardAppState {
  return {
    ...state,
    liveThreadOptions,
  };
}

function mergeActivityQuotaHistory(
  days: ActivityDay[],
  historyDays: Array<QuotaHistoryDailyPoint | ActivityDay>,
): ActivityDay[] {
  if (historyDays.length === 0) {
    return days;
  }

  const historyByDate = new Map(historyDays.map((day) => [day.date, day]));
  return days.map((day) => {
    const history = historyByDate.get(day.date);
    if (history === undefined) {
      return day;
    }
    return {
      ...day,
      fiveHourRemainingPercent: history.fiveHourRemainingPercent,
      sevenDayRemainingPercent: history.sevenDayRemainingPercent,
    };
  });
}

function mergeQuotaHistory(points: RecentUsagePoint[], historyPoints: QuotaHistoryPoint[]): RecentUsagePoint[] {
  if (historyPoints.length === 0) {
    return points;
  }

  const historyByStart = new Map(historyPoints.map((point) => [point.startUnix, point]));
  return points.map((point) => {
    const history = historyByStart.get(point.startUnix);
    if (history === undefined) {
      return point;
    }
    return {
      ...point,
      fiveHourRemainingPercent: history.fiveHourRemainingPercent,
      sevenDayRemainingPercent: history.sevenDayRemainingPercent,
    };
  });
}

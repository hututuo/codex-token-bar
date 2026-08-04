import {
  quotaRadarWindowAvailable,
  type CodexRadarQuotaRadar,
  type CodexRadarQuotaRow,
} from "../../domain/codexRadar/model.ts";
import type { OfficialAPIPriceModel, QuotaPriceBasis } from "../../settings/quotaPriceModel";
import { modelAwareAPICostUSD } from "../../settings/quotaPriceModel.ts";
import type { SharedAccountRadarTier } from "../../settings/sharedAccountAttribution";
import type { QuotaAttributionIdentity, QuotaLimit } from "../../types/dashboard";
import { ATTRIBUTION_BUCKET_SECONDS, type AttributionTokenBucket } from "./highWater.ts";
import {
  ATTRIBUTION_RESET_GRACE_SECONDS,
  type AttributionCutoverReason,
  type AttributionSegmentStatus,
  type StoredAttributionSegment,
} from "./segment.ts";

const SEVEN_DAYS_SECONDS = 7 * 24 * 60 * 60;
export const SHARED_ACCOUNT_ATTRIBUTION_TOLERANCE_PERCENTAGE_POINTS = 2;

export type SharedAccountAttributionStatus =
  | "disabled"
  | "attributionStorageUnavailable"
  | "nativeHistoryUnsafe"
  | "persistenceRebaseline"
  | "preciseDataUnavailable"
  | "preciseDataStale"
  | "quotaUnavailable"
  | "quotaResetUnavailable"
  | "identityUnavailable"
  | "quotaTimestampUnavailable"
  | "radarUnavailable"
  | "radarTierUnavailable"
  | "pricingVersionUnavailable"
  | "awaitingAccountSwitchBaseline"
  | "localHistoryAmbiguous"
  | "waitingQuotaRefresh"
  | "indistinguishable"
  | "positiveResidual"
  | "negativeResidual";

export type SharedAccountPricingBasisStatus = "legacyRadarBasis" | "currentBasis" | "unknown";

export interface SharedAccountTokenBreakdown {
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  totalTokens: number;
  calls: number;
  bucketCount: number;
}

export interface SharedAccountAttributionResult {
  status: SharedAccountAttributionStatus;
  pricingBasisStatus: SharedAccountPricingBasisStatus;
  priceBasis: QuotaPriceBasis | null;
  priceModel: OfficialAPIPriceModel;
  selectedTier: SharedAccountRadarTier;
  selectedTierLabel: string;
  cutoverReason: AttributionCutoverReason;
  accountRawUsedPercent: number | null;
  baselineAccountUsedPercent: number | null;
  accountUsedPercent: number | null;
  localSharePercent: number | null;
  residualPercent: number | null;
  localComparableUSD: number | null;
  scannedLocalComparableUSD: number | null;
  localCurrentAPIEquivalentUSD: number | null;
  scannedLocalCurrentAPIEquivalentUSD: number | null;
  scannedLocalRadar20260730EquivalentUSD: number | null;
  historyChangedLowConfidence: boolean;
  usagePendingQuotaRefresh: boolean;
  quotaDataStale: boolean;
  radarDataStale: boolean;
  preciseDataFresh: boolean;
  preciseDataCoveredAtUnix: number | null;
  radarPlanTotalUSD: number | null;
  radarDate: string;
  radarPricingBasisDate: string;
  radarBasis: string;
  radarUpdatedAt: string;
  radarSource: string;
  cycleStartUnix: number | null;
  cycleEndUnix: number | null;
  segmentStartUnix: number | null;
  quotaUpdatedAtUnix: number | null;
  tokens: SharedAccountTokenBreakdown;
  scannedTokens: SharedAccountTokenBreakdown;
}

export interface SharedAccountAttributionInput {
  enabled: boolean;
  storageHealthy: boolean;
  nativeHistoryUnsafe: boolean;
  persistenceRebaseline: boolean;
  preciseDataAvailable: boolean;
  preciseDataFresh: boolean;
  preciseDataCoveredAtUnix: number | null;
  buckets: AttributionTokenBucket[];
  scannedBuckets: AttributionTokenBucket[];
  usagePendingQuotaRefresh: boolean;
  historyChangedLowConfidence: boolean;
  localHistoryAmbiguous: boolean;
  quotaDataStale: boolean;
  radarDataStale: boolean;
  sevenDayQuota: QuotaLimit;
  quotaRadar: CodexRadarQuotaRadar | null;
  selectedTier: SharedAccountRadarTier;
  priceModel: OfficialAPIPriceModel;
  segmentStatus: AttributionSegmentStatus;
  segment: StoredAttributionSegment | null;
  quotaUpdatedAtUnix: number | null;
  nowUnix?: number;
}

export function estimateSharedAccountAttribution({
  enabled,
  storageHealthy,
  nativeHistoryUnsafe,
  persistenceRebaseline,
  preciseDataAvailable,
  preciseDataFresh,
  preciseDataCoveredAtUnix,
  buckets,
  scannedBuckets,
  usagePendingQuotaRefresh,
  historyChangedLowConfidence,
  localHistoryAmbiguous,
  quotaDataStale,
  radarDataStale,
  sevenDayQuota,
  quotaRadar,
  selectedTier,
  priceModel,
  segmentStatus,
  segment,
  quotaUpdatedAtUnix,
  nowUnix = Date.now() / 1_000,
}: SharedAccountAttributionInput): SharedAccountAttributionResult {
  const base = {
    ...emptyResult(selectedTier, priceModel, quotaRadar),
    cutoverReason: segment?.cutoverReason ?? "none",
    quotaDataStale,
    radarDataStale,
    preciseDataFresh,
    preciseDataCoveredAtUnix,
  };
  if (!enabled) return { ...base, status: "disabled" };
  if (nativeHistoryUnsafe) return { ...base, status: "nativeHistoryUnsafe" };
  if (persistenceRebaseline) return { ...base, status: "persistenceRebaseline" };
  if (!storageHealthy) return { ...base, status: "attributionStorageUnavailable" };
  if (!preciseDataAvailable) return { ...base, status: "preciseDataUnavailable" };
  if (!preciseDataFresh) return { ...base, status: "preciseDataStale" };

  if (sevenDayQuota.availability !== "measured"
    || sevenDayQuota.usedPercent === null
    || !Number.isFinite(sevenDayQuota.usedPercent)) {
    return { ...base, status: "quotaUnavailable" };
  }

  const observedResetUnix = sevenDayQuota.resetsAtUnix;
  if (typeof observedResetUnix !== "number"
    || !Number.isFinite(observedResetUnix)
    || observedResetUnix <= 0) {
    return { ...base, status: "quotaResetUnavailable" };
  }
  const resetUnix = segment !== null
    && Math.abs(segment.resetAtUnix - observedResetUnix) <= ATTRIBUTION_RESET_GRACE_SECONDS
    ? segment.resetAtUnix
    : observedResetUnix;
  if (resetUnix <= nowUnix) {
    return {
      ...base,
      status: "waitingQuotaRefresh",
      accountRawUsedPercent: quotaValueToPercentagePoints(sevenDayQuota.usedPercent),
      cycleStartUnix: resetUnix - SEVEN_DAYS_SECONDS,
      cycleEndUnix: resetUnix,
    };
  }

  if (segmentStatus === "identityUnavailable") {
    return { ...base, status: "identityUnavailable" };
  }
  if (segmentStatus === "quotaTimestampUnavailable"
    || quotaUpdatedAtUnix === null
    || !Number.isFinite(quotaUpdatedAtUnix)) {
    return { ...base, status: "quotaTimestampUnavailable" };
  }
  if (!segment) {
    return { ...base, status: "identityUnavailable" };
  }
  if (segmentStatus === "awaitingAccountSwitchBaseline"
    || !segment.baselineReady
    || segment.baselineAccountUsedPercent === null) {
    return { ...base, status: "awaitingAccountSwitchBaseline" };
  }
  if (!preciseUsageCoversQuota({
    preciseDataAvailable,
    preciseDataFresh,
    preciseDataCoveredAtUnix,
    quotaUpdatedAtUnix,
    requiredLocalObservationAfterUnix: segment.requiredLocalObservationAfterUnix,
  })) {
    return { ...base, status: "preciseDataStale" };
  }

  if (!quotaRadar) return { ...base, status: "radarUnavailable" };
  if (!quotaRadarWindowAvailable(quotaRadar, "sevenDay")) {
    return { ...base, status: "radarTierUnavailable" };
  }
  const tierRow = quotaRadar.rows.find((row) => radarTierForRow(row) === selectedTier) ?? null;
  // Attribution is strictly local USD / Radar 7d USD. A five-hour value is never
  // borrowed to fabricate a missing seven-day plan total.
  if (!tierRow || tierRow.sevenD === null || !Number.isFinite(tierRow.sevenD) || tierRow.sevenD <= 0) {
    return { ...base, status: "radarTierUnavailable" };
  }

  const radarPricingBasisDate = normalizedRadarDate(quotaRadar.basisDate);
  const priceBasis = radarCompatiblePriceBasis(quotaRadar);
  if (!priceBasis) {
    return { ...base, status: "pricingVersionUnavailable", radarPlanTotalUSD: tierRow.sevenD };
  }

  const tokens = aggregateAttributionBuckets(buckets);
  const scannedTokens = aggregateAttributionBuckets(scannedBuckets);
  const localRadar20260730EquivalentUSD = costForBreakdown(tokens, buckets, priceModel, "radar20260730");
  const localCurrentAPIEquivalentUSD = costForBreakdown(tokens, buckets, priceModel, "current");
  const scannedLocalRadar20260730EquivalentUSD = costForBreakdown(
    scannedTokens,
    scannedBuckets,
    priceModel,
    "radar20260730",
  );
  const scannedLocalCurrentAPIEquivalentUSD = costForBreakdown(
    scannedTokens,
    scannedBuckets,
    priceModel,
    "current",
  );
  const localComparableUSD = priceBasis === "radar20260730"
    ? localRadar20260730EquivalentUSD
    : localCurrentAPIEquivalentUSD;
  const scannedLocalComparableUSD = priceBasis === "radar20260730"
    ? scannedLocalRadar20260730EquivalentUSD
    : scannedLocalCurrentAPIEquivalentUSD;
  const accountRawUsedPercent = quotaValueToPercentagePoints(sevenDayQuota.usedPercent);
  const accountUsedPercent = Math.max(
    0,
    accountRawUsedPercent - segment.baselineAccountUsedPercent,
  );
  const localSharePercent = (localComparableUSD / tierRow.sevenD) * 100;
  const residualPercent = accountUsedPercent - localSharePercent;
  const effectiveUsagePendingQuotaRefresh = usagePendingQuotaRefresh
    || segment.quotaMovementPendingUntilUnix !== null;
  const status = effectiveUsagePendingQuotaRefresh
    || quotaDataStale
    || radarDataStale
    ? "waitingQuotaRefresh"
    : localHistoryAmbiguous
      ? "localHistoryAmbiguous"
      : attributionOutcome(accountUsedPercent, localSharePercent, residualPercent);
  const safeResidualPercent = status === "waitingQuotaRefresh"
    || status === "localHistoryAmbiguous"
    ? null
    : residualPercent;

  return {
    ...base,
    status,
    pricingBasisStatus: priceBasis === "radar20260730" ? "legacyRadarBasis" : "currentBasis",
    priceBasis,
    accountRawUsedPercent,
    baselineAccountUsedPercent: segment.baselineAccountUsedPercent,
    accountUsedPercent,
    localSharePercent,
    residualPercent: safeResidualPercent,
    localComparableUSD,
    scannedLocalComparableUSD,
    localCurrentAPIEquivalentUSD,
    scannedLocalCurrentAPIEquivalentUSD,
    scannedLocalRadar20260730EquivalentUSD,
    historyChangedLowConfidence,
    usagePendingQuotaRefresh: effectiveUsagePendingQuotaRefresh,
    quotaDataStale,
    radarDataStale,
    radarPlanTotalUSD: tierRow.sevenD,
    radarPricingBasisDate,
    cycleStartUnix: resetUnix - SEVEN_DAYS_SECONDS,
    cycleEndUnix: resetUnix,
    segmentStartUnix: segment.segmentStartUnix,
    quotaUpdatedAtUnix,
    tokens,
    scannedTokens,
  };
}

export function preciseUsageCoversQuota({
  preciseDataAvailable,
  preciseDataFresh,
  preciseDataCoveredAtUnix,
  quotaUpdatedAtUnix,
  requiredLocalObservationAfterUnix = null,
}: Pick<
  SharedAccountAttributionInput,
  "preciseDataAvailable" | "preciseDataFresh" | "preciseDataCoveredAtUnix" | "quotaUpdatedAtUnix"
> & { requiredLocalObservationAfterUnix?: number | null }): boolean {
  const comparisonBoundaryUnix = quotaUpdatedAtUnix === null
    ? null
    : Math.floor(quotaUpdatedAtUnix / ATTRIBUTION_BUCKET_SECONDS) * ATTRIBUTION_BUCKET_SECONDS;
  const requiredCoverageUnix = comparisonBoundaryUnix === null
    ? null
    : Math.max(comparisonBoundaryUnix, requiredLocalObservationAfterUnix ?? comparisonBoundaryUnix);
  return preciseDataAvailable
    && preciseDataFresh
    && preciseDataCoveredAtUnix !== null
    && Number.isFinite(preciseDataCoveredAtUnix)
    && requiredCoverageUnix !== null
    && Number.isFinite(requiredCoverageUnix)
    && preciseDataCoveredAtUnix >= requiredCoverageUnix;
}

export function radarTierForRow(row: Pick<CodexRadarQuotaRow, "tier">): SharedAccountRadarTier | null {
  const normalized = row.tier
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[×✕]/g, "x")
    .replace(/[^a-z0-9\u4e00-\u9fff]+/g, "");
  if (["20xpro", "pro20x", "chatgptpro20x", "20pro", "pro20"].includes(normalized)) {
    return "pro20x";
  }
  if (["5xpro", "pro5x", "chatgptpro5x", "5pro", "pro5"].includes(normalized)) {
    return "pro5x";
  }
  if (["plus", "chatgptplus", "plusplan", "加享"].includes(normalized)) return "plus";
  return null;
}

export function quotaValueToPercentagePoints(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return value >= 0 && value <= 1 ? value * 100 : value;
}

export function radarCompatiblePriceBasis(
  radar: Pick<CodexRadarQuotaRadar, "basisDate" | "sourceKind" | "sevenDayPolicy"> | null,
): QuotaPriceBasis | null {
  if (!radar) return null;
  const radarDate = normalizedRadarDate(radar.basisDate);
  if (radarDate === "2026-07-30") return "radar20260730";
  if (radarDate === "2026-07-31") return "current";
  if (radarDate > "2026-07-31"
    && normalizedSemanticKey(radar.sourceKind) === "quotaapi"
    && normalizedSemanticKey(radar.sevenDayPolicy) === "directquotaapi") {
    return "current";
  }
  return null;
}

/** Explicit invalidation signature for compatibility-sensitive Radar/account fields. */
export function sharedAccountAttributionInputSignature(
  quotaRadar: Pick<CodexRadarQuotaRadar, "basisDate" | "sevenDayPolicy"> | null,
  identity: Pick<QuotaAttributionIdentity, "plan"> | null | undefined,
): string {
  return JSON.stringify([
    quotaRadar?.basisDate ?? "",
    quotaRadar?.sevenDayPolicy ?? "",
    identity?.plan ?? "",
  ]);
}

export function aggregateAttributionBuckets(
  buckets: AttributionTokenBucket[],
): SharedAccountTokenBreakdown {
  return buckets.reduce<SharedAccountTokenBreakdown>((total, bucket) => ({
    inputTokens: total.inputTokens + finiteNonnegative(bucket.inputTokens),
    cachedInputTokens: total.cachedInputTokens + Math.min(
      finiteNonnegative(bucket.cachedInputTokens),
      finiteNonnegative(bucket.inputTokens),
    ),
    outputTokens: total.outputTokens + finiteNonnegative(bucket.outputTokens),
    totalTokens: total.totalTokens + finiteNonnegative(bucket.totalTokens),
    calls: total.calls + finiteNonnegative(bucket.calls),
    bucketCount: total.bucketCount + 1,
  }), emptyTokenBreakdown());
}

export function sharedAccountTierLabel(tier: SharedAccountRadarTier): string {
  switch (tier) {
    case "pro20x": return "20x Pro";
    case "pro5x": return "5x Pro";
    case "plus": return "Plus";
  }
}

function attributionOutcome(
  accountUsedPercent: number,
  localSharePercent: number,
  residualPercent: number,
): SharedAccountAttributionStatus {
  if (accountUsedPercent <= 0.0001 && localSharePercent > 0.0001) return "waitingQuotaRefresh";
  if (Math.abs(residualPercent) <= SHARED_ACCOUNT_ATTRIBUTION_TOLERANCE_PERCENTAGE_POINTS) {
    return "indistinguishable";
  }
  return residualPercent > 0 ? "positiveResidual" : "negativeResidual";
}

function costForBreakdown(
  breakdown: SharedAccountTokenBreakdown,
  buckets: AttributionTokenBucket[],
  priceModel: OfficialAPIPriceModel,
  basis: QuotaPriceBasis,
): number {
  const modelBreakdowns = buckets.every((bucket) => (
    bucket.modelTrackingComplete === true && Array.isArray(bucket.modelBreakdowns)
  ))
    ? buckets.flatMap((bucket) => bucket.modelBreakdowns ?? [])
    : [];
  return modelAwareAPICostUSD(
    modelBreakdowns,
    {
      inputTokens: breakdown.inputTokens,
      cachedInputTokens: breakdown.cachedInputTokens,
      outputTokens: breakdown.outputTokens,
      calls: breakdown.calls,
    },
    priceModel,
    basis,
  ).costUSD;
}

function emptyResult(
  selectedTier: SharedAccountRadarTier,
  priceModel: OfficialAPIPriceModel,
  quotaRadar: CodexRadarQuotaRadar | null,
): SharedAccountAttributionResult {
  const tierRow = quotaRadar?.rows.find((row) => radarTierForRow(row) === selectedTier) ?? null;
  const radarPlanTotalUSD = quotaRadar
    && quotaRadarWindowAvailable(quotaRadar, "sevenDay")
    && tierRow?.sevenD !== null
    && Number.isFinite(tierRow?.sevenD)
    && (tierRow?.sevenD ?? 0) > 0
    ? tierRow?.sevenD ?? null
    : null;
  const radarPricingBasisDate = normalizedRadarDate(quotaRadar?.basisDate || "");
  const priceBasis = radarCompatiblePriceBasis(quotaRadar);
  return {
    status: "radarUnavailable",
    pricingBasisStatus: priceBasis === "radar20260730"
      ? "legacyRadarBasis"
      : priceBasis === "current" ? "currentBasis" : "unknown",
    priceBasis,
    priceModel,
    selectedTier,
    selectedTierLabel: sharedAccountTierLabel(selectedTier),
    cutoverReason: "none",
    accountRawUsedPercent: null,
    baselineAccountUsedPercent: null,
    accountUsedPercent: null,
    localSharePercent: null,
    residualPercent: null,
    localComparableUSD: null,
    scannedLocalComparableUSD: null,
    localCurrentAPIEquivalentUSD: null,
    scannedLocalCurrentAPIEquivalentUSD: null,
    scannedLocalRadar20260730EquivalentUSD: null,
    historyChangedLowConfidence: false,
    usagePendingQuotaRefresh: false,
    quotaDataStale: false,
    radarDataStale: false,
    preciseDataFresh: false,
    preciseDataCoveredAtUnix: null,
    radarPlanTotalUSD,
    radarDate: quotaRadar?.date || quotaRadar?.basisDate || "",
    radarPricingBasisDate,
    radarBasis: quotaRadar?.basisWindowLabel || quotaRadar?.basisWindow || "",
    radarUpdatedAt: quotaRadar?.updatedAt || "",
    radarSource: quotaRadar?.source || "",
    cycleStartUnix: null,
    cycleEndUnix: null,
    segmentStartUnix: null,
    quotaUpdatedAtUnix: null,
    tokens: emptyTokenBreakdown(),
    scannedTokens: emptyTokenBreakdown(),
  };
}

function emptyTokenBreakdown(): SharedAccountTokenBreakdown {
  return { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, totalTokens: 0, calls: 0, bucketCount: 0 };
}

function normalizedRadarDate(value: string): string {
  return /^(\d{4}-\d{2}-\d{2})/.exec(value.trim())?.[1] ?? "";
}

function normalizedSemanticKey(value: string | null | undefined): string {
  return (value ?? "").normalize("NFKC").toLowerCase().replace(/[^a-z0-9]+/g, "");
}

function finiteNonnegative(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}

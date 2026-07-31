import assert from "node:assert/strict";
import test from "node:test";
import {
  estimateSharedAccountAttribution,
  quotaValueToPercentagePoints,
  radarTierForRow,
  sharedAccountAttributionInputSignature,
} from "./model.ts";

const RESET_UNIX = 2_000_000_000;
const CYCLE_START = RESET_UNIX - 7 * 24 * 60 * 60;

function bucket(offset, inputTokens = 2_000_000, overrides = {}) {
  return {
    startUnix: CYCLE_START + offset,
    inputTokens,
    cachedInputTokens: 0,
    outputTokens: 0,
    totalTokens: inputTokens,
    calls: inputTokens > 0 ? 1 : 0,
    ...overrides,
  };
}

function quota(overrides = {}) {
  return {
    label: "7d",
    availability: "measured",
    remainingPercent: 0.87,
    usedPercent: 0.13,
    resetsAt: "3天",
    resetsAtUnix: RESET_UNIX,
    ...overrides,
  };
}

function radar(overrides = {}) {
  return {
    date: "2026-07-30",
    source: "distributed_radar",
    updatedAt: "2026-07-30T08:20:35Z",
    basisDate: "2026-07-30",
    costUsd: 338.65,
    totalTokens: 1,
    basisWindow: "secondary_7d",
    basisWindowLabel: "7d",
    adjustedDelta: 20,
    rawDelta: 20,
    offset: 0,
    rate: 1,
    rows: [
      { tier: "20x Pro", basis: "distributed", fiveH: null, sevenD: 100 },
      { tier: "5× PRO", basis: "estimated", fiveH: 10, sevenD: 25 },
      { tier: "ChatGPT Plus", basis: "estimated", fiveH: 2, sevenD: 5 },
    ],
    trend: [],
    ...overrides,
  };
}

function segment(overrides = {}) {
  return {
    resetAtUnix: RESET_UNIX,
    scopeKey: "opaque-scope",
    plan: "pro",
    limit: "codex",
    segmentStartUnix: CYCLE_START,
    baselineAccountUsedPercent: 0,
    baselineReady: true,
    baselineObservedAtUnix: CYCLE_START + 600,
    highWaterInitialized: true,
    accountUsedObservedPercent: 13,
    comparisonUpdatedAtUnix: CYCLE_START + 600,
    quotaMovementPendingUntilUnix: null,
    quotaMovementObservedAtUnix: null,
    requiredLocalObservationAfterUnix: null,
    cutoverReason: "none",
    cutoverDetectedAtUnix: null,
    cutoverRecoveredAtUnix: null,
    continuityGapID: null,
    observedAtUnix: CYCLE_START + 600,
    ...overrides,
  };
}

function estimate(overrides = {}) {
  return estimateSharedAccountAttribution({
    enabled: true,
    storageHealthy: true,
    nativeHistoryUnsafe: false,
    persistenceRebaseline: false,
    preciseDataAvailable: true,
    preciseDataFresh: true,
    preciseDataCoveredAtUnix: CYCLE_START + 600,
    buckets: [bucket(0)],
    scannedBuckets: [bucket(0)],
    usagePendingQuotaRefresh: false,
    historyChangedLowConfidence: false,
    localHistoryAmbiguous: false,
    quotaDataStale: false,
    radarDataStale: false,
    sevenDayQuota: quota(),
    quotaRadar: radar(),
    selectedTier: "pro20x",
    priceModel: "gpt56Sol",
    segmentStatus: "ready",
    segment: segment(),
    quotaUpdatedAtUnix: CYCLE_START + 600,
    nowUnix: CYCLE_START + 600,
    ...overrides,
  });
}

test("Tauri 0..1 quota values become percentage points exactly once", () => {
  const result = estimate();
  assert.equal(quotaValueToPercentagePoints(0.13), 13);
  assert.equal(quotaValueToPercentagePoints(13), 13);
  assert.equal(result.accountUsedPercent, 13);
  assert.equal(result.localComparableUSD, 10);
  assert.equal(result.localSharePercent, 10);
  assert.equal(result.residualPercent, 3);
  assert.equal(result.status, "positiveResidual");
});

test("20x local share divides the equivalent amount by the Radar seven-day plan total", () => {
  const result = estimate({
    quotaRadar: radar({
      rows: [{ tier: "20x Pro", basis: "distributed", fiveH: 40, sevenD: 1_700 }],
    }),
  });
  assert.equal(result.localComparableUSD, 10);
  assert.equal(result.radarPlanTotalUSD, 1_700);
  assert.ok(Math.abs(result.localSharePercent - (10 / 1_700) * 100) < 1e-12);
});

test("Radar tier matching tolerates punctuation and never borrows five-hour totals", () => {
  assert.equal(radarTierForRow({ tier: "PRO · 20×" }), "pro20x");
  assert.equal(radarTierForRow({ tier: "5 x Pro" }), "pro5x");
  assert.equal(radarTierForRow({ tier: "ChatGPT Plus" }), "plus");
  const missingSevenDay = estimate({
    quotaRadar: radar({ rows: [{ tier: "20x Pro", basis: "measured", fiveH: 40, sevenD: null }] }),
  });
  assert.equal(missingSevenDay.status, "radarTierUnavailable");
});

test("a hidden or paused Radar seven-day policy rejects a retained positive row", () => {
  const hidden = estimate({
    quotaRadar: radar({
      sevenDayPolicy: "temporarily_paused_hidden",
      rows: [{ tier: "20x Pro", basis: "distributed", fiveH: 40, sevenD: 1_700 }],
    }),
  });
  assert.equal(hidden.status, "radarTierUnavailable");
  assert.equal(hidden.radarPlanTotalUSD, null);
});

test("Radar-compatible amount drives share while current API equivalent stays separate", () => {
  const terraBucket = bucket(0, 1_000_000);
  const result = estimate({
    buckets: [terraBucket],
    scannedBuckets: [terraBucket],
    priceModel: "gpt56Terra",
  });
  assert.equal(result.pricingBasisStatus, "legacyRadarBasis");
  assert.equal(result.localComparableUSD, 2.5);
  assert.equal(result.localCurrentAPIEquivalentUSD, 2);
  assert.equal(result.localSharePercent, 2.5);
  assert.equal(result.residualPercent, 10.5);
});

test("Radar basisDate controls pricing even when the outer feed date is newer", () => {
  const result = estimate({
    quotaRadar: radar({
      date: "2026-08-15",
      basisDate: "2026-07-30",
      updatedAt: "2026-08-15T12:00:00Z",
    }),
    priceModel: "gpt56Terra",
    buckets: [bucket(0, 1_000_000)],
    scannedBuckets: [bucket(0, 1_000_000)],
  });
  assert.equal(result.radarDate, "2026-08-15");
  assert.equal(result.radarPricingBasisDate, "2026-07-30");
  assert.equal(result.priceBasis, "radar20260730");
  assert.equal(result.localComparableUSD, 2.5);
});

test("unconfirmed or future Radar basis dates fail closed instead of using current prices", () => {
  const future = estimate({
    quotaRadar: radar({ basisDate: "2026-08-01", date: "2026-08-01" }),
  });
  assert.equal(future.status, "pricingVersionUnavailable");
  assert.equal(future.priceBasis, null);
  assert.equal(future.radarPricingBasisDate, "2026-08-01");
  assert.equal(future.radarPlanTotalUSD, 100);

  const old = estimate({
    quotaRadar: radar({ basisDate: "2026-07-29", date: "2026-07-29" }),
  });
  assert.equal(old.status, "pricingVersionUnavailable");

  const missingBasis = estimate({
    quotaRadar: radar({ basisDate: "", date: "2026-07-31" }),
  });
  assert.equal(missingBasis.status, "pricingVersionUnavailable");
});

test("input signature explicitly changes for basis date, seven-day policy and identity plan", () => {
  const base = sharedAccountAttributionInputSignature(radar(), { plan: "pro" });
  assert.notEqual(
    base,
    sharedAccountAttributionInputSignature(radar({ basisDate: "2026-07-31" }), { plan: "pro" }),
  );
  assert.notEqual(
    base,
    sharedAccountAttributionInputSignature(radar({ sevenDayPolicy: "hidden" }), { plan: "pro" }),
  );
  assert.notEqual(base, sharedAccountAttributionInputSignature(radar(), { plan: "plus" }));
});

test("negative residual remains negative and the ±2 point band remains indistinguishable", () => {
  const negative = estimate({ sevenDayQuota: quota({ usedPercent: 0.05 }) });
  assert.equal(negative.residualPercent, -5);
  assert.equal(negative.status, "negativeResidual");
  assert.equal(estimate({ sevenDayQuota: quota({ usedPercent: 0.12 }) }).status, "indistinguishable");
  assert.equal(estimate({ sevenDayQuota: quota({ usedPercent: 0.08 }) }).status, "indistinguishable");
});

test("account scope segment subtracts its switch baseline instead of the full-cycle usage", () => {
  const result = estimate({
    sevenDayQuota: quota({ usedPercent: 0.35 }),
    segment: segment({
      segmentStartUnix: CYCLE_START + 300,
      baselineAccountUsedPercent: 30,
    }),
  });
  assert.equal(result.accountRawUsedPercent, 35);
  assert.equal(result.baselineAccountUsedPercent, 30);
  assert.equal(result.accountUsedPercent, 5);
  assert.equal(result.residualPercent, -5);
});

test("small provider reset drift reuses the segment's canonical reset", () => {
  const result = estimate({
    sevenDayQuota: quota({ resetsAtUnix: RESET_UNIX + 120 }),
  });
  assert.equal(result.cycleEndUnix, RESET_UNIX);
  assert.equal(result.cycleStartUnix, CYCLE_START);
});

test("pending usage after the quota snapshot keeps aligned numbers but waits for refresh", () => {
  const result = estimate({ usagePendingQuotaRefresh: true });
  assert.equal(result.status, "waitingQuotaRefresh");
  assert.equal(result.localSharePercent, 10);
  assert.equal(result.residualPercent, null);
  assert.equal(result.usagePendingQuotaRefresh, true);
});

test("stale quota or Radar snapshots keep diagnostics but force a waiting state", () => {
  const staleQuota = estimate({ quotaDataStale: true });
  assert.equal(staleQuota.status, "waitingQuotaRefresh");
  assert.equal(staleQuota.quotaDataStale, true);
  assert.equal(staleQuota.localSharePercent, 10);
  assert.equal(staleQuota.residualPercent, null);

  const staleRadar = estimate({ radarDataStale: true });
  assert.equal(staleRadar.status, "waitingQuotaRefresh");
  assert.equal(staleRadar.radarDataStale, true);
  assert.equal(staleRadar.localSharePercent, 10);
  assert.equal(staleRadar.residualPercent, null);
});

test("stale or older precise usage never attributes a fresher quota snapshot", () => {
  const failedExactRead = estimate({ preciseDataFresh: false });
  assert.equal(failedExactRead.status, "preciseDataStale");
  assert.equal(failedExactRead.localSharePercent, null);
  assert.equal(failedExactRead.residualPercent, null);

  const alignedQuotaUpdatedAt = Math.ceil((CYCLE_START + 600) / 300) * 300;
  const olderCoverage = estimate({
    preciseDataCoveredAtUnix: alignedQuotaUpdatedAt - 1,
    quotaUpdatedAtUnix: alignedQuotaUpdatedAt,
  });
  assert.equal(olderCoverage.status, "preciseDataStale");
  assert.equal(olderCoverage.localSharePercent, null);

  const equalCoverage = estimate({
    preciseDataCoveredAtUnix: alignedQuotaUpdatedAt,
    quotaUpdatedAtUnix: alignedQuotaUpdatedAt,
  });
  assert.equal(equalCoverage.status, "positiveResidual");
});

test("12:01 movement cannot emit a residual until a post-boundary poll has a later exact observation", () => {
  const openBucketStart = Math.ceil((CYCLE_START + 1_200) / 300) * 300;
  const initialScanAt = openBucketStart + 30;
  const localUseAt = openBucketStart + 45;
  const quotaMovementAt = openBucketStart + 60;
  const releasePollAt = openBucketStart + 310;
  assert.ok(initialScanAt < localUseAt && localUseAt < quotaMovementAt);
  const localBucket = bucket(0, 2_000_000, { startUnix: openBucketStart });
  const releasedSegment = segment({
    comparisonUpdatedAtUnix: releasePollAt,
    requiredLocalObservationAfterUnix: releasePollAt,
    accountUsedObservedPercent: 13,
  });

  const beforeLocalUseWasVisible = estimate({
    preciseDataCoveredAtUnix: initialScanAt,
    quotaUpdatedAtUnix: releasePollAt,
    segment: releasedSegment,
    buckets: [],
    scannedBuckets: [],
  });
  assert.equal(beforeLocalUseWasVisible.status, "preciseDataStale");
  assert.equal(beforeLocalUseWasVisible.residualPercent, null);

  const boundaryOnly = estimate({
    preciseDataCoveredAtUnix: openBucketStart + 300,
    quotaUpdatedAtUnix: releasePollAt,
    segment: releasedSegment,
    buckets: [localBucket],
    scannedBuckets: [localBucket],
  });
  assert.equal(boundaryOnly.status, "preciseDataStale");

  const observedAfterPoll = estimate({
    preciseDataCoveredAtUnix: releasePollAt,
    quotaUpdatedAtUnix: releasePollAt,
    segment: releasedSegment,
    buckets: [localBucket],
    scannedBuckets: [localBucket],
  });
  assert.equal(observedAfterPoll.status, "positiveResidual");
  assert.equal(observedAfterPoll.localComparableUSD, 10);
  assert.equal(observedAfterPoll.residualPercent, 3);
});

test("a pending account-switch segment never emits a residual", () => {
  const pending = estimate({
    segmentStatus: "awaitingAccountSwitchBaseline",
    segment: segment({
      segmentStartUnix: CYCLE_START + 900,
      baselineAccountUsedPercent: null,
      baselineReady: false,
      baselineObservedAtUnix: null,
    }),
  });
  assert.equal(pending.status, "awaitingAccountSwitchBaseline");
  assert.equal(pending.localSharePercent, null);
  assert.equal(pending.residualPercent, null);
});

test("persistence corruption and ambiguous local lineage fail closed independently", () => {
  const storageFailure = estimate({ storageHealthy: false });
  assert.equal(storageFailure.status, "attributionStorageUnavailable");
  assert.equal(storageFailure.localSharePercent, null);
  assert.equal(storageFailure.residualPercent, null);

  const ambiguous = estimate({ localHistoryAmbiguous: true });
  assert.equal(ambiguous.status, "localHistoryAmbiguous");
  assert.equal(ambiguous.localComparableUSD, 10);
  assert.equal(ambiguous.localSharePercent, 10);
  assert.equal(ambiguous.residualPercent, null);
});

test("native unsafe and quarantined rebaseline states stop every residual calculation", () => {
  const nativeUnsafe = estimate({ nativeHistoryUnsafe: true });
  assert.equal(nativeUnsafe.status, "nativeHistoryUnsafe");
  assert.equal(nativeUnsafe.localSharePercent, null);
  assert.equal(nativeUnsafe.residualPercent, null);

  const rebaseline = estimate({ persistenceRebaseline: true });
  assert.equal(rebaseline.status, "persistenceRebaseline");
  assert.equal(rebaseline.localSharePercent, null);
  assert.equal(rebaseline.residualPercent, null);
});

test("expired reset waits for quota refresh before pricing or persistence inputs are used", () => {
  const result = estimate({ nowUnix: RESET_UNIX });
  assert.equal(result.status, "waitingQuotaRefresh");
  assert.equal(result.localComparableUSD, null);
  assert.equal(result.localSharePercent, null);
});

test("disabled, precise, quota, reset, identity, timestamp, Radar, tier and price states are distinct", () => {
  assert.equal(estimate({ enabled: false, buckets: [], scannedBuckets: [] }).status, "disabled");
  assert.equal(estimate({ preciseDataAvailable: false }).status, "preciseDataUnavailable");
  assert.equal(estimate({ sevenDayQuota: quota({ availability: "unavailable", usedPercent: null }) }).status, "quotaUnavailable");
  assert.equal(estimate({ sevenDayQuota: quota({ resetsAtUnix: null }) }).status, "quotaResetUnavailable");
  assert.equal(estimate({ segmentStatus: "identityUnavailable", segment: null }).status, "identityUnavailable");
  assert.equal(estimate({ segmentStatus: "quotaTimestampUnavailable", segment: null, quotaUpdatedAtUnix: null }).status, "quotaTimestampUnavailable");
  assert.equal(estimate({ quotaRadar: null }).status, "radarUnavailable");
  assert.equal(estimate({ selectedTier: "plus", quotaRadar: radar({ rows: [] }) }).status, "radarTierUnavailable");
  assert.equal(estimate({ quotaRadar: radar({ date: "", basisDate: "", updatedAt: "" }) }).status, "pricingVersionUnavailable");
});

test("bucket high-water values are priced after merge while the current scan remains diagnostic", () => {
  const result = estimate({
    buckets: [bucket(0, 2_600_000)],
    scannedBuckets: [bucket(0, 1_000_000)],
    historyChangedLowConfidence: true,
  });
  assert.equal(result.localComparableUSD, 13);
  assert.equal(result.scannedLocalComparableUSD, 5);
  assert.equal(result.historyChangedLowConfidence, true);
});

test("current Radar price revision reprices the same raw bucket breakdown without a new money key", () => {
  const terraBucket = bucket(0, 1_000_000);
  const result = estimate({
    buckets: [terraBucket],
    scannedBuckets: [terraBucket],
    quotaRadar: radar({ date: "2026-07-31", basisDate: "2026-07-31" }),
    priceModel: "gpt56Terra",
  });
  assert.equal(result.priceBasis, "current");
  assert.equal(result.localComparableUSD, 2);
  assert.equal(result.localCurrentAPIEquivalentUSD, 2);
});

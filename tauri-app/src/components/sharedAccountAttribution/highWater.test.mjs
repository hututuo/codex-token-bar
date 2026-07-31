import assert from "node:assert/strict";
import test from "node:test";
import { officialAPICostUSD } from "../../settings/quotaPriceModel.ts";
import {
  attributionHighWaterStorageKey,
  mergeAttributionBucketHighWater,
  pruneAttributionHighWaterCycles,
  readAttributionHighWater,
  readAttributionHighWaterState,
  writeAttributionHighWater,
} from "./highWater.ts";

const START = 2_000_000_000;

function identity(overrides = {}) {
  return {
    scopeKey: "opaque-scope-a",
    plan: "pro",
    limit: "codex",
    resetAtUnix: START + 7 * 24 * 60 * 60,
    segmentStartUnix: START,
    tier: "pro20x",
    priceModel: "gpt56Sol",
    ...overrides,
  };
}

function contribution(sourceId, inputTokens, overrides = {}) {
  return {
    sourceId,
    tokens: inputTokens,
    calls: inputTokens > 0 ? 1 : 0,
    inputTokens,
    cachedInputTokens: 0,
    outputTokens: 0,
    ...overrides,
  };
}

function point(startUnix, sources, overrides = {}) {
  const totals = sources.reduce((sum, source) => ({
    tokens: sum.tokens + source.tokens,
    calls: sum.calls + source.calls,
    inputTokens: sum.inputTokens + source.inputTokens,
    cachedInputTokens: sum.cachedInputTokens + source.cachedInputTokens,
    outputTokens: sum.outputTokens + source.outputTokens,
  }), { tokens: 0, calls: 0, inputTokens: 0, cachedInputTokens: 0, outputTokens: 0 });
  return {
    label: "bucket",
    startUnix,
    ...totals,
    cacheHitRate: 0,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
    sourceContributionEpoch: "epoch-a",
    sourceContributions: sources,
    ...overrides,
  };
}

function aggregatePoint(startUnix, inputTokens, overrides = {}) {
  return {
    label: "bucket",
    startUnix,
    tokens: inputTokens,
    calls: inputTokens > 0 ? 1 : 0,
    inputTokens,
    cachedInputTokens: 0,
    outputTokens: 0,
    cacheHitRate: 0,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
    ...overrides,
  };
}

function merge(stored, points, overrides = {}) {
  return mergeAttributionBucketHighWater(stored, points, {
    segmentStartUnix: START,
    resetAtUnix: START + 10_000,
    persistenceCutoffUnix: START + 3_000,
    comparisonEndUnix: START + 3_000,
    metadataObservedAtUnix: 100,
    preciseCoveredAt: "2026-07-31T00:00:00Z",
    quotaObservationFresh: true,
    ...overrides,
  }, new Date("2026-07-31T00:00:00Z"));
}

test("deleted old source plus a new source in the same bucket accumulates 2M + 3M, not max 3M", () => {
  const first = merge(null, [point(START, [contribution("source-a", 2_000_000)])]);
  assert.equal(first.ambiguityDetected, false);
  assert.equal(first.effectiveBuckets[0].inputTokens, 2_000_000);

  const replacedScan = merge(first.record, [point(START, [contribution("source-b", 3_000_000)])]);
  assert.equal(replacedScan.ambiguityDetected, false);
  assert.equal(replacedScan.effectiveBuckets[0].inputTokens, 5_000_000);
  assert.deepEqual(
    Object.keys(replacedScan.effectiveBuckets[0].sourceContributions).sort(),
    ["source-a", "source-b"],
  );
  assert.equal(officialAPICostUSD(5_000_000, 0, 0, "gpt56Sol"), 25);

  const restored = merge(replacedScan.record, [point(START, [
    contribution("source-a", 2_000_000),
    contribution("source-b", 3_000_000),
  ])]);
  assert.equal(restored.effectiveBuckets[0].inputTokens, 5_000_000);
  assert.equal(restored.changed, false);
});

test("durable sparse contributions may exceed the current chart aggregate after source deletion", () => {
  const currentChartOnlyShowsNew = point(START, [contribution("source-old", 2_000_000), contribution("source-new", 3_000_000)], {
    tokens: 3_000_000,
    calls: 1,
    inputTokens: 3_000_000,
  });
  const result = merge(null, [currentChartOnlyShowsNew]);
  assert.equal(result.ambiguityDetected, false);
  assert.equal(result.effectiveBuckets[0].inputTokens, 5_000_000);
  assert.equal(result.effectiveBuckets[0].totalTokens, 5_000_000);
});

test("a sparse source ledger smaller than the visible chart fails closed as incomplete", () => {
  const incompleteLedger = point(START, [contribution("source-a", 2_000_000)], {
    tokens: 3_000_000,
    calls: 2,
    inputTokens: 3_000_000,
  });
  const result = merge(null, [incompleteLedger]);
  assert.equal(result.ambiguityDetected, true);
  assert.equal(result.effectiveBuckets[0].inputTokens, 3_000_000);
  assert.equal(result.effectiveBuckets[0].sourceTrackingComplete, false);
});

test("same source and bucket merge each component monotonically within one provenance epoch", () => {
  const first = merge(null, [point(START, [contribution("source-a", 100, {
    tokens: 140,
    cachedInputTokens: 80,
    outputTokens: 40,
    calls: 2,
  })])]);
  const second = merge(first.record, [point(START, [contribution("source-a", 120, {
    tokens: 160,
    cachedInputTokens: 90,
    outputTokens: 40,
    calls: 3,
  })])]);
  assert.equal(second.ambiguityDetected, false);
  assert.deepEqual(second.effectiveBuckets[0], {
    startUnix: START,
    inputTokens: 120,
    cachedInputTokens: 90,
    outputTokens: 40,
    totalTokens: 160,
    calls: 3,
    sourceContributions: {
      "source-a": {
        inputTokens: 120,
        cachedInputTokens: 90,
        outputTokens: 40,
        totalTokens: 160,
        calls: 3,
      },
    },
    sourceTrackingComplete: true,
  });
});

test("a source component decrease or provenance epoch rotation becomes sticky ambiguity", () => {
  const first = merge(null, [point(START, [contribution("source-a", 200)])]);
  const decreased = merge(first.record, [point(START, [contribution("source-a", 150)])]);
  assert.equal(decreased.ambiguityDetected, true);
  assert.equal(decreased.effectiveBuckets[0].inputTokens, 200);

  const rotated = merge(first.record, [point(
    START,
    [contribution("source-b", 300)],
    { sourceContributionEpoch: "epoch-b" },
  )]);
  assert.equal(rotated.ambiguityDetected, true);
  assert.equal(rotated.record.provenanceEpoch, "epoch-a");
  assert.equal(rotated.effectiveBuckets[0].sourceTrackingComplete, false);
  const target = memoryStorage();
  const key = attributionHighWaterStorageKey(identity());
  assert.equal(writeAttributionHighWater(key, rotated.record, target), true);
  const restoredAmbiguity = readAttributionHighWaterState(key, target);
  assert.equal(restoredAmbiguity.healthy, true);
  assert.equal(restoredAmbiguity.record.ambiguityDetected, true);
  assert.equal(merge(restoredAmbiguity.record, [point(START + 300, [contribution("source-c", 50)], {
    sourceContributionEpoch: "epoch-b",
  })]).ambiguityDetected, true);
});

test("aggregate-only current or legacy buckets are retained but never support a residual", () => {
  const aggregateOnly = merge(null, [aggregatePoint(START, 2_000_000)]);
  assert.equal(aggregateOnly.ambiguityDetected, true);
  assert.equal(aggregateOnly.effectiveBuckets[0].inputTokens, 2_000_000);

  const legacyRecord = {
    buckets: {
      [START]: {
        startUnix: START,
        inputTokens: 2_000_000,
        cachedInputTokens: 0,
        outputTokens: 0,
        totalTokens: 2_000_000,
        calls: 1,
      },
    },
    updatedAt: "2026-07-30T00:00:00Z",
  };
  const target = memoryStorage();
  const key = attributionHighWaterStorageKey(identity());
  target.setItem(key, JSON.stringify(legacyRecord));
  const migrated = readAttributionHighWaterState(key, target);
  assert.equal(migrated.healthy, true);
  assert.equal(migrated.record.buckets[START].inputTokens, 2_000_000);
  const rescanned = merge(migrated.record, [point(START, [contribution("source-new", 3_000_000)])]);
  assert.equal(rescanned.ambiguityDetected, true);
  assert.equal(rescanned.effectiveBuckets[0].inputTokens, 3_000_000);
});

test("an open partial bucket persists raw and enters money only after comparison catches up", () => {
  const pending = merge(null, [point(START, [contribution("source-a", 100)])], {
    persistenceCutoffUnix: START + 120,
    comparisonEndUnix: START,
  });
  assert.equal(pending.hasPendingUsage, true);
  assert.deepEqual(pending.effectiveBuckets, []);
  assert.equal(pending.record.buckets[START].inputTokens, 100);

  const archived = merge(pending.record, [], {
    persistenceCutoffUnix: START + 300,
    comparisonEndUnix: START,
  });
  assert.equal(archived.hasPendingUsage, true);
  const covered = merge(pending.record, [], {
    persistenceCutoffUnix: START + 300,
    comparisonEndUnix: START + 300,
  });
  assert.equal(covered.hasPendingUsage, false);
  assert.equal(covered.effectiveBuckets[0].inputTokens, 100);
  assert.equal(covered.usedHistoricalHighWater, true);
});

test("an unaligned seven-day cycle start includes its straddling 5m bucket conservatively", () => {
  const alignedBucketStart = Math.floor(START / 300) * 300;
  const unalignedCycleStart = alignedBucketStart + 120;
  const result = merge(null, [point(alignedBucketStart, [contribution("source-a", 250)])], {
    segmentStartUnix: unalignedCycleStart,
    resetAtUnix: unalignedCycleStart + 7 * 24 * 60 * 60,
    persistenceCutoffUnix: alignedBucketStart + 600,
    comparisonEndUnix: alignedBucketStart + 600,
  });
  assert.equal(result.ambiguityDetected, false);
  assert.equal(result.effectiveBuckets.length, 1);
  assert.equal(result.effectiveBuckets[0].startUnix, alignedBucketStart);
  assert.equal(result.effectiveBuckets[0].inputTokens, 250);
});

test("stale-to-fresh and later same-value polls update metadata without token changes", () => {
  const sourcePoint = point(START, [contribution("source-a", 100)]);
  const stale = merge(null, [sourcePoint], {
    metadataObservedAtUnix: 100,
    quotaObservationFresh: false,
  });
  assert.equal(stale.record.quotaObservationFresh, false);

  const freshSameObservation = merge(stale.record, [sourcePoint], {
    metadataObservedAtUnix: 100,
    quotaObservationFresh: true,
  });
  assert.equal(freshSameObservation.changed, true);
  assert.equal(freshSameObservation.record.quotaObservationFresh, true);

  const laterSameValuePoll = merge(freshSameObservation.record, [sourcePoint], {
    metadataObservedAtUnix: 200,
    quotaObservationFresh: true,
    preciseCoveredAt: "2026-07-31T00:05:00Z",
  });
  assert.equal(laterSameValuePoll.changed, true);
  assert.equal(laterSameValuePoll.record.metadataObservedAtUnix, 200);
  assert.equal(laterSameValuePoll.record.updatedAt, "2026-07-31T00:05:00Z");
});

test("cleanup retains all segments in only the newest two reset cycles per account scope", () => {
  const target = memoryStorage();
  const reset1 = START + 10_000;
  const reset2 = START + 20_000;
  const reset3 = START + 30_000;
  const keys = [
    attributionHighWaterStorageKey(identity({ resetAtUnix: reset1, segmentStartUnix: START })),
    attributionHighWaterStorageKey(identity({ resetAtUnix: reset2, segmentStartUnix: START + 100 })),
    attributionHighWaterStorageKey(identity({ resetAtUnix: reset3, segmentStartUnix: START + 200 })),
    attributionHighWaterStorageKey(identity({ resetAtUnix: reset3, segmentStartUnix: START + 300 })),
  ];
  const otherScope = attributionHighWaterStorageKey(identity({
    scopeKey: "opaque-scope-b",
    resetAtUnix: reset1,
  }));
  for (const key of [...keys, otherScope]) target.setItem(key, "record");

  const cleanup = pruneAttributionHighWaterCycles(identity(), target);
  assert.equal(cleanup.healthy, true);
  assert.deepEqual(cleanup.removed, [keys[0]]);
  assert.equal(target.values.has(keys[1]), true);
  assert.equal(target.values.has(keys[2]), true);
  assert.equal(target.values.has(keys[3]), true);
  assert.equal(target.values.has(otherScope), true);
});

test("key isolates anonymous scope, reset and segment but not pricing choices", () => {
  const base = attributionHighWaterStorageKey(identity());
  assert.match(base, /^sharedAccountAttributionBuckets:v4:/);
  assert.notEqual(base, attributionHighWaterStorageKey(identity({ scopeKey: "opaque-scope-b" })));
  assert.notEqual(base, attributionHighWaterStorageKey(identity({ plan: "plus" })));
  assert.notEqual(base, attributionHighWaterStorageKey(identity({ limit: "other" })));
  assert.notEqual(base, attributionHighWaterStorageKey(identity({ resetAtUnix: START + 1 })));
  assert.notEqual(base, attributionHighWaterStorageKey(identity({ segmentStartUnix: START + 300 })));
  assert.equal(base, attributionHighWaterStorageKey(identity({ tier: "plus" })));
  assert.equal(base, attributionHighWaterStorageKey(identity({ priceModel: "gpt56Terra" })));
});

test("record corruption fails closed and successful writes require exact read-back", () => {
  const target = memoryStorage();
  const key = attributionHighWaterStorageKey(identity());
  target.setItem(key, "{broken");
  assert.deepEqual(readAttributionHighWaterState(key, target), { healthy: false, record: null });

  const result = merge(null, [point(START, [contribution("source-a", 100)])]);
  assert.equal(writeAttributionHighWater(key, result.record, target), true);
  assert.deepEqual(readAttributionHighWater(key, target), result.record);
  assert.equal(writeAttributionHighWater(key, result.record, {
    getItem() { return null; },
    setItem() { throw new Error("quota exceeded"); },
  }), false);
});

function memoryStorage() {
  const values = new Map();
  return {
    values,
    get length() { return values.size; },
    key(index) { return [...values.keys()][index] ?? null; },
    getItem(key) { return values.get(key) ?? null; },
    setItem(key, value) { values.set(key, value); },
    removeItem(key) { values.delete(key); },
  };
}

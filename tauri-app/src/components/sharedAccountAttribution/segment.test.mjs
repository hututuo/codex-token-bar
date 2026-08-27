import assert from "node:assert/strict";
import test from "node:test";
import {
  attributionSegmentStorageKey,
  beginAttributionUnsafeEpisodeCutover,
  beginContinuityGapCutover,
  completedBucketBoundary,
  holdAttributionSegmentDuringContinuityGap,
  readAttributionSegment,
  readAttributionSegmentState,
  readLegacyAttributionSegment,
  readLegacyAttributionResidueState,
  readLegacyAttributionSegmentState,
  retireLegacyAttributionSegments,
  resolveAttributionSegment,
  writeAttributionSegment,
} from "./segment.ts";
import { attributionHighWaterStorageKey } from "./highWater.ts";

const RESET = 2_000_700_000;
const UPDATED = RESET - 10_777;
const GAP_ID = "11111111-2222-4333-8444-555555555555";

function identity(scopeKey = "scope-a", overrides = {}) {
  return { scopeKey, plan: "pro", limit: "codex", ...overrides };
}

function input(overrides = {}) {
  return {
    enabled: true,
    sourceHomeIdentity: "canonical-home\u0000physical-home",
    identity: identity(),
    quotaDataFresh: true,
    resetAtUnix: RESET,
    quotaUpdatedAtUnix: UPDATED,
    accountUsedPercent: 13,
    ...overrides,
  };
}

function readySegment(overrides = {}) {
  const pending = resolveAttributionSegment(null, input());
  const baselineAt = Math.max(UPDATED + 1, pending.segment.segmentStartUnix);
  const ready = resolveAttributionSegment(pending.segment, input({
    quotaUpdatedAtUnix: baselineAt,
    accountUsedPercent: 14,
  }));
  assert.equal(ready.status, "ready");
  return { ...ready.segment, ...overrides };
}

test("disabled and missing identity never produce a segment storage key", () => {
  assert.equal(resolveAttributionSegment(null, input({ enabled: false })).storageKey, null);
  assert.equal(resolveAttributionSegment(null, input({ identity: null })).status, "identityUnavailable");
  assert.equal(resolveAttributionSegment(null, input({ accountUsedPercent: null })).status, "quotaTimestampUnavailable");
});

test("first activation is a synthetic pending cutover, never a zero whole-cycle baseline", () => {
  const pending = resolveAttributionSegment(null, input());
  assert.equal(pending.status, "awaitingAccountSwitchBaseline");
  assert.equal(pending.segment.cutoverReason, "initialActivation");
  assert.equal(pending.segment.segmentStartUnix, completedBucketBoundary(UPDATED));
  assert.equal(pending.segment.baselineAccountUsedPercent, null);
  assert.equal(pending.segment.baselineReady, false);
  assert.match(pending.storageKey, /^sharedAccountAttributionSegment:v7:/);
  assert.equal(pending.segment.highWaterInitialized, false);

  const sameObservation = resolveAttributionSegment(pending.segment, input());
  assert.equal(sameObservation.changed, false);
  assert.equal(sameObservation.status, "awaitingAccountSwitchBaseline");

  const baselineAt = pending.segment.segmentStartUnix + 1;
  const ready = resolveAttributionSegment(pending.segment, input({
    quotaUpdatedAtUnix: baselineAt,
    accountUsedPercent: 15,
  }));
  assert.equal(ready.status, "ready");
  assert.equal(ready.segment.baselineAccountUsedPercent, 15);
  assert.equal(ready.segment.baselineObservedAtUnix, baselineAt);
  assert.equal(ready.segment.requiredLocalObservationAfterUnix, baselineAt);
  assert.equal(ready.pendingAlignmentAdvanced, true);
});

test("a native unsafe episode stays pending until native acknowledgement is observed", () => {
  const current = readySegment();
  const unsafeID = "99999999-9999-4999-8999-999999999999";
  const recoveredAt = current.comparisonUpdatedAtUnix + 600;
  const firstClean = beginAttributionUnsafeEpisodeCutover(
    current,
    input({
      quotaUpdatedAtUnix: recoveredAt,
      accountUsedPercent: current.accountUsedObservedPercent + 1,
    }),
    unsafeID,
    recoveredAt - 300,
    recoveredAt,
  );
  assert.equal(firstClean.status, "awaitingAccountSwitchBaseline");
  assert.equal(firstClean.segment.continuityGapID, unsafeID);
  assert.equal(firstClean.segment.baselineReady, false);

  const newerQuotaBeforeAck = beginAttributionUnsafeEpisodeCutover(
    firstClean.segment,
    input({
      quotaUpdatedAtUnix: recoveredAt + 600,
      accountUsedPercent: current.accountUsedObservedPercent + 2,
    }),
    unsafeID,
    recoveredAt - 300,
    recoveredAt,
  );
  assert.equal(newerQuotaBeforeAck.changed, false);
  assert.equal(newerQuotaBeforeAck.segment.baselineReady, false);

  const afterAck = resolveAttributionSegment(firstClean.segment, input({
    quotaUpdatedAtUnix: recoveredAt + 600,
    accountUsedPercent: current.accountUsedObservedPercent + 2,
  }));
  assert.equal(afterAck.status, "ready");
  assert.equal(afterAck.segment.baselineReady, true);
});

test("a new reset also waits for a synthetic baseline even if identity changes", () => {
  const current = readySegment();
  for (const nextIdentity of [identity(), identity("scope-b")]) {
    const next = resolveAttributionSegment(current, input({
      identity: nextIdentity,
      resetAtUnix: RESET + 7 * 24 * 60 * 60,
      quotaUpdatedAtUnix: RESET + 1_000,
      accountUsedPercent: 0,
    }));
    assert.equal(next.status, "awaitingAccountSwitchBaseline");
    assert.equal(next.scopeChanged, false);
    assert.equal(next.segment.cutoverReason, "initialActivation");
    assert.equal(next.segment.baselineAccountUsedPercent, null);
  }
});

test("a new cycle without an ID never inherits the old ID or cuts over twice", () => {
  const current = readySegment({ cycleId: "cycle-old" });
  const nextReset = RESET + 7 * 24 * 60 * 60;
  const pending = resolveAttributionSegment(current, input({
    resetAtUnix: nextReset,
    quotaUpdatedAtUnix: RESET + 1_000,
    accountUsedPercent: 0,
    cycleId: null,
  }));
  assert.equal(pending.status, "awaitingAccountSwitchBaseline");
  assert.equal(pending.segment.cycleId, null);
  assert.equal(pending.segment.cutoverReason, "initialActivation");

  const baselineAt = Math.max(
    pending.segment.segmentStartUnix,
    pending.segment.observedAtUnix + 1,
  );
  const finalized = resolveAttributionSegment(pending.segment, input({
    resetAtUnix: nextReset,
    quotaUpdatedAtUnix: baselineAt,
    accountUsedPercent: 1,
    cycleId: "cycle-new",
  }));
  assert.equal(finalized.status, "ready");
  assert.equal(finalized.segment.cycleId, "cycle-new");
  assert.equal(finalized.segment.segmentStartUnix, pending.segment.segmentStartUnix);
  assert.equal(finalized.segment.cutoverReason, "initialActivation");
});

test("same-cycle account or plan switch enters its own pending segment", () => {
  const current = readySegment();
  const switchObservedAt = current.comparisonUpdatedAtUnix + 60;
  const switched = resolveAttributionSegment(current, input({
    identity: identity("scope-b", { plan: "plus" }),
    quotaUpdatedAtUnix: switchObservedAt,
    accountUsedPercent: 35,
  }));
  assert.equal(switched.status, "awaitingAccountSwitchBaseline");
  assert.equal(switched.scopeChanged, true);
  assert.equal(switched.segment.cutoverReason, "accountSwitch");
  assert.equal(switched.segment.segmentStartUnix, completedBucketBoundary(switchObservedAt));
  assert.equal(switched.segment.baselineReady, false);
});

test("same-percent polls preserve comparison while movement releases only after its boundary", () => {
  const current = readySegment({
    quotaMovementPendingUntilUnix: null,
    quotaMovementObservedAtUnix: null,
  });
  const same = resolveAttributionSegment(current, input({
    quotaUpdatedAtUnix: current.comparisonUpdatedAtUnix + 30,
    accountUsedPercent: current.accountUsedObservedPercent,
  }));
  assert.equal(same.changed, false);

  const movementAt = current.comparisonUpdatedAtUnix + 60;
  const movement = resolveAttributionSegment(current, input({
    quotaUpdatedAtUnix: movementAt,
    accountUsedPercent: current.accountUsedObservedPercent + 1,
  }));
  assert.equal(movement.segment.comparisonUpdatedAtUnix, current.comparisonUpdatedAtUnix);
  assert.equal(movement.segment.quotaMovementPendingUntilUnix, completedBucketBoundary(movementAt));
  assert.equal(movement.pendingAlignmentAdvanced, false);

  const releaseAt = Math.max(movementAt + 1, movement.segment.quotaMovementPendingUntilUnix);
  const released = resolveAttributionSegment(movement.segment, input({
    quotaUpdatedAtUnix: releaseAt,
    accountUsedPercent: movement.segment.accountUsedObservedPercent,
  }));
  assert.equal(released.pendingAlignmentAdvanced, true);
  assert.equal(released.segment.comparisonUpdatedAtUnix, releaseAt);
  assert.equal(released.segment.requiredLocalObservationAfterUnix, releaseAt);
});

test("proven raw usage advances one unchanged comparison at most once per boundary", () => {
  const current = readySegment({
    quotaMovementPendingUntilUnix: null,
    quotaMovementObservedAtUnix: null,
  });
  const boundary = completedBucketBoundary(current.comparisonUpdatedAtUnix + 1);
  const advanced = resolveAttributionSegment(current, input({
    quotaUpdatedAtUnix: boundary,
    accountUsedPercent: current.accountUsedObservedPercent,
    pendingRawCanAdvanceComparison: true,
  }));
  assert.equal(advanced.pendingAlignmentAdvanced, true);
  assert.equal(advanced.segment.comparisonUpdatedAtUnix, boundary);
  const duplicate = resolveAttributionSegment(advanced.segment, input({
    quotaUpdatedAtUnix: boundary,
    accountUsedPercent: current.accountUsedObservedPercent,
    pendingRawCanAdvanceComparison: true,
  }));
  assert.equal(duplicate.changed, false);
});

test("stale quota can only hold a matching durable segment unchanged", () => {
  const current = readySegment();
  const held = holdAttributionSegmentDuringContinuityGap(current, input({
    quotaDataFresh: false,
    quotaUpdatedAtUnix: UPDATED + 1_000,
    accountUsedPercent: 90,
  }));
  assert.equal(held.status, "ready");
  assert.deepEqual(held.segment, current);
  assert.equal(held.changed, false);

  const wrongReset = holdAttributionSegmentDuringContinuityGap(current, input({
    quotaDataFresh: false,
    resetAtUnix: RESET + 1_000,
  }));
  assert.equal(wrongReset.segment, null);
});

test("a non-full reset drift stays in-cycle and an authoritative ID is adopted immediately", () => {
  const current = readySegment();
  const drifted = resolveAttributionSegment(current, input({
    resetAtUnix: RESET + 900,
    quotaUpdatedAtUnix: current.comparisonUpdatedAtUnix,
    accountUsedPercent: current.accountUsedObservedPercent,
    cycleId: "cycle-7",
  }));
  assert.equal(drifted.segment.resetAtUnix, RESET);
  assert.equal(drifted.segment.cycleId, "cycle-7");
  assert.equal(drifted.changed, true);
  const held = holdAttributionSegmentDuringContinuityGap(drifted.segment, input({
    quotaDataFresh: false,
    resetAtUnix: RESET + 1_200,
    cycleId: "cycle-7",
  }));
  assert.equal(held.status, "ready");
  const highWaterKey = (segment) => attributionHighWaterStorageKey({
    ...identity(),
    resetAtUnix: segment.resetAtUnix,
    segmentStartUnix: segment.segmentStartUnix,
    tier: "pro20x",
    priceModel: "gpt56Sol",
  });
  assert.equal(highWaterKey(drifted.segment), highWaterKey(current));
});

test("legacy migration retains segmentStart so archived high-water buckets stay addressable", () => {
  const legacyStart = completedBucketBoundary(UPDATED - 900);
  const migrated = resolveAttributionSegment(null, input(), {
    resetAtUnix: RESET,
    segmentStartUnix: legacyStart,
  });
  assert.equal(migrated.status, "awaitingAccountSwitchBaseline");
  assert.equal(migrated.segment.cutoverReason, "legacyMigration");
  assert.equal(migrated.segment.segmentStartUnix, legacyStart);

  const key = attributionHighWaterStorageKey({
    ...identity(),
    resetAtUnix: RESET,
    segmentStartUnix: legacyStart,
    tier: "pro20x",
    priceModel: "gpt56Sol",
  });
  assert.equal(key, attributionHighWaterStorageKey({
    ...identity(),
    resetAtUnix: migrated.segment.resetAtUnix,
    segmentStartUnix: migrated.segment.segmentStartUnix,
    tier: "plus",
    priceModel: "gpt56Terra",
  }));
});

test("legacy reader accepts v6 through v2 without exposing the Home identity", () => {
  const currentKey = attributionSegmentStorageKey(input().sourceHomeIdentity);
  const legacyKey = currentKey.replace(
    "sharedAccountAttributionSegment:v7",
    "sharedAccountAttributionSegment:v6",
  );
  const target = {
    getItem(key) {
      return key === legacyKey
        ? JSON.stringify({ resetAtUnix: RESET, segmentStartUnix: UPDATED - 600 })
        : null;
    },
  };
  assert.deepEqual(readLegacyAttributionSegment(input().sourceHomeIdentity, target), {
    resetAtUnix: RESET,
    segmentStartUnix: UPDATED - 600,
  });
  assert.doesNotMatch(legacyKey, /canonical-home|physical-home/);
});

test("a durable v7 migration retires every legacy key so stale state cannot resurrect", () => {
  const values = new Map();
  const target = {
    getItem(key) { return values.get(key) ?? null; },
    setItem(key, value) { values.set(key, value); },
    removeItem(key) { values.delete(key); },
  };
  const currentKey = attributionSegmentStorageKey(input().sourceHomeIdentity);
  const legacyKeys = ["v6", "v5", "v4", "v3", "v2"].map((version) => currentKey.replace(
    "sharedAccountAttributionSegment:v7",
    `sharedAccountAttributionSegment:${version}`,
  ));
  for (const key of legacyKeys) values.set(key, JSON.stringify({ resetAtUnix: RESET }));
  assert.equal(writeAttributionSegment(currentKey, readySegment(), target), true);
  assert.deepEqual(
    readLegacyAttributionResidueState(input().sourceHomeIdentity, target).keys,
    legacyKeys,
  );
  const retired = retireLegacyAttributionSegments(input().sourceHomeIdentity, target);
  assert.equal(retired.healthy, true);
  assert.deepEqual(retired.removed, legacyKeys);
  values.delete(currentKey);
  assert.equal(readLegacyAttributionSegment(input().sourceHomeIdentity, target), null);
});

test("continuity recovery is keyed by UUID and clears only after a later baseline", () => {
  const current = readySegment();
  const held = holdAttributionSegmentDuringContinuityGap(current, input({ quotaDataFresh: false }));
  assert.deepEqual(held.segment, current);

  const recoveredCoverageAt = current.comparisonUpdatedAtUnix + 725;
  const recoveryQuotaAt = current.comparisonUpdatedAtUnix + 900;
  const recovery = beginContinuityGapCutover(
    current,
    input({ quotaUpdatedAtUnix: recoveryQuotaAt, accountUsedPercent: 40 }),
    GAP_ID,
    current.comparisonUpdatedAtUnix + 60,
    recoveredCoverageAt,
  );
  assert.equal(recovery.status, "awaitingAccountSwitchBaseline");
  assert.equal(recovery.segment.cutoverReason, "continuityGap");
  assert.equal(recovery.segment.continuityGapID, GAP_ID);
  assert.equal(recovery.segment.cutoverRecoveredAtUnix, recoveredCoverageAt);
  assert.equal(recovery.segment.baselineReady, false);

  const sameSnapshot = beginContinuityGapCutover(
    recovery.segment,
    input({ quotaUpdatedAtUnix: recoveryQuotaAt, accountUsedPercent: 40 }),
    GAP_ID,
    current.comparisonUpdatedAtUnix + 60,
    recoveredCoverageAt,
  );
  assert.equal(sameSnapshot.changed, false);

  const baselineAt = Math.max(recovery.segment.segmentStartUnix, recoveryQuotaAt + 1);
  const baseline = beginContinuityGapCutover(
    recovery.segment,
    input({ quotaUpdatedAtUnix: baselineAt, accountUsedPercent: 41 }),
    GAP_ID,
    current.comparisonUpdatedAtUnix + 60,
    recoveredCoverageAt,
  );
  assert.equal(baseline.status, "ready");
  assert.equal(baseline.segment.baselineAccountUsedPercent, 41);
  assert.equal(baseline.segment.requiredLocalObservationAfterUnix, baselineAt);
  assert.equal(baseline.segment.continuityGapID, GAP_ID);
});

test("current and legacy corruption fail closed independently", () => {
  const currentKey = attributionSegmentStorageKey(input().sourceHomeIdentity);
  const corruptCurrent = { getItem: (key) => key === currentKey ? "{broken" : null };
  assert.deepEqual(readAttributionSegmentState(currentKey, corruptCurrent), {
    healthy: false,
    value: null,
  });

  const legacyKey = currentKey.replace(
    "sharedAccountAttributionSegment:v7",
    "sharedAccountAttributionSegment:v6",
  );
  const corruptLegacy = { getItem: (key) => key === legacyKey ? "[]" : null };
  assert.deepEqual(readLegacyAttributionSegmentState(input().sourceHomeIdentity, corruptLegacy), {
    healthy: false,
    value: null,
  });
});

test("segment record round-trips only after exact read-back verification", () => {
  const values = new Map();
  const target = {
    getItem(key) { return values.get(key) ?? null; },
    setItem(key, value) { values.set(key, value); },
  };
  const segment = readySegment();
  const key = attributionSegmentStorageKey(input().sourceHomeIdentity);
  assert.equal(writeAttributionSegment(key, segment, target), true);
  assert.deepEqual(readAttributionSegment(key, target), segment);
  assert.equal(writeAttributionSegment(key, segment, {
    getItem() { return null; },
    setItem() { throw new Error("quota exceeded"); },
  }), false);
});

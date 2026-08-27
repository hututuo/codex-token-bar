import assert from "node:assert/strict";
import test from "node:test";
import {
  advanceQuotaComparisonObservation,
  alignQuotaComparisonObservation,
  quotaComparisonNeedsPreciseRequest,
} from "./quotaComparisonObservation.ts";

const RESET = 2_000_700_000;

function observation(overrides = {}) {
  return {
    quotaDataFresh: true,
    updatedAt: "2033-05-18T03:33:20.000Z",
    resetAtUnix: RESET,
    usedPercent: 0.13,
    identity: { scopeKey: "scope-a", plan: "pro", limit: "codex" },
    ...overrides,
  };
}

test("same integer-percent quota polls preserve the comparison watermark", () => {
  const first = advanceQuotaComparisonObservation(null, observation());
  assert.equal(first.shouldRefreshPreciseUsage, true);

  const poll = advanceQuotaComparisonObservation(first.state, observation({
    updatedAt: "2033-05-18T03:34:20.000Z",
  }));
  assert.equal(poll.shouldRefreshPreciseUsage, false);
  assert.equal(poll.reason, "unchanged");
  assert.equal(poll.state.comparisonUpdatedAt, first.state.comparisonUpdatedAt);
});

test("same-bucket percent changes update observation without rescanning, then release once", () => {
  const first = advanceQuotaComparisonObservation(null, observation({
    updatedAt: "2033-05-18T03:31:00.000Z",
  }));
  const initialBoundary = advanceQuotaComparisonObservation(first.state, observation({
    updatedAt: "2033-05-18T03:35:00.000Z",
  }));
  assert.equal(initialBoundary.reason, "movementBoundary");

  const usage = advanceQuotaComparisonObservation(initialBoundary.state, observation({
    updatedAt: "2033-05-18T03:36:20.000Z",
    usedPercent: 0.14,
  }));
  assert.equal(usage.reason, "usagePending");
  assert.equal(usage.shouldRefreshPreciseUsage, false);
  assert.equal(usage.state.comparisonUpdatedAt, initialBoundary.state.comparisonUpdatedAt);

  const repeated = advanceQuotaComparisonObservation(usage.state, observation({
    updatedAt: "2033-05-18T03:37:20.000Z",
    usedPercent: 0.15,
  }));
  assert.equal(repeated.reason, "usagePending");
  assert.equal(repeated.shouldRefreshPreciseUsage, false);

  const released = advanceQuotaComparisonObservation(repeated.state, observation({
    updatedAt: "2033-05-18T03:40:20.000Z",
    usedPercent: 0.15,
  }));
  assert.equal(released.reason, "movementBoundary");
  assert.equal(released.shouldRefreshPreciseUsage, true);
  assert.equal(released.state.requiredLocalObservationAfterUnix, Date.parse(
    "2033-05-18T03:40:20.000Z",
  ) / 1_000);

  const nonFullResetDrift = advanceQuotaComparisonObservation(released.state, observation({
    updatedAt: "2033-05-18T03:41:20.000Z",
    usedPercent: 0.15,
    resetAtUnix: RESET + 900,
  }));
  assert.equal(nonFullResetDrift.shouldRefreshPreciseUsage, false);
  assert.equal(nonFullResetDrift.state.canonicalResetAtUnix, RESET);

  const exactlyFiveMinutes = advanceQuotaComparisonObservation(released.state, observation({
    updatedAt: "2033-05-18T03:41:20.000Z",
    usedPercent: 0,
    resetAtUnix: RESET + 300,
  }));
  assert.notEqual(exactlyFiveMinutes.reason, "reset");

  const nonFullDrift = advanceQuotaComparisonObservation(released.state, observation({
    updatedAt: "2033-05-18T03:41:20.000Z",
    usedPercent: 0.01,
    resetAtUnix: RESET + 301,
  }));
  assert.notEqual(nonFullDrift.reason, "reset");

  const newReset = advanceQuotaComparisonObservation(released.state, observation({
    updatedAt: "2033-05-18T03:41:20.000Z",
    usedPercent: 0,
    resetAtUnix: RESET + 301,
  }));
  assert.equal(newReset.reason, "reset");

  const postResetUsage = advanceQuotaComparisonObservation(newReset.state, observation({
    updatedAt: "2033-05-18T03:42:20.000Z",
    usedPercent: 0.01,
    resetAtUnix: RESET + 302,
  }));
  assert.equal(postResetUsage.reason, "usagePending");

  const planSwitch = advanceQuotaComparisonObservation(released.state, observation({
    updatedAt: "2033-05-18T03:41:20.000Z",
    usedPercent: 0.15,
    identity: { scopeKey: "scope-a", plan: "plus", limit: "codex" },
  }));
  assert.equal(planSwitch.reason, "identity");
  assert.equal(planSwitch.shouldRefreshPreciseUsage, true);
});

test("authoritative cycle IDs replace reset-time inference", () => {
  const first = advanceQuotaComparisonObservation(null, observation({ cycleId: "cycle-7" }));
  const drift = advanceQuotaComparisonObservation(first.state, observation({
    updatedAt: "2033-05-18T03:34:20.000Z",
    resetAtUnix: RESET + 900,
    usedPercent: 0.13,
    cycleId: "cycle-7",
  }));
  assert.equal(drift.reason, "unchanged");
  assert.equal(drift.state.canonicalResetAtUnix, RESET);

  const next = advanceQuotaComparisonObservation(drift.state, observation({
    updatedAt: "2033-05-18T03:35:20.000Z",
    resetAtUnix: RESET + 901,
    usedPercent: 0.01,
    cycleId: "cycle-8",
  }));
  assert.equal(next.reason, "reset");
  assert.equal(next.state.cycleId, "cycle-8");
});

test("introducing a cycle ID upgrades legacy state without a synthetic reset", () => {
  const legacy = advanceQuotaComparisonObservation(null, observation());
  const upgraded = advanceQuotaComparisonObservation(legacy.state, observation({
    updatedAt: "2033-05-18T03:34:20.000Z",
    resetAtUnix: RESET + 200,
    cycleId: "cycle-7",
  }));
  assert.equal(upgraded.reason, "unchanged");
  assert.equal(upgraded.shouldRefreshPreciseUsage, false);
  assert.equal(upgraded.state.cycleId, "cycle-7");
  assert.equal(upgraded.state.canonicalResetAtUnix, RESET);
});

test("account switch finalizes only on a later observation at its 5m boundary", () => {
  const first = advanceQuotaComparisonObservation(null, observation({
    updatedAt: "2033-05-18T03:31:00.000Z",
  }));
  const switched = advanceQuotaComparisonObservation(first.state, observation({
    updatedAt: "2033-05-18T03:32:00.000Z",
    identity: { scopeKey: "scope-b", plan: "pro", limit: "codex" },
  }));
  assert.equal(switched.reason, "identity");

  const early = advanceQuotaComparisonObservation(switched.state, observation({
    updatedAt: "2033-05-18T03:34:00.000Z",
    identity: { scopeKey: "scope-b", plan: "pro", limit: "codex" },
  }));
  assert.equal(early.shouldRefreshPreciseUsage, false);

  const baseline = advanceQuotaComparisonObservation(switched.state, observation({
    updatedAt: "2033-05-18T03:35:00.000Z",
    identity: { scopeKey: "scope-b", plan: "pro", limit: "codex" },
  }));
  assert.equal(baseline.reason, "baseline");
  assert.equal(baseline.shouldRefreshPreciseUsage, true);
  assert.equal(baseline.state.pendingBoundaryUnix, null);
});

test("stale and incomplete quota snapshots never move a valid watermark", () => {
  const first = advanceQuotaComparisonObservation(null, observation());
  const stale = advanceQuotaComparisonObservation(first.state, observation({
    quotaDataFresh: false,
    updatedAt: "2033-05-18T03:34:20.000Z",
    usedPercent: 0.14,
  }));
  assert.equal(stale.reason, "unavailable");
  assert.equal(stale.shouldRefreshPreciseUsage, false);
  assert.deepEqual(stale.state, first.state);
});

test("a proven pending-bucket alignment is retained across later same-percent polls", () => {
  const first = advanceQuotaComparisonObservation(null, observation({
    updatedAt: "2033-05-18T03:31:00.000Z",
  }));
  const ready = advanceQuotaComparisonObservation(first.state, observation({
    updatedAt: "2033-05-18T03:35:00.000Z",
  }));
  const aligned = alignQuotaComparisonObservation(
    ready.state,
    "2033-05-18T03:40:00.000Z",
  );
  assert.equal(aligned.comparisonUpdatedAt, "2033-05-18T03:40:00.000Z");
  assert.equal(aligned.requiredLocalObservationAfterUnix, Date.parse(
    "2033-05-18T03:40:00.000Z",
  ) / 1_000);

  const nextPoll = advanceQuotaComparisonObservation(aligned, observation({
    updatedAt: "2033-05-18T03:41:00.000Z",
  }));
  assert.equal(nextPoll.shouldRefreshPreciseUsage, false);
  assert.equal(nextPoll.state.comparisonUpdatedAt, "2033-05-18T03:40:00.000Z");
});

test("the initial quota baseline joins an active precise owner without replacing its publisher", () => {
  const initial = advanceQuotaComparisonObservation(null, observation());
  assert.equal(initial.reason, "initial");
  assert.equal(quotaComparisonNeedsPreciseRequest(initial, true), false);
  assert.equal(quotaComparisonNeedsPreciseRequest(initial, false), true);

  const reset = { ...initial, reason: "reset" };
  assert.equal(quotaComparisonNeedsPreciseRequest(reset, true), true);
});

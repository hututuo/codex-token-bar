import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("quota auto refresh plan preserves a supported multi-minute cadence when the dashboard is ready", () => {
  return withSsrModules(async (load) => {
    const { makeQuotaAutoRefreshPlan } = await load("/src/state/quotaAutoRefreshModel.ts");

    assert.deepEqual(
      makeQuotaAutoRefreshPlan({
        dashboardReady: true,
        fastSnapshotLoaded: true,
        intervalMs: 180_000,
      }),
      { active: true, intervalMs: 180_000 },
    );
  });
});

test("quota auto refresh plan falls back to one minute and stays stable for the same value", () => {
  return withSsrModules(async (load) => {
    const { makeQuotaAutoRefreshPlan } = await load("/src/state/quotaAutoRefreshModel.ts");
    const first = makeQuotaAutoRefreshPlan({
      dashboardReady: true,
      fastSnapshotLoaded: true,
      intervalMs: Number.NaN,
    });
    const second = makeQuotaAutoRefreshPlan({
      dashboardReady: true,
      fastSnapshotLoaded: true,
      intervalMs: 60_000,
    });

    assert.deepEqual(first, { active: true, intervalMs: 60_000 });
    assert.deepEqual(second, first);
  });
});

test("quota auto refresh plan is inactive only before quota prerequisites are ready", () => {
  return withSsrModules(async (load) => {
    const { makeQuotaAutoRefreshPlan } = await load("/src/state/quotaAutoRefreshModel.ts");

    assert.deepEqual(
      makeQuotaAutoRefreshPlan({
        dashboardReady: false,
        fastSnapshotLoaded: true,
        intervalMs: 30_000,
      }),
      { active: false, intervalMs: null },
    );
    assert.deepEqual(
      makeQuotaAutoRefreshPlan({
        dashboardReady: true,
        fastSnapshotLoaded: false,
        intervalMs: 30_000,
      }),
      { active: false, intervalMs: null },
    );
  });
});

test("quota auto refresh plan remains active while unrelated precise loading is true", () => {
  return withSsrModules(async (load) => {
    const { makeQuotaAutoRefreshPlan } = await load("/src/state/quotaAutoRefreshModel.ts");

    assert.deepEqual(
      makeQuotaAutoRefreshPlan({
        dashboardReady: true,
        fastSnapshotLoaded: true,
        intervalMs: 60_000,
        loading: true,
      }),
      { active: true, intervalMs: 60_000 },
    );
  });
});

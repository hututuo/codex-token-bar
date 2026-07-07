import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("quota auto refresh plan uses the selected cadence when the dashboard is ready", () => {
  return withSsrModules(async (load) => {
    const { makeQuotaAutoRefreshPlan } = await load("/src/state/quotaAutoRefreshModel.ts");

    assert.deepEqual(
      makeQuotaAutoRefreshPlan({
        dashboardReady: true,
        fastSnapshotLoaded: true,
        intervalMs: 180_000,
        loading: false,
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
      loading: false,
    });
    const second = makeQuotaAutoRefreshPlan({
      dashboardReady: true,
      fastSnapshotLoaded: true,
      intervalMs: 60_000,
      loading: false,
    });

    assert.deepEqual(first, { active: true, intervalMs: 60_000 });
    assert.deepEqual(second, first);
  });
});

test("quota auto refresh plan is inactive before data is ready or while loading", () => {
  return withSsrModules(async (load) => {
    const { makeQuotaAutoRefreshPlan } = await load("/src/state/quotaAutoRefreshModel.ts");

    assert.deepEqual(
      makeQuotaAutoRefreshPlan({
        dashboardReady: false,
        fastSnapshotLoaded: true,
        intervalMs: 30_000,
        loading: false,
      }),
      { active: false, intervalMs: null },
    );
    assert.deepEqual(
      makeQuotaAutoRefreshPlan({
        dashboardReady: true,
        fastSnapshotLoaded: false,
        intervalMs: 30_000,
        loading: false,
      }),
      { active: false, intervalMs: null },
    );
    assert.deepEqual(
      makeQuotaAutoRefreshPlan({
        dashboardReady: true,
        fastSnapshotLoaded: true,
        intervalMs: 30_000,
        loading: true,
      }),
      { active: false, intervalMs: null },
    );
  });
});

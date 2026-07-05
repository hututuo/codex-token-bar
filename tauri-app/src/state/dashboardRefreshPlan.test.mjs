import assert from "node:assert/strict";
import test from "node:test";

import {
  applyDashboardRefreshPlan,
  makeDashboardRefreshPlan,
  makeDashboardWakeRefreshContext,
} from "./dashboardRefreshPlan.ts";

function dispatchCounts(actions) {
  const counts = {
    preciseUsage: 0,
    forceQuota: 0,
    radar: 0,
    providerScan: 0,
  };

  applyDashboardRefreshPlan(actions, {
    refreshPreciseUsage: () => {
      counts.preciseUsage += 1;
    },
    refreshQuota: () => {
      counts.forceQuota += 1;
    },
    refreshRadar: () => {
      counts.radar += 1;
    },
    scanProviders: () => {
      counts.providerScan += 1;
    },
  });

  return counts;
}

test("manual refresh updates usage quota and radar, with provider only when visible", () => {
  assert.deepEqual(makeDashboardRefreshPlan("manual", { providerVisible: false }), [
    "preciseUsage",
    "forceQuota",
    "radar",
  ]);
  assert.deepEqual(makeDashboardRefreshPlan("manual", { providerVisible: true }), [
    "preciseUsage",
    "forceQuota",
    "radar",
    "providerScan",
  ]);
});

test("quota retry is quota only", () => {
  assert.deepEqual(makeDashboardRefreshPlan("quotaRetry", { providerVisible: true }), [
    "forceQuota",
  ]);
  assert.deepEqual(dispatchCounts(makeDashboardRefreshPlan("quotaRetry", {
    providerVisible: true,
  })), {
    preciseUsage: 0,
    forceQuota: 1,
    radar: 0,
    providerScan: 0,
  });
});

test("manual refresh dispatches precise usage forced quota and radar without provider scan in Tauri", () => {
  assert.deepEqual(dispatchCounts(makeDashboardRefreshPlan("manual", {
    providerVisible: false,
  })), {
    preciseUsage: 1,
    forceQuota: 1,
    radar: 1,
    providerScan: 0,
  });
});

test("system wake always refreshes quota but does not scan providers", () => {
  assert.deepEqual(makeDashboardRefreshPlan("systemWake", {
    providerVisible: true,
    dashboardVisible: false,
    usageStale: false,
    radarVisible: false,
    radarStale: false,
  }), [
    "forceQuota",
  ]);
});

test("system wake refreshes usage and radar only when visible or stale", () => {
  assert.deepEqual(makeDashboardRefreshPlan("systemWake", {
    providerVisible: false,
    dashboardVisible: true,
    usageStale: false,
    radarVisible: true,
    radarStale: false,
  }), [
    "preciseUsage",
    "forceQuota",
    "radar",
  ]);

  assert.deepEqual(makeDashboardRefreshPlan("systemWake", {
    providerVisible: false,
    dashboardVisible: false,
    usageStale: true,
    radarVisible: false,
    radarStale: true,
  }), [
    "preciseUsage",
    "forceQuota",
    "radar",
  ]);
});

test("Tauri wake context derives dashboard visibility and stale usage without provider scans", () => {
  const nowMs = Date.parse("2026-07-06T02:30:00.000Z");
  const intervalMs = 3 * 60 * 1000;

  assert.deepEqual(makeDashboardWakeRefreshContext({
    dashboardGeneratedAt: "2026-07-06T02:29:00.000Z",
    dashboardVisible: true,
    nowMs,
    visibleRefreshIntervalMs: intervalMs,
  }), {
    providerVisible: false,
    dashboardVisible: true,
    usageStale: false,
    radarVisible: true,
    radarStale: false,
  });

  assert.deepEqual(makeDashboardWakeRefreshContext({
    dashboardGeneratedAt: "2026-07-06T02:26:59.999Z",
    dashboardVisible: false,
    nowMs,
    visibleRefreshIntervalMs: intervalMs,
  }), {
    providerVisible: false,
    dashboardVisible: false,
    usageStale: true,
    radarVisible: false,
    radarStale: false,
  });

  assert.deepEqual(makeDashboardWakeRefreshContext({
    dashboardGeneratedAt: null,
    dashboardVisible: false,
    nowMs,
    visibleRefreshIntervalMs: intervalMs,
  }), {
    providerVisible: false,
    dashboardVisible: false,
    usageStale: true,
    radarVisible: false,
    radarStale: false,
  });
});

test("system wake dispatches forced quota plus visible or stale refresh effects from Tauri context", () => {
  const nowMs = Date.parse("2026-07-06T02:30:00.000Z");
  const intervalMs = 3 * 60 * 1000;

  assert.deepEqual(dispatchCounts(makeDashboardRefreshPlan("systemWake",
    makeDashboardWakeRefreshContext({
      dashboardGeneratedAt: "2026-07-06T02:29:00.000Z",
      dashboardVisible: true,
      nowMs,
      visibleRefreshIntervalMs: intervalMs,
    }),
  )), {
    preciseUsage: 1,
    forceQuota: 1,
    radar: 1,
    providerScan: 0,
  });

  assert.deepEqual(dispatchCounts(makeDashboardRefreshPlan("systemWake",
    makeDashboardWakeRefreshContext({
      dashboardGeneratedAt: "2026-07-06T02:29:00.000Z",
      dashboardVisible: false,
      nowMs,
      visibleRefreshIntervalMs: intervalMs,
    }),
  )), {
    preciseUsage: 0,
    forceQuota: 1,
    radar: 0,
    providerScan: 0,
  });
});

test("applyDashboardRefreshPlan dispatches actions in plan order", () => {
  const calls = [];
  applyDashboardRefreshPlan(["preciseUsage", "forceQuota", "radar"], {
    refreshPreciseUsage: () => calls.push("preciseUsage"),
    refreshQuota: () => calls.push("forceQuota"),
    refreshRadar: () => calls.push("radar"),
    scanProviders: () => calls.push("providerScan"),
  });

  assert.deepEqual(calls, ["preciseUsage", "forceQuota", "radar"]);
});

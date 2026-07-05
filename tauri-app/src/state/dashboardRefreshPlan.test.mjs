import assert from "node:assert/strict";
import test from "node:test";

import {
  applyDashboardRefreshPlan,
  makeDashboardRefreshPlan,
} from "./dashboardRefreshPlan.ts";

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

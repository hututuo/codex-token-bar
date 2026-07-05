import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("mergeQuota aligns quota history by startUnix instead of array position", async () => {
  const source = await readFile(new URL("./dashboardMergers.ts", import.meta.url), "utf8");

  assert.equal(source.includes("new Map(historyPoints.map((point) => [point.startUnix, point]))"), true);
  assert.equal(source.includes("historyByStart.get(point.startUnix)"), true);
  assert.equal(source.includes("historyPoints[index]"), false);
});

test("mergeQuota carries daily quota history for the heatmap", async () => {
  const source = await readFile(new URL("./dashboardMergers.ts", import.meta.url), "utf8");

  assert.equal(source.includes("quota.quotaHistoryDaily"), true);
  assert.equal(source.includes("mergeActivityQuotaHistory"), true);
  assert.equal(source.includes("new Map(historyDays.map((day) => [day.date, day]))"), true);
});

test("precise dashboard merge preserves already loaded quota overlays", async () => {
  const source = await readFile(new URL("./dashboardMergers.ts", import.meta.url), "utf8");

  assert.equal(source.includes("activityDays: mergeActivityQuotaHistory(precise.activityDays, state.dashboard.activityDays)"), true);
  assert.equal(source.includes("recentUsage24h: mergeQuotaHistory(precise.recentUsage24h, state.dashboard.recentUsage24h)"), true);
  assert.equal(source.includes("recentUsage7d: mergeQuotaHistory(precise.recentUsage7d, state.dashboard.recentUsage7d)"), true);
  assert.equal(source.includes("recentUsage30d: mergeQuotaHistory(precise.recentUsage30d, state.dashboard.recentUsage30d)"), true);
});

test("dashboard snapshots do not synchronously apply quota history", async () => {
  const dashboardSource = await readFile(new URL("../../src-tauri/src/core/dashboard.rs", import.meta.url), "utf8");
  const stateSqliteSource = await readFile(new URL("../../src-tauri/src/core/usage/state_sqlite.rs", import.meta.url), "utf8");
  const tokenCountSource = await readFile(new URL("../../src-tauri/src/core/usage/token_count_jsonl.rs", import.meta.url), "utf8");

  assert.equal(dashboardSource.includes("apply_recent_quota_history"), false);
  assert.equal(stateSqliteSource.includes("apply_activity_history"), false);
  assert.equal(tokenCountSource.includes("apply_activity_history"), false);
});

test("mergeQuota replaces stale quota warnings and diagnostics after a successful quota refresh", () => {
  return withSsrModules(async (load) => {
    const { mergeQuota } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      warnings: [
        { source: "account_quota", message: "登录凭证缺失" },
        { source: "usage_cache", message: "用量缓存仍在刷新" },
      ],
      diagnostics: [
        quotaDiagnostic({
          source: "account_quota",
          category: "auth_missing",
          message: "登录凭证缺失",
          rawCause: "未找到 access token",
        }),
        quotaDiagnostic({
          source: "source_integrity",
          category: "source_mismatch",
          message: "Codex Home 与额度登录来源不一致",
        }),
        quotaDiagnostic({
          source: "usage_cache",
          category: "stale_cached_data",
          message: "用量缓存仍在刷新",
        }),
      ],
    });
    const quota = quotaBundleFixture({
      warnings: [],
      diagnostics: [],
    });

    const next = mergeQuota(state, quota);

    assert.deepEqual(next.dashboard.warnings, [{ source: "usage_cache", message: "用量缓存仍在刷新" }]);
    assert.deepEqual(next.dashboard.diagnostics.map((diagnostic) => diagnostic.message), ["用量缓存仍在刷新"]);
  });
});

test("mergeQuota replaces old quota diagnostics with the latest quota diagnostic", () => {
  return withSsrModules(async (load) => {
    const { mergeQuota } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      warnings: [{ source: "account_quota", message: "登录凭证缺失" }],
      diagnostics: [
        quotaDiagnostic({
          source: "account_quota",
          category: "auth_missing",
          message: "登录凭证缺失",
        }),
      ],
    });
    const quota = quotaBundleFixture({
      warnings: [{ source: "reset_credit", message: "重置卡读取失败：网络连接失败" }],
      diagnostics: [
        quotaDiagnostic({
          source: "reset_credit",
          category: "reset_credit_failure",
          message: "重置卡读取失败：网络连接失败",
          underlyingCategory: "network_send_fetch",
        }),
      ],
    });

    const next = mergeQuota(state, quota);

    assert.deepEqual(next.dashboard.warnings, [{ source: "reset_credit", message: "重置卡读取失败：网络连接失败" }]);
    assert.deepEqual(next.dashboard.diagnostics.map((diagnostic) => diagnostic.category), ["reset_credit_failure"]);
  });
});

function stateWithDashboard(overrides = {}) {
  return {
    codexHome: null,
    platform: null,
    dashboard: dashboardFixture(overrides),
    liveRate: null,
    liveThreadOptions: [],
    repair: null,
    diagnostics: [],
    loading: false,
  };
}

function dashboardFixture(overrides = {}) {
  return {
    generatedAt: "2026-07-06T00:00:00Z",
    account: { displayName: "本地用户", planLabel: "Pro" },
    stats: {
      totalTokens: 0,
      peakDayTokens: 0,
      peakThreadTokens: 0,
      currentStreakDays: 0,
      longestStreakDays: 0,
      totalCalls: 0,
      totalThreads: 0,
    },
    quota: quotaSnapshotFixture(),
    activityDays: [],
    recentUsage24h: [],
    recentUsage7d: [],
    recentUsage30d: [],
    cacheHitRanking: [],
    cacheUsage: { sessions: [], turns: [] },
    warnings: [],
    diagnostics: [],
    ...overrides,
  };
}

function quotaBundleFixture(overrides = {}) {
  return {
    account: { displayName: "本地用户", planLabel: "Pro" },
    quota: quotaSnapshotFixture(),
    quotaHistoryDaily: [],
    quotaHistory24h: [],
    quotaHistory7d: [],
    quotaHistory30d: [],
    warnings: [],
    diagnostics: [],
    ...overrides,
  };
}

function quotaSnapshotFixture() {
  return {
    fiveHour: {
      label: "5h",
      remainingPercent: 0.8,
      usedPercent: 0.2,
      resetsAt: "2h",
      resetsAtUnix: 1781715600,
    },
    sevenDay: {
      label: "7d",
      remainingPercent: 0.7,
      usedPercent: 0.3,
      resetsAt: "3天",
      resetsAtUnix: 1782144492,
    },
    resetCredit: {
      availableCount: 0,
      status: "无可用重置卡",
      credits: [],
    },
    paceLabel: "稳定",
  };
}

function quotaDiagnostic(overrides = {}) {
  return {
    source: "account_quota",
    category: "unknown",
    severity: "warning",
    message: "未知诊断",
    rawCause: "raw",
    underlyingCategory: null,
    attempts: null,
    httpStatus: null,
    retryable: true,
    occurredAt: "2026-07-06T00:00:00Z",
    staleDataDisplayed: false,
    ...overrides,
  };
}

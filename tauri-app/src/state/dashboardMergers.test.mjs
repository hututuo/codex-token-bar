import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";
import { LONG_RECENT_POINT_COUNT } from "../timeSeriesTimeline.ts";

test("mergeQuota aligns quota history by startUnix instead of array position", async () => {
  return withSsrModules(async (load) => {
    const { mergeQuota } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      recentUsage24h: [
        recentUsagePoint({ label: "00:00", startUnix: 100, tokens: 10 }),
        recentUsagePoint({ label: "01:00", startUnix: 200, tokens: 20 }),
        recentUsagePoint({ label: "02:00", startUnix: 300, tokens: 30 }),
      ],
    });
    const quota = quotaBundleFixture({
      quotaHistory24h: [
        quotaHistoryPoint({ label: "02:00", startUnix: 300, fiveHourRemainingPercent: 0.3, sevenDayRemainingPercent: 0.7 }),
        quotaHistoryPoint({ label: "00:00", startUnix: 100, fiveHourRemainingPercent: 0.1, sevenDayRemainingPercent: 0.9 }),
        quotaHistoryPoint({ label: "extra", startUnix: 999, fiveHourRemainingPercent: 0.9, sevenDayRemainingPercent: 0.1 }),
      ],
    });

    const next = mergeQuota(state, quota);

    assert.deepEqual(next.dashboard.recentUsage24h.map((point) => point.startUnix), [100, 200, 300]);
    assert.deepEqual(next.dashboard.recentUsage24h.map((point) => point.tokens), [10, 20, 30]);
    assert.deepEqual(next.dashboard.recentUsage24h.map((point) => point.fiveHourRemainingPercent), [0.1, null, 0.3]);
    assert.deepEqual(next.dashboard.recentUsage24h.map((point) => point.sevenDayRemainingPercent), [0.9, null, 0.7]);
  });
});

test("quota metadata reaches DashboardSnapshot and survives a later precise usage merge", async () => {
  return withSsrModules(async (load) => {
    const { mergePreciseDashboard, mergeQuota } = await load("/src/state/dashboardMergers.ts");
    const quota = quotaBundleFixture({
      updatedAt: "2026-07-31T05:02:00Z",
      attributionIdentity: {
        scopeKey: "opaque-hash-only",
        plan: "pro",
        limit: "codex",
      },
    });
    const withQuota = mergeQuota(stateWithDashboard(), quota);
    const next = mergePreciseDashboard(withQuota, dashboardFixture({
      generatedAt: "2026-07-31T05:05:00Z",
      quotaUpdatedAt: null,
      attributionIdentity: null,
    }));

    assert.equal(next.dashboard.quotaUpdatedAt, "2026-07-31T05:02:00Z");
    assert.deepEqual(next.dashboard.attributionIdentity, quota.attributionIdentity);
  });
});

test("exact-read start marks prior recent usage stale while quota merge preserves coverage metadata", async () => {
  return withSsrModules(async (load) => {
    const { markPreciseRecentUsageStale, mergeQuota } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      preciseRecentUsageCoveredAt: "2026-07-31T05:05:00Z",
      preciseRecentUsageFresh: true,
    });

    const stale = markPreciseRecentUsageStale(state);
    assert.equal(stale.dashboard.preciseRecentUsageFresh, false);
    assert.equal(stale.dashboard.preciseRecentUsageCoveredAt, "2026-07-31T05:05:00Z");

    const withQuota = mergeQuota(stale, quotaBundleFixture({ updatedAt: "2026-07-31T05:06:00Z" }));
    assert.equal(withQuota.dashboard.preciseRecentUsageFresh, false);
    assert.equal(withQuota.dashboard.preciseRecentUsageCoveredAt, "2026-07-31T05:05:00Z");
    assert.equal(withQuota.dashboard.quotaUpdatedAt, "2026-07-31T05:06:00Z");
  });
});

test("attribution safety acknowledgement clears only the local episode marker", async () => {
  return withSsrModules(async (load) => {
    const { clearPreciseAttributionSafety } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      preciseAttributionProvenanceEpoch: "epoch-1",
      preciseAttributionGeneration: 42,
      preciseAttributionUnsafeSinceGeneration: 40,
      preciseAttributionUnsafeId: "unsafe-1",
      preciseAttributionCurrentScanUnsafe: true,
      stats: {
        totalTokens: 123,
        peakDayTokens: 123,
        peakThreadTokens: 123,
        currentStreakDays: 1,
        longestStreakDays: 1,
        totalCalls: 2,
        totalThreads: 1,
      },
    });

    const next = clearPreciseAttributionSafety(state);

    assert.equal(next.dashboard.preciseAttributionProvenanceEpoch, "epoch-1");
    assert.equal(next.dashboard.preciseAttributionGeneration, 42);
    assert.equal(next.dashboard.preciseAttributionUnsafeSinceGeneration, null);
    assert.equal(next.dashboard.preciseAttributionUnsafeId, null);
    assert.equal(next.dashboard.preciseAttributionCurrentScanUnsafe, false);
    assert.equal(next.dashboard.stats.totalTokens, 123);
  });
});

test("incomplete precise result keeps the last trusted coverage visible", async () => {
  return withSsrModules(async (load) => {
    const { dashboardSnapshotHasTrustedStartupData } = await load("/src/state/dashboardState.ts");
    const { mergePreciseDashboard } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      preciseRecentUsageCoveredAt: "2026-07-31T05:05:00Z",
      preciseRecentUsageFresh: true,
      stats: {
        totalTokens: 100,
        peakDayTokens: 100,
        peakThreadTokens: 100,
        currentStreakDays: 1,
        longestStreakDays: 1,
        totalCalls: 1,
        totalThreads: 1,
      },
    });
    const incomplete = dashboardFixture({
      preciseRecentUsageCoveredAt: null,
      preciseRecentUsageFresh: false,
      stats: {
        totalTokens: 120,
        peakDayTokens: 120,
        peakThreadTokens: 120,
        currentStreakDays: 1,
        longestStreakDays: 1,
        totalCalls: 2,
        totalThreads: 1,
      },
    });

    const next = mergePreciseDashboard(state, incomplete);

    assert.equal(next.dashboard.preciseRecentUsageCoveredAt, "2026-07-31T05:05:00Z");
    assert.equal(next.dashboard.preciseRecentUsageFresh, false);
    assert.equal(next.dashboard.stats.totalTokens, 100);
    assert.equal(next.dashboard.stats.totalCalls, 1);
    assert.equal(dashboardSnapshotHasTrustedStartupData(next.dashboard), true);
  });
});

test("all-zero legacy startup placeholder remains unavailable", async () => {
  return withSsrModules(async (load) => {
    const { dashboardSnapshotHasTrustedStartupData } = await load("/src/state/dashboardState.ts");
    assert.equal(dashboardSnapshotHasTrustedStartupData(dashboardFixture()), false);
  });
});

test("mergeQuota overlays the full 30-day five-minute canvas without changing 7d or 30d axes", async () => {
  return withSsrModules(async (load) => {
    const { mergeQuota } = await load("/src/state/dashboardMergers.ts");
    const pointCount = LONG_RECENT_POINT_COUNT;
    const firstStartUnix = 1_780_000_000;
    const recentUsage24h = Array.from({ length: pointCount }, (_, index) =>
      recentUsagePoint({ startUnix: firstStartUnix + index * 5 * 60, tokens: index }),
    );
    const latestStartUnix = recentUsage24h.at(-1).startUnix;
    const recentUsage7d = [recentUsagePoint({ startUnix: 700, tokens: 7 })];
    const recentUsage30d = [recentUsagePoint({ startUnix: 3_000, tokens: 30 })];
    const state = stateWithDashboard({ recentUsage24h, recentUsage7d, recentUsage30d });
    const quota = quotaBundleFixture({
      quotaHistory24h: [
        quotaHistoryPoint({ startUnix: firstStartUnix, fiveHourRemainingPercent: 0.91 }),
        quotaHistoryPoint({ startUnix: latestStartUnix, fiveHourRemainingPercent: 0.42 }),
      ],
      quotaHistory7d: [quotaHistoryPoint({ startUnix: 700, sevenDayRemainingPercent: 0.77 })],
      quotaHistory30d: [quotaHistoryPoint({ startUnix: 3_000, sevenDayRemainingPercent: 0.33 })],
    });

    const next = mergeQuota(state, quota);

    assert.equal(next.dashboard.recentUsage24h.length, pointCount);
    assert.equal(next.dashboard.recentUsage24h[0].fiveHourRemainingPercent, 0.91);
    assert.equal(next.dashboard.recentUsage24h.at(-1).fiveHourRemainingPercent, 0.42);
    assert.deepEqual(next.dashboard.recentUsage7d.map((point) => [point.startUnix, point.sevenDayRemainingPercent]), [[700, 0.77]]);
    assert.deepEqual(next.dashboard.recentUsage30d.map((point) => [point.startUnix, point.sevenDayRemainingPercent]), [[3_000, 0.33]]);
  });
});

test("fallback -> quota -> precise preserves quota across the full long recent timeline", async () => {
  return withSsrModules(async (load) => {
    const { mergePreciseDashboard, mergeQuota } = await load("/src/state/dashboardMergers.ts");
    const { emptyRecentUsage } = await load("/src/api/fallback/timeSeriesFallback.ts");
    const fallbackPoints = emptyRecentUsage(new Date("2026-07-11T12:02:00Z"));
    const indices = [0, Math.floor(fallbackPoints.length / 2), fallbackPoints.length - 1];
    const quota = quotaBundleFixture({
      quotaHistory24h: indices.map((index) => quotaHistoryPoint({
        startUnix: fallbackPoints[index].startUnix,
        fiveHourRemainingPercent: 0.9 - index / fallbackPoints.length / 2,
      })),
    });
    const fallback = stateWithDashboard({ recentUsage24h: fallbackPoints });
    const withQuota = mergeQuota(fallback, quota);
    const precisePoints = fallbackPoints.map((point, index) => recentUsagePoint({
      ...point,
      tokens: index + 1,
    }));
    const precise = dashboardFixture({ recentUsage24h: precisePoints });

    const next = mergePreciseDashboard(withQuota, precise);

    assert.equal(next.dashboard.recentUsage24h.length, LONG_RECENT_POINT_COUNT);
    assert.deepEqual(
      indices.map((index) => next.dashboard.recentUsage24h[index].fiveHourRemainingPercent),
      indices.map((index) => withQuota.dashboard.recentUsage24h[index].fiveHourRemainingPercent),
    );
    assert.deepEqual(
      indices.map((index) => next.dashboard.recentUsage24h[index].tokens),
      indices.map((index) => index + 1),
    );
  });
});

test("mergeQuota carries daily quota history for the activity heatmap", async () => {
  return withSsrModules(async (load) => {
    const { mergeQuota } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      activityDays: [
        activityDay({ date: "2026-07-04", tokens: 400 }),
        activityDay({ date: "2026-07-05", tokens: 500 }),
      ],
    });
    const quota = quotaBundleFixture({
      quotaHistoryDaily: [
        quotaHistoryDay({ date: "2026-07-05", fiveHourRemainingPercent: 0.42, sevenDayRemainingPercent: 0.84 }),
        quotaHistoryDay({ date: "2026-07-06", fiveHourRemainingPercent: 0.1, sevenDayRemainingPercent: 0.2 }),
      ],
    });

    const next = mergeQuota(state, quota);

    assert.deepEqual(next.dashboard.activityDays.map((day) => day.date), ["2026-07-04", "2026-07-05"]);
    assert.deepEqual(next.dashboard.activityDays.map((day) => day.tokens), [400, 500]);
    assert.deepEqual(next.dashboard.activityDays.map((day) => day.fiveHourRemainingPercent), [null, 0.42]);
    assert.deepEqual(next.dashboard.activityDays.map((day) => day.sevenDayRemainingPercent), [null, 0.84]);
  });
});

test("precise dashboard merge preserves already loaded quota overlays", async () => {
  return withSsrModules(async (load) => {
    const { mergePreciseDashboard } = await load("/src/state/dashboardMergers.ts");
    const currentQuota = quotaSnapshotFixture({
      paceLabel: "已加载额度",
    });
    const state = stateWithDashboard({
      account: { displayName: "已加载账户", planLabel: "Pro" },
      quota: currentQuota,
      activityDays: [
        activityDay({ date: "2026-07-04", fiveHourRemainingPercent: 0.4, sevenDayRemainingPercent: 0.8 }),
      ],
      recentUsage24h: [
        recentUsagePoint({ label: "24h", startUnix: 100, fiveHourRemainingPercent: 0.41, sevenDayRemainingPercent: 0.81 }),
      ],
      recentUsage7d: [
        recentUsagePoint({ label: "7d", startUnix: 700, fiveHourRemainingPercent: 0.47, sevenDayRemainingPercent: 0.87 }),
      ],
      recentUsage30d: [
        recentUsagePoint({ label: "30d", startUnix: 3000, fiveHourRemainingPercent: 0.43, sevenDayRemainingPercent: 0.83 }),
      ],
      warnings: [{ source: "usage_cache", message: "旧缓存提醒" }],
      diagnostics: [quotaDiagnostic({ source: "usage_cache", message: "旧缓存诊断" })],
    });
    const precise = dashboardFixture({
      generatedAt: "2026-07-06T01:00:00Z",
      account: { displayName: "精确快照占位账户", planLabel: "Unknown" },
      quota: quotaSnapshotFixture({ paceLabel: "精确快照占位额度" }),
      stats: {
        totalTokens: 999,
        peakDayTokens: 500,
        peakThreadTokens: 300,
        currentStreakDays: 2,
        longestStreakDays: 3,
        totalCalls: 9,
        totalThreads: 4,
      },
      activityDays: [
        activityDay({ date: "2026-07-04", tokens: 44, fiveHourRemainingPercent: null, sevenDayRemainingPercent: null }),
        activityDay({ date: "2026-07-05", tokens: 55, fiveHourRemainingPercent: null, sevenDayRemainingPercent: null }),
      ],
      recentUsage24h: [
        recentUsagePoint({ label: "24h", startUnix: 100, tokens: 11, fiveHourRemainingPercent: null, sevenDayRemainingPercent: null }),
      ],
      recentUsage7d: [
        recentUsagePoint({ label: "7d", startUnix: 700, tokens: 77, fiveHourRemainingPercent: null, sevenDayRemainingPercent: null }),
      ],
      recentUsage30d: [
        recentUsagePoint({ label: "30d", startUnix: 3000, tokens: 30, fiveHourRemainingPercent: null, sevenDayRemainingPercent: null }),
      ],
      warnings: [{ source: "token_count", message: "新精确提醒" }],
      diagnostics: [quotaDiagnostic({ source: "token_count", message: "新精确诊断" })],
    });

    const next = mergePreciseDashboard(state, precise);

    assert.equal(next.dashboard.generatedAt, "2026-07-06T01:00:00Z");
    assert.equal(next.dashboard.stats.totalTokens, 999);
    assert.deepEqual(next.dashboard.account, { displayName: "已加载账户", planLabel: "Pro" });
    assert.equal(next.dashboard.quota, currentQuota);
    assert.deepEqual(next.dashboard.activityDays.map((day) => [day.date, day.tokens, day.fiveHourRemainingPercent]), [
      ["2026-07-04", 44, 0.4],
      ["2026-07-05", 55, null],
    ]);
    assert.deepEqual(next.dashboard.recentUsage24h.map((point) => [point.startUnix, point.tokens, point.fiveHourRemainingPercent]), [
      [100, 11, 0.41],
    ]);
    assert.deepEqual(next.dashboard.recentUsage7d.map((point) => [point.startUnix, point.tokens, point.sevenDayRemainingPercent]), [
      [700, 77, 0.87],
    ]);
    assert.deepEqual(next.dashboard.recentUsage30d.map((point) => [point.startUnix, point.tokens, point.fiveHourRemainingPercent]), [
      [3000, 30, 0.43],
    ]);
    assert.deepEqual(next.dashboard.warnings.map((warning) => warning.message), ["旧缓存提醒", "新精确提醒"]);
    assert.deepEqual(next.dashboard.diagnostics.map((diagnostic) => diagnostic.message), ["旧缓存诊断", "新精确诊断"]);
  });
});

test("precise dashboard merge clears metadata-only usage precision warning", async () => {
  return withSsrModules(async (load) => {
    const { mergePreciseDashboard } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      warnings: [
        {
          source: "usage_precision",
          message: "精确 token 仍在读取，当前仅显示会话元数据，请稍后刷新。",
        },
      ],
    });
    const precise = dashboardFixture({
      stats: {
        totalTokens: 500,
        peakDayTokens: 300,
        peakThreadTokens: 200,
        currentStreakDays: 1,
        longestStreakDays: 2,
        totalCalls: 5,
        totalThreads: 3,
      },
      warnings: [],
    });

    const next = mergePreciseDashboard(state, precise);

    assert.equal(next.dashboard.stats.totalTokens, 500);
    assert.deepEqual(next.dashboard.warnings, []);
  });
});

test("dashboard snapshots do not synchronously apply quota history", async () => {
  // This is an architecture guard: quota-history overlays should stay in the frontend merge layer,
  // not in the Rust fast/precise snapshot builders.
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

test("mergeQuota clears only main quota diagnostics and preserves the reset-credit channel", () => {
  return withSsrModules(async (load) => {
    const { mergeQuota } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      warnings: [
        { source: "account_quota", message: "登录凭证缺失" },
        { source: "reset_credit", message: "旧重置卡错误" },
      ],
      diagnostics: [
        quotaDiagnostic({
          source: "account_quota",
          category: "auth_missing",
          message: "登录凭证缺失",
        }),
        quotaDiagnostic({
          source: "reset_credit",
          category: "reset_credit_failure",
          message: "旧重置卡错误",
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

    assert.deepEqual(next.dashboard.warnings, [{ source: "reset_credit", message: "旧重置卡错误" }]);
    assert.deepEqual(next.dashboard.diagnostics.map((diagnostic) => diagnostic.message), ["旧重置卡错误"]);
  });
});

test("mergeResetCredits changes only reset data and reset diagnostics", () => {
  return withSsrModules(async (load) => {
    const { mergeResetCredits } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      quotaUpdatedAt: "2026-08-11T01:00:00Z",
      quota: quotaSnapshotFixture({
        paceLabel: "主额度保持",
        resetCredit: { availableCount: 1, status: "旧卡", credits: [] },
      }),
      warnings: [{ source: "account_quota", message: "主额度错误" }],
      diagnostics: [quotaDiagnostic({ source: "account_quota", message: "主额度错误" })],
    });
    const next = mergeResetCredits(state, {
      updatedAt: "2026-08-11T01:01:00Z",
      resetCredit: { availableCount: 3, status: "重置卡已更新", credits: [] },
      warnings: [],
      diagnostics: [],
      successful: true,
    });

    assert.equal(next.dashboard.quotaUpdatedAt, "2026-08-11T01:00:00Z");
    assert.equal(next.dashboard.quota.paceLabel, "主额度保持");
    assert.equal(next.dashboard.quota.resetCredit.availableCount, 3);
    assert.equal(next.dashboard.quota.resetCredit.updatedAt, "2026-08-11T01:01:00Z");
    assert.deepEqual(next.dashboard.warnings, [{ source: "account_quota", message: "主额度错误" }]);
    assert.deepEqual(next.dashboard.diagnostics.map((item) => item.message), ["主额度错误"]);
  });
});

test("failed reset refresh preserves prior cards without changing main quota", () => {
  return withSsrModules(async (load) => {
    const { mergeResetCredits } = await load("/src/state/dashboardMergers.ts");
    const state = stateWithDashboard({
      quota: quotaSnapshotFixture({
        paceLabel: "主额度保持",
        resetCredit: { availableCount: 2, status: "旧卡已更新", credits: [{ cardId: "kept" }] },
      }),
    });
    const next = mergeResetCredits(state, {
      updatedAt: "2026-08-11T01:02:00Z",
      resetCredit: { availableCount: 0, status: "重置卡读取失败", credits: [] },
      warnings: [{ source: "reset_credit", message: "重置卡读取失败" }],
      diagnostics: [quotaDiagnostic({
        source: "reset_credit",
        category: "reset_credit_failure",
        message: "重置卡读取失败",
      })],
      successful: false,
    });

    assert.equal(next.dashboard.quota.paceLabel, "主额度保持");
    assert.equal(next.dashboard.quota.resetCredit.availableCount, 2);
    assert.deepEqual(next.dashboard.quota.resetCredit.credits, [{ cardId: "kept" }]);
    assert.equal(next.dashboard.quota.resetCredit.status, "重置卡读取失败");
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
    preciseRecentUsageCoveredAt: null,
    preciseRecentUsageFresh: false,
    quotaUpdatedAt: null,
    attributionIdentity: null,
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
    updatedAt: "2026-07-06T00:00:00Z",
    attributionIdentity: null,
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

function quotaSnapshotFixture(overrides = {}) {
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
    ...overrides,
  };
}

function activityDay(overrides = {}) {
  return {
    date: "2026-07-05",
    tokens: 0,
    calls: 0,
    cacheHitRate: 0,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
    ...overrides,
  };
}

function recentUsagePoint(overrides = {}) {
  return {
    label: "00:00",
    startUnix: 0,
    tokens: 0,
    calls: 0,
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    cacheHitRate: null,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
    ...overrides,
  };
}

function quotaHistoryDay(overrides = {}) {
  return {
    date: "2026-07-05",
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
    ...overrides,
  };
}

function quotaHistoryPoint(overrides = {}) {
  return {
    label: "00:00",
    startUnix: 0,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
    ...overrides,
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

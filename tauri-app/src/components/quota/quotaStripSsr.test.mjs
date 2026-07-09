import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

const quotaSnapshot = {
  fiveHour: {
    label: "5h",
    remainingPercent: 0.62,
    usedPercent: 0.38,
    resetsAt: "2h",
  },
  sevenDay: {
    label: "7d",
    remainingPercent: 0.81,
    usedPercent: 0.19,
    resetsAt: "3天",
  },
  resetCredit: {
    availableCount: 0,
    status: "empty",
    credits: [],
  },
  paceLabel: "稳定",
};

const quotaWarnings = [
  { source: "account_quota", message: "账户额度读取失败" },
  { source: "usage_cache", message: "缓存还在初始化" },
  { source: "reset_credit", message: "重置卡读取失败" },
  { source: "account_quota", message: "重复账户额度读取失败" },
];

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("QuotaStrip renders quota read warnings and retry affordance from filtered warning model", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, {
      onRetryQuotaRefresh: () => {},
      snapshot: quotaSnapshot,
      warnings: quotaWarnings,
    });

    assert.match(html, /role="status"/);
    assert.match(html, />读取失败原因</);
    assert.match(html, /账户额度读取失败；重置卡读取失败/);
    assert.doesNotMatch(html, /缓存还在初始化/);
    assert.doesNotMatch(html, /重复账户额度读取失败/);
    assert.match(html, /aria-label="只刷新额度"/);
    assert.match(html, />刷新</);
  });
});

test("QuotaStrip renders the shared quota refresh cadence control", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, {
      onQuotaRefreshIntervalChange: () => {},
      quotaRefreshIntervalMs: 180_000,
      snapshot: quotaSnapshot,
      warnings: [],
    });

    assert.match(html, /额度刷新/);
    assert.match(html, /class="quota-refresh-row"/);
    assert.match(html, /aria-label="额度刷新频率"/);
    assert.match(html, /<option value="30000">30 秒<\/option>/);
    assert.match(html, /<option value="60000">1 分钟<\/option>/);
    assert.match(html, /<option value="180000" selected="">3 分钟<\/option>/);
    assert.match(html, /<option value="300000">5 分钟<\/option>/);
    assert.match(html, /<option value="600000">10 分钟<\/option>/);
  });
});

test("QuotaStrip keeps quota refresh cadence in a stable full-width tool row", async () => {
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");

  assert.match(css, /\.quota-refresh-row\s*{[^}]*grid-column:\s*1 \/ -1/s);
  assert.match(css, /\.quota-refresh-row\s*{[^}]*min-height:\s*24px/s);
  assert.match(css, /\.quota-refresh-cadence select\s*{[^}]*min-width:\s*92px/s);
  assert.match(css, /\.quota-refresh-cadence select\s*{[^}]*font-size:\s*10px/s);
});

test("QuotaStrip omits the retry button when no retry handler is provided", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, {
      snapshot: quotaSnapshot,
      warnings: quotaWarnings,
    });

    assert.match(html, /账户额度读取失败；重置卡读取失败/);
    assert.doesNotMatch(html, /aria-label="只刷新额度"/);
    assert.doesNotMatch(html, /class="quota-warning-refresh"/);
  });
});

test("QuotaStrip renders reset-credit count without fake nearest text when expiry is unknown or past", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, {
      snapshot: {
        ...quotaSnapshot,
        resetCredit: {
          availableCount: 0,
          status: "重置卡详情可用",
          credits: [
            resetCredit({ cardId: "unknown", expiresAtUnix: null }),
            resetCredit({ cardId: "past", expiresAtUnix: Math.floor((Date.now() - 60 * 60 * 1000) / 1000) }),
          ],
        },
      },
      warnings: [],
    });

    assert.match(html, />2 张重置卡</);
    assert.match(html, />2 张可用/);
    assert.doesNotMatch(html, /最近/);
    assert.doesNotMatch(html, /到期未知/);
    assert.doesNotMatch(html, /已到期/);
    assert.doesNotMatch(html, /卡--/);
  });
});

test("QuotaStrip renders reset-credit nearest text only for future-expiring details", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, {
      snapshot: {
        ...quotaSnapshot,
        resetCredit: {
          availableCount: 3,
          status: "3 张重置卡可用",
          credits: [
            resetCredit({ cardId: "unknown", expiresAtUnix: null }),
            resetCredit({ cardId: "future", expiresAtUnix: Math.floor((Date.now() + (4 * 60 + 20) * 60 * 1000) / 1000) }),
          ],
        },
      },
      warnings: [],
    });

    assert.match(html, />3 张重置卡</);
    assert.match(html, />3 张可用/);
    assert.match(html, /最近 剩 4h/);
    assert.doesNotMatch(html, /最近 到期未知/);
    assert.doesNotMatch(html, /最近 已到期/);
  });
});

test("DashboardSummarySection passes dashboard warnings through to QuotaStrip rendering", async () => {
  await withSsrModules(async (load) => {
    const { DashboardSummarySection } = await load("/src/pages/dashboard/DashboardSummarySection.tsx");
    const html = renderComponent(DashboardSummarySection, {
      dashboard: dashboardFixture(),
      displaySurfaces: {
        floatingWindowEnabled: true,
        liveRateEnabled: true,
        statusTrayLiveTextEnabled: false,
      },
      floatingSettings: floatingSettingsFixture(),
      liveRate: liveRateFixture(),
      liveThreadOptions: [],
      onFloatingOpacityChange: () => {},
      onFloatingScaleChange: () => {},
      onTokenRateFullScaleChange: () => {},
      onFloatingUnreadEffectChange: () => {},
      onFloatingGradientChange: () => {},
      onFloatingTextToneChange: () => {},
      onFloatingContentVisibilityChange: () => {},
      onLiveRateReset: async () => {},
      onLiveRateRetry: () => {},
      onLiveThreadSelect: () => {},
      onQuotaRefresh: () => {},
      onToggleLiveRate: () => {},
      onToggleFloating: () => {},
      onToggleStatusTray: () => {},
      platform: platformFixture(),
      radarRefreshGeneration: 0,
      liveRateEnabled: true,
      selectedLiveThreadId: "",
    });

    assert.match(html, /账户额度读取失败；重置卡读取失败/);
    assert.match(html, /aria-label="只刷新额度"/);
    assert.match(html, /全会话实时速度/);
  });
});

test("DashboardSummarySection renders usage precision warning as a wait note outside quota and live-rate retry UI", async () => {
  await withSsrModules(async (load) => {
    const { DashboardSummarySection } = await load("/src/pages/dashboard/DashboardSummarySection.tsx");
    const dashboard = dashboardFixture();
    dashboard.stats = {
      ...dashboard.stats,
      totalTokens: 0,
      peakDayTokens: 0,
      peakThreadTokens: 0,
      totalCalls: 0,
      totalThreads: 2,
    };
    dashboard.warnings = [
      {
        source: "usage_precision",
        message: "精确 token 仍在读取，当前仅显示会话元数据，请稍后刷新。",
      },
    ];
    const html = renderComponent(DashboardSummarySection, {
      dashboard,
      displaySurfaces: {
        floatingWindowEnabled: true,
        liveRateEnabled: true,
        statusTrayLiveTextEnabled: false,
      },
      floatingSettings: floatingSettingsFixture(),
      liveRate: liveRateFixture(),
      liveThreadOptions: [],
      onFloatingOpacityChange: () => {},
      onFloatingScaleChange: () => {},
      onTokenRateFullScaleChange: () => {},
      onFloatingUnreadEffectChange: () => {},
      onFloatingGradientChange: () => {},
      onFloatingTextToneChange: () => {},
      onFloatingContentVisibilityChange: () => {},
      onLiveRateReset: async () => {},
      onLiveRateRetry: () => {},
      onLiveThreadSelect: () => {},
      onQuotaRefresh: () => {},
      onToggleLiveRate: () => {},
      onToggleFloating: () => {},
      onToggleStatusTray: () => {},
      platform: platformFixture(),
      radarRefreshGeneration: 0,
      liveRateEnabled: true,
      selectedLiveThreadId: "",
    });

    assert.match(html, /Token 统计准备中/);
    assert.match(html, /当前仅显示会话元数据/);
    assert.match(html, /请稍后刷新/);
    assert.doesNotMatch(html, /读取失败原因/);
    assert.doesNotMatch(html, /aria-label="只刷新额度"/);
    assert.doesNotMatch(html, /实时速率准备中/);
    assert.doesNotMatch(html, />重试</);
  });
});

test("DashboardSummarySection passes structured quota diagnostics through to QuotaStrip rendering", async () => {
  await withSsrModules(async (load) => {
    const { DashboardSummarySection } = await load("/src/pages/dashboard/DashboardSummarySection.tsx");
    const dashboard = dashboardFixture();
    dashboard.warnings = [
      { source: "account_quota", message: "旧账户额度读取失败" },
      { source: "reset_credit", message: "旧重置卡读取失败" },
    ];
    dashboard.diagnostics = [
      quotaDiagnostic({
        source: "account_quota",
        category: "auth_missing",
        message: "登录凭证缺失",
        rawCause: "未找到 access token",
        retryable: false,
      }),
      quotaDiagnostic({
        source: "source_integrity",
        category: "source_mismatch",
        message: "Codex Home 与额度登录来源不一致",
        rawCause: "source mismatch",
        retryable: false,
      }),
      quotaDiagnostic({
        source: "reset_credit",
        category: "reset_credit_failure",
        message: "重置卡读取失败：网络连接失败",
        rawCause: "error sending request for url",
        underlyingCategory: "network_send_fetch",
        retryable: true,
      }),
    ];

    const html = renderComponent(DashboardSummarySection, {
      dashboard,
      displaySurfaces: {
        floatingWindowEnabled: true,
        liveRateEnabled: true,
        statusTrayLiveTextEnabled: false,
      },
      floatingSettings: floatingSettingsFixture(),
      liveRate: liveRateFixture(),
      liveThreadOptions: [],
      onFloatingOpacityChange: () => {},
      onFloatingScaleChange: () => {},
      onTokenRateFullScaleChange: () => {},
      onFloatingUnreadEffectChange: () => {},
      onFloatingGradientChange: () => {},
      onFloatingTextToneChange: () => {},
      onFloatingContentVisibilityChange: () => {},
      onLiveRateReset: async () => {},
      onLiveRateRetry: () => {},
      onLiveThreadSelect: () => {},
      onQuotaRefresh: () => {},
      onToggleLiveRate: () => {},
      onToggleFloating: () => {},
      onToggleStatusTray: () => {},
      platform: platformFixture(),
      radarRefreshGeneration: 0,
      liveRateEnabled: true,
      selectedLiveThreadId: "",
    });

    assert.match(html, /登录凭证缺失；Codex Home 与额度登录来源不一致；重置卡读取失败：网络连接失败/);
    assert.doesNotMatch(html, /旧账户额度读取失败/);
  });
});

test("DashboardSummarySection links refresh state to live-rate cache wait copy", async () => {
  await withSsrModules(async (load) => {
    const { DashboardSummarySection } = await load("/src/pages/dashboard/DashboardSummarySection.tsx");
    const html = renderComponent(DashboardSummarySection, {
      dashboard: dashboardFixture(),
      displaySurfaces: {
        floatingWindowEnabled: true,
        liveRateEnabled: true,
        statusTrayLiveTextEnabled: false,
      },
      floatingSettings: floatingSettingsFixture(),
      liveRate: liveRateFixture({
        warnings: [
          {
            source: "live_rate_summary",
            message: "精确 token 缓存尚未就绪，已忽略 state_5.sqlite 的重复线程口径",
          },
        ],
      }),
      liveThreadOptions: [],
      onFloatingOpacityChange: () => {},
      onFloatingScaleChange: () => {},
      onTokenRateFullScaleChange: () => {},
      onFloatingUnreadEffectChange: () => {},
      onFloatingGradientChange: () => {},
      onFloatingTextToneChange: () => {},
      onFloatingContentVisibilityChange: () => {},
      onLiveRateReset: async () => {},
      onLiveRateRetry: () => {},
      onLiveThreadSelect: () => {},
      onQuotaRefresh: () => {},
      onToggleLiveRate: () => {},
      onToggleFloating: () => {},
      onToggleStatusTray: () => {},
      platform: platformFixture(),
      radarRefreshGeneration: 0,
      refreshing: true,
      liveRateEnabled: true,
      selectedLiveThreadId: "",
      usageCacheInitializing: true,
    });

    assert.match(html, /用量统计重建中/);
    assert.match(html, /刷新仍在扫描本地会话文件，完成后会恢复总\/今\/次。/);
    assert.doesNotMatch(html, /实时速率降级/);
    assert.doesNotMatch(html, />重试</);
  });
});

function dashboardFixture() {
  return {
    generatedAt: "2026-07-05T00:00:00Z",
    account: {
      displayName: "Local",
      planLabel: "Pro",
    },
    stats: {
      totalTokens: 120000,
      peakDayTokens: 50000,
      peakThreadTokens: 25000,
      currentStreakDays: 4,
      longestStreakDays: 8,
      totalCalls: 30,
      totalThreads: 5,
    },
    quota: quotaSnapshot,
    activityDays: [],
    recentUsage24h: [],
    recentUsage7d: [],
    recentUsage30d: [],
    cacheHitRanking: [],
    cacheUsage: {
      sessions: [],
      turns: [],
    },
    warnings: quotaWarnings,
  };
}

function resetCredit(overrides = {}) {
  return {
    cardId: "card",
    title: "一次免费额度重置",
    status: "可用",
    summary: "",
    resetType: "codex_rate_limits",
    issuedAt: "2026-06-25 00:00",
    grantedAtUnix: Date.parse("2026-06-25T00:00:00Z") / 1000,
    expiresAt: "2026-06-28 03:00",
    expiresAtUnix: Date.parse("2026-06-28T03:00:00Z") / 1000,
    redeemStartedAt: "未提供",
    redeemedAt: "未使用",
    source: "invite",
    detailNote: "邀请获得",
    associatedUser: "user_1",
    profileImageUrl: "",
    shortId: "card",
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

function liveRateFixture(overrides = {}) {
  return {
    scopeLabel: "all",
    threadTitle: "全部会话",
    selectedThreadId: null,
    selectedThreadTitle: "",
    selectedTokensPerSecond: 0,
    tokensPerSecond: 12.3,
    totalTokens: 120000,
    totalTokensToday: 2000,
    requestsToday: 8,
    maxTokensPerSecond: 200,
    preciseEnabled: true,
    unreadSummary: {
      active: false,
      count: 0,
      label: "无未读",
      detail: "",
      source: "test",
    },
    warnings: [],
    ...overrides,
  };
}

function floatingSettingsFixture() {
  return {
    opacity: 0.92,
    scale: 1,
    tokenRateFullScale: 200,
    unreadEffect: "ripple",
    gradientStart: "#ffffff",
    gradientEnd: "#daefff",
    gradientDirection: "135deg",
    gradientType: "linear",
    textTone: -1,
    contentVisibility: {
      showRateAndBar: true,
      showUsageStatus: true,
      showMetrics: true,
      showQuota: true,
      showRadar: true,
      order: ["rateAndBar", "usageStatus", "metrics", "radar", "quota"],
    },
  };
}

function platformFixture() {
  const ready = {
    available: true,
    status: "ready",
    label: "ready",
    note: "ready",
  };
  return {
    platform: "darwin",
    shell: "zsh",
    floatingWindow: ready,
    floatingTransparency: ready,
    floatingDrag: ready,
    floatingLock: ready,
    statusTray: ready,
    statusTrayLiveText: {
      ...ready,
      available: false,
      status: "pending",
    },
    autostart: ready,
    notifications: ready,
  };
}

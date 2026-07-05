import assert from "node:assert/strict";
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

function liveRateFixture() {
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

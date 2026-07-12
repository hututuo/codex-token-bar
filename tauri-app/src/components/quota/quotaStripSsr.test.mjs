import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

const quotaSnapshot = {
  fiveHour: {
    label: "5h",
    availability: "measured",
    remainingPercent: 0.62,
    usedPercent: 0.38,
    resetsAt: "2h",
  },
  sevenDay: {
    label: "7d",
    availability: "measured",
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

const unavailableQuotaSnapshot = {
  ...quotaSnapshot,
  fiveHour: {
    label: "5h",
    availability: "unavailable",
    remainingPercent: null,
    usedPercent: null,
    resetsAt: "待读取",
    resetsAtUnix: null,
  },
  sevenDay: {
    label: "7d",
    availability: "unavailable",
    remainingPercent: null,
    usedPercent: null,
    resetsAt: "待读取",
    resetsAtUnix: null,
  },
  paceLabel: "额度读取失败",
};

test("QuotaStrip renders unavailable quota as pending instead of exhausted zero", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, {
      snapshot: unavailableQuotaSnapshot,
      diagnostics: [],
      warnings: [],
    });

    assert.match(html, /5h.*待读取/s);
    assert.match(html, /7d.*待读取/s);
    assert.doesNotMatch(html, /剩 0%/);
    assert.doesNotMatch(html, /width:0%/);
  });
});

test("QuotaStrip preserves a measured exhausted zero", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, {
      snapshot: {
        ...quotaSnapshot,
        fiveHour: {
          ...quotaSnapshot.fiveHour,
          availability: "measured",
          remainingPercent: 0,
          usedPercent: 1,
        },
      },
      diagnostics: [],
      warnings: [],
    });

    assert.match(html, /剩 0%/);
    assert.match(html, /已用 100%/);
  });
});

test("QuotaStrip preserves a measured full 100 percent", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, {
      snapshot: {
        ...quotaSnapshot,
        fiveHour: {
          ...quotaSnapshot.fiveHour,
          remainingPercent: 1,
          usedPercent: 0,
        },
      },
      diagnostics: [],
      warnings: [],
    });

    assert.match(html, /剩 100%/);
    assert.match(html, /已用 0%/);
    assert.match(html, /width:100%/);
  });
});

test("QuotaStrip renders each quota as a complete header above a full-width value track", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, { snapshot: quotaSnapshot, warnings: [] });

    assert.match(html, /class="quota-bar-header"><span class="quota-label">5h<\/span><em>2h<\/em><\/div>/);
    assert.match(html, /class="quota-track"[^>]*><i class="quota-track-fill" style="width:62%"><\/i><span class="quota-track-copy"><b>剩 62%<\/b><em>已用 38%<\/em><\/span>/);
    assert.match(html, /aria-label="5h 剩 62%，已用 38%，重置 2h"/);
    assert.match(html, /aria-label="7d 剩 81%，已用 19%，重置 3天"/);
  });
});

test("QuotaStrip derives used percent when the measured snapshot omits it", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const { usedPercent: _omitted, ...fiveHourWithoutUsed } = quotaSnapshot.fiveHour;
    const html = renderComponent(QuotaStrip, {
      snapshot: { ...quotaSnapshot, fiveHour: fiveHourWithoutUsed },
      warnings: [],
    });

    assert.match(html, /aria-label="5h 剩 62%，已用 38%，重置 2h"/);
    assert.match(html, /<b>剩 62%<\/b><em>已用 38%<\/em>/);
  });
});

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
    assert.match(html, /class="quota-side-card quota-pace quota-pace--with-cadence"[\s\S]*class="quota-refresh-cadence"/);
    assert.doesNotMatch(html, /class="quota-refresh-row"/);
    assert.match(html, /aria-label="刷新频率"/);
    assert.match(html, /<option value="30000">额度刷新 30 秒<\/option>/);
    assert.match(html, /<option value="60000">额度刷新 1 分钟<\/option>/);
    assert.match(html, /<option value="180000" selected="">额度刷新 3 分钟<\/option>/);
    assert.match(html, /<option value="300000">额度刷新 5 分钟<\/option>/);
    assert.match(html, /<option value="600000">额度刷新 10 分钟<\/option>/);
  });
});

test("QuotaStrip releases cadence space when no save handler is provided", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, { snapshot: quotaSnapshot, warnings: [] });

    assert.match(html, /class="quota-side-card quota-pace quota-pace--without-cadence"/);
    assert.doesNotMatch(html, /class="quota-refresh-cadence"|<select/);
  });
});

test("QuotaStrip keeps the longest production pace copy beside the longest cadence option", async () => {
  await withSsrModules(async (load) => {
    const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
    const html = renderComponent(QuotaStrip, {
      onQuotaRefreshIntervalChange: () => {},
      quotaRefreshIntervalMs: 600_000,
      snapshot: {
        ...quotaSnapshot,
        paceLabel: "用得太快，先省着（低 100%）",
      },
      warnings: [],
    });

    assert.match(html, />用得太快，先省着（低 100%）<\/strong>/);
    assert.match(html, />7d 均速比较<\/span>/);
    assert.match(html, /<option value="600000" selected="">额度刷新 10 分钟<\/option>/);
  });
});

test("QuotaStrip CSS source guard locks the single-row grid and long-track budget", async () => {
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");

  assert.match(css, /\.quota-strip\s*{[^}]*grid-template-columns:\s*74px minmax\(190px, 1\.35fr\) minmax\(190px, 1\.35fr\) minmax\(116px, 0\.72fr\) minmax\(320px, 1\.45fr\)/s);
  assert.match(css, /\.quota-strip\s*{[^}]*gap:\s*4px/s);
  assert.match(css, /\.quota-bar\s*{[^}]*grid-template-rows:\s*auto 1fr/s);
  assert.match(css, /\.quota-track\s*{[^}]*width:\s*100%/s);
  assert.match(css, /\.quota-pace--with-cadence\s*{[^}]*grid-template-columns:\s*minmax\(0, 1fr\) 132px/s);
  assert.match(css, /\.quota-pace--without-cadence\s*{[^}]*grid-template-columns:\s*minmax\(0, 1fr\)/s);
  assert.match(css, /\.quota-refresh-cadence select\s*{[^}]*width:\s*132px/s);
  assert.match(css, /\.quota-refresh-cadence select\s*{[^}]*height:\s*28px/s);
  assert.match(css, /\.quota-pace-title strong\s*{[^}]*white-space:\s*nowrap/s);
  assert.doesNotMatch(css, /\.quota-pace-title strong\s*{[^}]*(?:overflow|text-overflow):/s);
  assert.doesNotMatch(css, /\.quota-refresh-row\s*{/);
});

test("QuotaStrip CSS box-model budget fits the reachable 960px viewport", async () => {
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");
  const quotaGroup = css.slice(css.indexOf(".quota-strip,"), css.indexOf(".quota-strip {"));
  const quotaBlock = css.slice(css.indexOf(".quota-strip {"), css.indexOf(".quota-strip--details-open"));
  const media960Start = css.indexOf("@media (max-width: 960px)");
  const media960 = css.slice(media960Start, css.indexOf("@media (", media960Start + 1));
  const grid = quotaBlock.match(/grid-template-columns:\s*(\d+)px minmax\((\d+)px,[^)]+\) minmax\((\d+)px,[^)]+\) minmax\((\d+)px,[^)]+\) minmax\((\d+)px,[^)]+\)/);
  assert.ok(grid);

  const viewport = 960;
  const shellPadding = Number(media960.match(/\.app-shell\s*{[^}]*padding-inline:\s*(\d+)px/s)?.[1]);
  const dashboardGutter = Number(media960.match(/\.dashboard\s*{[^}]*100vw - (\d+)px/s)?.[1]);
  const quotaBorder = Number(quotaGroup.match(/border:\s*(\d+)px/)?.[1]);
  const quotaPadding = Number(quotaBlock.match(/padding:\s*\d+px\s+(\d+)px/)?.[1]);
  const gap = Number(quotaBlock.match(/gap:\s*(\d+)px/)?.[1]);
  const dashboardWidth = Math.min(980, viewport - shellPadding * 2, viewport - dashboardGutter);
  const quotaContentWidth = dashboardWidth - quotaBorder * 2 - quotaPadding * 2;
  const minimumGridWidth = grid.slice(1).map(Number).reduce((sum, value) => sum + value, 0) + gap * 4;

  assert.equal(dashboardWidth, 932);
  assert.equal(quotaContentWidth, 914);
  assert.equal(minimumGridWidth, 906);
  assert.ok(quotaContentWidth >= minimumGridWidth);
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

import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("LiveRateCard renders stream failure warning and retry affordance", async () => {
  await withSsrModules(async (load) => {
    const { LiveRateCard } = await load("/src/components/LiveRateCard.tsx");
    const html = renderComponent(LiveRateCard, cardProps({
      snapshot: liveRateSnapshot({
        warnings: [
          {
            source: "live_rate_stream",
            message: "实时速率流启动失败：Command timed out after 2000ms。可点击重试重新连接。",
          },
        ],
      }),
    }));

    assert.match(html, /role="status"/);
    assert.match(html, /实时速率降级/);
    assert.match(html, /Command timed out after 2000ms/);
    assert.match(html, />重试</);
  });
});

test("LiveRateCard treats precise summary cache warnings as a wait state during refresh", async () => {
  await withSsrModules(async (load) => {
    const { LiveRateCard } = await load("/src/components/LiveRateCard.tsx");
    const html = renderComponent(LiveRateCard, cardProps({
      refreshing: true,
      usageCacheInitializing: true,
      snapshot: liveRateSnapshot({
        warnings: [
          {
            source: "live_rate_summary",
            message: "精确 token 缓存尚未就绪，已忽略 state_5.sqlite 的重复线程口径",
          },
        ],
      }),
    }));

    assert.match(html, /role="status"/);
    assert.match(html, /实时速率准备中/);
    assert.match(html, /刷新仍在扫描精确 token 缓存，请稍后/);
    assert.match(html, /class="live-rate-warning is-pending"/);
    assert.match(html, /class="live-reset-button" disabled=""/);
    assert.match(html, /title="刷新仍在扫描精确 token 缓存，请稍后。"/);
    assert.doesNotMatch(html, /实时速率降级/);
    assert.doesNotMatch(html, />重试</);
  });
});

test("LiveRateCard does not show stream failure warning when live rate is disabled", async () => {
  await withSsrModules(async (load) => {
    const { LiveRateCard } = await load("/src/components/LiveRateCard.tsx");
    const html = renderComponent(LiveRateCard, cardProps({
      liveRateEnabled: false,
      snapshot: liveRateSnapshot({
        warnings: [
          {
            source: "live_rate_stream",
            message: "实时速率流启动失败",
          },
        ],
      }),
    }));

    assert.match(html, /live-card is-live-disabled/);
    assert.match(html, /live-left is-live-disabled/);
    assert.match(html, /live-heading-line/);
    assert.match(html, /aria-pressed="false"/);
    assert.match(html, />实时速率 关</);
    assert.match(html, /实时速率已关闭/);
    assert.match(html, /官方为减少磁盘写入关闭了部分流式日志/);
    assert.match(html, /class="live-reset-button" disabled=""/);
    assert.match(html, /aria-label="重置整体速率"/);
    assert.doesNotMatch(html, /实时速率降级/);
    assert.doesNotMatch(html, />重试</);
    assert.doesNotMatch(html, /LiveRateSessionRow/);
  });
});

function cardProps(overrides = {}) {
  return {
    floatingEnabled: true,
    floatingSettings: floatingSettingsFixture(),
    liveRateEnabled: true,
    onFloatingOpacityChange: () => {},
    onFloatingScaleChange: () => {},
    onTokenRateFullScaleChange: () => {},
    onFloatingUnreadEffectChange: () => {},
    onFloatingGradientChange: () => {},
    onFloatingTextToneChange: () => {},
    onFloatingContentVisibilityChange: () => {},
    onLiveRateReset: async () => {},
    onLiveRateRetry: () => {},
    onToggleLiveRate: () => {},
    onToggleFloating: () => {},
    onToggleStatusTray: () => {},
    platform: platformFixture(),
    snapshot: liveRateSnapshot(),
    statusTrayLiveTextEnabled: true,
    refreshing: false,
    usageCacheInitializing: false,
    ...overrides,
  };
}

function liveRateSnapshot(overrides = {}) {
  return {
    scopeLabel: "全会话",
    threadTitle: "全部会话",
    selectedThreadId: null,
    selectedThreadTitle: "选择会话查看单会话速率",
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
    statusTrayLiveText: ready,
    autostart: ready,
    notifications: ready,
  };
}

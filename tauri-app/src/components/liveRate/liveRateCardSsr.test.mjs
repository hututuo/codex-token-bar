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
    assert.match(html, /class="live-title-status is-pending" role="status"/);
    assert.match(html, /用量统计重建中/);
    assert.match(html, /刷新仍在扫描本地会话文件，完成后会恢复总\/今\/次/);
    assert.doesNotMatch(html, /class="live-rate-warning is-pending"/);
    assert.doesNotMatch(html, /class="live-rate-warning"/);
    assert.match(html, /class="live-reset-button" disabled=""/);
    assert.match(html, /title="刷新仍在扫描本地会话文件，完成后会恢复总\/今\/次。"/);
    assert.doesNotMatch(html, /实时速率降级/);
    assert.doesNotMatch(html, />重试</);
  });
});

test("LiveRateCard does not infer a rebuild notice from an ordinary refresh", async () => {
  await withSsrModules(async (load) => {
    const { LiveRateCard } = await load("/src/components/LiveRateCard.tsx");
    const html = renderComponent(LiveRateCard, cardProps({
      refreshing: true,
      snapshot: liveRateSnapshot({ warnings: [] }),
    }));

    assert.doesNotMatch(html, /用量统计重建中/);
    assert.doesNotMatch(html, /精确 token 缓存/);
    assert.doesNotMatch(html, /class="live-rate-warning/);
  });
});

test("LiveRateCard ignores dashboard usage precision warnings when they leak into live snapshot", async () => {
  await withSsrModules(async (load) => {
    const { LiveRateCard } = await load("/src/components/LiveRateCard.tsx");
    const html = renderComponent(LiveRateCard, cardProps({
      snapshot: liveRateSnapshot({
        warnings: [
          {
            source: "usage_precision",
            message: "精确 token 缓存尚未就绪，当前仅显示会话元数据，请稍后刷新。",
          },
        ],
      }),
    }));

    assert.doesNotMatch(html, /实时速率准备中/);
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
    assert.doesNotMatch(html, /class="session-picker"/);
    assert.doesNotMatch(html, /<select/);
  });
});

test("LiveRateCard keeps the unread acknowledgement action visible when unread is idle", async () => {
  await withSsrModules(async (load) => {
    const { LiveRateCard } = await load("/src/components/LiveRateCard.tsx");
    const html = renderComponent(LiveRateCard, cardProps());

    assert.match(html, /一键已读/);
    assert.match(html, /unread-ack-button unread-ack-button--idle/);
    assert.match(html, /当前没有未读会话/);
    assert.doesNotMatch(html, /标记已读/);
  });
});

test("LiveRateCard exposes active unread acknowledgement with blue tone when unread is active", async () => {
  await withSsrModules(async (load) => {
    const { LiveRateCard } = await load("/src/components/LiveRateCard.tsx");
    const html = renderComponent(LiveRateCard, cardProps({
      snapshot: liveRateSnapshot({
        unreadSummary: {
          active: true,
          count: 2,
          label: "有未读完成会话",
          detail: "2 个会话等待查看",
          source: "codex_unread_state",
        },
      }),
    }));

    assert.match(html, /一键已读/);
    assert.match(html, /unread-ack-button unread-ack-button--active/);
    assert.match(html, /拉基线/);
    assert.doesNotMatch(html, /标记已读/);
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
    onAcknowledgeUnread: async () => {},
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
      showRunningThreads: true,
      showQuota: true,
      showRadar: true,
      order: ["rateAndBar", "usageStatus", "metrics", "runningThreads", "radar", "quota"],
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

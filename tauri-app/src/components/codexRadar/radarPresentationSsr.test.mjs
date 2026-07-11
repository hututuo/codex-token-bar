import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { withSsrModules } from "../../test/ssrHarness.mjs";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("Codex Radar diagnostics notice renders root failure without fake radar values", async () => {
  await withSsrModules(async (load) => {
    const { CodexRadarDiagnosticsNotice } = await load("/src/components/CodexRadarStrip.tsx");
    const html = renderComponent(CodexRadarDiagnosticsNotice, {
      snapshot: null,
      diagnostics: [{
        category: "http_server",
        source: "root",
        message: "Codex 雷达读取失败：Codex Radar HTTP 503",
        rawCause: "Codex Radar HTTP 503",
        retryable: true,
      }],
    });

    assert.match(html, /role="status"/);
    assert.match(html, /雷达读取失败/);
    assert.match(html, /Codex Radar HTTP 503/);
    assert.doesNotMatch(html, /IQ --/);
    assert.doesNotMatch(html, /动作 --/);
  });
});

test("Codex Radar diagnostics notice marks stale root and feed states", async () => {
  await withSsrModules(async (load) => {
    const { CodexRadarDiagnosticsNotice } = await load("/src/components/CodexRadarStrip.tsx");
    const { normalizeCodexRadarSnapshot } = await load("/src/domain/codexRadar/model.ts");

    const staleRoot = {
      ...normalizeCodexRadarSnapshot(snapshotFixture()),
      diagnostics: [{
        category: "stale_cached_data",
        source: "cache",
        message: "Codex 雷达暂时无法刷新，正在显示上次成功数据。",
        rawCause: "Codex Radar HTTP 502",
        retryable: true,
      }],
      staleDataDisplayed: true,
    };
    const staleFeed = {
      ...normalizeCodexRadarSnapshot(snapshotFixture()),
      diagnostics: [{
        category: "rss_failure",
        source: "feed",
        message: "Codex 雷达 RSS 读取失败：Codex Radar RSS HTTP 500",
        rawCause: "Codex Radar RSS HTTP 500",
        retryable: true,
      }],
      feedStaleDataDisplayed: true,
    };

    assert.match(renderComponent(CodexRadarDiagnosticsNotice, { snapshot: staleRoot }), /雷达旧数据/);
    assert.match(renderComponent(CodexRadarDiagnosticsNotice, { snapshot: staleRoot }), /显示上次成功数据/);
    assert.match(renderComponent(CodexRadarDiagnosticsNotice, { snapshot: staleFeed }), /RSS 旧数据/);
    assert.match(renderComponent(CodexRadarDiagnosticsNotice, { snapshot: staleFeed }), /RSS 提醒暂用上次成功数据/);
  });
});

test("floating Radar row preserves stale snapshot and shows a restrained marker", async () => {
  await withSsrModules(async (load) => {
    const { FloatingPanelSurface } = await load("/src/floating/FloatingPanelPreview.tsx");
    const { normalizeCodexRadarSnapshot } = await load("/src/domain/codexRadar/model.ts");
    const radarSnapshot = {
      ...normalizeCodexRadarSnapshot(snapshotFixture()),
      diagnostics: [{
        category: "stale_cached_data",
        source: "cache",
        message: "Codex 雷达暂时无法刷新，正在显示上次成功数据。",
        rawCause: "Codex Radar HTTP 502",
        retryable: true,
      }],
      staleDataDisplayed: true,
    };

    const html = renderComponent(FloatingPanelSurface, {
      settings: floatingSettingsFixture(),
      snapshot: floatingSnapshotFixture(),
      radarSnapshot,
    });

    assert.match(html, /雷达旧数据 · 动作 wait/);
    assert.match(html, /IQ 100/);
    assert.doesNotMatch(html, /Radar 待读取/);
  });
});

test("Codex Radar detail overlay prefers full detail snapshot and falls back to public summary", async () => {
  await withSsrModules(async (load) => {
    const { CodexRadarDetailOverlay } = await load("/src/components/CodexRadarStrip.tsx");
    const { normalizeCodexRadarSnapshot, primaryModelRow, secondaryModelRows } = await load("/src/domain/codexRadar/model.ts");
    const publicSnapshot = normalizeCodexRadarSnapshot(snapshotFixture({
      recommended_action: "wait",
      model_iq: { ...snapshotFixture().model_iq, latest: { ...snapshotFixture().model_iq.latest, score: 100 } },
    }));
    const detailSnapshot = normalizeCodexRadarSnapshot(snapshotFixture({
      recommended_action: "run",
      model_iq: { ...snapshotFixture().model_iq, latest: { ...snapshotFixture().model_iq.latest, score: 125 } },
    }));
    const publicModels = [primaryModelRow(publicSnapshot.modelIq), ...secondaryModelRows(publicSnapshot.modelIq)];

    const fallbackHtml = renderComponent(CodexRadarDetailOverlay, {
      allModels: publicModels,
      detailSnapshot: null,
      detailStatus: "详细信息待读取",
      diagnostics: [],
      isDetailRefreshing: false,
      isRefreshing: false,
      onClose: () => {},
      onRefresh: () => {},
      primary: primaryModelRow(publicSnapshot.modelIq),
      probability24h: publicSnapshot.prediction.probability24H,
      probability48h: publicSnapshot.prediction.probability48H,
      quotaRows: publicSnapshot.modelIq.quotaRadar?.rows ?? [],
      snapshot: publicSnapshot,
      status: "公开摘要已更新",
    });
    const detailHtml = renderComponent(CodexRadarDetailOverlay, {
      allModels: publicModels,
      detailSnapshot,
      detailStatus: "详细信息已更新",
      diagnostics: [],
      isDetailRefreshing: false,
      isRefreshing: false,
      onClose: () => {},
      onRefresh: () => {},
      primary: primaryModelRow(publicSnapshot.modelIq),
      probability24h: publicSnapshot.prediction.probability24H,
      probability48h: publicSnapshot.prediction.probability48H,
      quotaRows: publicSnapshot.modelIq.quotaRadar?.rows ?? [],
      snapshot: publicSnapshot,
      status: "公开摘要已更新",
    });

    assert.match(fallbackHtml, /<td>100<\/td>/);
    assert.match(detailHtml, /详细信息已更新/);
    assert.match(detailHtml, /<td>125<\/td>/);
    assert.doesNotMatch(detailHtml, /详细信息待读取/);
  });
});


function snapshotFixture(overrides = {}) {
  return {
    schema_version: "1",
    service: "codex-radar",
    monitored_at: "2026-07-06T02:00:00+08:00",
    timezone: "Asia/Shanghai",
    window_open: false,
    status: "normal",
    recommended_action: "wait",
    window: {
      open: false,
      status: "closed",
      action: "wait",
      message: "当前没有开启的速蹬窗口",
      title: "无窗口",
      scope: "Codex 用户",
    },
    prediction: {
      level: "low",
      probability_24h: 0.12,
      probability_48h: 0.24,
      expected_window: "未来 24-48 小时",
      summary: "保持观察",
      positive_signals: [],
      negative_signals: [],
      updated_at: "2026-07-06T02:00:00+08:00",
    },
    links: {
      html: "https://codexradar.com",
      rss: "https://codexradar.com/feed.xml",
    },
    model_iq: {
      latest: {
        date: "2026-07-06-pm",
        score: 100,
        status: "green",
        passed: 4,
        tasks: 5,
        invalid: 0,
        valid_tasks: 5,
        total_tokens: 10000,
        input_tokens: 6000,
        cached_input_tokens: 2000,
        output_tokens: 4000,
        wall_seconds: 120,
        wall_time_human: "2m",
        model: "gpt-5.5",
        reasoning_effort: "high",
        cost_usd: 1,
      },
      recent_days: [],
      comparisons: {},
    },
    codex_environment: {
      schema_version: "1",
      type: "radar",
      updated_at: "2026-07-06T02:00:00+08:00",
      complaint_pressure: "low",
      official_news: [],
      status_incidents: [],
      complaint_examples: [],
      role_counts: {},
    },
    ...overrides,
  };
}

function floatingSnapshotFixture() {
  return {
    unreadSummary: {
      active: false,
      count: 0,
      label: "无未读",
      detail: "",
      source: "test",
    },
  };
}

function floatingSettingsFixture() {
  return {
    opacity: 0.92,
    scale: 1,
    tokenRateFullScale: 200,
    unreadEffect: "off",
    gradientStart: "#ffffff",
    gradientEnd: "#daefff",
    gradientDirection: "135deg",
    gradientType: "linear",
    textTone: -1,
    contentVisibility: {
      showRateAndBar: false,
      showUsageStatus: false,
      showMetrics: false,
      showQuota: false,
      showRadar: true,
      order: ["radar"],
    },
  };
}

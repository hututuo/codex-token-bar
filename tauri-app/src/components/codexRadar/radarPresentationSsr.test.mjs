import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
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

    assert.match(html, /雷达旧数据 · 动作 等待/);
    assert.match(html, /IQ 100/);
    assert.match(html, /--radar-action-color:rgb\(204 139 38\)/);
    assert.match(html, /--radar-score-color:rgb\(100 150 72\)/);
    assert.match(html, /class="floating-radar-dot"/);
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

test("Codex Radar detail hides the paused five-hour quota without dropping seven-day data", async () => {
  await withSsrModules(async (load) => {
    const { CodexRadarDetailOverlay } = await load("/src/components/CodexRadarStrip.tsx");
    const { normalizeCodexRadarSnapshot, primaryModelRow } = await load("/src/domain/codexRadar/model.ts");
    const raw = snapshotFixture();
    raw.model_iq.quota_radar = {
      date: "2026-07-19",
      source: "super-account-app-server-measurement",
      updated_at: "2026-07-19T04:35:09+00:00",
      basis_date: "2026-07-19",
      cost_usd: 369.517156,
      basis_window: "secondary_7d",
      basis_window_label: "7d",
      raw_delta: 19,
      five_hour_policy: "temporarily_paused_hidden",
      seven_day_policy: "direct_quota_api",
      rows: [
        { tier: "20x Pro", basis: "distributed radar", five_h: 200, seven_d: 1944.83 },
        { tier: "Plus", basis: "estimated", five_h: 10, seven_d: 97.24 },
      ],
      trend: [{
        date: "2026-07-19",
        source: "super-account-app-server-measurement",
        updated_at: "2026-07-19T04:35:09+00:00",
        five_h_20x: 200,
        seven_d_20x: 1944.83,
        five_h_5x: 50,
        five_h_plus: 10,
        basis_window: "secondary_7d",
        basis_window_label: "7d",
        cost_usd: 369.517156,
      }],
    };
    const snapshot = normalizeCodexRadarSnapshot(raw);
    const html = renderComponent(CodexRadarDetailOverlay, {
      allModels: [primaryModelRow(snapshot.modelIq)],
      detailSnapshot: snapshot,
      detailStatus: "详细信息已更新",
      diagnostics: [],
      isDetailRefreshing: false,
      isRefreshing: false,
      onClose: () => {},
      onRefresh: () => {},
      primary: primaryModelRow(snapshot.modelIq),
      probability24h: snapshot.prediction.probability24H,
      probability48h: snapshot.prediction.probability48H,
      quotaRows: snapshot.modelIq.quotaRadar.rows,
      snapshot,
      status: "公开摘要已更新",
    });

    assert.match(html, /7 天 额度趋势/);
    assert.match(html, /role="tab"[^>]*>7d<\/button>/);
    assert.doesNotMatch(html, /role="tab"[^>]*>5h<\/button>/);
    assert.match(html, /<th>套餐<\/th><th>7d<\/th><th>依据<\/th>/);
    assert.doesNotMatch(html, /<th>5h<\/th>/);
    assert.match(html, /\$1,?944\.83/);
  });
});

test("Codex Radar chart toggles expose enabled series with aria-pressed", async () => {
  await withSsrModules(async (load) => {
    const { CodexRadarDetailOverlay } = await load("/src/components/CodexRadarStrip.tsx");
    const { normalizeCodexRadarSnapshot, primaryModelRow, secondaryModelRows } = await load("/src/domain/codexRadar/model.ts");
    const raw = snapshotFixture();
    raw.model_iq.comparisons = {
      medium: comparisonFixture(raw.model_iq.latest, "GPT-5.5 medium", "medium"),
      xhigh: comparisonFixture(raw.model_iq.latest, "GPT-5.4 xhigh", "xhigh", "gpt-5.4"),
    };
    const snapshot = normalizeCodexRadarSnapshot(raw);
    const allModels = [primaryModelRow(snapshot.modelIq), ...secondaryModelRows(snapshot.modelIq)];
    const html = renderComponent(CodexRadarDetailOverlay, {
      allModels,
      detailSnapshot: snapshot,
      detailStatus: "详细信息已更新",
      diagnostics: [],
      isDetailRefreshing: false,
      isRefreshing: false,
      onClose: () => {},
      onRefresh: () => {},
      primary: primaryModelRow(snapshot.modelIq),
      probability24h: snapshot.prediction.probability24H,
      probability48h: snapshot.prediction.probability48H,
      quotaRows: [],
      snapshot,
      status: "公开摘要已更新",
    });
    const toggles = [...html.matchAll(/<button(?<attrs>[^>]*codex-radar-chart-toggle[^>]*)>/g)];

    assert.equal(toggles.length, 3);
    assert.match(toggles[0].groups.attrs, /aria-pressed="true"/);
    assert.match(toggles[1].groups.attrs, /aria-pressed="true"/);
    assert.match(toggles[2].groups.attrs, /aria-pressed="false"/);
  });
});

test("Codex Radar summary carries accent color through labels and right-side values", async () => {
  const component = await readFile(new URL("../CodexRadarStrip.tsx", import.meta.url), "utf8");
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");

  assert.match(component, /accentColor=\{semanticMetricColor\(86\)\} icon="\$" title="预估额度"/);
  for (const title of ["速蹬窗口", "官方雷达", "众测雷达", "预估额度"]) {
    assert.match(component, new RegExp(`title="${title}"`));
  }
  const summaryTitles = ["速蹬窗口", "官方雷达", "众测雷达", "预估额度"].map((title) => component.indexOf(`title="${title}"`));
  assert.ok(summaryTitles.every((offset) => offset >= 0));
  assert.deepEqual(summaryTitles, [...summaryTitles].sort((left, right) => left - right));
  assert.doesNotMatch(component, /title="环境压力"/);
  assert.match(component, /title="环境压力与资讯"/);
  assert.match(component, /--radar-score-color/);
  assert.match(component, /rankedCodexCrowdRadarModels\(crowdRadar, 3\)/);
  assert.match(css, /grid-template-columns:\s*0\.82fr 1\.08fr 1\.08fr 1\.02fr/);
  assert.match(css, /\.radar-block-title\s*\{[^}]*color:\s*var\(--radar-accent, var\(--muted\)\)/s);
  assert.match(css, /\.radar-score-row span\s*\{[^}]*color:\s*var\(--radar-score-color, var\(--muted\)\)/s);
  assert.match(css, /\.radar-quota-row span\s*\{[^}]*color:\s*var\(--radar-accent, var\(--muted\)\)/s);
});

function comparisonFixture(latest, label, reasoningEffort, model = "gpt-5.5") {
  return {
    label,
    model,
    reasoning_effort: reasoningEffort,
    latest: { ...latest, model, reasoning_effort: reasoningEffort },
    recent_days: [],
  };
}


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

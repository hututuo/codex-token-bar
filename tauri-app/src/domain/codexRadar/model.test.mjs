import assert from "node:assert/strict";
import test from "node:test";
import { codexRadarSnapshotHasContent, compactRadarModelName, modelIqChartSeries, normalizeCodexRadarSnapshot, parseCodexRadarFeedXml, primaryModelMeasurementRow, primaryModelRow, quotaChartSeries, quotaRadarAvailableWindows, radarActionDisplayText, secondaryModelRows, selectCodexRadarDetailSnapshot, shortDateLabel } from "./model.ts";

const snapshot = {
  modelIq: {
    latest: {
      date: "2026-06-23-pm",
      score: 100,
      status: "yellow",
      passed: 3,
      tasks: 5,
      invalid: 0,
      totalTokens: 120000,
      inputTokens: 80000,
      cachedInputTokens: 60000,
      outputTokens: 40000,
      wallSeconds: 120,
      wallTimeHuman: "2m",
      model: "gpt-5.5",
      reasoningEffort: "high",
      validTasks: 5,
      costUsd: 4,
    },
    recentDays: [],
    comparisons: {
      medium: {
        label: "GPT-5.5 medium",
        model: "gpt-5.5",
        reasoningEffort: "medium",
        latest: {
          date: "2026-06-23-pm",
          score: 104,
          status: "green",
          passed: 4,
          tasks: 5,
          invalid: 0,
          totalTokens: 110000,
          inputTokens: 75000,
          cachedInputTokens: 58000,
          outputTokens: 35000,
          wallSeconds: 102,
          wallTimeHuman: "1m 42s",
          model: "gpt-5.5",
          reasoningEffort: "medium",
          validTasks: 5,
          costUsd: 2.8,
        },
        recentDays: [],
      },
      xhigh: {
        label: "GPT-5.4 xhigh",
        model: "gpt-5.4",
        reasoningEffort: "xhigh",
        latest: {
          date: "2026-06-23-pm",
          score: 104,
          status: "green",
          passed: 4,
          tasks: 5,
          invalid: 0,
          totalTokens: 210000,
          inputTokens: 120000,
          cachedInputTokens: 80000,
          outputTokens: 90000,
          wallSeconds: 260,
          wallTimeHuman: "4m 20s",
          model: "gpt-5.4",
          reasoningEffort: "xhigh",
          validTasks: 5,
          costUsd: 8,
        },
        recentDays: [],
      },
    },
  },
};

test("compact Radar presentation localizes actions and keeps model reasoning effort", () => {
  assert.equal(radarActionDisplayText("wait"), "等待");
  assert.equal(radarActionDisplayText("run"), "运行");
  for (const rawAction of ["Use Windows", "use_window", "use-window", "use windows", "use_remaining_tokens"]) {
    assert.equal(radarActionDisplayText(rawAction), "速登窗口");
  }
  assert.equal(compactRadarModelName("GPT-5.6 Sol max"), "Sol max");
  assert.equal(compactRadarModelName("GPT-5.6 Luna max"), "Luna max");
  assert.equal(compactRadarModelName("GPT-5.6 Terra max"), "Terra max");
  assert.equal(compactRadarModelName("GPT-5.6 Terra ultra"), "Terra ultra");
  assert.equal(compactRadarModelName("GPT-5.6 Sol xhigh"), "Sol xhigh");
  assert.equal(compactRadarModelName("DeepSeek V4 Flash max"), "DS F max");
  assert.equal(compactRadarModelName("DeepSeek V4 Flash high"), "DS F high");
  assert.equal(compactRadarModelName("DeepSeek V4 Pro max"), "DS P max");
  assert.equal(compactRadarModelName("DeepSeek R1"), "DS R1");
  assert.equal(compactRadarModelName("DSH F max"), "DSH F max");
  assert.equal(compactRadarModelName("DSH-V4-Pro high"), "DSH P high");
  assert.equal(compactRadarModelName("DSH R1 medium"), "DSH R1 medium");
});

test("current Sol max score outranks older Terra and keeps its effort in the compact label", () => {
  const current = {
    latest: {
      ...snapshot.modelIq.latest,
      score: 150,
      model: "gpt-5.6-sol",
      reasoningEffort: "max",
      costUsd: 35,
    },
    recentDays: [],
    comparisons: {
      terra: {
        label: "GPT-5.6 Terra max",
        model: "gpt-5.6-terra",
        reasoningEffort: "max",
        latest: {
          ...snapshot.modelIq.latest,
          score: 135,
          model: "gpt-5.6-terra",
          reasoningEffort: "max",
          costUsd: 30,
        },
        recentDays: [],
      },
    },
  };

  const primary = primaryModelRow(current);
  assert.equal(primary.point.score, 150);
  assert.equal(primary.point.model, "gpt-5.6-sol");
  assert.equal(compactRadarModelName(primary.label), "Sol max");
});

test("primaryModelRow chooses the strongest score and cheaper equal-score model", () => {
  const primary = primaryModelRow(snapshot.modelIq);

  assert.equal(primary.label, "GPT-5.5 medium");
  assert.equal(primary.point.score, 104);
});

test("secondaryModelRows excludes the selected primary model", () => {
  const secondary = secondaryModelRows(snapshot.modelIq);

  assert.deepEqual(secondary.map((row) => row.label), ["GPT-5.4 xhigh", "GPT-5.5 high"]);
});

test("shortDateLabel compacts Codex Radar date labels", () => {
  assert.equal(shortDateLabel("2026-06-23-pm"), "6.23 pm");
});

test("modelIqChartSeries mirrors the Swift detail chart series", () => {
  const series = modelIqChartSeries({
    ...snapshot.modelIq,
    recentDays: [
      { ...snapshot.modelIq.latest, date: "2026-06-22-pm", score: 98 },
      { ...snapshot.modelIq.latest, date: "2026-06-23-pm", score: 100 },
    ],
  });

  assert.equal(series[0].id, "gpt-5.5-high");
  assert.equal(series[0].label, "GPT-5.5 high");
  assert.deepEqual(series[0].points.map((point) => point.xLabel), ["6.22 pm", "6.23 pm"]);
  assert.deepEqual(series.slice(1).map((item) => item.label), ["GPT-5.5 medium", "GPT-5.4 xhigh"]);
});

test("quotaChartSeries computes 5h and 7d windows with Swift-compatible tier math", () => {
  const quotaRadar = {
    date: "2026-06-23",
    source: "test",
    updatedAt: "2026-06-23",
    basisDate: "2026-06-23",
    costUsd: 4,
    totalTokens: 120000,
    basisWindow: "5h",
    basisWindowLabel: "5h",
    adjustedDelta: 0,
    rawDelta: 0,
    offset: 0,
    rate: 1,
    rows: [],
    trend: [{
      date: "2026-06-23-pm",
      source: "test",
      updatedAt: "2026-06-23",
      fiveHour20x: 200,
      sevenDay20x: 1400,
      fiveHour5x: 50,
      fiveHourPlus: 10,
      basisWindow: "5h",
      basisWindowLabel: "5h",
      rate: 1,
      rawDelta: 0,
      adjustedDelta: 0,
      offset: 0,
      costUsd: 4,
      totalTokens: 120000,
    }],
  };

  assert.deepEqual(quotaChartSeries(quotaRadar, "fiveHour").map((item) => item.points[0].value), [10, 50, 200]);
  assert.deepEqual(quotaChartSeries(quotaRadar, "sevenDay").map((item) => item.points[0].value), [70, 350, 1400]);
});

test("normalizeCodexRadarSnapshot accepts the public snake_case feed", () => {
  const normalized = normalizeCodexRadarSnapshot({
    monitored_at: "2026-06-24T14:55:20+08:00",
    status: "none",
    recommended_action: "wait",
    window: {
      message: "当前没有开启的速蹬窗口",
      scope: "Codex 用户",
      source_url: "https://example.com/source",
    },
    prediction: {
      probability_24h: 0.18,
      probability_48h: 0.34,
      expected_window: "未来 24-48 小时",
      summary: "中低判断",
    },
    links: {
      html: "https://codexradar.com",
      rss: "https://codexradar.com/feed.xml",
    },
    model_iq: {
      latest: {
        date: "2026-06-24-pm",
        score: 125,
        status: "green",
        passed: 10,
        tasks: 12,
        invalid: 2,
        valid_tasks: 10,
        total_tokens: 39090118,
        input_tokens: 28000118,
        cached_input_tokens: 21000118,
        output_tokens: 11090000,
        wall_seconds: 1510,
        wall_time_human: "25分钟",
        model: "gpt-5.5",
        reasoning_effort: "xhigh",
        cost_usd: 40.38,
      },
      recent_days: [],
      comparisons: {},
      quota_radar: {
        rows: [
          {
            tier: "20x Pro",
            basis: "measured",
            five_h: 284.57,
            seven_d: 1707.42,
          },
        ],
      },
    },
    codex_environment: {
      status_incidents_24h: 1,
      official_updates_24h: 2,
      community_mentions_24h: 3,
      issue_or_limit_anomalies_24h: 4,
      complaint_pressure: "medium",
    },
  });

  assert.equal(primaryModelRow(normalized.modelIq).point.reasoningEffort, "xhigh");
  assert.equal(primaryModelRow(normalized.modelIq).point.validTasks, 10);
  assert.equal(primaryModelRow(normalized.modelIq).point.invalid, 2);
  assert.equal(primaryModelRow(normalized.modelIq).point.inputTokens, 28000118);
  assert.equal(primaryModelRow(normalized.modelIq).point.cachedInputTokens, 21000118);
  assert.equal(primaryModelRow(normalized.modelIq).point.outputTokens, 11090000);
  assert.equal(primaryModelRow(normalized.modelIq).point.wallSeconds, 1510);
  assert.equal(normalized.modelIq.quotaRadar.rows[0].fiveH, 284.57);
  assert.equal(normalized.prediction.probability24H, 0.18);
  assert.equal(normalized.codexEnvironment.issueOrLimitAnomalies24H, 4);
  assert.deepEqual(normalized.feedItems, []);
});

test("normalizeCodexRadarSnapshot keeps the current seven-day-only quota schema nullable", () => {
  const raw = radarSnapshotFixture();
  raw.model_iq.quota_radar = {
    date: "2026-07-19",
    source: "super-account-app-server-measurement",
    updated_at: "2026-07-19T04:35:09+00:00",
    basis_date: "2026-07-19",
    cost_usd: 369.517156,
    basis_window: "secondary_7d",
    basis_window_label: "7d",
    raw_delta: 19,
    endpoint: "https://api.codexradar.com/api/v1/quota",
    source_kind: "quota_api",
    tasks: 78,
    five_hour_policy: "temporarily_paused_hidden",
    seven_day_policy: "direct_quota_api",
    rows: [
      { tier: "20x Pro", basis: "distributed radar", five_h: null, seven_d: 1944.83 },
      { tier: "5x Pro", basis: "estimated", five_h: null, seven_d: 486.21 },
      { tier: "Plus", basis: "estimated", five_h: null, seven_d: 97.24 },
    ],
    trend: [{
      date: "2026-07-19",
      source: "super-account-app-server-measurement",
      updated_at: "2026-07-19T04:35:09+00:00",
      five_h_20x: null,
      seven_d_20x: 1944.83,
      five_h_5x: null,
      five_h_plus: null,
      basis_window: "secondary_7d",
      basis_window_label: "7d",
      cost_usd: 369.517156,
    }],
  };

  const normalized = normalizeCodexRadarSnapshot(raw);
  const quotaRadar = normalized.modelIq.quotaRadar;

  assert.ok(quotaRadar);
  assert.equal(quotaRadar.totalTokens, null);
  assert.equal(quotaRadar.adjustedDelta, null);
  assert.equal(quotaRadar.rate, null);
  assert.equal(quotaRadar.fiveHourPolicy, "temporarily_paused_hidden");
  assert.deepEqual(quotaRadarAvailableWindows(quotaRadar), ["sevenDay"]);
  assert.equal(quotaRadar.rows[0].fiveH, null);
  assert.deepEqual(quotaChartSeries(quotaRadar, "fiveHour"), []);
  assert.deepEqual(quotaChartSeries(quotaRadar, "sevenDay").map((item) => item.points[0].value), [97.2415, 486.2075, 1944.83]);

  for (const policy of ["cancelled", "removed", "retired"]) {
    assert.deepEqual(quotaRadarAvailableWindows({
      ...quotaRadar,
      fiveHourPolicy: policy,
      rows: quotaRadar.rows.map((row) => ({ ...row, fiveH: 123 })),
    }), ["sevenDay"]);
  }
});

test("Radar normalization matches formatting-only key variants and numeric strings", () => {
  const normalized = normalizeCodexRadarSnapshot({ "PAY-LOAD": {
    "MONITORED-AT": "2026-07-20T08:00:00+08:00",
    "WINDOW OPEN": "false",
    "RECOMMENDED-ACTION": "wait",
    "WIN-DOW": {
      "MES-SAGE": "窗口数据仍可读取",
    },
    "PRE-DICTION": {
      "PROBABILITY-24-H": "0.21",
      "PROBABILITY 48H": "0.34",
    },
    "MODEL IQ": {
      "LATEST": {
        "SCORE": "125",
        "TOTAL-TOKENS": "39090118",
        "MODEL": "gpt-5.6-sol",
        "REASONING EFFORT": "max",
      },
      "QUOTA-RADAR": {
        "FIVE-HOUR-POLICY": "temporarily_paused_hidden",
        "SEVEN-DAY-POLICY": "direct_quota_api",
        "ROWS": [{ "TIER": "Plus", "SEVEN D": "97.24" }],
      },
    },
  } });

  assert.equal(normalized.monitoredAt, "2026-07-20T08:00:00+08:00");
  assert.equal(normalized.windowOpen, false);
  assert.equal(normalized.window.message, "窗口数据仍可读取");
  assert.equal(normalized.prediction.probability24H, 0.21);
  assert.equal(normalized.prediction.probability48H, 0.34);
  assert.equal(primaryModelMeasurementRow(normalized.modelIq)?.point.score, 125);
  assert.equal(normalized.modelIq.latest.totalTokens, 39090118);
  assert.equal(normalized.modelIq.quotaRadar?.rows[0].sevenD, 97.24);
  assert.equal(codexRadarSnapshotHasContent(normalized), true);
});

test("one changed Radar block does not hide healthy window quota and environment blocks", () => {
  const normalized = normalizeCodexRadarSnapshot({
    status: "normal",
    window: { message: "窗口块仍然健康" },
    prediction: { unexpected_v3: { value: 1 } },
    model_iq: {
      latest: { score: { new_shape: 125 } },
      comparisons: { broken: { latest: "not_an_object" } },
      quota_radar: {
        rows: [
          { tier: 123, five_h: "unknown" },
          { tier: "Plus", seven_d: "97.24", basis: "estimated" },
        ],
      },
    },
    codex_environment: {
      official_updates_24h: "4",
      official_news: [
        { title_zh: "仍可读取的资讯", url: "https://codexradar.com/kept" },
        { title_zh: 123 },
      ],
    },
  });

  assert.equal(normalized.window.message, "窗口块仍然健康");
  assert.equal(primaryModelMeasurementRow(normalized.modelIq), null);
  assert.equal(modelIqChartSeries(normalized.modelIq).length, 0);
  assert.equal(normalized.modelIq.quotaRadar?.rows.length, 1);
  assert.equal(normalized.modelIq.quotaRadar?.rows[0].sevenD, 97.24);
  assert.equal(normalized.codexEnvironment.officialUpdates24H, 4);
  assert.equal(codexRadarSnapshotHasContent(normalized), true);
});

test("exact Radar keys win and genuinely empty normalized payloads fail the content gate", () => {
  const exactWins = normalizeCodexRadarSnapshot({
    recommendedAction: "wait",
    "recommended-action": "run",
    window: { message: "有内容" },
  });
  assert.equal(exactWins.recommendedAction, "wait");
  assert.equal(codexRadarSnapshotHasContent(exactWins), true);
  assert.equal(codexRadarSnapshotHasContent(normalizeCodexRadarSnapshot({ schema_version: "3" })), false);
});

test("selectCodexRadarDetailSnapshot prefers optional full detail and falls back to public summary", () => {
  const publicSnapshot = normalizeCodexRadarSnapshot(radarSnapshotFixture({
    recommended_action: "wait",
    model_iq: { ...radarSnapshotFixture().model_iq, latest: { ...radarSnapshotFixture().model_iq.latest, score: 100 } },
  }));
  const detailSnapshot = normalizeCodexRadarSnapshot(radarSnapshotFixture({
    recommended_action: "run",
    model_iq: { ...radarSnapshotFixture().model_iq, latest: { ...radarSnapshotFixture().model_iq.latest, score: 125 } },
  }));

  assert.equal(selectCodexRadarDetailSnapshot(publicSnapshot, null)?.recommendedAction, "wait");
  assert.equal(selectCodexRadarDetailSnapshot(publicSnapshot, detailSnapshot)?.recommendedAction, "run");
  assert.equal(primaryModelRow(selectCodexRadarDetailSnapshot(publicSnapshot, detailSnapshot).modelIq).point.score, 125);
});

test("parseCodexRadarFeedXml mirrors the Swift RSS reminder parser", () => {
  const items = parseCodexRadarFeedXml(`
    <rss>
      <channel>
        <item>
          <title>速蹬窗口开启：500 万用户庆祝重置</title>
          <link>https://codexradar.com/#codex-speed-window-2026-05-31-500</link>
          <guid>radar-500</guid>
          <pubDate>2026-06-24 20:00</pubDate>
          <description><![CDATA[发现有效重置预告，速蹬窗口开启。]]></description>
        </item>
        <item>
          <title>Codex &amp; Radar 更新</title>
          <link>https://codexradar.com/#update</link>
          <guid>radar-update</guid>
          <pubDate>2026-06-25 09:00</pubDate>
          <description>公开订阅 &amp; 提醒历史</description>
        </item>
      </channel>
    </rss>
  `);

  assert.equal(items.length, 2);
  assert.equal(items[0].title, "速蹬窗口开启：500 万用户庆祝重置");
  assert.equal(items[0].description, "发现有效重置预告，速蹬窗口开启。");
  assert.equal(items[1].title, "Codex & Radar 更新");
  assert.equal(items[1].description, "公开订阅 & 提醒历史");
});

function radarSnapshotFixture(overrides = {}) {
  return {
    monitored_at: "2026-06-24T14:55:20+08:00",
    recommended_action: "wait",
    model_iq: {
      latest: {
        date: "2026-06-24-pm",
        score: 100,
        status: "green",
        passed: 10,
        tasks: 12,
        invalid: 2,
        valid_tasks: 10,
        total_tokens: 39090118,
        input_tokens: 28000118,
        cached_input_tokens: 21000118,
        output_tokens: 11090000,
        wall_seconds: 1510,
        wall_time_human: "25分钟",
        model: "gpt-5.5",
        reasoning_effort: "xhigh",
        cost_usd: 40.38,
      },
      recent_days: [],
      comparisons: {},
    },
    codex_environment: {},
    ...overrides,
  };
}

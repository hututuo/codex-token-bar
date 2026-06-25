import assert from "node:assert/strict";
import test from "node:test";
import { normalizeCodexRadarSnapshot, primaryModelRow, secondaryModelRows, shortDateLabel } from "./model.ts";

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
});

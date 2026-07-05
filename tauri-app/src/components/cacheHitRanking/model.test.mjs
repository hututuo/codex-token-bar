import assert from "node:assert/strict";
import test from "node:test";
import {
  buildCacheRankingItems,
  cacheHitRate,
  rankingSubtitle,
  uncachedInputTokens,
} from "./model.ts";

function breakdown(inputTokens, cachedInputTokens, calls = 1) {
  return {
    inputTokens,
    cachedInputTokens,
    outputTokens: 0,
    totalTokens: inputTokens,
    calls,
  };
}

const cacheUsage = {
  sessions: [
    { id: "single", title: "单轮会话", lastUpdated: "2026-06-24T08:00:00Z", breakdown: breakdown(2_000, 100, 1) },
    { id: "low", title: "低命中会话", lastUpdated: "2026-06-24T09:00:00Z", breakdown: breakdown(2_000, 200, 2) },
    { id: "high", title: "高命中会话", lastUpdated: "2026-06-24T10:00:00Z", breakdown: breakdown(2_000, 1_800, 3) },
    { id: "unknown", title: "未知时间会话", lastUpdated: null, breakdown: breakdown(5_000, 4_500, 2) },
  ],
  turns: [
    {
      id: "low-1",
      sessionId: "low",
      sessionTitle: "低命中会话",
      timestamp: "2026-06-24T09:00:00Z",
      turnIndexInSession: 1,
      userPrompt: "第一轮问题",
      assistantResponse: "第一轮回答",
      breakdown: breakdown(3_000, 0),
    },
    {
      id: "low-2",
      sessionId: "low",
      sessionTitle: "低命中会话",
      timestamp: "2026-06-24T09:05:00Z",
      turnIndexInSession: 2,
      userPrompt: "第二轮问题",
      assistantResponse: "第二轮回答",
      breakdown: breakdown(3_000, 300),
    },
    {
      id: "latest",
      sessionId: "high",
      sessionTitle: "高命中会话",
      timestamp: "2026-06-24T10:10:00Z",
      turnIndexInSession: 2,
      userPrompt: "最新问题",
      assistantResponse: "最新回答",
      breakdown: breakdown(3_000, 2_700),
    },
    {
      id: "unknown-time",
      sessionId: "unknown",
      sessionTitle: "未知时间会话",
      timestamp: null,
      turnIndexInSession: 3,
      userPrompt: "未知时间问题",
      assistantResponse: "未知时间回答",
      breakdown: breakdown(4_000, 0),
    },
  ],
};

test("buildCacheRankingItems excludes single-turn sessions by default and sorts low hit first", () => {
  const items = buildCacheRankingItems(cacheUsage, {
    scope: "sessions",
    sortOrder: "lowHit",
    excludesSingleTurnSessions: true,
    excludesFirstTurns: true,
  });

  assert.deepEqual(items.map((item) => item.title), ["低命中会话", "未知时间会话", "高命中会话"]);
  assert.equal(items[0].subtitle.includes("2 轮"), true);
});

test("buildCacheRankingItems can include single-turn sessions", () => {
  const items = buildCacheRankingItems(cacheUsage, {
    scope: "sessions",
    sortOrder: "lowHit",
    excludesSingleTurnSessions: false,
    excludesFirstTurns: true,
  });

  assert.equal(items[0].title, "单轮会话");
});

test("turn ranking excludes first turns and displays question answer snippets", () => {
  const items = buildCacheRankingItems(cacheUsage, {
    scope: "turns",
    sortOrder: "lowHit",
    excludesSingleTurnSessions: true,
    excludesFirstTurns: true,
  });

  assert.deepEqual(items.map((item) => item.title), ["问：未知时间问题", "问：第二轮问题", "问：最新问题"]);
  assert.equal(items[1].subtitle, "答：第二轮回答");
  assert.match(items[1].context ?? "", /低命中会话 · 第 2 轮/);
});

test("buildCacheRankingItems can sort sessions and turns by latest activity first", () => {
  const sessionItems = buildCacheRankingItems(cacheUsage, {
    scope: "sessions",
    sortOrder: "latest",
    excludesSingleTurnSessions: true,
    excludesFirstTurns: true,
  });
  assert.deepEqual(sessionItems.map((item) => item.title), ["高命中会话", "低命中会话", "未知时间会话"]);

  const turnItems = buildCacheRankingItems(cacheUsage, {
    scope: "turns",
    sortOrder: "latest",
    excludesSingleTurnSessions: true,
    excludesFirstTurns: true,
  });
  assert.deepEqual(turnItems.map((item) => item.title), ["问：最新问题", "问：第二轮问题", "问：未知时间问题"]);
});

test("ranking helpers expose Swift-compatible subtitles and token math", () => {
  assert.equal(rankingSubtitle("sessions", "lowHit", true, true), "低命中优先 · 已排除只有一轮的会话");
  assert.equal(rankingSubtitle("turns", "latest", true, false), "最新优先 · 包含首轮");
  assert.equal(cacheHitRate(breakdown(1_000, 250)), 0.25);
  assert.equal(uncachedInputTokens(breakdown(1_000, 250)), 750);
});

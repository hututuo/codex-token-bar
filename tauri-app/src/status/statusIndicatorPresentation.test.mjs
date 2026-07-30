import assert from "node:assert/strict";
import test from "node:test";

import {
  buildStatusIndicatorPresentation,
  buildStatusIndicatorPreview,
  buildStatusMetricStates,
  estimateStatusIndicatorWidth,
} from "./statusIndicatorPresentation.ts";
import { attemptStatusIndicatorReadoutPublish } from "./statusIndicatorPublisher.ts";

const BASE_SNAPSHOT = {
  tokensPerSecond: 0,
  maxTokensPerSecond: 200,
  liveRateAvailable: true,
  trendLabel: "",
  resetCreditLabel: "",
  totalTokensLabel: "总 1.2M",
  todayTokensLabel: "今 84K",
  requestsLabel: "次 42",
  fiveHourLabel: "5h 41%",
  fiveHourAvailability: "measured",
  fiveHourRemainingPercent: 41.2,
  fiveHourExpectedRemainingPercent: 50,
  sevenDayLabel: "7d 76%",
  sevenDayAvailability: "measured",
  sevenDayRemainingPercent: 75.6,
  sevenDayExpectedRemainingPercent: 80,
  unread: false,
  unreadSummary: {
    active: false,
    count: 0,
    label: "已读",
    detail: "",
    source: "test",
  },
};

test("status presentation follows configured order and preserves a real zero rate", () => {
  const result = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["sevenDay", "rate", "today"],
    snapshot: BASE_SNAPSHOT,
  });

  assert.deepEqual(result.visibleItems.map((item) => item.id), ["sevenDay", "rate", "today"]);
  assert.equal(result.title, "⁷ᵈ76% · 0/s · 今84K");
  assert.match(result.tooltip, /7 天额度剩余 76%.*速度 0 tok\/s.*今日 Token 84K/);
  assert.ok(result.width >= 38);
});

test("status presentation keeps selected unavailable and zero metrics visible", () => {
  const result = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor({
      ...BASE_SNAPSHOT,
      todayTokensLabel: "今 待读取",
      totalTokensLabel: "总 读取失败",
      requestsLabel: "次 不可用",
      unreadSummary: {
        ...BASE_SNAPSHOT.unreadSummary,
        source: "pending",
      },
    }, {
      liveRateEnabled: false,
    }),
    order: ["rate", "fiveHour", "sevenDay", "iq", "running", "unread"],
    radar: null,
    running: {
      total: 0,
      mainThreads: 0,
      subagents: 0,
      status: "ready",
      updatedAt: 1,
      detail: "",
      livenessLeaseHours: 24,
    },
    snapshot: {
      ...BASE_SNAPSHOT,
      todayTokensLabel: "今 待读取",
      totalTokensLabel: "总 读取失败",
      requestsLabel: "次 不可用",
      fiveHourAvailability: "unavailable",
      fiveHourRemainingPercent: null,
      sevenDayAvailability: "absent",
      sevenDayRemainingPercent: null,
      unreadSummary: {
        ...BASE_SNAPSHOT.unreadSummary,
        source: "pending",
      },
    },
  });

  assert.deepEqual(
    result.visibleItems.map((item) => item.id),
    ["rate", "fiveHour", "sevenDay", "iq", "running", "unread"],
  );
  assert.equal(result.title, "—/s · ⁵ʰ— · ⁷ᵈ— · IQ— · 跑0 · 未—");
});

test("status presentation includes measured IQ, running and unread values", () => {
  const snapshot = {
    ...BASE_SNAPSHOT,
    unread: true,
    unreadSummary: {
      ...BASE_SNAPSHOT.unreadSummary,
      active: true,
      count: 2,
      label: "未读 2",
    },
  };
  const result = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(snapshot),
    order: ["iq", "running", "unread"],
    radar: radarFixture(103.6),
    running: {
      total: 3,
      mainThreads: 2,
      subagents: 1,
      status: "ready",
      updatedAt: 1,
      detail: "",
      livenessLeaseHours: 24,
    },
    snapshot,
  });

  assert.equal(result.title, "IQ103.6 · 跑3 · 未2");
  assert.deepEqual(result.visibleItems.map((item) => item.id), ["iq", "running", "unread"]);
});

test("empty metric order produces icon-only output without inventing a metric", () => {
  const result = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: [],
    snapshot: BASE_SNAPSHOT,
  });

  assert.deepEqual(result.visibleItems, []);
  assert.equal(result.title, "");
  assert.equal(result.tooltip, "Codex Token Bar");
  assert.equal(result.width, 0);
  assert.equal(estimateStatusIndicatorWidth(""), 0);
});

test("metric states distinguish unavailable placeholders from real zero values", () => {
  const unavailable = metricStatesFor({
    ...BASE_SNAPSHOT,
    tokensPerSecond: 0,
    liveRateAvailable: false,
    todayTokensLabel: "今 待读取",
    totalTokensLabel: "总 读取失败",
    requestsLabel: "次 不可用",
    unreadSummary: {
      ...BASE_SNAPSHOT.unreadSummary,
      count: 0,
      source: "pending",
    },
  });
  assert.deepEqual(unavailable, {
    rate: { available: false, value: "—" },
    today: { available: false, value: "—" },
    total: { available: false, value: "—" },
    requests: { available: false, value: "—" },
    unread: { available: false, value: "—" },
  });

  const zero = metricStatesFor({
    ...BASE_SNAPSHOT,
    tokensPerSecond: 0,
    todayTokensLabel: "今 0",
    totalTokensLabel: "总 0",
    requestsLabel: "次 0",
    unreadSummary: {
      ...BASE_SNAPSHOT.unreadSummary,
      count: 0,
      source: "official",
    },
  });
  assert.deepEqual(zero, {
    rate: { available: true, value: "0" },
    today: { available: true, value: "0" },
    total: { available: true, value: "0" },
    requests: { available: true, value: "0" },
    unread: { available: true, value: "0" },
  });
});

test("unread availability does not depend on the live-rate toggle", () => {
  const states = metricStatesFor({
    ...BASE_SNAPSHOT,
    liveRateAvailable: false,
    unreadSummary: {
      ...BASE_SNAPSHOT.unreadSummary,
      count: 0,
      source: "official",
    },
  }, {
    liveRateEnabled: false,
  });

  assert.deepEqual(states.rate, { available: false, value: "—" });
  assert.deepEqual(states.unread, { available: true, value: "0" });
});

test("readout signature commits only after native success and failed attempts can retry", async () => {
  const readout = {
    title: "12.4/s",
    tooltip: "Codex Token Bar · 速度 12.4 tok/s",
    width: 64,
  };
  let calls = 0;
  const failed = await attemptStatusIndicatorReadoutPublish(readout, "", async () => {
    calls += 1;
    return false;
  });
  assert.deepEqual(failed, {
    committedSignature: "",
    published: false,
    shouldRetry: true,
  });

  const succeeded = await attemptStatusIndicatorReadoutPublish(
    readout,
    failed.committedSignature,
    async () => {
      calls += 1;
      return true;
    },
  );
  assert.equal(calls, 2);
  assert.equal(succeeded.published, true);
  assert.equal(succeeded.shouldRetry, false);
  assert.notEqual(succeeded.committedSignature, "");

  const unchanged = await attemptStatusIndicatorReadoutPublish(
    readout,
    succeeded.committedSignature,
    async () => {
      calls += 1;
      return true;
    },
  );
  assert.equal(calls, 2, "a committed signature is not republished without a change");
  assert.equal(unchanged.published, false);
  assert.equal(unchanged.shouldRetry, false);
});

test("switching between live metrics and icon-only readouts republishes each state", async () => {
  const liveReadout = {
    title: "12.4/s",
    tooltip: "Codex Token Bar · 速度 12.4 tok/s",
    width: 64,
  };
  const iconOnlyReadout = {
    title: "",
    tooltip: "Codex Token Bar",
    width: 0,
  };
  const publishedTitles = [];
  const publish = async (title) => {
    publishedTitles.push(title);
    return true;
  };

  const live = await attemptStatusIndicatorReadoutPublish(liveReadout, "", publish);
  const iconOnly = await attemptStatusIndicatorReadoutPublish(
    iconOnlyReadout,
    live.committedSignature,
    publish,
  );
  const liveAgain = await attemptStatusIndicatorReadoutPublish(
    liveReadout,
    iconOnly.committedSignature,
    publish,
  );

  assert.deepEqual(publishedTitles, ["12.4/s", "", "12.4/s"]);
  assert.equal(liveAgain.published, true);
});

test("full and hidden label styles change only the short title, not tooltip detail", () => {
  const full = buildStatusIndicatorPreview(["rate", "fiveHour", "sevenDay", "today"], "full");
  const hidden = buildStatusIndicatorPreview(["rate", "fiveHour", "sevenDay", "today"], "hidden");

  assert.equal(full.title, "速率12.4/s · 5h42% · 7d76% · 今日84K");
  assert.equal(hidden.title, "12.4 · 42% · 76% · 84K");
  assert.equal(full.tooltip, hidden.tooltip);
});

function radarFixture(score) {
  const point = {
    date: "2026-07-30",
    score,
    status: "ready",
    passed: 10,
    tasks: 10,
    invalid: 0,
    validTasks: 10,
    totalTokens: 100,
    inputTokens: 50,
    cachedInputTokens: 0,
    outputTokens: 50,
    wallSeconds: 1,
    wallTimeHuman: "1s",
    model: "gpt-5.6",
    reasoningEffort: "high",
  };
  return {
    modelIq: {
      latest: point,
      recentDays: [point],
      comparisons: {},
    },
  };
}

function metricStatesFor(snapshot, overrides = {}) {
  return buildStatusMetricStates({
    liveRateEnabled: true,
    sourceReady: true,
    snapshot,
    ...overrides,
  });
}

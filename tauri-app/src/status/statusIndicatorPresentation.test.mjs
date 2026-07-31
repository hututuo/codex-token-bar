import assert from "node:assert/strict";
import test from "node:test";

import {
  buildStatusIndicatorPresentation,
  buildStatusIndicatorPreview,
  buildStatusMetricStates,
  estimateStatusIndicatorWidth,
  statusSnapshotForQuotaDiagnostics,
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
  fiveHourRemainingPercent: 0.412,
  fiveHourExpectedRemainingPercent: 50,
  sevenDayLabel: "7d 76%",
  sevenDayAvailability: "measured",
  sevenDayRemainingPercent: 0.756,
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

const RADAR_NOW = new Date("2026-07-30T04:00:00Z");

test("status presentation follows configured order and preserves a real zero rate", () => {
  const result = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["sevenDay", "rate", "today"],
    snapshot: BASE_SNAPSHOT,
  });

  assert.deepEqual(result.visibleItems.map((item) => item.id), ["sevenDay", "rate", "today"]);
  assert.equal(result.title, "7D76% · 0/s · 今84K");
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
  assert.equal(result.title, "—/s · 5H— · 7D— · 1 — / 2 — · 跑0 · 未—");
});

test("status presentation replaces IQ score with a structured two-row model ranking", () => {
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
    now: RADAR_NOW,
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

  assert.equal(result.title, "1 Sol·MAX / 2 Luna·H · 跑3 · 未2");
  assert.deepEqual(result.visibleItems.map((item) => item.id), ["iq", "running", "unread"]);
  assert.deepEqual(result.visibleItems[0].compactRows, ["1 Sol·MAX", "2 Luna·H"]);
  assert.doesNotMatch(result.title, /IQ|103\.6/);
  assert.match(result.tooltip, /今日模型榜：1 Sol·MAX；2 Luna·H/);
});

test("status model ranking compacts every supported reasoning effort", () => {
  const expected = new Map([
    ["ultra", "U"],
    ["max", "MAX"],
    ["xhigh", "XH"],
    ["high", "H"],
    ["medium", "M"],
    ["low", "L"],
    ["minimal", "MIN"],
  ]);
  for (const [effort, compact] of expected) {
    const radar = radarFixture(100);
    radar.modelIq.latest.reasoningEffort = effort;
    radar.modelIq.comparisons = {};
    const result = buildStatusIndicatorPresentation({
      labelStyle: "compact",
      metricStates: metricStatesFor(BASE_SNAPSHOT),
      now: RADAR_NOW,
      order: ["iq"],
      radar,
      snapshot: BASE_SNAPSHOT,
    });
    assert.deepEqual(result.visibleItems[0].compactRows, [`1 Sol·${compact}`, "2 —"]);
  }
});

test("today model ranking excludes stale snapshots and prior-day scores", () => {
  const stale = radarFixture(150);
  stale.staleDataDisplayed = true;
  const staleResult = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    now: RADAR_NOW,
    order: ["iq"],
    radar: stale,
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(staleResult.visibleItems[0].compactRows, ["1 —", "2 —"]);

  const mixedDates = radarFixture(150);
  mixedDates.modelIq.latest.date = "2026-07-29T23:00:00+08:00";
  mixedDates.modelIq.comparisons.luna.latest.score = 95;
  const currentOnly = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    now: RADAR_NOW,
    order: ["iq"],
    radar: mixedDates,
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(currentOnly.visibleItems[0].compactRows, ["1 Luna·H", "2 —"]);
});

test("today model ranking rejects zero-sample placeholders but preserves a measured zero score", () => {
  const placeholder = radarFixture(150);
  Object.assign(placeholder.modelIq.latest, {
    passed: 0,
    tasks: 0,
    validTasks: 0,
  });
  const withoutPlaceholder = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    now: RADAR_NOW,
    order: ["iq"],
    radar: placeholder,
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(withoutPlaceholder.visibleItems[0].compactRows, ["1 Luna·H", "2 —"]);

  const realZero = radarFixture(0);
  realZero.modelIq.comparisons = {};
  realZero.modelIq.latest.passed = 0;
  realZero.modelIq.latest.tasks = 1;
  delete realZero.modelIq.latest.validTasks;
  const measuredZero = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    now: RADAR_NOW,
    order: ["iq"],
    radar: realZero,
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(measuredZero.visibleItems[0].compactRows, ["1 Sol·MAX", "2 —"]);

  const explicitlyInvalid = radarFixture(200);
  Object.assign(explicitlyInvalid.modelIq.latest, {
    passed: 10,
    tasks: 10,
    validTasks: 0,
  });
  const withoutInvalidSamples = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    now: RADAR_NOW,
    order: ["iq"],
    radar: explicitlyInvalid,
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(withoutInvalidSamples.visibleItems[0].compactRows, ["1 Luna·H", "2 —"]);
});

test("today model ranking falls back to comparison identity and skips identity-free rows", () => {
  const radar = radarFixture(150);
  Object.assign(radar.modelIq.latest, {
    model: null,
    passed: 0,
    tasks: 0,
    validTasks: 0,
  });
  const comparison = radar.modelIq.comparisons.luna;
  comparison.label = "Current contender";
  comparison.model = "gpt-5.6-sol";
  comparison.reasoningEffort = "ultra";
  comparison.latest.model = null;
  comparison.latest.reasoningEffort = null;
  const result = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    now: RADAR_NOW,
    order: ["iq"],
    radar,
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(result.visibleItems[0].compactRows, ["1 Sol·U", "2 —"]);

  comparison.model = "";
  comparison.reasoningEffort = "";
  comparison.label = "MODEL";
  const identityFree = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    now: RADAR_NOW,
    order: ["iq"],
    radar,
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(identityFree.visibleItems[0].compactRows, ["1 —", "2 —"]);
});

test("an officially absent five-hour window is omitted while unavailable five-hour and absent seven-day stay visible", () => {
  const absentFiveHour = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["fiveHour", "sevenDay"],
    snapshot: {
      ...BASE_SNAPSHOT,
      fiveHourAvailability: "absent",
      fiveHourRemainingPercent: null,
      sevenDayAvailability: "absent",
      sevenDayRemainingPercent: null,
    },
  });
  assert.deepEqual(absentFiveHour.visibleItems.map((item) => item.id), ["sevenDay"]);
  assert.equal(absentFiveHour.title, "7D—");

  const unavailableFiveHour = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["fiveHour", "sevenDay"],
    snapshot: {
      ...BASE_SNAPSHOT,
      fiveHourAvailability: "unavailable",
      fiveHourRemainingPercent: null,
    },
  });
  assert.deepEqual(unavailableFiveHour.visibleItems.map((item) => item.id), ["fiveHour", "sevenDay"]);
  assert.equal(unavailableFiveHour.title, "5H— · 7D76%");
});

test("status quota uses the shared zero-to-one contract and preserves measured zero and full values", () => {
  const result = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["fiveHour", "sevenDay"],
    snapshot: {
      ...BASE_SNAPSHOT,
      fiveHourRemainingPercent: 0,
      sevenDayRemainingPercent: 1,
    },
  });
  assert.equal(result.title, "5H0% · 7D100%");
  assert.equal(result.visibleItems[0].available, true);
  assert.equal(result.visibleItems[1].available, true);
  assert.deepEqual(result.visibleItems[0].compactMarker, { top: "5", bottom: "H" });
  assert.deepEqual(result.visibleItems[1].compactMarker, { top: "7", bottom: "D" });
});

test("stale cached quota diagnostics replace retained percentages with two unavailable dashes", () => {
  const staleSnapshot = statusSnapshotForQuotaDiagnostics(BASE_SNAPSHOT, [{
    category: "stale_cached_data",
    message: "额度刷新失败，暂时显示上次成功额度。",
    occurredAt: "2026-07-31T08:20:35Z",
    retryable: true,
    severity: "warning",
    source: "account_quota",
    staleDataDisplayed: true,
  }]);
  assert.equal(staleSnapshot.fiveHourAvailability, "unavailable");
  assert.equal(staleSnapshot.fiveHourRemainingPercent, null);
  assert.equal(staleSnapshot.sevenDayAvailability, "unavailable");
  assert.equal(staleSnapshot.sevenDayRemainingPercent, null);

  const result = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(staleSnapshot),
    order: ["fiveHour", "sevenDay"],
    snapshot: staleSnapshot,
  });
  assert.equal(result.title, "5H— · 7D—");
  assert.deepEqual(result.visibleItems.map((item) => item.id), ["fiveHour", "sevenDay"]);
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

  assert.equal(full.title, "速率12.4/s · 5H42% · 7D76% · 今日84K");
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
    model: "gpt-5.6-sol",
    reasoningEffort: "max",
  };
  return {
    staleDataDisplayed: false,
    timezone: "Asia/Shanghai",
    modelIq: {
      latest: point,
      recentDays: [point],
      comparisons: {
        luna: {
          label: "GPT-5.6 Luna high",
          model: "gpt-5.6-luna",
          reasoningEffort: "high",
          latest: {
            ...point,
            score: score - 5,
            model: "gpt-5.6-luna",
            reasoningEffort: "high",
          },
          recentDays: [],
        },
      },
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

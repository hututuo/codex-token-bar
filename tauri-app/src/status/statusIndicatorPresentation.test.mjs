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

test("status presentation follows configured order and preserves a real zero rate", () => {
  const result = buildStatusIndicatorPresentation({
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["sevenDay", "rate", "today"],
    snapshot: BASE_SNAPSHOT,
  });

  assert.deepEqual(result.visibleItems.map((item) => item.id), ["sevenDay", "rate", "today"]);
  assert.equal(result.title, "7D76% · 0/s · 今84K");
  assert.deepEqual(result.columns, [
    { top: { text: "⁷76%" }, bottom: { text: "" } },
    { top: { text: "0" }, bottom: { secondary: true, text: "tok/s" } },
    { top: { text: "今84K" }, bottom: { text: "" } },
  ]);
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
    crowdRadar: crowdRadarFixture(),
    labelStyle: "compact",
    metricStates: metricStatesFor(snapshot),
    order: ["iq", "running", "unread"],
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

  assert.equal(result.title, "1 Sol·MAX / 2 Terra·U · 跑3 · 未2");
  assert.deepEqual(result.visibleItems.map((item) => item.id), ["iq", "running", "unread"]);
  assert.deepEqual(result.visibleItems[0].compactRows, ["1 Sol·MAX", "2 Terra·U"]);
  assert.doesNotMatch(result.title, /IQ/);
  assert.match(result.tooltip, /今日众测实时榜：1 Sol·MAX；2 Terra·U/);
});

test("default metrics collapse into three compact two-line tray columns", () => {
  const result = buildStatusIndicatorPresentation({
    crowdRadar: crowdRadarFixture(),
    labelStyle: "compact",
    metricStates: metricStatesFor({ ...BASE_SNAPSHOT, tokensPerSecond: 12.4 }),
    order: ["rate", "fiveHour", "sevenDay", "iq"],
    snapshot: { ...BASE_SNAPSHOT, tokensPerSecond: 12.4 },
  });

  assert.deepEqual(result.columns, [
    { top: { text: "12.4" }, bottom: { secondary: true, text: "tok/s" } },
    { top: { text: "⁵41%" }, bottom: { text: "⁷76%" } },
    { top: { text: "1 Sol·MAX" }, bottom: { text: "2 Terra·U" } },
  ]);
  assert.equal(result.columns.flatMap((column) => [column.top.text, column.bottom.text]).join(" ").includes("5 小时"), false);
  assert.ok(result.width >= 50 + result.columns.length * 20);
  assert.ok(result.width < estimateStatusIndicatorWidth(result.title));
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
    const crowdRadar = crowdRadarFixture();
    crowdRadar.models = [{ ...crowdRadar.models[0], effort }];
    crowdRadar.recentModels = crowdRadar.models;
    const result = buildStatusIndicatorPresentation({
      crowdRadar,
      labelStyle: "compact",
      metricStates: metricStatesFor(BASE_SNAPSHOT),
      order: ["iq"],
      snapshot: BASE_SNAPSHOT,
    });
    assert.deepEqual(result.visibleItems[0].compactRows, [`1 Sol·${compact}`, "2 —"]);
  }
});

test("today crowd ranking rejects published fallback data and trusts the freshly read realtime table", () => {
  const recentOnly = crowdRadarFixture();
  recentOnly.realtimeAvailable = false;
  const recentOnlyResult = buildStatusIndicatorPresentation({
    crowdRadar: recentOnly,
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["iq"],
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(recentOnlyResult.visibleItems[0].compactRows, ["1 —", "2 —"]);

  const priorDay = crowdRadarFixture();
  priorDay.generatedAt = "2026-07-29T03:30:00Z";
  const priorDayResult = buildStatusIndicatorPresentation({
    crowdRadar: priorDay,
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["iq"],
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(priorDayResult.visibleItems[0].compactRows, ["1 Sol·MAX", "2 Terra·U"]);
});

test("status model ranking reads only today's live crowd radar", () => {
  const crowdRadar = crowdRadarFixture();
  const result = buildStatusIndicatorPresentation({
    crowdRadar,
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["iq"],
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(result.visibleItems[0].compactRows, ["1 Sol·MAX", "2 Terra·U"]);
});

test("today crowd ranking rejects zero-sample placeholders but preserves a measured zero result", () => {
  const placeholder = crowdRadarFixture();
  placeholder.models[0].scoreSamples = 0;
  const withoutPlaceholder = buildStatusIndicatorPresentation({
    crowdRadar: placeholder,
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["iq"],
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(withoutPlaceholder.visibleItems[0].compactRows, ["1 Terra·U", "2 —"]);

  const realZero = crowdRadarFixture();
  realZero.models = [{
    ...realZero.models[0],
    graded: 1,
    passed: 0,
    passRate: 0,
    scorePassed: 0,
    scoreSamples: 112,
  }];
  realZero.recentModels = realZero.models;
  const measuredZero = buildStatusIndicatorPresentation({
    crowdRadar: realZero,
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["iq"],
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(measuredZero.visibleItems[0].compactRows, ["1 Sol·MAX", "2 —"]);
});

test("today crowd ranking compacts non-family identifiers and skips identity-free rows", () => {
  const crowdRadar = crowdRadarFixture();
  crowdRadar.models = [{ ...crowdRadar.models[0], model: "gpt-5.6-orbit" }];
  crowdRadar.recentModels = crowdRadar.models;
  const result = buildStatusIndicatorPresentation({
    crowdRadar,
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["iq"],
    snapshot: BASE_SNAPSHOT,
  });
  assert.deepEqual(result.visibleItems[0].compactRows, ["1 5.6-orbit·MAX", "2 —"]);

  crowdRadar.models = [{ ...crowdRadar.models[0], model: "" }];
  crowdRadar.recentModels = crowdRadar.models;
  const identityFree = buildStatusIndicatorPresentation({
    crowdRadar,
    labelStyle: "compact",
    metricStates: metricStatesFor(BASE_SNAPSHOT),
    order: ["iq"],
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
    columns: [{ top: { text: "12.4" }, bottom: { secondary: true, text: "tok/s" } }],
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

  const relayout = await attemptStatusIndicatorReadoutPublish(
    {
      ...readout,
      columns: [{ top: { text: "tok/s" }, bottom: { text: "12.4" } }],
    },
    succeeded.committedSignature,
    async () => {
      calls += 1;
      return true;
    },
  );
  assert.equal(calls, 3, "a native row-layout change must be republished");
  assert.equal(relayout.published, true);
});

test("switching between live metrics and icon-only readouts republishes each state", async () => {
  const liveReadout = {
    columns: [{ top: { text: "12.4" }, bottom: { secondary: true, text: "tok/s" } }],
    title: "12.4/s",
    tooltip: "Codex Token Bar · 速度 12.4 tok/s",
    width: 64,
  };
  const iconOnlyReadout = {
    columns: [],
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

test("full and hidden label styles change title and stacked labels without changing tooltip detail", () => {
  const full = buildStatusIndicatorPreview(["rate", "fiveHour", "sevenDay", "today"], "full");
  const hidden = buildStatusIndicatorPreview(["rate", "fiveHour", "sevenDay", "today"], "hidden");

  assert.equal(full.title, "速率12.4/s · 5H42% · 7D76% · 今日84K");
  assert.equal(hidden.title, "12.4 · 42% · 76% · 84K");
  assert.deepEqual(full.columns[0], {
    top: { text: "12.4" },
    bottom: { secondary: true, text: "tok/s" },
  });
  assert.deepEqual(hidden.columns[0], {
    top: { text: "12.4" },
    bottom: { text: "" },
  });
  assert.equal(full.tooltip, hidden.tooltip);
});

function metricStatesFor(snapshot, overrides = {}) {
  return buildStatusMetricStates({
    liveRateEnabled: true,
    sourceReady: true,
    snapshot,
    ...overrides,
  });
}

function crowdRadarFixture() {
  const models = [
    {
      model: "gpt-5.6-sol",
      effort: "max",
      graded: 77,
      passed: 53,
      passRate: 53 / 77,
      cells: 112,
      scorePassed: 77,
      scoreSamples: 112,
      latestGradedAt: "2026-07-30T03:30:00Z",
    },
    {
      model: "gpt-5.6-terra",
      effort: "ultra",
      graded: 72,
      passed: 46,
      passRate: 46 / 72,
      cells: 112,
      scorePassed: 72,
      scoreSamples: 112,
      latestGradedAt: "2026-07-30T03:29:00Z",
    },
  ];
  return {
    generatedAt: "2026-07-30T03:30:00Z",
    taskCount: 112,
    cellCount: 2352,
    contributorCount: 7,
    pendingGrades: 0,
    errorGrades: 0,
    models,
    recentModels: models,
    realtimeAvailable: true,
  };
}

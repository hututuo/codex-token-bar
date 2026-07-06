import assert from "node:assert/strict";
import test from "node:test";
import {
  compactTokens,
  disabledFloatingLiveSnapshot,
  floatingSnapshotForLiveRate,
} from "./compactPanelSnapshotModel.ts";

test("compact panel keeps usage summary raw state when live rate is disabled", () => {
  const current = {
    tokensPerSecond: 42,
    maxTokensPerSecond: 200,
    trendLabel: "",
    resetCreditLabel: "",
    totalTokensLabel: "总 59.1亿",
    todayTokensLabel: "今 7965.0万",
    requestsLabel: "次 534",
    fiveHourLabel: "5h",
    fiveHourRemainingPercent: 80,
    sevenDayLabel: "7d",
    sevenDayRemainingPercent: 63,
    unread: false,
    unreadSummary: {
      active: false,
      count: 0,
      label: "",
      detail: "",
      source: "none",
    },
  };

  const disabled = disabledFloatingLiveSnapshot(current);

  assert.equal(disabled.tokensPerSecond, 0);
  assert.equal(disabled.totalTokensLabel, "总 59.1亿");
  assert.equal(disabled.todayTokensLabel, "今 7965.0万");
  assert.equal(disabled.requestsLabel, "次 534");
});

test("compact panel summary labels are generated from raw summary instead of compact labels", () => {
  const liveRate = liveRateSnapshot({
    totalTokens: 1,
    totalTokensToday: 2,
    requestsToday: 3,
  });
  const trustedSummary = {
    totalTokens: 5_912_345_678,
    todayTokens: 79_650_123,
    todayRequests: 534,
  };

  const snapshot = floatingSnapshotForLiveRate(liveRate, trustedSummary);

  assert.equal(compactTokens(trustedSummary.totalTokens), "59.1亿");
  assert.equal(snapshot.totalTokensLabel, "总 59.1亿");
  assert.equal(snapshot.todayTokensLabel, "今 7965.0万");
  assert.equal(snapshot.requestsLabel, "次 534");
});

test("compact panel waits for trusted summary instead of using live-rate totals", () => {
  const snapshot = floatingSnapshotForLiveRate(
    liveRateSnapshot({
      totalTokens: 11_308_620_519,
      totalTokensToday: 333_123_813,
      requestsToday: 2_222,
    }),
    null,
  );

  assert.equal(snapshot.totalTokensLabel, "总 待读取");
  assert.equal(snapshot.todayTokensLabel, "今 待读取");
  assert.equal(snapshot.requestsLabel, "次 待读取");
});

test("compact panel fallback snapshot does not leak reset card placeholder", () => {
  const snapshot = floatingSnapshotForLiveRate(liveRateSnapshot(), null);

  assert.equal(snapshot.resetCreditLabel, "");
  assert.equal(snapshot.resetCreditRateBarLabel, "");
  assert.equal(snapshot.resetCreditStandaloneLabel, "");
});

function liveRateSnapshot(overrides) {
  return {
    scopeLabel: "全会话",
    threadTitle: "等待输出",
    selectedThreadId: null,
    selectedThreadTitle: "未选择",
    selectedTokensPerSecond: 0,
    tokensPerSecond: 12.3,
    totalTokens: 0,
    totalTokensToday: 0,
    requestsToday: 0,
    maxTokensPerSecond: 200,
    preciseEnabled: true,
    unreadSummary: {
      active: false,
      count: 0,
      label: "",
      detail: "",
      source: "none",
    },
    warnings: [],
    ...overrides,
  };
}

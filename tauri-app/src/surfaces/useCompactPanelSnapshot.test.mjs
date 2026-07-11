import assert from "node:assert/strict";
import test from "node:test";
import {
  compactTokens,
  disabledFloatingLiveSnapshot,
  floatingLiveRateStatusText,
  floatingSnapshotForLiveRate,
  liveRateStreamStartFailureSnapshot,
  preserveFloatingUsageSummary,
  compactSnapshotForSurfaceActivity,
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

test("hidden compact surface retains the exact last snapshot", () => {
  const current = floatingSnapshotForLiveRate(liveRateSnapshot({ tokensPerSecond: 42 }), {
    totalTokens: 500,
    todayTokens: 50,
    todayRequests: 5,
  });

  assert.equal(compactSnapshotForSurfaceActivity(current, false, true), current);
  assert.equal(compactSnapshotForSurfaceActivity(current, true, false).tokensPerSecond, 0);
  assert.equal(compactSnapshotForSurfaceActivity(current, true, false).totalTokensLabel, current.totalTokensLabel);
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

test("compact panel preserves the last trusted usage summary while precise summary rebuilds", () => {
  const trustedSnapshot = floatingSnapshotForLiveRate(
    liveRateSnapshot({
      totalTokens: 11_336_821_671,
      totalTokensToday: 333_123_813,
      requestsToday: 2_222,
    }),
    {
      totalTokens: 11_336_821_671,
      todayTokens: 333_123_813,
      todayRequests: 2_222,
    },
  );

  const preserved = preserveFloatingUsageSummary(trustedSnapshot);

  assert.equal(preserved.totalTokensLabel, "总 113.4亿");
  assert.equal(preserved.todayTokensLabel, "今 3.3亿");
  assert.equal(preserved.requestsLabel, "次 2222");
  assert.equal(preserved.tokensPerSecond, trustedSnapshot.tokensPerSecond);
  assert.equal(preserved.unreadSummary, trustedSnapshot.unreadSummary);
});

test("compact panel keeps trusted summary when a later live-rate event carries giant totals", () => {
  const trustedSummary = {
    totalTokens: 5_912_345_678,
    todayTokens: 79_650_123,
    todayRequests: 534,
  };

  const snapshot = floatingSnapshotForLiveRate(
    liveRateSnapshot({
      totalTokens: 113_308_620_519,
      totalTokensToday: 33_312_381_300,
      requestsToday: 2_222_000,
    }),
    trustedSummary,
  );

  assert.equal(snapshot.totalTokensLabel, "总 59.1亿");
  assert.equal(snapshot.todayTokensLabel, "今 7965.0万");
  assert.equal(snapshot.requestsLabel, "次 534");
});

test("initial compact panel still waits when no trusted summary exists", () => {
  const snapshot = preserveFloatingUsageSummary(floatingSnapshotForLiveRate(liveRateSnapshot(), null));

  assert.equal(snapshot.totalTokensLabel, "总 待读取");
  assert.equal(snapshot.todayTokensLabel, "今 待读取");
  assert.equal(snapshot.requestsLabel, "次 待读取");
});

test("compact panel keeps failure marker separate from untrusted live-rate totals", () => {
  const snapshot = floatingSnapshotForLiveRate(
    liveRateSnapshot({
      totalTokens: 11_308_620_519,
      totalTokensToday: 333_123_813,
      requestsToday: 2_222,
      warnings: [{ source: "live_rate_stream", message: "stream failed" }],
    }),
    null,
  );

  assert.equal(snapshot.liveRateStatusKind, "failure");
  assert.equal(snapshot.liveRateStatusLabel, "实时速率降级");
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

test("compact panel treats live-rate summary warnings as preparation not failure", () => {
  const snapshot = floatingSnapshotForLiveRate(
    liveRateSnapshot({
      warnings: [
        {
          source: "live_rate_summary",
          message: "精确 token 缓存尚未就绪",
        },
      ],
    }),
    null,
  );

  assert.equal(snapshot.liveRateStatusKind, "pending");
  assert.equal(snapshot.liveRateStatusLabel, "统计重建中");
  assert.equal(floatingLiveRateStatusText(snapshot), "统计重建中");
});

test("compact panel marks only live-rate stream warnings as degraded", () => {
  const snapshot = floatingSnapshotForLiveRate(
    liveRateSnapshot({
      warnings: [
        {
          source: "live_rate_stream",
          message: "stream failed",
        },
      ],
    }),
    null,
  );

  assert.equal(snapshot.liveRateStatusKind, "failure");
  assert.equal(snapshot.liveRateStatusLabel, "实时速率降级");
});

test("disabled compact live rate remains a clean non-error state", () => {
  const disabled = disabledFloatingLiveSnapshot(floatingSnapshotForLiveRate(liveRateSnapshot(), null));

  assert.equal(disabled.tokensPerSecond, 0);
  assert.equal(disabled.liveRateStatusKind, undefined);
  assert.equal(disabled.liveRateStatusLabel, undefined);
});

test("compact panel can represent live-rate stream start failure without usage fallback", () => {
  const snapshot = floatingSnapshotForLiveRate(
    liveRateStreamStartFailureSnapshot("stream transport failed"),
    null,
  );

  assert.equal(snapshot.tokensPerSecond, 0);
  assert.equal(snapshot.liveRateStatusKind, "failure");
  assert.equal(snapshot.liveRateStatusLabel, "实时速率降级");
  assert.equal(snapshot.totalTokensLabel, "总 待读取");
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

import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import {
  changedLiveRateDisplayBucket,
  displayRawRate,
  formatLiveRateValue,
  liveRateDisplayBucket,
  rateFillScale,
  smoothLiveRateSnapshot,
  smoothLiveRateValue,
} from "./rateDisplay.ts";

function snapshot(overrides = {}) {
  return {
    scopeLabel: "全会话",
    threadTitle: "正在汇总",
    selectedThreadId: null,
    selectedThreadTitle: "选择会话",
    selectedTokensPerSecond: 0,
    tokensPerSecond: 0,
    totalTokens: 0,
    totalTokensToday: 0,
    requestsToday: 0,
    maxTokensPerSecond: 200,
    preciseEnabled: false,
    unreadSummary: {
      active: false,
      count: 0,
      label: "无",
      detail: "无",
      source: "test",
    },
    warnings: [],
    ...overrides,
  };
}

test("rate fill uses a transform-friendly 0-1 scale with a small visible floor", () => {
  assert.equal(rateFillScale(0, 200), 0.03);
  assert.equal(rateFillScale(1, 200), 0.03);
  assert.equal(rateFillScale(40, 200), 0.2);
  assert.equal(rateFillScale(999, 200), 1);
});

test("live rate display matches Swift EMA from the idle floor", () => {
  assert.equal(smoothLiveRateValue(10, 0.01), 0);
  assert.equal(Number(smoothLiveRateValue(0, 40).toFixed(1)), 11.2);
  assert.equal(smoothLiveRateValue(10, 40), 18.4);
  assert.equal(Number(smoothLiveRateValue(40, 10).toFixed(1)), 34.6);

  const smoothed = smoothLiveRateSnapshot(
    snapshot({ tokensPerSecond: 40, selectedTokensPerSecond: 5 }),
    snapshot({ tokensPerSecond: 10, selectedTokensPerSecond: 1 }),
  );
  assert.equal(Number(smoothed.tokensPerSecond.toFixed(1)), 18.4);
  assert.equal(Number(smoothed.selectedTokensPerSecond.toFixed(2)), 2.12);
});

test("selected session display is capped without capping global rate", () => {
  assert.equal(displayRawRate(220, "allSessions"), 220);
  assert.equal(displayRawRate(220, "selectedSession"), 80);
  assert.equal(displayRawRate(-1, "selectedSession"), 0);

  const smoothed = smoothLiveRateSnapshot(
    snapshot({ tokensPerSecond: 220, selectedTokensPerSecond: 220 }),
    snapshot({ tokensPerSecond: 0, selectedTokensPerSecond: 0 }),
  );
  assert.equal(Number(smoothed.tokensPerSecond.toFixed(1)), 61.6);
  assert.equal(Number(smoothed.selectedTokensPerSecond.toFixed(1)), 22.4);
});

test("live rate display buckets match visible precision", () => {
  assert.equal(formatLiveRateValue(9.94), "9.9");
  assert.equal(formatLiveRateValue(10.1), "10.1");
  assert.equal(formatLiveRateValue(42.4), "42.4");
  assert.equal(formatLiveRateValue(80), "80.0");

  const first = liveRateDisplayBucket(snapshot({ tokensPerSecond: 42.1 }));
  const second = liveRateDisplayBucket(snapshot({ tokensPerSecond: 42.4 }));
  const third = liveRateDisplayBucket(snapshot({ tokensPerSecond: 42.6 }));
  assert.notEqual(first, second);
  assert.notEqual(second, third);
});

test("live rate display buckets include warning identity and message", () => {
  const first = liveRateDisplayBucket(snapshot({
    warnings: [{ source: "live_rate_stream", message: "启动失败 A" }],
  }));
  const second = liveRateDisplayBucket(snapshot({
    warnings: [{ source: "live_rate_stream", message: "启动失败 B" }],
  }));

  assert.notEqual(first, second);
});

test("unchanged visible live-rate buckets do not request another surface render", () => {
  const first = snapshot({ tokensPerSecond: 42.14 });
  const bucket = changedLiveRateDisplayBucket("", first);

  assert.equal(typeof bucket, "string");
  assert.equal(changedLiveRateDisplayBucket(bucket, snapshot({ tokensPerSecond: 42.13 })), null);
  assert.notEqual(
    changedLiveRateDisplayBucket(bucket, snapshot({ tokensPerSecond: 42.26 })),
    null,
  );
});

test("rate bars use shared transform fill styles instead of width animation", async () => {
  const meter = await readFile(new URL("./LiveRateMeter.tsx", import.meta.url), "utf8");
  const floating = await readFile(new URL("../../floating/FloatingPanelPreview.tsx", import.meta.url), "utf8");
  const status = await readFile(new URL("../../status/StatusPanelApp.tsx", import.meta.url), "utf8");
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");

  for (const source of [meter, floating, status]) {
    assert.equal(source.includes("rateFillStyle("), true);
    assert.equal(source.includes("formatLiveRateValue("), true);
    assert.equal(source.includes('style={{ width:'), false);
  }
  assert.match(css, /\.rate-fill\s*{[\s\S]*?transform-origin: left center;[\s\S]*?transition: transform 200ms ease-out;/);
  assert.match(css, /\.rate-fill\s*{[\s\S]*?transform: scaleX\(var\(--rate-fill-scale, 0\)\);/);
  const floatingTrackBlock = css.slice(
    css.indexOf(".floating-rate-track i {"),
    css.indexOf(".floating-close-button {"),
  );
  assert.doesNotMatch(floatingTrackBlock, /transition: width/);
});

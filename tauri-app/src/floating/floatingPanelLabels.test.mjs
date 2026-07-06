import assert from "node:assert/strict";
import test from "node:test";
import {
  floatingRateBarStatusText,
  floatingStandaloneStatusText,
} from "./floatingPanelLabels.ts";

function snapshot(overrides = {}) {
  return {
    trendLabel: "慢一点(余量低8%)",
    resetCreditLabel: " · 旧兜底",
    resetCreditRateBarLabel: " · 1卡 · 6h",
    resetCreditStandaloneLabel: " · 1卡 · 近6h到期",
    ...overrides,
  };
}

test("floating status helpers keep rate-bar and standalone reset-card suffixes separate", () => {
  const sample = snapshot();

  assert.equal(floatingRateBarStatusText(sample), "慢一点(余量低8%) · 1卡 · 6h");
  assert.equal(floatingStandaloneStatusText(sample), "慢一点(余量低8%) · 1卡 · 近6h到期");
});

test("floating status helpers prioritize compact live-rate degraded or preparation state", () => {
  const sample = snapshot({
    liveRateStatusKind: "pending",
    liveRateStatusLabel: "准备中，请稍后",
  });

  assert.equal(floatingRateBarStatusText(sample), "准备中，请稍后 · 1卡 · 6h");
  assert.equal(floatingStandaloneStatusText(sample), "准备中，请稍后 · 1卡 · 近6h到期");
});

test("floating status helpers fall back safely without leaking placeholders", () => {
  const legacy = snapshot({
    trendLabel: "",
    resetCreditLabel: " · 1卡",
    resetCreditRateBarLabel: undefined,
    resetCreditStandaloneLabel: undefined,
  });
  const pending = snapshot({
    trendLabel: "",
    resetCreditLabel: "",
    resetCreditRateBarLabel: "",
    resetCreditStandaloneLabel: "",
  });

  assert.equal(floatingRateBarStatusText(legacy), " · 1卡");
  assert.equal(floatingStandaloneStatusText(legacy), "节奏待读取 · 1卡");
  assert.equal(floatingStandaloneStatusText(pending), "节奏待读取");
  assert.equal(floatingRateBarStatusText(pending).includes("卡--"), false);
  assert.equal(floatingStandaloneStatusText(pending).includes("卡--"), false);
});

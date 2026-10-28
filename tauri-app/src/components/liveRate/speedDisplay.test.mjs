import assert from "node:assert/strict";
import test from "node:test";
import { projectSpeedDisplay, EMPTY_AGENT_SPEED_DISPLAY, validSpeedColor, invalidateSpeedColors, writeSpeedColor } from "./speedDisplay.ts";
import { modelUsageColor } from "../modelUsagePresentation.ts";
import { SpeedDisplayHistory } from "./speedDisplayHistory.ts";

const preferences = { mode: "agentSpeed", grouping: "client" };
const base = { tokensPerSecond: 40, modelRates: [{ model: "gpt-6-astra", tokensPerSecond: 40 }], totalTokens: 999 };
const now = 1800000000000;
const incoming = { available: true, updatedAtMs: now, status: "active", tokensPerSecond: 100,
  modelRates: [{ model: "claude-opus-5", tokensPerSecond: 60 }, { model: "deepseek-v4-flash", tokensPerSecond: 40 }],
  clientRates: [{ model: "client:claudeCode", tokensPerSecond: 60 }, { model: "client:deepseek", tokensPerSecond: 40 }] };

test("algorithm and color grouping are independent and cannot mutate accounting or source input", () => {
  const result = projectSpeedDisplay(base, preferences, incoming, true, now);
  assert.equal(result.tokensPerSecond, 100);
  assert.deepEqual(result.modelRates, incoming.modelRates);
  assert.deepEqual(result.colorRates, incoming.clientRates);
  assert.equal(result.totalTokens, 999);
  assert.equal(base.tokensPerSecond, 40);
  assert.equal(incoming.tokensPerSecond, 100);
  assert.deepEqual(projectSpeedDisplay(base, { ...preferences, grouping: "model" }, incoming, true, now).colorRates, incoming.modelRates);
  assert.equal(projectSpeedDisplay(base, { mode: "activity", grouping: "client" }, incoming, true, now).tokensPerSecond, 40);
});
test("stale helper, disable, error and empty sources immediately show zero", () => {
  assert.equal(projectSpeedDisplay(base, preferences, incoming, true, now + 3001).tokensPerSecond, 0);
  assert.equal(projectSpeedDisplay(base, preferences, incoming, false, now).tokensPerSecond, 0);
  assert.equal(projectSpeedDisplay(base, preferences, EMPTY_AGENT_SPEED_DISPLAY, true, now).tokensPerSecond, 0);
  const result = projectSpeedDisplay(base, preferences, { ...incoming, modelRates: [], clientRates: [] }, true, now);
  assert.equal(result.tokensPerSecond, 0); assert.deepEqual(result.colorRates, []);
});
test("invalid rates and colors cannot enter a display", () => {
  const result = projectSpeedDisplay(base, preferences, { ...incoming, modelRates: [{ model: "x", tokensPerSecond: Infinity }] }, true, now);
  assert.equal(result.tokensPerSecond, 0);
  assert.ok(validSpeedColor("#d4512c")); assert.ok(!validSpeedColor("red")); assert.ok(!validSpeedColor("#000000;display:none"));
});
test("five-second display history averages time, retains zero and leaves long gaps", () => {
  const history = new SpeedDisplayHistory();
  for (let at = 0; at <= 5; at++) history.record(at, [{ model: "m", tokensPerSecond: at < 3 ? 100 : 50 }]);
  assert.equal(history.points(5)[0].modelRates[0].tokensPerSecond, 80);
  history.record(100, []); history.record(101, []);
  assert.ok(history.points(101).every(p => p.start <= 5 || p.start >= 100));
});

test("model and client color overrides are persistent and resettable", () => {
  const old = globalThis.window, store = new Map();
  globalThis.window = { localStorage: { getItem: key => store.get(key) ?? null, setItem: (key, value) => store.set(key, value) }, dispatchEvent() {} };
  try {
    invalidateSpeedColors(); writeSpeedColor("gpt-6.1-sol", "#abcdef");
    assert.equal(modelUsageColor("gpt-6.1-sol"), "#abcdef");
    writeSpeedColor("client:deepseek", "#123456");
    assert.equal(modelUsageColor("client:deepseek"), "#123456");
    invalidateSpeedColors(); assert.equal(modelUsageColor("gpt-6.1-sol"), "#abcdef");
    writeSpeedColor("gpt-6.1-sol", null); assert.equal(modelUsageColor("gpt-6.1-sol"), "#df7055");
  } finally { globalThis.window = old; invalidateSpeedColors(); }
});

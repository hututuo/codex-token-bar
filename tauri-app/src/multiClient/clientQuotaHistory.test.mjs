import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

const now = 1_800_000_000;
const point = startUnix => ({ startUnix, label: "", tokens: 17, calls: 1, inputTokens: 10,
  outputTokens: 7, cachedInputTokens: 0, cacheHitRate: null,
  fiveHourRemainingPercent: 0.12, sevenDayRemainingPercent: 0.34 });

test("each Antigravity pool uses its own windows and preserves fractional and zero balances", async () => withSsrModules(async load => {
  const { applyClientQuotaHistory, resolveQuotaChartSource } = await load("/src/multiClient/clientQuotaHistory.ts");
  const reading = { client: "antigravity", history: [
    { windowId: "gemini-5h", observedAt: now, usedPercent: 99.7554, resetsAt: now + 300 },
    { windowId: "gemini-weekly", observedAt: now, usedPercent: 100, resetsAt: now + 300 },
    { windowId: "3p-5h", observedAt: now, usedPercent: 0, resetsAt: now + 300 },
  ] };
  const gemini = resolveQuotaChartSource("antigravity:gemini", ["antigravity"]);
  const third = resolveQuotaChartSource("antigravity:3p", ["antigravity"]);
  const values = applyClientQuotaHistory([point(now), point(now + 300)], reading, gemini, 300, now + 600);
  assert.ok(Math.abs(values[0].fiveHourRemainingPercent - 0.002446) < 0.00000001);
  assert.equal(values[0].sevenDayRemainingPercent, 0);
  assert.equal(values[1].fiveHourRemainingPercent, null);
  assert.equal(values[0].tokens, 17);
  assert.equal(applyClientQuotaHistory([point(now)], reading, third, 300, now + 1)[0].fiveHourRemainingPercent, 1);
  assert.equal(applyClientQuotaHistory([point(now)], reading, third, 300, now + 1)[0].sevenDayRemainingPercent, null);
}));

test("idle disk cache is positioned at its observation and gaps do not borrow Codex quota", async () => withSsrModules(async load => {
  const { applyClientQuotaHistory, resolveQuotaChartSource } = await load("/src/multiClient/clientQuotaHistory.ts");
  const source = resolveQuotaChartSource("codex", ["claudeDesktop"]);
  assert.equal(source.client, "claudeDesktop");
  const reading = { client: "claudeDesktop", history: [
    { windowId: "5h", observedAt: now, usedPercent: 12.5, resetsAt: null },
    { windowId: "7d", observedAt: now + 4000, usedPercent: 99, resetsAt: null },
    { windowId: "7d", observedAt: now, usedPercent: Number.NaN, resetsAt: null },
  ] };
  const values = applyClientQuotaHistory([point(now), point(now + 1800)], reading, source, 300, now + 3600);
  assert.equal(values[0].fiveHourRemainingPercent, 0.875);
  assert.equal(values[1].fiveHourRemainingPercent, null);
  assert.equal(values[0].sevenDayRemainingPercent, null);
  assert.equal(values[1].sevenDayRemainingPercent, null);
  assert.equal(resolveQuotaChartSource("codex", ["deepseek"]), undefined);
}));

test("quota-only clients retain a 24-hour axis without transcript opt-in", async () => withSsrModules(async load => {
  const { applyClientQuotaHistory, resolveQuotaChartSource } = await load("/src/multiClient/clientQuotaHistory.ts");
  const source = resolveQuotaChartSource("claudeDesktop", ["claudeDesktop"]);
  const values = applyClientQuotaHistory([], { client: "claudeDesktop", history: [
    { windowId: "5h", observedAt: now - 300, usedPercent: 10.25, resetsAt: null },
  ] }, source, 300, now);
  assert.equal(values.length, 288);
  assert.ok(values.some(value => value.fiveHourRemainingPercent === 0.8975));
}));

test("imported Desktop history remains selectable without mixing cache sources", async () => withSsrModules(async load => {
  const { applyClientQuotaHistory, quotaChartSources, resolveQuotaChartSource } = await load("/src/multiClient/clientQuotaHistory.ts");
  const reading = { client: "claudeDesktop", source: "http-cache", history: [
    { windowId: "5h", observedAt: now, usedPercent: 20, resetsAt: null, source: "http-cache" },
    { windowId: "5h", observedAt: now - 300, usedPercent: 60, resetsAt: null, source: "local-desktop-history" },
  ] };
  const options = quotaChartSources(["claudeDesktop"], [reading]);
  assert.equal(options.length, 2);
  const older = resolveQuotaChartSource(options[1].id, ["claudeDesktop"], [reading]);
  const values = applyClientQuotaHistory([point(now - 300), point(now)], reading, older, 300, now + 1);
  assert.equal(values[0].fiveHourRemainingPercent, 0.4);
  assert.equal(values[1].fiveHourRemainingPercent, 0.4);
}));

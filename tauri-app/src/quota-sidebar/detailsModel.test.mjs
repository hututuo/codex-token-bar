import assert from "node:assert/strict";
import test from "node:test";
import { sidebarTodayModels, sidebarLocalTime, sidebarMetricValue } from "./detailsModel.ts";

function row(model, totalTokens, cachedInputTokens = 0) { return { model, breakdown: { inputTokens: 0, cachedInputTokens, outputTokens: 0, totalTokens, calls: 0 } }; }
test("today model shares use all models, aggregate exact names and never add cache twice", () => {
  const values = sidebarTodayModels([row("sol", 40, 30), row("sol", 10, 8), row("astra", 20), row("luna", 15), row(null, 10), row("other", 5)]);
  assert.deepEqual(values.map(v => [v.model, v.tokens, v.percent]), [["sol", 50, 50], ["astra", 20, 20], ["luna", 15, 15], [null, 10, 10]]);
  assert.equal(values.reduce((sum, v) => sum + v.percent, 0), 95);
});
test("empty, zero and invalid model totals never create sample or misleading ratio rows", () => {
  for (const rows of [[], [row("sol", 0)], [row("sol", NaN)], [row("sol", Infinity)], [row("sol", -1)], [row("sol", 20), row("other", NaN)]]) assert.deepEqual(sidebarTodayModels(rows), []);
});
test("local reset formatting preserves unknown text and uses genuine timestamps", () => {
  assert.equal(sidebarLocalTime("时间未知"), "时间未知");
  assert.equal(sidebarLocalTime(""), "重置时间未知");
  const formatted = sidebarLocalTime("2026-09-14T02:29:00.000Z");
  assert.doesNotMatch(formatted, /T|\.000Z/); assert.match(formatted, /14/);
  assert.equal(sidebarLocalTime("ignored", 1789352940), sidebarLocalTime("2026-09-14T02:29:00.000Z"));
  assert.equal(sidebarMetricValue("今 59.1万"), "59.1万");
  assert.equal(sidebarMetricValue("总 待读取"), "待读取");
});

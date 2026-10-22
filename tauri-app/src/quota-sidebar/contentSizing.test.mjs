import assert from "node:assert/strict";
import test from "node:test";
import { createSidebarHeightBudget } from "./contentSizing.ts";
import { createSidebarNativeCoordinator } from "./nativeCoordinator.ts";

test("one TPS row spends existing headroom; a second grows and close rearms", () => {
  const budget = createSidebarHeightBudget();
  assert.equal(budget.update({ contentHeight: 400, speedRowHeight: 40 }, false), 464);
  assert.equal(budget.update(undefined, true), 464);
  assert.equal(budget.update({ contentHeight: 440, speedRowHeight: 40 }, true), 464);
  assert.equal(budget.update({ contentHeight: 480, speedRowHeight: 40 }, true), 504);
  assert.equal(budget.update({ contentHeight: 400, speedRowHeight: 40 }, true), 504);
  assert.equal(budget.update(undefined, false), 464);
});
test("measurement rejects nonfinite sizes and rounds fractional CSS pixels", () => {
  const budget = createSidebarHeightBudget();
  assert.equal(budget.update({ contentHeight: NaN, speedRowHeight: Infinity }, true), undefined);
  assert.equal(budget.update({ contentHeight: 400.2, speedRowHeight: 38.2 }, true), 464);
  assert.equal(budget.update({ contentHeight: -10, speedRowHeight: -20 }, true), 464);
});
test("native requests deduplicate equal budgets but animate a changed target", async () => {
  const heights = [];
  const coordinator = createSidebarNativeCoordinator(async (_mode, _five, _refresh, _id, height) => heights.push(height), () => {});
  coordinator.update("hover", false, 464); coordinator.setEnabled(true);
  await new Promise(resolve => setImmediate(resolve));
  coordinator.update("hover", false, 464);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(heights, [464]);
  coordinator.update("hover", false, 504);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(heights, [464, 504]);
  coordinator.update("hover", false, 10000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(heights.at(-1), 4096);
});

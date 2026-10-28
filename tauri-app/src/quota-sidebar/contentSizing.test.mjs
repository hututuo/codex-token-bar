import assert from "node:assert/strict";
import test from "node:test";
import { createSidebarHeightBudget } from "./contentSizing.ts";
import { createSidebarNativeCoordinator } from "./nativeCoordinator.ts";

test("height follows intrinsic content growth and shrinkage while expanded", () => {
  const budget = createSidebarHeightBudget();
  assert.equal(budget.update({ contentHeight: 400, speedRowHeight: 40 }, false), 424);
  assert.equal(budget.update(undefined, true), 424);
  assert.equal(budget.update({ contentHeight: 440, speedRowHeight: 40 }, true), 464);
  assert.equal(budget.update({ contentHeight: 480, speedRowHeight: 40 }, true), 504);
  assert.equal(budget.update({ contentHeight: 400, speedRowHeight: 40 }, true), 424);
  assert.equal(budget.update({ contentHeight: 520, speedRowHeight: 40 }, true), 544);
});
test("minimum height applies to small content without preserving a previous high-water", () => {
  const budget = createSidebarHeightBudget();
  assert.equal(budget.update({ contentHeight: 600, speedRowHeight: 40 }, true), 624);
  assert.equal(budget.update({ contentHeight: 400, speedRowHeight: 40 }, true), 424);
  assert.equal(budget.update({ contentHeight: 60, speedRowHeight: 0 }, true), 90);
});
test("measurement rejects nonfinite sizes, retains the last valid value, and rounds CSS pixels", () => {
  const budget = createSidebarHeightBudget();
  assert.equal(budget.update({ contentHeight: NaN, speedRowHeight: Infinity }, true), undefined);
  assert.equal(budget.update({ contentHeight: 400.2, speedRowHeight: 38.2 }, true), 425);
  assert.equal(budget.update({ contentHeight: Infinity, speedRowHeight: NaN }, true), 425);
  assert.equal(budget.update({ contentHeight: -10, speedRowHeight: -20 }, true), 425);
});
test("native requests deduplicate equal budgets but animate a changed target", async () => {
  const heights = [];
  const coordinator = createSidebarNativeCoordinator(async (_mode, _five, _refresh, _id, height) => heights.push(height), () => {});
  coordinator.update("hover", false, 424); coordinator.setEnabled(true);
  await new Promise(resolve => setImmediate(resolve));
  coordinator.update("hover", false, 424);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(heights, [424]);
  coordinator.update("hover", false, 464);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(heights, [424, 464]);
  coordinator.update("hover", false, 12);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(heights.at(-1), 90);
  coordinator.update("hover", false, 10000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(heights.at(-1), 4096);
});

test("conditional content disappearance shrinks while open without rebasing", () => {
  const budget = createSidebarHeightBudget();
  assert.equal(budget.update({ contentHeight: 600, speedRowHeight: 40 }, true), 624);
  assert.equal(budget.update({ contentHeight: 200, speedRowHeight: 0 }, true), 224);
  assert.equal(budget.update({ contentHeight: 60, speedRowHeight: 0 }, true), 90);
});

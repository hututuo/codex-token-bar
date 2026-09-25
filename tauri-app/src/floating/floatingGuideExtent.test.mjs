import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { floatingGuideRequiredHeight } from "./floatingGuideExtent.ts";

test("custom row layouts include the real guide footer below the main panel", () => {
  // Offscreen WebKit: a valid unpaired/reordered 180px panel puts the
  // production running-model instruction card at y=187 with height=123.
  assert.equal(floatingGuideRequiredHeight(0, [180, 147, 310], 1), 316);
  assert.ok(floatingGuideRequiredHeight(0, [180, 147, 310], 1) > 284);
});
test("guide extent is relative to the host and stays in CSS pixels at every UI scale", () => {
  for (const scale of [0.9, 1, 1.25, 1.38]) {
    assert.equal(floatingGuideRequiredHeight(40, [40 + 310 * scale], scale), Math.ceil(316 * scale));
  }
  assert.equal(floatingGuideRequiredHeight(0, [], 1), 0);
  assert.equal(floatingGuideRequiredHeight(0, [Number.NaN, 200], 1), 206);
});
test("guide measurement is scoped to mounted cards and feeds native geometry without idle polling", () => {
  const guide = readFileSync(new URL("./FloatingPagingGuide.tsx", import.meta.url), "utf8");
  const app = readFileSync(new URL("./FloatingWindowApp.tsx", import.meta.url), "utf8");
  assert.match(guide, /new ResizeObserver\(measure\)/);
  assert.match(guide, /observer.disconnect\(\)/);
  assert.doesNotMatch(guide, /setInterval/);
  assert.match(app, /Math.max\(FLOATING_PAGING_GUIDE_HEIGHT \* scale, pagingGuideHeight\)/);
  assert.match(app, /onHeightChange=\{handlePagingGuideHeightChange\}/);
});

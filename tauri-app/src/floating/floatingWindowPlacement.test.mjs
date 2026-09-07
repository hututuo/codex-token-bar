import assert from "node:assert/strict";
import test from "node:test";
import { floatingDockShellMetrics, resolveFloatingDetailsDrawer } from "./floatingWindowPlacement.ts";

test("the taller black shell preserves the card aspect and aligns its corner centers", () => {
  for (const scale of [.84, 1, 1.38]) {
    const width = 258 * scale;
    const mainHeight = 120 * scale;
    const metrics = floatingDockShellMetrics({ width, mainHeight, scale });
    assert.ok(Math.abs(metrics.height - mainHeight - 12 * scale) < 1e-9);
    const visibleWidth = (width - 2) * metrics.contentScale;
    const visibleHeight = mainHeight * metrics.contentScale;
    assert.ok(Math.abs(visibleWidth / visibleHeight - (width - 2) / mainHeight) < 1e-9);
    const insetX = (width - visibleWidth) / 2;
    const insetY = (metrics.height - visibleHeight) / 2;
    assert.ok(insetY >= 6 * scale);
    assert.ok(Math.abs(metrics.radiusX - insetX - (metrics.radiusY - insetY)) < 1e-9);
    assert.ok(Math.abs(metrics.contentOffsetY + metrics.paddingY * metrics.contentScale - insetY) < 1e-9);
  }
});

const workArea = { x: 0, y: 24, width: 1200, height: 776 };
test("right-edge details grow below without widening or moving the main card", () => {
  const base = { x: 892, y: 160, width: 308, height: 120 };
  const result = resolveFloatingDetailsDrawer({ base, workArea, detailsHeight: 180 });
  assert.equal(result.placement, "below");
  assert.deepEqual(result.frame, { ...base, height: 312 });
  assert.equal(result.surfaceOffsetY, 0);
});
test("bottom-edge details grow above and preserve the original main card position", () => {
  const base = { x: 892, y: 680, width: 308, height: 120 };
  const result = resolveFloatingDetailsDrawer({ base, workArea, detailsHeight: 180 });
  assert.equal(result.placement, "above");
  assert.equal(result.frame.x, base.x);
  assert.equal(result.frame.width, base.width);
  assert.equal(result.frame.y + result.surfaceOffsetY, base.y);
  assert.equal(result.frame.y + result.frame.height, 800);
});
test("long details cap to the available side and remain inside a short display", () => {
  const base = { x: 100, y: 140, width: 308, height: 120 };
  const area = { x: 0, y: 0, width: 800, height: 400 };
  const result = resolveFloatingDetailsDrawer({ base, workArea: area, detailsHeight: 1000 });
  assert.equal(result.frame.width, 308);
  assert.ok(result.frame.y >= 0 && result.frame.y + result.frame.height <= 400);
  assert.ok(result.detailsHeight < 1000);
  assert.equal(result.frame.y + result.surfaceOffsetY, base.y);
});
test("negative display origins and physical scaling choose the same vertical geometry", () => {
  const base = { x: -1200, y: -200, width: 308, height: 120 };
  const area = { x: -1200, y: -800, width: 1200, height: 800 };
  const a = resolveFloatingDetailsDrawer({ base, workArea: area, detailsHeight: 180 });
  const doubled = rect => Object.fromEntries(Object.entries(rect).map(([k,v]) => [k, v * 2]));
  const b = resolveFloatingDetailsDrawer({ base: doubled(base), workArea: doubled(area), detailsHeight: 360, gap: 16, inset: 8, minimumDetailsHeight: 192 });
  assert.equal(a.placement, "above");
  assert.equal(b.placement, a.placement);
  assert.deepEqual(b.frame, doubled(a.frame));
});

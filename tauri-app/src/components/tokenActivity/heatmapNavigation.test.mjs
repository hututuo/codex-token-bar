import assert from "node:assert/strict";
import test from "node:test";

import {
  heatmapKeyboardAction,
  resolveHeatmapFocusDate,
  selectHeatmapDate,
} from "./heatmapNavigation.ts";

test("column-major arrow navigation moves by one day vertically and seven horizontally", () => {
  assert.deepEqual(heatmapKeyboardAction("ArrowUp", 100, 365), { handled: true, index: 99, select: false });
  assert.deepEqual(heatmapKeyboardAction("ArrowDown", 100, 365), { handled: true, index: 101, select: false });
  assert.deepEqual(heatmapKeyboardAction("ArrowLeft", 100, 365), { handled: true, index: 93, select: false });
  assert.deepEqual(heatmapKeyboardAction("ArrowRight", 100, 365), { handled: true, index: 107, select: false });
});

test("navigation clamps at boundaries and supports Home and End", () => {
  assert.equal(heatmapKeyboardAction("ArrowUp", 0, 365).index, 0);
  assert.equal(heatmapKeyboardAction("ArrowLeft", 3, 365).index, 0);
  assert.equal(heatmapKeyboardAction("ArrowDown", 364, 365).index, 364);
  assert.equal(heatmapKeyboardAction("ArrowRight", 360, 365).index, 364);
  assert.equal(heatmapKeyboardAction("Home", 200, 365).index, 0);
  assert.equal(heatmapKeyboardAction("End", 200, 365).index, 364);
  assert.deepEqual(heatmapKeyboardAction("Tab", 200, 365), { handled: false, index: 200, select: false });
});

test("Enter and Space select the focused date without moving it", () => {
  assert.deepEqual(heatmapKeyboardAction("Enter", 42, 365), { handled: true, index: 42, select: true });
  assert.deepEqual(heatmapKeyboardAction(" ", 42, 365), { handled: true, index: 42, select: true });
  const selected = [];

  selectHeatmapDate("2026-07-11", (date) => selected.push(date));
  selectHeatmapDate("2026-07-18", (date) => selected.push(date));

  assert.deepEqual(selected, ["2026-07-11", "2026-07-18"]);
});

test("roving focus defaults to latest and remains valid after data changes", () => {
  const dates = ["2026-07-09", "2026-07-10", "2026-07-11"];

  assert.equal(resolveHeatmapFocusDate(dates, null, null, null), "2026-07-11");
  assert.equal(resolveHeatmapFocusDate(dates, null, "2026-07-10", null), "2026-07-10");
  assert.equal(resolveHeatmapFocusDate(dates, "2026-07-09", "2026-07-10", null), "2026-07-09");
  assert.equal(resolveHeatmapFocusDate(dates.slice(1), "2026-07-09", null, null), "2026-07-11");
});

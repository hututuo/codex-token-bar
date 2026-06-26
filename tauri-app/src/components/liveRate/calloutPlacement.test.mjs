import assert from "node:assert/strict";
import test from "node:test";
import { computeBoundedSettingsCalloutFrame } from "./calloutPlacement.ts";

test("settings callout clamps to the right edge of the window", () => {
  const frame = computeBoundedSettingsCalloutFrame(
    { left: 910, top: 120, bottom: 152 },
    { width: 980, height: 720 },
    { width: 340, estimatedHeight: 320 },
  );

  assert.equal(frame.width, 340);
  assert.equal(frame.left + frame.width <= 980 - 16, true);
  assert.equal(frame.left >= 16, true);
});

test("settings callout flips above the button near the bottom edge", () => {
  const frame = computeBoundedSettingsCalloutFrame(
    { left: 420, top: 620, bottom: 654 },
    { width: 980, height: 720 },
    { width: 340, estimatedHeight: 260 },
  );

  assert.equal(frame.top < 620, true);
  assert.equal(frame.top >= 16, true);
  assert.equal(frame.top + frame.maxHeight <= 720, true);
});

test("settings callout shrinks inside very narrow windows", () => {
  const frame = computeBoundedSettingsCalloutFrame(
    { left: 260, top: 90, bottom: 124 },
    { width: 320, height: 520 },
    { width: 340, estimatedHeight: 300 },
  );

  assert.equal(frame.width, 288);
  assert.equal(frame.left, 16);
  assert.equal(frame.left + frame.width <= 320 - 16, true);
});

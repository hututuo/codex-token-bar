import assert from "node:assert/strict";
import test from "node:test";

import {
  DEFAULT_STATUS_METRIC_ORDER,
  DEFAULT_STATUS_SUMMARY_ORDER,
  sanitizeDisplaySurfaces,
  sanitizeStatusMetricLabelStyle,
  sanitizeStatusMetricOrder,
  sanitizeStatusSummaryOrder,
} from "./displaySettings.ts";

test("missing status metric order migrates to the compact default", () => {
  const settings = sanitizeDisplaySurfaces({
    floatingWindowEnabled: true,
    liveRateEnabled: true,
    statusTrayLiveTextEnabled: true,
  });

  assert.deepEqual(settings.statusMetricOrder, DEFAULT_STATUS_METRIC_ORDER);
  assert.notEqual(settings.statusMetricOrder, DEFAULT_STATUS_METRIC_ORDER);
  assert.equal(settings.statusMetricLabelStyle, "compact");
  assert.deepEqual(settings.statusSummaryOrder, DEFAULT_STATUS_SUMMARY_ORDER);
});

test("status tray live text is off by default for the experimental surface", () => {
  const settings = sanitizeDisplaySurfaces({});

  assert.equal(settings.statusTrayLiveTextEnabled, false);
});

test("status metric order removes unsupported and duplicate raw ids while preserving order", () => {
  assert.deepEqual(
    sanitizeStatusMetricOrder([
      "iq",
      "iq",
      "unknown",
      "running",
      42,
      "rate",
      "running",
    ]),
    ["iq", "running", "rate"],
  );
});

test("status metric order preserves an explicit empty selection", () => {
  assert.deepEqual(sanitizeStatusMetricOrder([]), []);
});

test("status label style accepts three canonical values and defaults invalid input", () => {
  assert.equal(sanitizeStatusMetricLabelStyle("full"), "full");
  assert.equal(sanitizeStatusMetricLabelStyle("compact"), "compact");
  assert.equal(sanitizeStatusMetricLabelStyle("hidden"), "hidden");
  assert.equal(sanitizeStatusMetricLabelStyle("wide"), "compact");
});

test("status summary order sanitizes raw ids and preserves an explicit empty selection", () => {
  assert.deepEqual(
    sanitizeStatusSummaryOrder(["radar", "overview", "radar", "unknown", "quota"]),
    ["radar", "overview", "quota"],
  );
  assert.deepEqual(sanitizeStatusSummaryOrder([]), []);
});

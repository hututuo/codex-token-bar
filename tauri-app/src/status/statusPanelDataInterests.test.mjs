import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  buildStatusPanelDataInterests,
  statusPanelBackgroundActive,
  statusPanelSummaryVisible,
} from "./statusPanelDataInterests.ts";

test("hidden status owner runs only when live metrics are enabled and selected", () => {
  assert.equal(statusPanelBackgroundActive(true, ["rate"]), true);
  assert.equal(statusPanelBackgroundActive(true, []), false);
  assert.equal(statusPanelBackgroundActive(false, ["rate"]), false);
});

test("a visible Windows compact strip does not activate expanded summary readers", () => {
  assert.equal(statusPanelSummaryVisible(true, true), false);
  assert.equal(statusPanelSummaryVisible(true, false), true);
  assert.equal(statusPanelSummaryVisible(false, false), false);
});

test("hidden status owner reads only data required by compact metrics", () => {
  assert.deepEqual(buildStatusPanelDataInterests({
    liveRateEnabled: true,
    metricOrder: ["rate", "fiveHour", "running", "iq"],
    panelVisible: false,
    statusMetricsEnabled: true,
    summaryOrder: ["usage", "crowdRadar"],
  }), {
    liveRate: true,
    snapshot: true,
    quota: true,
    running: true,
    radar: true,
    crowdRadar: false,
  });

  assert.deepEqual(buildStatusPanelDataInterests({
    liveRateEnabled: true,
    metricOrder: [],
    panelVisible: false,
    statusMetricsEnabled: true,
    summaryOrder: ["overview", "radar", "crowdRadar"],
  }), {
    liveRate: false,
    snapshot: false,
    quota: false,
    running: false,
    radar: false,
    crowdRadar: false,
  });
});

test("visible summary enables only its configured data modules", () => {
  assert.deepEqual(buildStatusPanelDataInterests({
    liveRateEnabled: true,
    metricOrder: [],
    panelVisible: true,
    statusMetricsEnabled: false,
    summaryOrder: ["usage", "radar", "crowdRadar"],
  }), {
    liveRate: false,
    snapshot: true,
    quota: false,
    running: false,
    radar: true,
    crowdRadar: true,
  });
});

test("disabled live rate skips rate polling but keeps independently selected unread available", () => {
  assert.deepEqual(buildStatusPanelDataInterests({
    liveRateEnabled: false,
    metricOrder: ["rate", "unread"],
    panelVisible: false,
    statusMetricsEnabled: true,
    summaryOrder: ["overview", "unread"],
  }), {
    liveRate: false,
    snapshot: true,
    quota: false,
    running: false,
    radar: false,
    crowdRadar: false,
  });

  assert.equal(buildStatusPanelDataInterests({
    liveRateEnabled: false,
    metricOrder: ["rate"],
    panelVisible: false,
    statusMetricsEnabled: true,
    summaryOrder: [],
  }).snapshot, false);
});

test("compact data hook gates snapshot quota and running readers independently", async () => {
  const source = await readFile(
    new URL("../surfaces/useCompactPanelData.ts", import.meta.url),
    "utf8",
  );

  assert.match(source, /active: sourceActive && snapshotEnabled,/);
  assert.match(source, /active: sourceActive && quotaEnabled,/);
  assert.match(source, /active: sourceActive && runningEnabled,/);
});

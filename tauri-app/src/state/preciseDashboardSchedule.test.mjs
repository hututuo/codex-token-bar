import assert from "node:assert/strict";
import test from "node:test";

import {
  INITIAL_PRECISE_DASHBOARD_DELAY_MS,
  initialPreciseDashboardDeadlineMs,
  preciseDashboardStartDelayMs,
} from "./preciseDashboardSchedule.ts";

test("cold precise scan yields the first render while later refreshes stay immediate", () => {
  const deadline = initialPreciseDashboardDeadlineMs(null, 500);
  assert.equal(deadline, 500 + INITIAL_PRECISE_DASHBOARD_DELAY_MS);
  assert.equal(preciseDashboardStartDelayMs(null, deadline, 500), INITIAL_PRECISE_DASHBOARD_DELAY_MS);
  assert.equal(preciseDashboardStartDelayMs(null, deadline, 1_000), 1_000);
  assert.equal(preciseDashboardStartDelayMs(null, deadline, deadline + 50), 0);
  assert.equal(preciseDashboardStartDelayMs(0, deadline, 500), 0);
  assert.equal(preciseDashboardStartDelayMs(12, deadline, 500), 0);
  assert.ok(INITIAL_PRECISE_DASHBOARD_DELAY_MS >= 1_000);
});

test("rerenders reuse the original cold-start deadline instead of postponing it", () => {
  const firstDeadline = initialPreciseDashboardDeadlineMs(null, 1_000);
  const rerenderDeadline = initialPreciseDashboardDeadlineMs(firstDeadline, 1_700);
  assert.equal(rerenderDeadline, firstDeadline);
  assert.equal(preciseDashboardStartDelayMs(null, rerenderDeadline, 1_700), 800);
});

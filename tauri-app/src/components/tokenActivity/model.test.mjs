import test from "node:test";
import assert from "node:assert/strict";
import { buildCalendarDays } from "./calendar.ts";

test("buildCalendarDays keeps a 365-day window ending at the latest activity date", () => {
  const days = [
    {
      date: "2026-06-20",
      tokens: 120,
      calls: 2,
      cacheHitRate: 0.9,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    },
  ];

  const calendarDays = buildCalendarDays(days);

  assert.equal(calendarDays.length, 365);
  assert.equal(calendarDays.at(-1)?.date, "2026-06-20");
  assert.equal(calendarDays[0]?.date, "2025-06-21");
});

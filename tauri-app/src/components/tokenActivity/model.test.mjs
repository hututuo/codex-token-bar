import test from "node:test";
import assert from "node:assert/strict";
import { buildCalendarDays } from "./calendar.ts";
import { hoverSummary } from "./hoverSummary.ts";

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

test("hoverSummary describes the nearby heatmap day without changing range total", () => {
  const day = {
    date: "2026-06-20",
    tokens: 123456,
    calls: 7,
    cacheHitRate: 0.92,
    fiveHourRemainingPercent: 0.81,
    sevenDayRemainingPercent: 0.64,
  };

  assert.equal(hoverSummary(day, "daily"), "2026-06-20 · 12.3万 tokens · 7 calls");
  assert.equal(hoverSummary(day, "cache"), "2026-06-20 · 命中率 92% · 7 calls");
  assert.equal(hoverSummary(day, "quota"), "2026-06-20 · 7d 64% · 5h 81%");
});

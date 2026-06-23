import type { ActivityDay } from "../../types/dashboard";
import type { MonthMarker } from "./types";

export function buildCalendarDays(days: ActivityDay[]): ActivityDay[] {
  const byDate = new Map(days.map((day) => [day.date, day]));
  const end = latestActivityDate(days) ?? new Date();
  const start = addDays(end, -364);

  return Array.from({ length: 365 }, (_, index) => {
    const date = formatDateKey(addDays(start, index));
    return byDate.get(date) ?? emptyActivityDay(date);
  });
}

export function buildMonthMarkers(days: ActivityDay[]): MonthMarker[] {
  const markers: MonthMarker[] = [];
  let lastMonth = "";

  days.forEach((day, index) => {
    const [, month] = day.date.split("-");
    if (month === undefined || month === lastMonth) {
      return;
    }

    lastMonth = month;
    markers.push({
      column: Math.floor(index / 7) + 1,
      label: `${Number(month)}月`,
    });
  });

  return markers;
}

function latestActivityDate(days: ActivityDay[]): Date | null {
  const sorted = days
    .map((day) => parseDateKey(day.date))
    .filter((date): date is Date => date !== null)
    .sort((a, b) => a.getTime() - b.getTime());

  return sorted.at(-1) ?? null;
}

function emptyActivityDay(date: string): ActivityDay {
  return {
    date,
    tokens: 0,
    calls: 0,
    cacheHitRate: 0,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
  };
}

function parseDateKey(date: string): Date | null {
  const [year, month, day] = date.split("-").map(Number);
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) {
    return null;
  }

  return new Date(year, month - 1, day, 12);
}

function addDays(date: Date, days: number): Date {
  const next = new Date(date);
  next.setDate(next.getDate() + days);
  return next;
}

function formatDateKey(date: Date): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

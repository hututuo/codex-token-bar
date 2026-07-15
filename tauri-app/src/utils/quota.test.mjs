import assert from "node:assert/strict";
import test from "node:test";
import { compactQuotaLabel, expectedRemainingPercentByEvenPace } from "./quota.ts";

function quotaLimit({
  label = "7d",
  remainingPercent = 0.42,
  resetsAt = "07/07",
  resetsAtUnix,
} = {}) {
  return {
    label,
    availability: "measured",
    remainingPercent,
    usedPercent: 1 - remainingPercent,
    resetsAt,
    resetsAtUnix,
  };
}

function localUnix(year, month, day, hour, minute) {
  return Math.floor(new Date(year, month - 1, day, hour, minute, 0).getTime() / 1000);
}

test("compactQuotaLabel shows tomorrow time for 7d reset within 24 hours", () => {
  const now = new Date(2026, 6, 6, 10, 0, 0);
  const label = compactQuotaLabel(
    quotaLimit({
      resetsAt: "07/07",
      resetsAtUnix: localUnix(2026, 7, 7, 9, 30),
    }),
    now,
  );

  assert.equal(label, "7d 42% 明天 09:30");
});

test("compactQuotaLabel shows today time for 7d reset later today", () => {
  const now = new Date(2026, 6, 6, 10, 0, 0);
  const label = compactQuotaLabel(
    quotaLimit({
      resetsAt: "20:15",
      resetsAtUnix: localUnix(2026, 7, 6, 20, 15),
    }),
    now,
  );

  assert.equal(label, "7d 42% 今天 20:15");
});

test("compactQuotaLabel keeps existing 7d date copy outside the 24 hour window", () => {
  const now = new Date(2026, 6, 6, 10, 0, 0);
  const label = compactQuotaLabel(
    quotaLimit({
      resetsAt: "07/08",
      resetsAtUnix: localUnix(2026, 7, 8, 10, 1),
    }),
    now,
  );

  assert.equal(label, "7d 42% 07/08");
});

test("compactQuotaLabel leaves 5h reset labels unchanged", () => {
  const now = new Date(2026, 6, 6, 10, 0, 0);
  const label = compactQuotaLabel(
    quotaLimit({
      label: "5h",
      resetsAt: "14:00",
      resetsAtUnix: localUnix(2026, 7, 6, 14, 0),
    }),
    now,
  );

  assert.equal(label, "5h 42% 14:00");
});

test("expectedRemainingPercentByEvenPace uses each official quota duration", () => {
  const nowUnix = localUnix(2026, 7, 6, 10, 0);

  assert.equal(expectedRemainingPercentByEvenPace(quotaLimit({
    label: "5h",
    resetsAtUnix: nowUnix + 150 * 60,
  }), nowUnix), 50);
  assert.equal(expectedRemainingPercentByEvenPace(quotaLimit({
    label: "7d",
    resetsAtUnix: nowUnix + 3.5 * 24 * 60 * 60,
  }), nowUnix), 50);
  assert.equal(expectedRemainingPercentByEvenPace(quotaLimit({
    label: "7d",
    resetsAtUnix: undefined,
  }), nowUnix), null);
  assert.equal(expectedRemainingPercentByEvenPace(quotaLimit({
    label: "30d",
    resetsAtUnix: nowUnix + 15 * 24 * 60 * 60,
  }), nowUnix), null);
});

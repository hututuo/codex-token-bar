export const CODEX_RADAR_DETAIL_REFRESH_STORAGE_KEY = "codexRadarDetailLastSuccessfulRefreshAt";
export const CODEX_RADAR_DETAIL_ATTEMPT_STORAGE_KEY = "codexRadarDetailLastAttemptedSlotAt";

const MORNING_SLOT_HOUR = 8;
const EVENING_SLOT_HOUR = 18;

export function latestCodexRadarDetailSlot(now: Date): Date {
  const latest = new Date(now);
  latest.setMilliseconds(0);
  latest.setSeconds(0);
  latest.setMinutes(0);

  if (now.getHours() < MORNING_SLOT_HOUR) {
    latest.setDate(latest.getDate() - 1);
    latest.setHours(EVENING_SLOT_HOUR);
    return latest;
  }

  latest.setHours(now.getHours() < EVENING_SLOT_HOUR ? MORNING_SLOT_HOUR : EVENING_SLOT_HOUR);
  return latest;
}

export function millisecondsUntilNextCodexRadarDetailSlot(now: Date): number {
  const next = new Date(now);
  next.setMilliseconds(0);
  next.setSeconds(0);
  next.setMinutes(0);

  if (now.getHours() < MORNING_SLOT_HOUR) {
    next.setHours(MORNING_SLOT_HOUR);
  } else if (now.getHours() < EVENING_SLOT_HOUR) {
    next.setHours(EVENING_SLOT_HOUR);
  } else {
    next.setDate(next.getDate() + 1);
    next.setHours(MORNING_SLOT_HOUR);
  }

  return Math.max(0, next.getTime() - now.getTime());
}

export function shouldRefreshCodexRadarDetail({
  lastAttemptedSlotAt,
  lastSuccessfulRefreshAt,
  mode = "automatic",
  now,
}: {
  lastAttemptedSlotAt?: string | null | undefined;
  lastSuccessfulRefreshAt: string | null | undefined;
  mode?: "automatic" | "manual";
  now: Date;
}): boolean {
  if (mode === "manual") {
    return true;
  }
  const latestSlot = latestCodexRadarDetailSlot(now);
  if (!lastSuccessfulRefreshAt) {
    return !isAtOrAfterSlot(lastAttemptedSlotAt, latestSlot);
  }
  const last = new Date(lastSuccessfulRefreshAt);
  if (!Number.isFinite(last.getTime())) {
    return !isAtOrAfterSlot(lastAttemptedSlotAt, latestSlot);
  }
  return last.getTime() < latestSlot.getTime() && !isAtOrAfterSlot(lastAttemptedSlotAt, latestSlot);
}

function isAtOrAfterSlot(value: string | null | undefined, slot: Date): boolean {
  if (!value) {
    return false;
  }
  const timestamp = new Date(value).getTime();
  return Number.isFinite(timestamp) && timestamp >= slot.getTime();
}

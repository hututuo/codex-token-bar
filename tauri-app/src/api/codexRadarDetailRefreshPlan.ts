export const CODEX_RADAR_DETAIL_REFRESH_STORAGE_KEY = "codexRadarDetailLastSuccessfulRefreshAt";

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
  lastSuccessfulRefreshAt,
  now,
}: {
  lastSuccessfulRefreshAt: string | null | undefined;
  now: Date;
}): boolean {
  if (!lastSuccessfulRefreshAt) {
    return true;
  }
  const last = new Date(lastSuccessfulRefreshAt);
  if (!Number.isFinite(last.getTime())) {
    return true;
  }
  return last.getTime() < latestCodexRadarDetailSlot(now).getTime();
}

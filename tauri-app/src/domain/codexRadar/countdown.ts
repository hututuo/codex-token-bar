export type RadarCountdownListener = (nowMs: number) => void;

const RADAR_COUNTDOWN_MINUTE_MS = 60_000;
const RADAR_COUNTDOWN_SECOND_MS = 1_000;

/**
 * Keeps long countdowns on minute-boundary wakeups and only uses second-level
 * updates for the final minute, when the extra precision is visible.
 */
export function radarCountdownDelayMs(deadlineMs: number, nowMs = Date.now()): number {
  const remainingMs = deadlineMs - nowMs;
  if (remainingMs <= 0) {
    return 0;
  }
  if (remainingMs <= RADAR_COUNTDOWN_MINUTE_MS) {
    return RADAR_COUNTDOWN_SECOND_MS;
  }
  const untilNextMinuteMs = remainingMs % RADAR_COUNTDOWN_MINUTE_MS;
  return Math.max(
    RADAR_COUNTDOWN_SECOND_MS,
    Math.min(RADAR_COUNTDOWN_MINUTE_MS, untilNextMinuteMs || RADAR_COUNTDOWN_MINUTE_MS),
  );
}

/**
 * Keeps a Radar countdown display current without making callers own timer
 * cleanup. The callback is only scheduled while the deadline is still ahead;
 * long windows wake on minute boundaries instead of once per second.
 */
export function subscribeRadarCountdown(
  deadlineMs: number | null,
  listener: RadarCountdownListener,
): () => void {
  let timer: number | null = null;
  let cancelled = false;

  const tick = () => {
    if (cancelled) {
      return;
    }
    const currentMs = Date.now();
    listener(currentMs);
    if (deadlineMs === null) {
      return;
    }
    const delayMs = radarCountdownDelayMs(deadlineMs, currentMs);
    if (delayMs <= 0) {
      timer = null;
      return;
    }
    timer = window.setTimeout(tick, delayMs);
  };

  tick();

  return () => {
    cancelled = true;
    if (timer !== null) {
      window.clearTimeout(timer);
      timer = null;
    }
  };
}

export const INITIAL_PRECISE_DASHBOARD_DELAY_MS = 1_500;

export function initialPreciseDashboardDeadlineMs(
  currentDeadlineMs: number | null,
  nowMs: number,
) {
  return currentDeadlineMs ?? nowMs + INITIAL_PRECISE_DASHBOARD_DELAY_MS;
}

export function preciseDashboardStartDelayMs(
  previousGeneration: number | null,
  initialDeadlineMs: number,
  nowMs: number,
) {
  return previousGeneration === null
    ? Math.max(0, initialDeadlineMs - nowMs)
    : 0;
}

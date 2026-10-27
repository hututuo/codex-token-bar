import type { PreciseDashboardProgress } from "../types/dashboard";

export function samePreciseDashboardProgress(
  left: PreciseDashboardProgress | null,
  right: PreciseDashboardProgress | null,
): boolean {
  if (left === right) return true;
  if (left === null || right === null) return false;

  return Object.is(left.phase, right.phase)
    && Object.is(left.message, right.message)
    && Object.is(left.completed, right.completed)
    && Object.is(left.total, right.total)
    && Object.is(left.fraction, right.fraction)
    && Object.is(left.startedAt, right.startedAt)
    && Object.is(left.updatedAt, right.updatedAt);
}

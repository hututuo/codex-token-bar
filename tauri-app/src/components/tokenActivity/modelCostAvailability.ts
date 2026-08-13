import type { ActivityDay, ModelTokenBreakdown } from "../../types/dashboard";

export function modelCostRowsAvailable(
  rows: ModelTokenBreakdown[] | null | undefined,
  preciseDataFresh: boolean | undefined,
): boolean {
  return preciseDataFresh === true || (rows?.length ?? 0) > 0;
}

export function modelCostProjectionAvailable(
  days: ActivityDay[],
  preciseDataFresh: boolean | undefined,
): boolean {
  return preciseDataFresh === true
    || days.some((day) => (day.modelBreakdowns?.length ?? 0) > 0);
}

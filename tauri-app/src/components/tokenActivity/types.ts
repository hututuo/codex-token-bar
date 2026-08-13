import type { ActivityDay } from "../../types/dashboard";

export type ActivityMode = "daily" | "weekly" | "cumulative" | "model" | "modelCost" | "cache" | "quota";

export interface HeatmapDay {
  day: ActivityDay;
  intensity: number;
}

export interface MonthMarker {
  column: number;
  label: string;
}

export const activityModes: Array<{ id: ActivityMode; label: string }> = [
  { id: "daily", label: "每日" },
  { id: "weekly", label: "每周" },
  { id: "cumulative", label: "累计" },
  { id: "model", label: "模型" },
  { id: "modelCost", label: "费用" },
  { id: "cache", label: "命中率" },
  { id: "quota", label: "额度" },
];

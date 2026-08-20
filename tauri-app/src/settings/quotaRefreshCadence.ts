export const DEFAULT_QUOTA_REFRESH_INTERVAL_MS = 60_000;

export const QUOTA_REFRESH_CADENCE_OPTIONS = [
  { valueMs: 30_000, label: "30 秒" },
  { valueMs: 60_000, label: "1 分钟" },
  { valueMs: 120_000, label: "2 分钟" },
  { valueMs: 180_000, label: "3 分钟" },
  { valueMs: 300_000, label: "5 分钟" },
  { valueMs: 600_000, label: "10 分钟" },
] as const;

const ALLOWED_QUOTA_REFRESH_INTERVALS = new Set<number>(
  QUOTA_REFRESH_CADENCE_OPTIONS.map((option) => option.valueMs),
);

export function sanitizeQuotaRefreshIntervalMs(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return DEFAULT_QUOTA_REFRESH_INTERVAL_MS;
  }

  return ALLOWED_QUOTA_REFRESH_INTERVALS.has(value)
    ? value
    : DEFAULT_QUOTA_REFRESH_INTERVAL_MS;
}

export function quotaRefreshCadenceLabel(value: unknown): string {
  const intervalMs = sanitizeQuotaRefreshIntervalMs(value);
  return QUOTA_REFRESH_CADENCE_OPTIONS.find((option) => option.valueMs === intervalMs)?.label
    ?? "1 分钟";
}

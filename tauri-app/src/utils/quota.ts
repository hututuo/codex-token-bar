import type { AccountQuotaBundle } from "../types/dashboard";

export function compactQuotaLabel(limit: AccountQuotaBundle["quota"]["fiveHour"]): string {
  const percent = Math.round(limit.remainingPercent * 100);
  return `${limit.label} ${percent}% ${limit.resetsAt}`;
}

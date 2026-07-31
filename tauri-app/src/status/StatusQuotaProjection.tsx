import type { QuotaLimit } from "../types/dashboard";
import { compactQuotaLabel } from "../utils/quota";

interface StatusQuotaProjectionProps {
  fiveHour: QuotaLimit;
  sevenDay: QuotaLimit;
}

export function StatusQuotaProjection({ fiveHour, sevenDay }: StatusQuotaProjectionProps) {
  const visibleLimits = [
    ...(fiveHour.availability === "absent" ? [] : [fiveHour]),
    sevenDay,
  ];
  return (
    <div className="status-panel-quota">
      {visibleLimits.map((limit) => <StatusQuotaText key={limit.label} limit={limit} />)}
    </div>
  );
}

function StatusQuotaText({ limit }: { limit: QuotaLimit }) {
  const measured = limit.availability === "measured"
    && typeof limit.remainingPercent === "number"
    && Number.isFinite(limit.remainingPercent);
  return (
    <span role={measured ? undefined : "status"}>
      {compactQuotaLabel(measured ? limit : { ...limit, availability: "unavailable" })}
    </span>
  );
}

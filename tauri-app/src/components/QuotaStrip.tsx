import type { QuotaLimit, QuotaSnapshot } from "../types/dashboard";
import { formatPercent } from "../utils/format";

interface QuotaStripProps {
  snapshot: QuotaSnapshot;
}

function QuotaBar({ quota }: { quota: QuotaLimit }) {
  return (
    <div className="quota-bar">
      <span className="quota-label">{quota.label}</span>
      <div className="quota-track">
        <span style={{ width: `${Math.round(quota.remainingPercent * 100)}%` }} />
      </div>
      <strong>剩 {formatPercent(quota.remainingPercent)}</strong>
      <em>{quota.resetsAt}</em>
    </div>
  );
}

export function QuotaStrip({ snapshot }: QuotaStripProps) {
  return (
    <section className="quota-strip" aria-label="账户额度">
      <div className="quota-plan">
        <span>本地账户额度</span>
        <strong>PRO</strong>
      </div>
      <QuotaBar quota={snapshot.fiveHour} />
      <QuotaBar quota={snapshot.sevenDay} />
      <div className="quota-pace">
        <strong>{snapshot.paceLabel}</strong>
        <span>{snapshot.resetCredit.status}</span>
      </div>
    </section>
  );
}

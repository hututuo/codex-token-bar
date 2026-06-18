import { useState } from "react";
import type { QuotaLimit, QuotaSnapshot, ResetCreditDetail } from "../types/dashboard";
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

function ResetCreditItem({ credit }: { credit: ResetCreditDetail }) {
  return (
    <article className="reset-credit-item">
      <div className="reset-credit-title">
        <strong>{credit.title}</strong>
        <span>{credit.status}</span>
      </div>
      <p>{credit.summary}</p>
      <dl className="reset-credit-fields">
        <div>
          <dt>发放</dt>
          <dd>{credit.issuedAt}</dd>
        </div>
        <div>
          <dt>到期</dt>
          <dd>{credit.expiresAt}</dd>
        </div>
        <div>
          <dt>使用</dt>
          <dd>{credit.redeemedAt}</dd>
        </div>
        <div>
          <dt>来源</dt>
          <dd>{credit.source}</dd>
        </div>
        <div>
          <dt>关联用户</dt>
          <dd>{credit.associatedUser}</dd>
        </div>
        <div>
          <dt>短 ID</dt>
          <dd>{credit.shortId}</dd>
        </div>
      </dl>
    </article>
  );
}

export function QuotaStrip({ snapshot }: QuotaStripProps) {
  const [showResetDetails, setShowResetDetails] = useState(false);
  const credits = snapshot.resetCredit.credits ?? [];

  return (
    <section className="quota-strip" aria-label="账户额度">
      <div className="quota-plan">
        <span>本地账户额度</span>
        <strong>本地读取</strong>
      </div>
      <QuotaBar quota={snapshot.fiveHour} />
      <QuotaBar quota={snapshot.sevenDay} />
      <div className="quota-pace">
        <div className="quota-pace-title">
          <strong>{snapshot.paceLabel}</strong>
          <button
            type="button"
            className="quota-detail-button"
            aria-expanded={showResetDetails}
            onClick={() => setShowResetDetails((value) => !value)}
          >
            重置卡详情
          </button>
        </div>
        <span>{snapshot.resetCredit.status}</span>
      </div>
      {showResetDetails ? (
        <div className="reset-credit-panel">
          <div className="reset-credit-panel-head">
            <strong>重置卡详情</strong>
            <span>
              读到 {credits.length} 条明细，可用 {snapshot.resetCredit.availableCount} 张
            </span>
          </div>
          {credits.length > 0 ? (
            <div className="reset-credit-list">
              {credits.map((credit, index) => (
                <ResetCreditItem credit={credit} key={`${credit.shortId}-${index}`} />
              ))}
            </div>
          ) : (
            <p className="reset-credit-empty">
              没有读到单张重置卡明细；当前接口状态：{snapshot.resetCredit.status}
            </p>
          )}
        </div>
      ) : null}
    </section>
  );
}

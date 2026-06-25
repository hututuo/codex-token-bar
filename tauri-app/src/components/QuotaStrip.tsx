import { memo, useState } from "react";
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
          <dt>类型</dt>
          <dd>{credit.resetType}</dd>
        </div>
        <div>
          <dt>到期</dt>
          <dd>{credit.expiresAt}</dd>
        </div>
        <div>
          <dt>兑换开始</dt>
          <dd>{credit.redeemStartedAt}</dd>
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
          <dt>说明</dt>
          <dd>{credit.detailNote}</dd>
        </div>
        <div>
          <dt>关联用户</dt>
          <dd>{credit.associatedUser}</dd>
        </div>
        <div>
          <dt>头像</dt>
          <dd>{credit.profileImageUrl}</dd>
        </div>
        <div>
          <dt>短 ID</dt>
          <dd>{credit.shortId}</dd>
        </div>
      </dl>
    </article>
  );
}

function QuotaStripView({ snapshot }: QuotaStripProps) {
  const [showResetDetails, setShowResetDetails] = useState(false);
  const credits = snapshot.resetCredit.credits ?? [];

  return (
    <section className={showResetDetails ? "quota-strip quota-strip--details-open" : "quota-strip"} aria-label="账户额度">
      <div className="quota-plan">
        <span>本地账户额度</span>
        <strong>本地读取</strong>
      </div>
      <QuotaBar quota={snapshot.fiveHour} />
      <QuotaBar quota={snapshot.sevenDay} />
      <button
        type="button"
        className="quota-side-card quota-reset-card"
        aria-expanded={showResetDetails}
        onClick={() => setShowResetDetails((value) => !value)}
      >
        <span>重置卡</span>
        <strong>{snapshot.resetCredit.status}</strong>
        <em>
          {snapshot.resetCredit.availableCount} 张可用
          <b aria-hidden="true">{showResetDetails ? "⌃" : "⌄"}</b>
        </em>
      </button>
      <div className="quota-side-card quota-pace">
        <div className="quota-pace-title">
          <strong>{snapshot.paceLabel}</strong>
        </div>
        <span>7d 均速比较</span>
      </div>
      {showResetDetails ? (
        <div className="reset-credit-panel">
          <div className="reset-credit-panel-head">
            <div>
              <strong>重置卡详情</strong>
              <span>
                读到 {credits.length} 条明细，可用 {snapshot.resetCredit.availableCount} 张
              </span>
            </div>
            <button aria-label="关闭重置卡详情" onClick={() => setShowResetDetails(false)} type="button">×</button>
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

export const QuotaStrip = memo(QuotaStripView);

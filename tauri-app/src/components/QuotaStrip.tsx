import { memo, useMemo, useState } from "react";
import type { QuotaLimit, QuotaSnapshot, ResetCreditDetail } from "../types/dashboard";
import { formatPercent } from "../utils/format";
import {
  cardIdentifier,
  nearestResetCreditCompactText,
  prepareResetCreditsForDisplay,
  resetCreditCountText,
  resetCreditPanelSubtitle,
  type ResetCreditDisplayItem,
} from "./quota/resetCredits";

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

function ResetCreditAvatar({ credit }: { credit: ResetCreditDetail }) {
  const avatarUrl =
    credit.profileImageUrl && credit.profileImageUrl !== "未提供" ? credit.profileImageUrl : null;

  return (
    <span className="reset-credit-avatar" aria-hidden="true">
      {avatarUrl ? <img alt="" src={avatarUrl} /> : <b>{credit.associatedUser.slice(0, 1) || "卡"}</b>}
    </span>
  );
}

function ResetCreditItem({
  item,
  index,
  expanded,
  onToggle,
}: {
  item: ResetCreditDisplayItem;
  index: number;
  expanded: boolean;
  onToggle: () => void;
}) {
  const { credit } = item;

  return (
    <article className={expanded ? "reset-credit-item reset-credit-item--expanded" : "reset-credit-item"}>
      <button
        type="button"
        className="reset-credit-summary-row"
        aria-expanded={expanded}
        onClick={onToggle}
      >
        <ResetCreditAvatar credit={credit} />
        <span className="reset-credit-summary-main">
          <strong>{item.compactRemainingText}</strong>
          <span className="reset-credit-progress" aria-hidden="true">
            <i style={{ width: `${Math.round(item.remainingProgress * 100)}%` }} />
          </span>
        </span>
        <em>第 {index + 1} 张</em>
        <b aria-hidden="true">{expanded ? "⌃" : "⌄"}</b>
      </button>
      {expanded ? (
        <dl className="reset-credit-fields">
          <div>
            <dt>原因</dt>
            <dd>{credit.detailNote}</dd>
          </div>
          <div>
            <dt>关联用户</dt>
            <dd>{credit.associatedUser}</dd>
          </div>
          <div>
            <dt>到期时间</dt>
            <dd>{credit.expiresAt}</dd>
          </div>
          <div>
            <dt>剩余时间</dt>
            <dd>{item.detailedRemainingText}</dd>
          </div>
          <div>
            <dt>卡片编号</dt>
            <dd>{cardIdentifier(credit)}</dd>
          </div>
        </dl>
      ) : null}
    </article>
  );
}

function QuotaStripView({ snapshot }: QuotaStripProps) {
  const [showResetDetails, setShowResetDetails] = useState(false);
  const [expandedCredits, setExpandedCredits] = useState<Set<string>>(() => new Set());
  const displayCredits = useMemo(
    () => prepareResetCreditsForDisplay(snapshot.resetCredit.credits ?? []),
    [snapshot.resetCredit.credits],
  );
  const nearestResetCredit = nearestResetCreditCompactText(snapshot.resetCredit);
  const resetCreditSummary = resetCreditCountText(snapshot.resetCredit);

  function toggleCredit(credit: ResetCreditDetail, index: number) {
    const key = `${cardIdentifier(credit)}-${index}`;
    setExpandedCredits((previous) => {
      const next = new Set(previous);
      if (next.has(key)) {
        next.delete(key);
      } else {
        next.add(key);
      }
      return next;
    });
  }

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
        <strong>{resetCreditSummary}</strong>
        <em>
          {snapshot.resetCredit.availableCount} 张可用
          {nearestResetCredit ? <small>{nearestResetCredit}</small> : null}
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
              <span>{resetCreditPanelSubtitle(snapshot.resetCredit, displayCredits)}</span>
            </div>
            <button aria-label="关闭重置卡详情" onClick={() => setShowResetDetails(false)} type="button">×</button>
          </div>
          {displayCredits.length > 0 ? (
            <div className="reset-credit-list">
              {displayCredits.map((item, index) => (
                <ResetCreditItem
                  expanded={expandedCredits.has(`${cardIdentifier(item.credit)}-${index}`)}
                  index={index}
                  item={item}
                  key={`${cardIdentifier(item.credit)}-${index}`}
                  onToggle={() => toggleCredit(item.credit, index)}
                />
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

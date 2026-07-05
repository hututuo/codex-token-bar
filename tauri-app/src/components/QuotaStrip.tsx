import { memo, useMemo, useState } from "react";
import type {
  LocalDataWarning,
  QuotaDiagnostic,
  QuotaLimit,
  QuotaSnapshot,
  ResetCreditDetail,
} from "../types/dashboard";
import { formatPercent } from "../utils/format";
import {
  cardIdentifier,
  resetCreditDetailKey,
  resetCreditPanelModel,
  type ResetCreditDisplayItem,
} from "./quota/resetCredits";
import { quotaReadWarnings } from "./quota/quotaWarnings";

interface QuotaStripProps {
  onRetryQuotaRefresh?: () => void;
  snapshot: QuotaSnapshot;
  diagnostics?: QuotaDiagnostic[];
  warnings?: LocalDataWarning[];
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

function QuotaStripView({ onRetryQuotaRefresh, snapshot, diagnostics = [], warnings = [] }: QuotaStripProps) {
  const [showResetDetails, setShowResetDetails] = useState(false);
  const [expandedCredits, setExpandedCredits] = useState<Set<string>>(() => new Set());
  const resetCreditPanel = useMemo(() => resetCreditPanelModel(snapshot.resetCredit), [snapshot.resetCredit]);
  const quotaWarnings = useMemo(() => quotaReadWarnings(warnings, diagnostics), [diagnostics, warnings]);

  function toggleCredit(credit: ResetCreditDetail, index: number) {
    const key = resetCreditDetailKey(credit, index);
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
        <strong>{resetCreditPanel.countText}</strong>
        <em>
          {resetCreditPanel.availableText}
          {resetCreditPanel.nearestText ? <small>{resetCreditPanel.nearestText}</small> : null}
          <b aria-hidden="true">{showResetDetails ? "⌃" : "⌄"}</b>
        </em>
      </button>
      <div className="quota-side-card quota-pace">
        <div className="quota-pace-title">
          <strong>{snapshot.paceLabel}</strong>
        </div>
        <span>7d 均速比较</span>
      </div>
      {quotaWarnings.length > 0 ? (
        <div className="quota-read-warning" role="status">
          <div className="quota-read-warning-main">
            <strong>读取失败原因</strong>
            <span>{quotaWarnings.join("；")}</span>
          </div>
          {onRetryQuotaRefresh ? (
            <button
              aria-label="只刷新额度"
              className="quota-warning-refresh"
              onClick={onRetryQuotaRefresh}
              type="button"
            >
              刷新
            </button>
          ) : null}
        </div>
      ) : null}
      {showResetDetails ? (
        <div className="reset-credit-panel-layer" role="presentation" onMouseDown={() => setShowResetDetails(false)}>
          <div
            className="reset-credit-panel"
            role="dialog"
            aria-modal="true"
            aria-label="重置卡详情"
            onMouseDown={(event) => event.stopPropagation()}
          >
            <div className="reset-credit-panel-head">
              <div>
                <strong>重置卡详情</strong>
                <span>{resetCreditPanel.subtitle}</span>
              </div>
              <button aria-label="关闭重置卡详情" onClick={() => setShowResetDetails(false)} type="button">×</button>
            </div>
            {resetCreditPanel.displayItems.length > 0 ? (
              <div className="reset-credit-list">
                {resetCreditPanel.displayItems.map((item, index) => (
                  <ResetCreditItem
                    expanded={expandedCredits.has(resetCreditDetailKey(item.credit, index))}
                    index={index}
                    item={item}
                    key={resetCreditDetailKey(item.credit, index)}
                    onToggle={() => toggleCredit(item.credit, index)}
                  />
                ))}
              </div>
            ) : (
              <p className="reset-credit-empty">
                {resetCreditPanel.emptyText}
              </p>
            )}
          </div>
        </div>
      ) : null}
    </section>
  );
}

export const QuotaStrip = memo(QuotaStripView);

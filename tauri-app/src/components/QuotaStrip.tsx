import { memo, useMemo, useState } from "react";
import type {
  LocalDataWarning,
  QuotaDiagnostic,
  QuotaLimit,
  QuotaSnapshot,
  ResetCreditDetail,
} from "../types/dashboard";
import {
  QUOTA_REFRESH_CADENCE_OPTIONS,
  sanitizeQuotaRefreshIntervalMs,
} from "../settings/quotaRefreshCadence";
import { formatPercent } from "../utils/format";
import {
  cardIdentifier,
  resetCreditDetailKey,
  resetCreditPanelModel,
  type ResetCreditDisplayItem,
} from "./quota/resetCredits";
import { quotaReadWarnings } from "./quota/quotaWarnings";

interface QuotaStripProps {
  onQuotaRefreshIntervalChange?: (intervalMs: number) => void | Promise<void>;
  onRetryQuotaRefresh?: () => void;
  quotaRefreshIntervalMs?: number;
  snapshot: QuotaSnapshot;
  diagnostics?: QuotaDiagnostic[];
  warnings?: LocalDataWarning[];
}

function QuotaBar({ quota }: { quota: QuotaLimit }) {
  const remainingPercent = typeof quota.remainingPercent === "number" ? quota.remainingPercent : null;
  const measured = quota.availability === "measured" && remainingPercent !== null;
  const measuredLabel = remainingPercent === null ? "" : formatPercent(remainingPercent);
  const usedPercent = typeof quota.usedPercent === "number"
    ? quota.usedPercent
    : remainingPercent === null ? null : Math.max(0, 1 - remainingPercent);
  const usedLabel = usedPercent === null ? "" : formatPercent(usedPercent);
  return (
    <div
      aria-label={measured
        ? `${quota.label} 剩 ${measuredLabel}，已用 ${usedLabel}，重置 ${quota.resetsAt}`
        : `${quota.label} 额度待读取，重置 ${quota.resetsAt}`}
      className={measured ? "quota-bar" : "quota-bar quota-bar--unavailable"}
    >
      <div className="quota-bar-header">
        <span className="quota-label">{quota.label}</span>
        <em>{quota.resetsAt}</em>
      </div>
      <div className="quota-track" aria-hidden="true">
        {measured && remainingPercent !== null ? (
          <>
            <i className="quota-track-fill" style={{ width: `${Math.round(remainingPercent * 100)}%` }} />
            <span className="quota-track-copy"><b>剩 {measuredLabel}</b><em>已用 {usedLabel}</em></span>
          </>
        ) : <span className="quota-track-pending">待读取</span>}
      </div>
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

function QuotaStripView({
  onQuotaRefreshIntervalChange,
  onRetryQuotaRefresh,
  quotaRefreshIntervalMs,
  snapshot,
  diagnostics = [],
  warnings = [],
}: QuotaStripProps) {
  const [showResetDetails, setShowResetDetails] = useState(false);
  const [expandedCredits, setExpandedCredits] = useState<Set<string>>(() => new Set());
  const resetCreditPanel = useMemo(() => resetCreditPanelModel(snapshot.resetCredit), [snapshot.resetCredit]);
  const quotaWarnings = useMemo(() => quotaReadWarnings(warnings, diagnostics), [diagnostics, warnings]);
  const selectedQuotaRefreshIntervalMs = sanitizeQuotaRefreshIntervalMs(quotaRefreshIntervalMs);

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
        <div className="quota-pace-copy">
          <div className="quota-pace-title">
            <strong>{snapshot.paceLabel}</strong>
          </div>
          <span>7d 均速比较</span>
        </div>
        {onQuotaRefreshIntervalChange ? (
          <label className="quota-refresh-cadence">
            <select
              aria-label="刷新频率"
              onChange={(event) => {
                void onQuotaRefreshIntervalChange(Number(event.currentTarget.value));
              }}
              value={selectedQuotaRefreshIntervalMs}
            >
              {QUOTA_REFRESH_CADENCE_OPTIONS.map((option) => (
                <option key={option.valueMs} value={option.valueMs}>额度刷新 {option.label}</option>
              ))}
            </select>
          </label>
        ) : null}
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

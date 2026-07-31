import { memo, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import type {
  LocalDataWarning,
  QuotaDiagnostic,
  QuotaAttributionIdentity,
  QuotaLimit,
  QuotaSnapshot,
  RecentUsagePoint,
  ResetCreditDetail,
} from "../types/dashboard";
import { useSubscribedCodexRadarSnapshot } from "../api/useSubscribedCodexRadarSnapshot";
import {
  QUOTA_REFRESH_CADENCE_OPTIONS,
  sanitizeQuotaRefreshIntervalMs,
} from "../settings/quotaRefreshCadence";
import { formatPercent, formatTokens } from "../utils/format";
import {
  estimateSharedAccountAttribution,
  quotaValueToPercentagePoints,
  sharedAccountAttributionInputSignature,
  type SharedAccountAttributionResult,
} from "./sharedAccountAttribution/model";
import {
  attributionHighWaterStorageKey,
  completedBucketEndBoundary,
  mergeAttributionBucketHighWater,
  pruneAttributionHighWaterCycles,
  readAttributionHighWaterState,
  writeAttributionHighWater,
  type AttributionBucketMergeResult,
} from "./sharedAccountAttribution/highWater";
import {
  attributionSegmentStorageKey,
  beginAttributionUnsafeEpisodeCutover,
  beginContinuityGapCutover,
  holdAttributionSegmentDuringContinuityGap,
  readAttributionSegmentState,
  readLegacyAttributionResidueState,
  readLegacyAttributionSegmentState,
  retireLegacyAttributionSegments,
  resolveAttributionSegment,
  writeAttributionSegment,
} from "./sharedAccountAttribution/segment";
import {
  clearPreciseUsageContinuityGap,
  markPreciseUsageContinuityGap,
  preciseUsageContinuityStorageKey,
  preciseUsageObserverStorageKey,
  preciseUsageObserverTransition,
  readPreciseUsageObserverState,
  readPreciseUsageContinuityState,
  reconcilePreciseUsageObserverEpoch,
  type PreciseUsageObserverEpoch,
} from "../state/preciseUsageContinuity";
import {
  acknowledgePreciseUsageFailure,
  subscribePreciseUsageFailures,
  type PreciseUsageFailureSignal,
} from "../state/preciseUsageFailureChannel";
import {
  attributionPersistenceFenceIsCurrent,
  attributionPersistenceOwnerInitializedStorageKey,
  attributionPersistenceOwnerStorageKey,
  createAttributionPersistenceOwnerID,
  holdAttributionPersistenceLock,
  publishAttributionPersistenceOwnerFence,
  readAttributionPersistenceOwnerState,
  type AttributionPersistenceOwnerLease,
} from "./sharedAccountAttribution/persistenceOwner";
import { quarantineAndRebaselineAttributionPersistence } from "./sharedAccountAttribution/persistenceRecovery";
import { priceModelTitle } from "../settings/quotaPriceModel";
import { useSharedAccountAttributionSettings } from "../settings/useSharedAccountAttributionSettings";
import {
  cardIdentifier,
  resetCreditDetailKey,
  resetCreditPanelModel,
  type ResetCreditDisplayItem,
} from "./quota/resetCredits";
import { quotaReadWarnings } from "./quota/quotaWarnings";
import { quotaPaceAccent, semanticMetricColor } from "../styles/semanticColors";

interface QuotaStripProps {
  attributionIdentity?: QuotaAttributionIdentity | null;
  onQuotaRefreshIntervalChange?: (intervalMs: number) => void | Promise<void>;
  onAttributionPreciseRefreshNeeded?: (comparisonUpdatedAt: string) => void;
  onAttributionSafetyAcknowledge?: (
    provenanceEpoch: string,
    unsafeID: string,
    throughGeneration: number,
  ) => Promise<boolean>;
  onAttributionSafetyRefreshNeeded?: () => void;
  onRetryQuotaRefresh?: () => void;
  preciseDataAvailable?: boolean;
  preciseDataCoveredAt?: string | null;
  preciseDataFresh?: boolean;
  preciseObserverEpoch?: string | null;
  preciseObserverStartedAtUnixMicros?: number | null;
  preciseObserverSequence?: number | null;
  preciseAttributionProvenanceEpoch?: string | null;
  preciseAttributionGeneration?: number | null;
  preciseAttributionUnsafeSinceGeneration?: number | null;
  preciseAttributionUnsafeID?: string | null;
  preciseAttributionCurrentScanUnsafe?: boolean;
  quotaUpdatedAt?: string | null;
  quotaRefreshIntervalMs?: number;
  recentUsage24h?: RecentUsagePoint[];
  snapshot: QuotaSnapshot;
  sourceHomeIdentity?: string;
  diagnostics?: QuotaDiagnostic[];
  warnings?: LocalDataWarning[];
}

const ATTRIBUTION_OWNER_LEASE_MS = 15_000;

function persistenceFenceKey(fence: AttributionPersistenceOwnerLease): string {
  return [
    fence.ownerID,
    fence.observationEpoch,
    String(fence.sequence),
    String(fence.leaseUntilUnixMs),
  ].join(":");
}

function QuotaBar({ quota }: { quota: QuotaLimit }) {
  const remainingPercent = typeof quota.remainingPercent === "number" ? quota.remainingPercent : null;
  const measured = quota.availability === "measured" && remainingPercent !== null;
  const measuredLabel = remainingPercent === null ? "" : formatPercent(remainingPercent);
  const usedPercent = typeof quota.usedPercent === "number"
    ? quota.usedPercent
    : remainingPercent === null ? null : Math.max(0, 1 - remainingPercent);
  const usedLabel = usedPercent === null ? "" : formatPercent(usedPercent);
  const boundedRemaining = remainingPercent === null ? null : Math.min(1, Math.max(0, remainingPercent));
  const fillStyle = boundedRemaining === null ? undefined : {
    width: `${Math.round(boundedRemaining * 100)}%`,
    "--metric-color": semanticMetricColor(boundedRemaining * 100),
  } as CSSProperties;
  return (
    <div
      aria-label={measured
        ? `${quota.label} 剩 ${measuredLabel}，已用 ${usedLabel}，重置 ${quota.resetsAt}`
        : `${quota.label} 额度待读取，重置 ${quota.resetsAt}`}
      className={measured ? "quota-bar" : "quota-bar quota-bar--unavailable"}
    >
      <span className="quota-label">{quota.label}</span>
      <div className="quota-track" aria-hidden="true">
        {measured && fillStyle ? <i className="quota-track-fill" style={fillStyle} /> : (
          <span className="quota-track-pending">待读取</span>
        )}
      </div>
      <div className="quota-bar-meta">
        {measured ? <span><b>剩 {measuredLabel}</b><em>已用 {usedLabel}</em></span> : <span>额度待读取</span>}
        <em>{quota.resetsAt}</em>
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
        <svg
          aria-hidden="true"
          className="reset-credit-disclosure"
          focusable="false"
          viewBox="0 0 20 20"
        >
          <path
            d={expanded ? "M4 12.5 10 6.5l6 6" : "M4 7.5l6 6 6-6"}
            fill="none"
            stroke="currentColor"
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth="2.4"
          />
        </svg>
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

function SharedAccountAttributionDetail({
  attribution,
  onClose,
  sourceUrl,
}: {
  attribution: SharedAccountAttributionResult;
  onClose: () => void;
  sourceUrl: string;
}) {
  const hasLocalCalculation = attribution.localSharePercent !== null
    && attribution.localComparableUSD !== null
    && attribution.radarPlanTotalUSD !== null;
  const hasResidualCalculation = hasLocalCalculation
    && attribution.accountUsedPercent !== null
    && attribution.residualPercent !== null;
  return (
    <div className="shared-attribution-layer" role="presentation" onMouseDown={onClose}>
      <section
        aria-label="共享账号用量归因详情"
        aria-modal="true"
        className="shared-attribution-panel"
        onMouseDown={(event) => event.stopPropagation()}
        role="dialog"
      >
        <header className="shared-attribution-head">
          <div>
            <span>本机估值与账号额度的差额</span>
            <strong>共享账号用量归因</strong>
          </div>
          <button aria-label="关闭共享账号用量归因详情" onClick={onClose} type="button">×</button>
        </header>

        <div className={`shared-attribution-status shared-attribution-status--${attribution.status}`}>
          <strong>{attributionStatusTitle(attribution)}</strong>
          <span>{attributionStatusDescription(attribution)}</span>
        </div>

        {hasLocalCalculation ? (
          <>
            <div className="shared-attribution-metrics">
              <div>
                <span>账号本段下降</span>
                <strong>{plainPercent(attribution.accountUsedPercent)}</strong>
              </div>
              <div>
                <span>本机占额度</span>
                <strong>{plainPercent(attribution.localSharePercent)}</strong>
              </div>
              <div className={hasResidualCalculation && (attribution.residualPercent ?? 0) < 0 ? "is-negative" : ""}>
                <span>差额（他人估）</span>
                <strong>{hasResidualCalculation ? signedPercent(attribution.residualPercent) : "—"}</strong>
              </div>
            </div>

            <div className="shared-attribution-formula" aria-label="归因计算公式">
              <span>本机占比</span>
              <code>{money(attribution.localComparableUSD)} ÷ {money(attribution.radarPlanTotalUSD)} × 100 = {plainPercent(attribution.localSharePercent)}</code>
              <span>差额</span>
              <code>{hasResidualCalculation
                ? `${plainPercent(attribution.accountUsedPercent)} − ${plainPercent(attribution.localSharePercent)} = ${signedPercent(attribution.residualPercent)}`
                : "等待新鲜额度与完整本机来源后再计算"}</code>
            </div>

            <dl className="shared-attribution-details">
              <div>
                <dt>当前 API 等值</dt>
                <dd>{money(attribution.localCurrentAPIEquivalentUSD)} · {priceModelTitle(attribution.priceModel)}</dd>
              </div>
              <div>
                <dt>本机 token</dt>
                <dd>
                  {formatTokens(attribution.tokens.totalTokens)} · 输入 {formatTokens(attribution.tokens.inputTokens)}
                  {" · "}缓存 {formatTokens(attribution.tokens.cachedInputTokens)} · 输出 {formatTokens(attribution.tokens.outputTokens)}
                </dd>
              </div>
              <div>
                <dt>账号段基线</dt>
                <dd>
                  {plainPercent(attribution.baselineAccountUsedPercent)} → {plainPercent(attribution.accountRawUsedPercent)}
                </dd>
              </div>
              <div>
                <dt>本机分段起点</dt>
                <dd>{localTimestamp(attribution.segmentStartUnix)}</dd>
              </div>
              <div>
                <dt>雷达套餐</dt>
                <dd>{attribution.selectedTierLabel} · 7d {money(attribution.radarPlanTotalUSD)}</dd>
              </div>
              <div>
                <dt>雷达依据</dt>
                <dd>{attribution.radarBasis || "7d"} · {attribution.radarDate || "日期未知"}</dd>
              </div>
              <div>
                <dt>定价基准日</dt>
                <dd>{attribution.radarPricingBasisDate || "日期未知"}</dd>
              </div>
              <div>
                <dt>更新时间</dt>
                <dd>{attribution.radarUpdatedAt || "待读取"}</dd>
              </div>
              <div>
                <dt>来源</dt>
                <dd>
                  {sourceUrl ? <a href={sourceUrl} rel="noreferrer" target="_blank">Codex 雷达</a> : "Codex 雷达"}
                  {attribution.radarSource ? ` · ${attribution.radarSource}` : ""}
                </dd>
              </div>
            </dl>
          </>
        ) : null}

        {attribution.pricingBasisStatus === "legacyRadarBasis" ? (
          <div className="shared-attribution-note shared-attribution-note--basis">
            雷达这期总额使用 2026-07-30 旧价格基准；本机占比同步使用 Sol 5/0.5/30、Terra 2.5/0.25/15、Luna 0.75/0.075/4.5，避免新旧价格混算。
          </div>
        ) : null}
        {attribution.status === "pricingVersionUnavailable" ? (
          <div className="shared-attribution-note shared-attribution-note--warning">
            雷达定价基准日：{attribution.radarPricingBasisDate || "日期未知"}。当前仅确认
            2026-07-30 与 2026-07-31 两套价格，其他日期不会自动套用最新价格。
          </div>
        ) : null}
        {attribution.historyChangedLowConfidence ? (
          <div className="shared-attribution-note shared-attribution-note--warning">
            本地历史发生变化，可能有会话被归档或移出当前扫描范围。当前扫描为
            {` ${money(attribution.scannedLocalComparableUSD)}（当前 API ${money(attribution.scannedLocalCurrentAPIEquivalentUSD)}）`}
            ，本周期已按每个 5 分钟桶的匿名来源贡献恢复历史累计；若来源身份无法证明完整，归因会直接停止而不是继续给出正差额。
          </div>
        ) : null}
        {attribution.usagePendingQuotaRefresh ? (
          <div className="shared-attribution-note shared-attribution-note--warning">
            额度百分比变化或本机用量仍与开放的 5 分钟桶重叠。需等后续额度快照越过边界，并完成一次该快照之后的精确观察，才会纳入结论。
          </div>
        ) : null}
        {attribution.quotaDataStale ? (
          <div className="shared-attribution-note shared-attribution-note--warning">
            账号额度来自读取失败后保留的旧快照；结论已降级为等待刷新。新鲜精确扫描读到的本机原始桶仍会写入既有安全分段，但不会据此推断他人用量。
          </div>
        ) : null}
        {attribution.radarDataStale ? (
          <div className="shared-attribution-note shared-attribution-note--warning">
            Radar 来自刷新失败后保留的旧快照；金额分母仍可查看，但结论已降级为等待刷新。
          </div>
        ) : null}
        {attribution.status === "preciseDataStale" ? (
          <div className="shared-attribution-note shared-attribution-note--warning">
            最近一次完整精确用量时间序列尚未覆盖当前额度比较时点，或本轮精确读取失败。已扫描的原始桶会保留，但在完整索引追平前不会纳入归因结论。
          </div>
        ) : null}
        {attribution.status === "awaitingAccountSwitchBaseline" ? (
          <div className="shared-attribution-note shared-attribution-note--warning">
            {attribution.cutoverReason === "continuityGap"
              ? "精确读取失败形成的未知区间已经隔离；安全切点取恢复覆盖时间的下一个 5 分钟边界，待后续额度快照固定基线前不输出他人用量结论。"
              : attribution.cutoverReason === "legacyMigration"
                ? "旧版记录已按升级安全切点隔离；待后续额度快照固定基线前不输出他人用量结论。"
                : attribution.cutoverReason === "initialActivation"
                  ? "这是本机首次可靠观察到当前额度周期，已从下一个完整 5 分钟桶建立安全切点。待后续新鲜额度快照固定基线前，不会把此前整周期假定为本机使用。"
                  : "检测到账号切换，已从下一个完整 5 分钟桶开始新分段。需要切换边界之后的首个新鲜额度快照固定基线，期间不输出他人用量结论。"}
          </div>
        ) : null}
        <div className="shared-attribution-note">
          额度通常只显示到整百分点，本机按 5 分钟分桶和所选模型估价。差额在 ±2 个百分点内不区分他人使用；差额不是其他账号的直接记录，也不会被截成 0。
        </div>
        <div className="shared-attribution-note">
          金额按用户所选模型和标准短上下文估算。当前索引无法逐事件识别 cache write、超过 272K 的长上下文、Fast 附加项或混用模型，因此这些情况会带来额外误差。
        </div>
        <div className="shared-attribution-note">
          本周期桶级高水位按原生层提供的匿名账号 scope、重置时间和账号切换分段隔离；原始 token 不随套餐或折算模型切换而丢失。scope 由稳定账户与额度 limit 哈希生成，不向前端暴露原始 ID。
        </div>
        <div className="shared-attribution-note">
          账号隔离从本功能首次可靠观察到当前 Home 起生效；首次启用和新周期都先等待合成切点后的新额度基线，不会用 0 基线倒推此前整周期。
        </div>
        <div className="shared-attribution-note">
          每个 5 分钟桶按原生层提供的匿名稳定来源逐项累计。旧来源消失、同桶出现新来源时会保留两者；来源身份不完整、回退或持久记录损坏时会停止输出他人用量结论。
        </div>
      </section>
    </div>
  );
}

function QuotaStripView({
  attributionIdentity = null,
  onAttributionPreciseRefreshNeeded,
  onAttributionSafetyAcknowledge,
  onAttributionSafetyRefreshNeeded,
  onQuotaRefreshIntervalChange,
  onRetryQuotaRefresh,
  preciseDataAvailable = false,
  preciseDataCoveredAt = null,
  preciseDataFresh = false,
  preciseObserverEpoch = null,
  preciseObserverStartedAtUnixMicros = null,
  preciseObserverSequence = null,
  preciseAttributionProvenanceEpoch = null,
  preciseAttributionGeneration = null,
  preciseAttributionUnsafeSinceGeneration = null,
  preciseAttributionUnsafeID = null,
  preciseAttributionCurrentScanUnsafe = false,
  quotaUpdatedAt = null,
  quotaRefreshIntervalMs,
  recentUsage24h = [],
  snapshot,
  sourceHomeIdentity = "",
  diagnostics = [],
  warnings = [],
}: QuotaStripProps) {
  const [showResetDetails, setShowResetDetails] = useState(false);
  const [showAttributionDetails, setShowAttributionDetails] = useState(false);
  const [expandedCredits, setExpandedCredits] = useState<Set<string>>(() => new Set());
  const [attributionPersistence, setAttributionPersistence] = useState({
    sourceHomeIdentity: "",
    healthy: true,
    revision: 0,
  });
  const [persistenceOwner, setPersistenceOwner] = useState({
    sourceHomeIdentity: "",
    healthy: true,
    isOwner: false,
    lockHeld: false,
    ownerID: "",
    observationEpoch: "",
    sequence: 0,
    leaseUntilUnixMs: 0,
  });
  const [persistenceRecovery, setPersistenceRecovery] = useState({
    sourceHomeIdentity: "",
    quarantined: false,
    healthy: true,
  });
  const [pendingPreciseFailure, setPendingPreciseFailure] =
    useState<PreciseUsageFailureSignal | null>(null);
  const ownerIDRef = useRef(createAttributionPersistenceOwnerID());
  const persistenceFenceRef = useRef<AttributionPersistenceOwnerLease | null>(null);
  const pendingFencedOperationsRef = useRef(new Map<string, Set<Promise<unknown>>>());
  const preciseCoverageRef = useRef<number | null>(null);
  const safetyRefreshRef = useRef(onAttributionSafetyRefreshNeeded);
  const requestedAlignmentRefreshRef = useRef<string | null>(null);
  const observerReconcileAttemptRef = useRef<string | null>(null);
  const persistenceRecoveryAttemptRef = useRef<string | null>(null);
  const nativeSafetyAcknowledgeAttemptRef = useRef<string | null>(null);
  const preciseFailureAttemptRef = useRef(new Map<string, string>());
  const radarSnapshot = useSubscribedCodexRadarSnapshot();
  const { settings: attributionSettings } = useSharedAccountAttributionSettings();
  const resetCreditPanel = useMemo(() => resetCreditPanelModel(snapshot.resetCredit), [snapshot.resetCredit]);
  const quotaWarnings = useMemo(() => quotaReadWarnings(warnings, diagnostics), [diagnostics, warnings]);
  const quotaDataStale = diagnostics.some((diagnostic) => (
    diagnostic.staleDataDisplayed || diagnostic.category === "stale_cached_data"
  ));
  const radarDataStale = radarSnapshot?.staleDataDisplayed === true;
  const quotaRadar = radarSnapshot?.modelIq.quotaRadar ?? null;
  const attributionCompatibilitySignature = sharedAccountAttributionInputSignature(
    quotaRadar,
    attributionIdentity,
  );
  const nowUnix = Date.now() / 1_000;
  const observedQuotaUpdatedAtUnix = parsedUnix(quotaUpdatedAt ?? undefined);
  const preciseDataCoveredAtUnix = parsedUnix(preciseDataCoveredAt ?? undefined);
  preciseCoverageRef.current = preciseDataCoveredAtUnix;
  safetyRefreshRef.current = onAttributionSafetyRefreshNeeded;
  const persistenceRevision = attributionPersistence.sourceHomeIdentity === sourceHomeIdentity
    ? attributionPersistence.revision
    : 0;
  const writeStorageHealthy = attributionPersistence.sourceHomeIdentity === sourceHomeIdentity
    ? attributionPersistence.healthy
    : true;
  const ownerReadState = useMemo(() => (
    attributionSettings.enabled
      ? readAttributionPersistenceOwnerState(sourceHomeIdentity)
      : { healthy: true, lease: null }
  ), [attributionSettings.enabled, persistenceRevision, sourceHomeIdentity]);
  const expectedPersistenceFence = persistenceOwner.sourceHomeIdentity === sourceHomeIdentity
    && persistenceOwner.ownerID
    && persistenceOwner.observationEpoch
    && persistenceOwner.sequence > 0
    ? {
        ownerID: persistenceOwner.ownerID,
        observationEpoch: persistenceOwner.observationEpoch,
        sequence: persistenceOwner.sequence,
        leaseUntilUnixMs: persistenceOwner.leaseUntilUnixMs,
      }
    : null;
  const persistenceFenceCurrent = attributionPersistenceFenceIsCurrent(
    sourceHomeIdentity,
    expectedPersistenceFence,
  );
  const ownsAttributionPersistence = persistenceOwner.sourceHomeIdentity === sourceHomeIdentity
    && persistenceOwner.lockHeld
    && persistenceOwner.healthy
    && persistenceOwner.isOwner
    && persistenceFenceCurrent;
  const holdsAttributionPersistenceLease = persistenceOwner.sourceHomeIdentity === sourceHomeIdentity
    && persistenceOwner.lockHeld;
  const recoveryRebaselineActive = persistenceRecovery.sourceHomeIdentity === sourceHomeIdentity
    && persistenceRecovery.quarantined;
  const nativeProvenanceMetadataValid = typeof preciseAttributionProvenanceEpoch === "string"
    && isUUID(preciseAttributionProvenanceEpoch)
    && typeof preciseAttributionGeneration === "number"
    && Number.isSafeInteger(preciseAttributionGeneration)
    && preciseAttributionGeneration >= 0;
  const nativeUnsafeFieldsPresent = preciseAttributionUnsafeID !== null
    || preciseAttributionUnsafeSinceGeneration !== null;
  const nativeUnsafeEpisode = nativeProvenanceMetadataValid
    && typeof preciseAttributionUnsafeID === "string"
    && isUUID(preciseAttributionUnsafeID)
    && typeof preciseAttributionUnsafeSinceGeneration === "number"
    && Number.isSafeInteger(preciseAttributionUnsafeSinceGeneration)
    && preciseAttributionUnsafeSinceGeneration > 0
    && preciseAttributionUnsafeSinceGeneration <= preciseAttributionGeneration
    ? {
        provenanceEpoch: preciseAttributionProvenanceEpoch,
        generation: preciseAttributionGeneration,
        unsafeSinceGeneration: preciseAttributionUnsafeSinceGeneration,
        unsafeID: preciseAttributionUnsafeID,
      }
    : null;
  const nativeSafetyMetadataHealthy = !preciseDataFresh
    || (nativeProvenanceMetadataValid
      && (nativeUnsafeFieldsPresent ? nativeUnsafeEpisode !== null : true)
      && (!preciseAttributionCurrentScanUnsafe || nativeUnsafeEpisode !== null));
  const continuityState = useMemo(() => (
    attributionSettings.enabled
      ? readPreciseUsageContinuityState(
          sourceHomeIdentity,
          undefined,
          ownsAttributionPersistence,
        )
      : { healthy: true, gap: null }
  ), [
    attributionSettings.enabled,
    ownsAttributionPersistence,
    persistenceRevision,
    sourceHomeIdentity,
  ]);
  const currentPreciseObserver = useMemo<PreciseUsageObserverEpoch | null>(() => (
    typeof preciseObserverEpoch === "string"
      && preciseObserverEpoch.trim()
      && typeof preciseObserverStartedAtUnixMicros === "number"
      && Number.isSafeInteger(preciseObserverStartedAtUnixMicros)
      && preciseObserverStartedAtUnixMicros > 0
      && typeof preciseObserverSequence === "number"
      && Number.isSafeInteger(preciseObserverSequence)
      && preciseObserverSequence >= 0
      ? {
          epoch: preciseObserverEpoch,
          startedAtUnixMicros: preciseObserverStartedAtUnixMicros,
          sequence: preciseObserverSequence,
        }
      : null
  ), [preciseObserverEpoch, preciseObserverSequence, preciseObserverStartedAtUnixMicros]);
  const observerState = useMemo(() => (
    attributionSettings.enabled
      ? readPreciseUsageObserverState(sourceHomeIdentity)
      : { healthy: true, observer: null }
  ), [attributionSettings.enabled, persistenceRevision, sourceHomeIdentity]);
  const observerTransition = preciseUsageObserverTransition(
    observerState,
    preciseDataFresh ? currentPreciseObserver : null,
  );
  useEffect(() => {
    if (!attributionSettings.enabled || !sourceHomeIdentity.trim()) {
      setPendingPreciseFailure(null);
      return undefined;
    }
    return subscribePreciseUsageFailures(
      sourceHomeIdentity,
      setPendingPreciseFailure,
    );
  }, [attributionSettings.enabled, sourceHomeIdentity]);
  useEffect(() => {
    persistenceRecoveryAttemptRef.current = null;
    nativeSafetyAcknowledgeAttemptRef.current = null;
    if (!attributionSettings.enabled || !sourceHomeIdentity.trim()) {
      persistenceFenceRef.current = null;
      setPersistenceOwner({
        sourceHomeIdentity,
        healthy: true,
        isOwner: false,
        lockHeld: false,
        ownerID: "",
        observationEpoch: "",
        sequence: 0,
        leaseUntilUnixMs: 0,
      });
      return undefined;
    }
    let cancelled = false;
    let lockAcquired = false;
    let activeFenceKey = "";
    let releaseLock!: () => void;
    const releaseRequested = new Promise<void>((resolve) => { releaseLock = resolve; });
    const abortController = new AbortController();
    void holdAttributionPersistenceLock(
      sourceHomeIdentity,
      abortController.signal,
      async () => {
        if (cancelled) return;
        lockAcquired = true;
        const claimed = publishAttributionPersistenceOwnerFence(
          sourceHomeIdentity,
          ownerIDRef.current,
          Date.now(),
          ATTRIBUTION_OWNER_LEASE_MS,
        );
        let healthy = claimed.healthy && claimed.isOwner && claimed.lease !== null;
        if (healthy && claimed.lease !== null) {
          persistenceFenceRef.current = claimed.lease;
          activeFenceKey = persistenceFenceKey(claimed.lease);
          if (claimed.transition === "takeover") {
            const gap = markPreciseUsageContinuityGap(
              sourceHomeIdentity,
              preciseCoverageRef.current ?? Date.now() / 1_000,
            );
            healthy = gap !== null;
            if (healthy) safetyRefreshRef.current?.();
          }
        }
        if (cancelled) {
          persistenceFenceRef.current = null;
          return;
        }
        setPersistenceOwner({
          sourceHomeIdentity,
          healthy,
          isOwner: healthy,
          lockHeld: true,
          ownerID: claimed.lease?.ownerID ?? ownerIDRef.current,
          observationEpoch: claimed.lease?.observationEpoch ?? "",
          sequence: claimed.lease?.sequence ?? 0,
          leaseUntilUnixMs: claimed.lease?.leaseUntilUnixMs ?? 0,
        });
        setAttributionPersistence((previous) => ({
          sourceHomeIdentity,
          healthy,
          revision: previous.sourceHomeIdentity === sourceHomeIdentity
            ? previous.revision + 1
            : 1,
        }));
        await releaseRequested;
        if (persistenceFenceRef.current !== null
          && persistenceFenceKey(persistenceFenceRef.current) === activeFenceKey) {
          persistenceFenceRef.current = null;
        }
      },
    ).catch((error: unknown) => {
      if (cancelled || (error instanceof Error && error.name === "AbortError")) return;
      persistenceFenceRef.current = null;
      setPersistenceOwner({
        sourceHomeIdentity,
        healthy: false,
        isOwner: false,
        lockHeld: false,
        ownerID: "",
        observationEpoch: "",
        sequence: 0,
        leaseUntilUnixMs: 0,
      });
      setAttributionPersistence((previous) => ({
        sourceHomeIdentity,
        healthy: false,
        revision: previous.sourceHomeIdentity === sourceHomeIdentity
          ? previous.revision + 1
          : 1,
      }));
    });
    const storageChanged = (event: StorageEvent) => {
      if (event.key !== attributionPersistenceOwnerStorageKey(sourceHomeIdentity)
        && event.key !== attributionPersistenceOwnerInitializedStorageKey(sourceHomeIdentity)) return;
      setAttributionPersistence((previous) => ({
        sourceHomeIdentity,
        healthy: previous.healthy,
        revision: previous.sourceHomeIdentity === sourceHomeIdentity
          ? previous.revision + 1
          : 1,
      }));
    };
    window.addEventListener("storage", storageChanged);
    return () => {
      cancelled = true;
      window.removeEventListener("storage", storageChanged);
      persistenceFenceRef.current = null;
      if (!lockAcquired) abortController.abort();
      // Recovery may replace the fencing row while an acknowledgement that
      // started under the prior fence is still in flight. Hold the Web Lock
      // until every already-started fenced operation settles, regardless of
      // which local fence generation registered it.
      const pending = [...pendingFencedOperationsRef.current.values()]
        .flatMap((operations) => [...operations]);
      void Promise.allSettled(pending).then(() => {
        releaseLock();
      });
    };
  }, [
    attributionSettings.enabled,
    sourceHomeIdentity,
  ]);
  const observedResetAtUnix = snapshot.sevenDay.resetsAtUnix;
  const accountUsedPercent = snapshot.sevenDay.usedPercent === null
    ? null
    : quotaValueToPercentagePoints(snapshot.sevenDay.usedPercent);
  const segmentInput = useMemo(() => ({
    enabled: attributionSettings.enabled,
    sourceHomeIdentity,
    identity: attributionIdentity,
    quotaDataFresh: !quotaDataStale,
    resetAtUnix: observedResetAtUnix,
    quotaUpdatedAtUnix: observedQuotaUpdatedAtUnix,
    accountUsedPercent,
  }), [
    accountUsedPercent,
    attributionCompatibilitySignature,
    attributionIdentity,
    attributionSettings.enabled,
    observedQuotaUpdatedAtUnix,
    observedResetAtUnix,
    quotaDataStale,
    sourceHomeIdentity,
  ]);
  const segmentStorageKey = attributionSettings.enabled && sourceHomeIdentity.trim()
    ? attributionSegmentStorageKey(sourceHomeIdentity)
    : null;
  const storedSegmentState = useMemo(() => (
    segmentStorageKey === null
      ? { healthy: true, value: null }
      : readAttributionSegmentState(segmentStorageKey)
  ), [persistenceRevision, segmentStorageKey]);
  const legacyResidueState = useMemo(() => (
    attributionSettings.enabled
      ? readLegacyAttributionResidueState(sourceHomeIdentity)
      : { healthy: true, keys: [] }
  ), [attributionSettings.enabled, persistenceRevision, sourceHomeIdentity]);
  const legacySegmentState = useMemo(() => {
    if (!attributionSettings.enabled
      || storedSegmentState.value !== null
      || !storedSegmentState.healthy
      || !continuityState.healthy
      || !observerState.healthy
      || observerTransition !== "current"
      || !nativeSafetyMetadataHealthy
      || preciseAttributionCurrentScanUnsafe
      || nativeUnsafeEpisode !== null
      || continuityState.gap !== null
      || quotaDataStale
      || !preciseDataAvailable
      || !preciseDataFresh) {
      return { healthy: true, value: null };
    }
    return readLegacyAttributionSegmentState(sourceHomeIdentity);
  }, [
    attributionSettings.enabled,
    continuityState.gap,
    continuityState.healthy,
    observerState.healthy,
    observerTransition,
    nativeSafetyMetadataHealthy,
    nativeUnsafeEpisode,
    persistenceRevision,
    preciseDataAvailable,
    preciseDataFresh,
    preciseAttributionCurrentScanUnsafe,
    quotaDataStale,
    sourceHomeIdentity,
    storedSegmentState.healthy,
    storedSegmentState.value,
  ]);
  const baseSegmentResolution = useMemo(() => {
    const stored = storedSegmentState.value;
    if (!continuityState.healthy
      || !observerState.healthy
      || observerTransition !== "current"
      || !nativeSafetyMetadataHealthy
      || preciseAttributionCurrentScanUnsafe
      || !storedSegmentState.healthy
      || !legacySegmentState.healthy
      || quotaDataStale
      || !preciseDataAvailable
      || !preciseDataFresh) {
      return holdAttributionSegmentDuringContinuityGap(stored, segmentInput);
    }
    if (nativeUnsafeEpisode !== null) {
      if (preciseDataCoveredAtUnix === null) {
        return holdAttributionSegmentDuringContinuityGap(stored, segmentInput);
      }
      return beginAttributionUnsafeEpisodeCutover(
        stored,
        segmentInput,
        nativeUnsafeEpisode.unsafeID,
        preciseDataCoveredAtUnix,
        preciseDataCoveredAtUnix,
      );
    }
    if (continuityState.gap !== null) {
      if (preciseDataCoveredAtUnix !== null) {
        return beginContinuityGapCutover(
          stored,
          segmentInput,
          continuityState.gap.id,
          continuityState.gap.detectedAtUnix,
          preciseDataCoveredAtUnix,
        );
      }
      return holdAttributionSegmentDuringContinuityGap(stored, segmentInput);
    }
    return resolveAttributionSegment(stored, segmentInput, legacySegmentState.value);
  }, [
    continuityState.gap,
    continuityState.healthy,
    legacySegmentState.healthy,
    legacySegmentState.value,
    nativeSafetyMetadataHealthy,
    nativeUnsafeEpisode,
    preciseAttributionCurrentScanUnsafe,
    preciseDataCoveredAtUnix,
    preciseDataAvailable,
    preciseDataFresh,
    quotaDataStale,
    observerState.healthy,
    observerTransition,
    segmentInput,
    storedSegmentState.healthy,
    storedSegmentState.value,
  ]);
  const canonicalResetAtUnix = baseSegmentResolution.segment?.resetAtUnix
    ?? observedResetAtUnix;
  const persistenceCutoffUnix = preciseDataAvailable
    && preciseDataFresh
    && nativeSafetyMetadataHealthy
    && !preciseAttributionCurrentScanUnsafe
    && preciseDataCoveredAtUnix !== null
    && typeof canonicalResetAtUnix === "number"
    && Number.isFinite(canonicalResetAtUnix)
    ? Math.min(preciseDataCoveredAtUnix, canonicalResetAtUnix)
    : null;
  const baseComparisonEndUnix = persistenceCutoffUnix !== null
    && baseSegmentResolution.segment !== null
    ? completedBucketEndBoundary(Math.min(
        persistenceCutoffUnix,
        baseSegmentResolution.segment.comparisonUpdatedAtUnix,
      ))
    : null;
  const baseHighWaterKey = useMemo(() => {
    if (!attributionSettings.enabled
      || (baseSegmentResolution.status !== "ready"
        && baseSegmentResolution.status !== "awaitingAccountSwitchBaseline")
      || !baseSegmentResolution.segment
      || typeof canonicalResetAtUnix !== "number"
      || !Number.isFinite(canonicalResetAtUnix)) {
      return null;
    }
    return attributionHighWaterStorageKey({
      scopeKey: baseSegmentResolution.segment.scopeKey,
      plan: baseSegmentResolution.segment.plan,
      limit: baseSegmentResolution.segment.limit,
      resetAtUnix: canonicalResetAtUnix,
      segmentStartUnix: baseSegmentResolution.segment.segmentStartUnix,
      tier: attributionSettings.radarTier,
      priceModel: attributionSettings.priceModel,
    });
  }, [
    attributionSettings.enabled,
    attributionSettings.priceModel,
    attributionSettings.radarTier,
    baseSegmentResolution.segment,
    baseSegmentResolution.status,
    canonicalResetAtUnix,
  ]);
  const baseHighWaterState = useMemo(() => (
    baseHighWaterKey === null
      ? { healthy: true, record: null }
      : readAttributionHighWaterState(baseHighWaterKey)
  ), [baseHighWaterKey, persistenceRevision]);
  const preliminaryBucketMerge = useMemo<AttributionBucketMergeResult>(() => {
    if (!attributionSettings.enabled
      || !baseHighWaterKey
      || !baseSegmentResolution.segment
      || typeof canonicalResetAtUnix !== "number"
      || persistenceCutoffUnix === null
      || persistenceCutoffUnix < baseSegmentResolution.segment.segmentStartUnix
      || baseComparisonEndUnix === null
      || !continuityState.healthy
      || !nativeSafetyMetadataHealthy
      || preciseAttributionCurrentScanUnsafe
      || !storedSegmentState.healthy
      || !legacySegmentState.healthy
      || !baseHighWaterState.healthy) {
      return emptyBucketMergeResult();
    }
    return mergeAttributionBucketHighWater(
      baseHighWaterState.record,
      recentUsage24h,
      {
        segmentStartUnix: baseSegmentResolution.segment.segmentStartUnix,
        resetAtUnix: canonicalResetAtUnix,
        persistenceCutoffUnix,
        comparisonEndUnix: baseComparisonEndUnix,
        metadataObservedAtUnix: observedQuotaUpdatedAtUnix ?? 0,
        preciseCoveredAt: preciseDataCoveredAt ?? undefined,
        quotaObservationFresh: !quotaDataStale,
      },
    );
  }, [
    attributionSettings.enabled,
    baseHighWaterState.healthy,
    baseHighWaterState.record,
    baseComparisonEndUnix,
    baseHighWaterKey,
    baseSegmentResolution.segment,
    canonicalResetAtUnix,
    continuityState.healthy,
    legacySegmentState.healthy,
    nativeSafetyMetadataHealthy,
    observedQuotaUpdatedAtUnix,
    persistenceCutoffUnix,
    preciseDataCoveredAt,
    preciseAttributionCurrentScanUnsafe,
    quotaDataStale,
    recentUsage24h,
    storedSegmentState.healthy,
  ]);
  const segmentResolution = useMemo(() => {
    if (baseSegmentResolution.status !== "ready"
      || baseSegmentResolution.changed
      || !baseSegmentResolution.segment
      || quotaDataStale
      || continuityState.gap !== null
      || nativeUnsafeEpisode !== null
      || preciseAttributionCurrentScanUnsafe
      || !preliminaryBucketMerge.hasPendingUsage) {
      return baseSegmentResolution;
    }
    return resolveAttributionSegment(baseSegmentResolution.segment, {
      ...segmentInput,
      pendingRawCanAdvanceComparison: true,
    });
  }, [
    baseSegmentResolution,
    continuityState.gap,
    nativeUnsafeEpisode,
    preliminaryBucketMerge.hasPendingUsage,
    preciseAttributionCurrentScanUnsafe,
    quotaDataStale,
    segmentInput,
  ]);
  const comparisonUpdatedAtUnix = segmentResolution.segment?.comparisonUpdatedAtUnix ?? null;
  const comparisonEndUnix = persistenceCutoffUnix !== null
    && comparisonUpdatedAtUnix !== null
    ? completedBucketEndBoundary(Math.min(persistenceCutoffUnix, comparisonUpdatedAtUnix))
    : null;
  const highWaterKey = segmentResolution.segment === baseSegmentResolution.segment
    ? baseHighWaterKey
    : segmentResolution.segment === null || typeof canonicalResetAtUnix !== "number"
      ? null
      : attributionHighWaterStorageKey({
          scopeKey: segmentResolution.segment.scopeKey,
          plan: segmentResolution.segment.plan,
          limit: segmentResolution.segment.limit,
          resetAtUnix: canonicalResetAtUnix,
          segmentStartUnix: segmentResolution.segment.segmentStartUnix,
          tier: attributionSettings.radarTier,
          priceModel: attributionSettings.priceModel,
        });
  const highWaterState = useMemo(() => (
    highWaterKey === null
      ? { healthy: true, record: null }
      : readAttributionHighWaterState(highWaterKey)
  ), [highWaterKey, persistenceRevision]);
  const expectedHighWaterMissing = segmentResolution.segment?.baselineReady === true
    && segmentResolution.segment.highWaterInitialized
    && highWaterState.record === null;
  const bucketMerge = useMemo<AttributionBucketMergeResult>(() => {
    if (!attributionSettings.enabled
      || !highWaterKey
      || !segmentResolution.segment
      || typeof canonicalResetAtUnix !== "number"
      || persistenceCutoffUnix === null
      || persistenceCutoffUnix < segmentResolution.segment.segmentStartUnix
      || comparisonEndUnix === null
      || !continuityState.healthy
      || !nativeSafetyMetadataHealthy
      || preciseAttributionCurrentScanUnsafe
      || !storedSegmentState.healthy
      || !legacySegmentState.healthy
      || !highWaterState.healthy) {
      return emptyBucketMergeResult();
    }
    return mergeAttributionBucketHighWater(
      highWaterState.record,
      recentUsage24h,
      {
        segmentStartUnix: segmentResolution.segment.segmentStartUnix,
        resetAtUnix: canonicalResetAtUnix,
        persistenceCutoffUnix,
        comparisonEndUnix,
        metadataObservedAtUnix: observedQuotaUpdatedAtUnix ?? 0,
        preciseCoveredAt: preciseDataCoveredAt ?? undefined,
        quotaObservationFresh: !quotaDataStale,
      },
    );
  }, [
    attributionSettings.enabled,
    canonicalResetAtUnix,
    comparisonEndUnix,
    continuityState.healthy,
    highWaterKey,
    highWaterState.healthy,
    highWaterState.record,
    legacySegmentState.healthy,
    nativeSafetyMetadataHealthy,
    observedQuotaUpdatedAtUnix,
    persistenceCutoffUnix,
    preciseDataCoveredAt,
    preciseAttributionCurrentScanUnsafe,
    quotaDataStale,
    recentUsage24h,
    segmentResolution.segment,
    storedSegmentState.healthy,
  ]);
  const attributionStorageReadsHealthy = continuityState.healthy
    && (!preciseDataFresh || (observerState.healthy && observerTransition === "current"))
    && nativeSafetyMetadataHealthy
    && !preciseAttributionCurrentScanUnsafe
    && storedSegmentState.healthy
    && legacyResidueState.healthy
    && legacySegmentState.healthy
    && baseHighWaterState.healthy
    && highWaterState.healthy
    && !expectedHighWaterMissing;
  const corruptPersistenceKeys = useMemo(() => {
    if (!attributionSettings.enabled || !sourceHomeIdentity.trim()) return [];
    const keys: string[] = [];
    if (!ownerReadState.healthy
      || (holdsAttributionPersistenceLease
        && !persistenceOwner.healthy
        && expectedPersistenceFence === null)
      || (holdsAttributionPersistenceLease
        && expectedPersistenceFence !== null
        && !persistenceFenceCurrent)) {
      keys.push(attributionPersistenceOwnerStorageKey(sourceHomeIdentity));
      keys.push(attributionPersistenceOwnerInitializedStorageKey(sourceHomeIdentity));
    }
    if (!continuityState.healthy) {
      keys.push(preciseUsageContinuityStorageKey(sourceHomeIdentity));
    }
    if (!observerState.healthy) {
      keys.push(preciseUsageObserverStorageKey(sourceHomeIdentity));
    }
    if (!storedSegmentState.healthy && segmentStorageKey) keys.push(segmentStorageKey);
    if (!legacySegmentState.healthy) keys.push(...legacyResidueState.keys);
    if (!baseHighWaterState.healthy && baseHighWaterKey) {
      keys.push(baseHighWaterKey);
      if (segmentStorageKey) keys.push(segmentStorageKey);
    }
    if (!highWaterState.healthy && highWaterKey) {
      keys.push(highWaterKey);
      if (segmentStorageKey) keys.push(segmentStorageKey);
    }
    if (expectedHighWaterMissing) {
      if (segmentStorageKey) keys.push(segmentStorageKey);
      if (highWaterKey) keys.push(highWaterKey);
    }
    return [...new Set(keys)].sort();
  }, [
    attributionSettings.enabled,
    baseHighWaterKey,
    baseHighWaterState.healthy,
    continuityState.healthy,
    expectedHighWaterMissing,
    highWaterKey,
    highWaterState.healthy,
    legacyResidueState.keys,
    legacySegmentState.healthy,
    expectedPersistenceFence,
    holdsAttributionPersistenceLease,
    observerState.healthy,
    ownerReadState.healthy,
    persistenceFenceCurrent,
    persistenceOwner.healthy,
    segmentStorageKey,
    sourceHomeIdentity,
    storedSegmentState.healthy,
  ]);
  const legacyResiduePendingForConclusion = storedSegmentState.value !== null
    && legacyResidueState.keys.length > 0;
  const persistencePendingForConclusion = segmentResolution.segment?.baselineReady === true
    && (segmentResolution.changed
      || bucketMerge.changed
      || !segmentResolution.segment.highWaterInitialized
      || legacyResiduePendingForConclusion);
  const attributionInput = useMemo(() => ({
    enabled: attributionSettings.enabled,
    nativeHistoryUnsafe: preciseAttributionCurrentScanUnsafe || !nativeSafetyMetadataHealthy,
    persistenceRebaseline: recoveryRebaselineActive
      && (continuityState.gap !== null || segmentResolution.segment?.baselineReady !== true),
    storageHealthy: ownsAttributionPersistence
      && attributionStorageReadsHealthy
      && writeStorageHealthy
      && !persistencePendingForConclusion,
    preciseDataAvailable,
    preciseDataFresh,
    preciseDataCoveredAtUnix,
    buckets: bucketMerge.effectiveBuckets,
    scannedBuckets: bucketMerge.scannedBuckets,
    usagePendingQuotaRefresh: bucketMerge.hasPendingUsage,
    historyChangedLowConfidence: bucketMerge.usedHistoricalHighWater,
    localHistoryAmbiguous: bucketMerge.ambiguityDetected,
    quotaDataStale,
    radarDataStale,
    sevenDayQuota: snapshot.sevenDay,
    quotaRadar,
    selectedTier: attributionSettings.radarTier,
    priceModel: attributionSettings.priceModel,
    segmentStatus: segmentResolution.status,
    segment: segmentResolution.segment,
    quotaUpdatedAtUnix: comparisonUpdatedAtUnix,
    nowUnix,
  }), [
    attributionSettings.enabled,
    attributionSettings.priceModel,
    attributionSettings.radarTier,
    attributionCompatibilitySignature,
    attributionStorageReadsHealthy,
    continuityState.gap,
    bucketMerge.ambiguityDetected,
    bucketMerge.changed,
    bucketMerge.effectiveBuckets,
    bucketMerge.hasPendingUsage,
    bucketMerge.scannedBuckets,
    bucketMerge.usedHistoricalHighWater,
    nowUnix,
    nativeSafetyMetadataHealthy,
    ownsAttributionPersistence,
    preciseDataAvailable,
    preciseDataCoveredAtUnix,
    preciseDataFresh,
    preciseAttributionCurrentScanUnsafe,
    quotaDataStale,
    comparisonUpdatedAtUnix,
    quotaRadar,
    radarDataStale,
    recoveryRebaselineActive,
    segmentResolution.segment,
    segmentResolution.status,
    snapshot.sevenDay,
    persistencePendingForConclusion,
    writeStorageHealthy,
  ]);
  const attribution = useMemo(
    () => estimateSharedAccountAttribution(attributionInput),
    [attributionInput],
  );

  useEffect(() => {
    if (!attributionSettings.enabled
      || !ownsAttributionPersistence
      || !preciseDataFresh
      || !nativeSafetyMetadataHealthy
      || preciseAttributionCurrentScanUnsafe
      || currentPreciseObserver === null
      || (observerTransition !== "initialize" && observerTransition !== "restart")) return;
    const mutationFence = persistenceFenceRef.current;
    if (!attributionPersistenceFenceIsCurrent(sourceHomeIdentity, mutationFence)) {
      setPersistenceOwner((previous) => previous.sourceHomeIdentity === sourceHomeIdentity
        ? { ...previous, healthy: false, isOwner: false }
        : previous);
      return;
    }
    const attemptSignature = JSON.stringify([
      sourceHomeIdentity,
      currentPreciseObserver.epoch,
      currentPreciseObserver.startedAtUnixMicros,
      currentPreciseObserver.sequence,
      observerTransition,
      observerState.observer?.epoch ?? "",
      preciseDataCoveredAt ?? "",
    ]);
    if (observerReconcileAttemptRef.current === attemptSignature) return;
    observerReconcileAttemptRef.current = attemptSignature;
    const requireGap = observerTransition === "restart"
      || storedSegmentState.value?.baselineReady === true;
    const reconciled = reconcilePreciseUsageObserverEpoch(
      sourceHomeIdentity,
      currentPreciseObserver,
      requireGap,
      preciseDataCoveredAtUnix ?? Date.now() / 1_000,
    );
    setAttributionPersistence((previous) => ({
      sourceHomeIdentity,
      healthy: reconciled.healthy,
      revision: previous.sourceHomeIdentity === sourceHomeIdentity
        ? previous.revision + 1
        : 1,
    }));
  }, [
    attributionSettings.enabled,
    currentPreciseObserver,
    observerState.observer?.epoch,
    observerTransition,
    ownsAttributionPersistence,
    nativeSafetyMetadataHealthy,
    preciseDataCoveredAt,
    preciseDataCoveredAtUnix,
    preciseDataFresh,
    preciseAttributionCurrentScanUnsafe,
    sourceHomeIdentity,
    storedSegmentState.value?.baselineReady,
  ]);

  useEffect(() => {
    requestedAlignmentRefreshRef.current = null;
    observerReconcileAttemptRef.current = null;
    persistenceRecoveryAttemptRef.current = null;
    nativeSafetyAcknowledgeAttemptRef.current = null;
    setPersistenceRecovery({
      sourceHomeIdentity,
      quarantined: false,
      healthy: true,
    });
  }, [sourceHomeIdentity]);

  useEffect(() => {
    if (!attributionSettings.enabled
      || !ownsAttributionPersistence
      || pendingPreciseFailure === null
      || pendingPreciseFailure.sourceHomeIdentity !== sourceHomeIdentity
      || preciseFailureAttemptRef.current.get(sourceHomeIdentity) === pendingPreciseFailure.id) return;
    const mutationFence = persistenceFenceRef.current;
    if (!attributionPersistenceFenceIsCurrent(sourceHomeIdentity, mutationFence)) {
      setPersistenceOwner((previous) => previous.sourceHomeIdentity === sourceHomeIdentity
        ? { ...previous, healthy: false, isOwner: false }
        : previous);
      return;
    }
    preciseFailureAttemptRef.current.set(sourceHomeIdentity, pendingPreciseFailure.id);
    const gap = markPreciseUsageContinuityGap(
      sourceHomeIdentity,
      pendingPreciseFailure.detectedAtUnix,
    );
    setAttributionPersistence((previous) => ({
      sourceHomeIdentity,
      healthy: gap !== null,
      revision: previous.sourceHomeIdentity === sourceHomeIdentity
        ? previous.revision + 1
        : 1,
    }));
    if (gap !== null) {
      acknowledgePreciseUsageFailure(
        sourceHomeIdentity,
        pendingPreciseFailure.id,
      );
      safetyRefreshRef.current?.();
    }
  }, [
    attributionSettings.enabled,
    ownsAttributionPersistence,
    pendingPreciseFailure,
    sourceHomeIdentity,
  ]);

  useEffect(() => {
    if (!attributionSettings.enabled || corruptPersistenceKeys.length === 0) return;
    if (!holdsAttributionPersistenceLease) return;
    const attemptSignature = JSON.stringify([sourceHomeIdentity, corruptPersistenceKeys]);
    if (persistenceRecoveryAttemptRef.current === attemptSignature) return;
    persistenceRecoveryAttemptRef.current = attemptSignature;
    const recovered = quarantineAndRebaselineAttributionPersistence(
      sourceHomeIdentity,
      corruptPersistenceKeys,
      preciseDataCoveredAtUnix ?? Date.now() / 1_000,
    );
    let ownerHealthy = recovered.healthy;
    let replacementFence = persistenceFenceRef.current;
    if (ownerHealthy && attributionPersistenceFenceIsCurrent(
      sourceHomeIdentity,
      replacementFence,
    )) {
      ownerHealthy = true;
    } else if (ownerHealthy) {
      const replacement = publishAttributionPersistenceOwnerFence(
        sourceHomeIdentity,
        ownerIDRef.current,
        Date.now(),
        ATTRIBUTION_OWNER_LEASE_MS,
      );
      replacementFence = replacement.lease;
      ownerHealthy = replacement.healthy
        && replacement.isOwner
        && replacementFence !== null;
      persistenceFenceRef.current = ownerHealthy ? replacementFence : null;
    }
    setPersistenceRecovery({
      sourceHomeIdentity,
      quarantined: recovered.quarantined,
      healthy: recovered.healthy && ownerHealthy,
    });
    if (recovered.healthy && ownerHealthy && replacementFence !== null) {
      setPersistenceOwner((previous) => previous.sourceHomeIdentity === sourceHomeIdentity
        ? {
            ...previous,
            healthy: true,
            isOwner: true,
            ownerID: replacementFence.ownerID,
            observationEpoch: replacementFence.observationEpoch,
            sequence: replacementFence.sequence,
            leaseUntilUnixMs: replacementFence.leaseUntilUnixMs,
          }
        : previous);
    }
    setAttributionPersistence((previous) => ({
      sourceHomeIdentity,
      healthy: recovered.healthy && ownerHealthy,
      revision: previous.sourceHomeIdentity === sourceHomeIdentity
        ? previous.revision + 1
        : 1,
    }));
    if (recovered.healthy && ownerHealthy) safetyRefreshRef.current?.();
  }, [
    attributionSettings.enabled,
    corruptPersistenceKeys,
    holdsAttributionPersistenceLease,
    preciseDataCoveredAtUnix,
    sourceHomeIdentity,
  ]);

  useEffect(() => {
    if (!attributionSettings.enabled
      || !ownsAttributionPersistence
      || !attributionStorageReadsHealthy
      || !nativeSafetyMetadataHealthy
      || preciseAttributionCurrentScanUnsafe) return;
    const mutationFence = persistenceFenceRef.current;
    if (!attributionPersistenceFenceIsCurrent(sourceHomeIdentity, mutationFence)) {
      setPersistenceOwner((previous) => previous.sourceHomeIdentity === sourceHomeIdentity
        ? { ...previous, healthy: false, isOwner: false }
        : previous);
      return;
    }
    let attemptedMutation = false;
    let healthy = true;
    let highWaterDurable = highWaterState.healthy && highWaterState.record !== null;
    if (highWaterKey
      && bucketMerge.changed
      && preciseDataFresh
      && persistenceCutoffUnix !== null
      && typeof canonicalResetAtUnix === "number") {
      attemptedMutation = true;
      highWaterDurable = writeAttributionHighWater(highWaterKey, bucketMerge.record);
      healthy &&= highWaterDurable;
    }

    if (highWaterDurable
      && highWaterKey
      && !quotaDataStale
      && segmentResolution.segment) {
      const cleanup = pruneAttributionHighWaterCycles({
        scopeKey: segmentResolution.segment.scopeKey,
        plan: segmentResolution.segment.plan,
        limit: segmentResolution.segment.limit,
      });
      if (!cleanup.healthy || cleanup.removed.length > 0) attemptedMutation = true;
      healthy &&= cleanup.healthy;
    }

    let segmentDurable = storedSegmentState.healthy && storedSegmentState.value !== null;
    const segmentToPersist = segmentResolution.segment === null
      ? null
      : segmentResolution.segment.baselineReady && highWaterDurable
        ? { ...segmentResolution.segment, highWaterInitialized: true }
        : segmentResolution.segment;
    const segmentMarkerChanged = segmentToPersist !== null
      && segmentToPersist.highWaterInitialized !== segmentResolution.segment?.highWaterInitialized;
    if (!quotaDataStale
      && segmentResolution.storageKey
      && segmentToPersist
      && (segmentResolution.changed || segmentMarkerChanged)) {
      attemptedMutation = true;
      segmentDurable = writeAttributionSegment(
        segmentResolution.storageKey,
        segmentToPersist,
      );
      healthy &&= segmentDurable;
    }

    if (segmentDurable
      && segmentResolution.storageKey
      && segmentToPersist
      && legacyResidueState.keys.length > 0) {
      attemptedMutation = true;
      const retirement = retireLegacyAttributionSegments(sourceHomeIdentity);
      healthy &&= retirement.healthy;
    }

    const continuityGap = continuityState.gap;
    const requiredCoverage = segmentResolution.segment?.requiredLocalObservationAfterUnix ?? null;
    if (healthy
      && highWaterDurable
      && segmentDurable
      && !quotaDataStale
      && continuityGap !== null
      && preciseDataFresh
      && preciseDataCoveredAtUnix !== null
      && requiredCoverage !== null
      && preciseDataCoveredAtUnix >= requiredCoverage
      && segmentResolution.segment?.baselineReady === true
      && segmentResolution.segment.cutoverReason === "continuityGap"
      && segmentResolution.segment.continuityGapID === continuityGap.id) {
      attemptedMutation = true;
      const cleared = clearPreciseUsageContinuityGap(
        sourceHomeIdentity,
        continuityGap.id,
      );
      healthy &&= cleared;
    }

    if (!attemptedMutation
      && healthy
      && !writeStorageHealthy
      && !bucketMerge.changed
      && !segmentResolution.changed) {
      attemptedMutation = true;
    }
    if (!attemptedMutation && healthy) return;
    setAttributionPersistence((previous) => ({
      sourceHomeIdentity,
      healthy,
      revision: previous.sourceHomeIdentity === sourceHomeIdentity
        ? previous.revision + 1
        : 1,
    }));
  }, [
    attributionSettings.enabled,
    attributionStorageReadsHealthy,
    bucketMerge.changed,
    bucketMerge.record,
    canonicalResetAtUnix,
    continuityState.gap,
    highWaterKey,
    highWaterState.healthy,
    highWaterState.record,
    legacyResidueState.keys,
    nativeSafetyMetadataHealthy,
    ownsAttributionPersistence,
    persistenceCutoffUnix,
    preciseDataCoveredAtUnix,
    preciseDataFresh,
    preciseAttributionCurrentScanUnsafe,
    quotaDataStale,
    segmentResolution,
    sourceHomeIdentity,
    storedSegmentState.healthy,
    storedSegmentState.value,
    writeStorageHealthy,
  ]);

  useEffect(() => {
    const durableSegment = storedSegmentState.value;
    if (!attributionSettings.enabled
      || !ownsAttributionPersistence
      || !writeStorageHealthy
      || !nativeSafetyMetadataHealthy
      || preciseAttributionCurrentScanUnsafe
      || !preciseDataFresh
      || nativeUnsafeEpisode === null
      || !onAttributionSafetyAcknowledge
      || !storedSegmentState.healthy
      || durableSegment === null
      || durableSegment.baselineReady
      || durableSegment.cutoverReason !== "continuityGap"
      || durableSegment.continuityGapID !== nativeUnsafeEpisode.unsafeID) return;
    const acknowledgementFence = persistenceFenceRef.current;
    if (!attributionPersistenceFenceIsCurrent(sourceHomeIdentity, acknowledgementFence)
      || acknowledgementFence === null) return;
    const attemptSignature = JSON.stringify([
      sourceHomeIdentity,
      nativeUnsafeEpisode.provenanceEpoch,
      nativeUnsafeEpisode.unsafeID,
      nativeUnsafeEpisode.generation,
    ]);
    if (nativeSafetyAcknowledgeAttemptRef.current === attemptSignature) return;
    nativeSafetyAcknowledgeAttemptRef.current = attemptSignature;
    let cancelled = false;
    const fenceKey = persistenceFenceKey(acknowledgementFence);
    const operation = onAttributionSafetyAcknowledge(
      nativeUnsafeEpisode.provenanceEpoch,
      nativeUnsafeEpisode.unsafeID,
      nativeUnsafeEpisode.generation,
    ).then((acknowledged) => {
      if (cancelled
        || !attributionPersistenceFenceIsCurrent(
          sourceHomeIdentity,
          acknowledgementFence,
        )) return;
      let healthy = acknowledged;
      if (acknowledged && continuityState.gap !== null) {
        healthy = clearPreciseUsageContinuityGap(
          sourceHomeIdentity,
          continuityState.gap.id,
        );
      }
      setAttributionPersistence((previous) => ({
        sourceHomeIdentity,
        healthy,
        revision: previous.sourceHomeIdentity === sourceHomeIdentity
          ? previous.revision + 1
          : 1,
      }));
      if (!acknowledged) onAttributionSafetyRefreshNeeded?.();
    }).catch(() => {
      if (cancelled
        || !attributionPersistenceFenceIsCurrent(
          sourceHomeIdentity,
          acknowledgementFence,
        )) return;
      setAttributionPersistence((previous) => ({
        sourceHomeIdentity,
        healthy: false,
        revision: previous.sourceHomeIdentity === sourceHomeIdentity
          ? previous.revision + 1
          : 1,
      }));
    });
    const pending = pendingFencedOperationsRef.current.get(fenceKey) ?? new Set();
    pending.add(operation);
    pendingFencedOperationsRef.current.set(fenceKey, pending);
    void operation.finally(() => {
      const current = pendingFencedOperationsRef.current.get(fenceKey);
      current?.delete(operation);
      if (current?.size === 0) pendingFencedOperationsRef.current.delete(fenceKey);
    });
    return () => {
      cancelled = true;
    };
  }, [
    attributionSettings.enabled,
    continuityState.gap,
    nativeSafetyMetadataHealthy,
    nativeUnsafeEpisode,
    onAttributionSafetyAcknowledge,
    onAttributionSafetyRefreshNeeded,
    ownsAttributionPersistence,
    preciseAttributionCurrentScanUnsafe,
    preciseDataFresh,
    sourceHomeIdentity,
    storedSegmentState.healthy,
    storedSegmentState.value,
    writeStorageHealthy,
  ]);

  useEffect(() => {
    if (!segmentResolution.pendingAlignmentAdvanced
      || !segmentResolution.segment
      || !onAttributionPreciseRefreshNeeded) return;
    const comparisonUpdatedAt = new Date(
      segmentResolution.segment.comparisonUpdatedAtUnix * 1_000,
    ).toISOString();
    if (requestedAlignmentRefreshRef.current === comparisonUpdatedAt) return;
    requestedAlignmentRefreshRef.current = comparisonUpdatedAt;
    onAttributionPreciseRefreshNeeded(comparisonUpdatedAt);
  }, [onAttributionPreciseRefreshNeeded, segmentResolution]);

  useEffect(() => {
    if (!showAttributionDetails) return undefined;
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setShowAttributionDetails(false);
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [showAttributionDetails]);

  const selectedQuotaRefreshIntervalMs = sanitizeQuotaRefreshIntervalMs(quotaRefreshIntervalMs);
  const visibleQuotaLimits = [snapshot.fiveHour, snapshot.sevenDay]
    .filter((quota) => quota.availability !== "absent");
  const quotaStripClassName = [
    "quota-strip",
    visibleQuotaLimits.length === 1 ? "quota-strip--single-window" : "",
    showResetDetails || showAttributionDetails ? "quota-strip--details-open" : "",
  ].filter(Boolean).join(" ");

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
    <section className={quotaStripClassName} aria-label="账户额度">
      <div className="quota-plan">
        <span>本地账户额度</span>
        <strong>本地读取</strong>
      </div>
      {visibleQuotaLimits.map((quota) => <QuotaBar key={quota.label} quota={quota} />)}
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
      <div className={onQuotaRefreshIntervalChange
        ? "quota-side-card quota-pace quota-pace--with-cadence"
        : "quota-side-card quota-pace quota-pace--without-cadence"}
        style={{ "--pace-accent": quotaPaceAccent(snapshot.paceLabel) } as CSSProperties}
      >
        <div className="quota-pace-copy">
          <div className="quota-pace-title">
            <strong>{snapshot.paceLabel}</strong>
            {attributionSettings.enabled ? (
              <button
                aria-expanded={showAttributionDetails}
                className="shared-attribution-trigger"
                onClick={() => setShowAttributionDetails(true)}
                title="查看本机与共享账号用量归因"
                type="button"
              >
                <span>归因</span>
                <b>{compactAttributionText(attribution)}</b>
              </button>
            ) : null}
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
      {showAttributionDetails ? (
        <SharedAccountAttributionDetail
          attribution={attribution}
          onClose={() => setShowAttributionDetails(false)}
          sourceUrl={radarSnapshot?.links.html ?? "https://codexradar.com"}
        />
      ) : null}
    </section>
  );
}

function compactAttributionText(attribution: SharedAccountAttributionResult): string {
  if (attribution.status === "nativeHistoryUnsafe") return "本机历史安全检查中";
  if (attribution.status === "persistenceRebaseline") return "损坏记录已隔离";
  if (attribution.quotaDataStale || attribution.radarDataStale) return "旧数据待刷新";
  switch (attribution.status) {
    case "disabled": return "已关闭";
    case "attributionStorageUnavailable": return "归因存储待恢复";
    case "positiveResidual":
      return `本≈${plainPercent(attribution.localSharePercent)} · 他≈${plainPercent(attribution.residualPercent)}`;
    case "negativeResidual":
      return `本≈${plainPercent(attribution.localSharePercent)} · 差${signedPercent(attribution.residualPercent)}`;
    case "indistinguishable":
      return attribution.historyChangedLowConfidence
        ? `本≈${plainPercent(attribution.localSharePercent)} · 低置信`
        : `本≈${plainPercent(attribution.localSharePercent)} · 差${signedPercent(attribution.residualPercent)}`;
    case "waitingQuotaRefresh": return attribution.localSharePercent === null
      ? "等待额度刷新"
      : `本≈${plainPercent(attribution.localSharePercent)} · 待刷新`;
    case "preciseDataUnavailable": return "精确统计准备中";
    case "preciseDataStale": return "精确用量待刷新";
    case "quotaUnavailable": return "额度待读取";
    case "quotaResetUnavailable": return "等待重置时间";
    case "identityUnavailable": return "等待账号身份";
    case "quotaTimestampUnavailable": return "等待额度时间";
    case "radarUnavailable": return "等待雷达";
    case "radarTierUnavailable": return "套餐总额缺失";
    case "pricingVersionUnavailable": return "价格基准待确认";
    case "awaitingAccountSwitchBaseline":
      if (attribution.cutoverReason === "continuityGap") return "连续性基线待刷新";
      if (attribution.cutoverReason === "legacyMigration") return "升级基线待刷新";
      if (attribution.cutoverReason === "initialActivation") return "首次基线待刷新";
      return "切号基线待刷新";
    case "localHistoryAmbiguous": return `本≈${plainPercent(attribution.localSharePercent)} · 来源待确认`;
  }
}

function attributionStatusTitle(attribution: SharedAccountAttributionResult): string {
  if (attribution.status === "nativeHistoryUnsafe") return "本机历史来源正在重新确认";
  if (attribution.status === "persistenceRebaseline") return "损坏记录已隔离并等待新基线";
  if (attribution.quotaDataStale || attribution.radarDataStale) return "旧数据 · 等待刷新";
  if (attribution.status !== "localHistoryAmbiguous"
    && attribution.historyChangedLowConfidence) return "本地历史发生变化 · 低置信";
  switch (attribution.status) {
    case "disabled": return "共享账号归因已关闭";
    case "attributionStorageUnavailable": return "归因持久记录暂不可用";
    case "positiveResidual": return "检测到明显正差额";
    case "negativeResidual": return "本机估值高于额度变化";
    case "indistinguishable": return "暂时无法区分他人使用";
    case "waitingQuotaRefresh": return "等待额度刷新";
    case "preciseDataUnavailable": return "精确本地统计尚未就绪";
    case "preciseDataStale": return "精确用量尚未覆盖额度快照";
    case "quotaUnavailable": return "账号额度尚未读到";
    case "quotaResetUnavailable": return "当前额度周期尚未确定";
    case "identityUnavailable": return "等待稳定账号身份";
    case "quotaTimestampUnavailable": return "等待额度快照时间";
    case "radarUnavailable": return "Codex 雷达额度尚未读到";
    case "radarTierUnavailable": return `${attribution.selectedTierLabel} 的 7 天总额缺失`;
    case "pricingVersionUnavailable": return "雷达价格版本尚未确定";
    case "awaitingAccountSwitchBaseline":
      if (attribution.cutoverReason === "continuityGap") return "精确读取恢复后等待安全基线";
      if (attribution.cutoverReason === "legacyMigration") return "升级后等待安全基线";
      if (attribution.cutoverReason === "initialActivation") return "首次启用后等待安全基线";
      return "账号切换后等待新基线";
    case "localHistoryAmbiguous": return "本机历史来源暂时无法安全合并";
  }
}

function attributionStatusDescription(attribution: SharedAccountAttributionResult): string {
  switch (attribution.status) {
    case "disabled":
      return "可在“监控与额度”重新开启；关闭期间不会计算、读取或写入归因数据。";
    case "attributionStorageUnavailable":
      return "分段、高水位或连续性记录无法完整读取或回读验证；已停止归因，恢复持久存储后会自动重算。";
    case "nativeHistoryUnsafe":
      return "本轮精确扫描仍检测到重写、重复来源或账本校验异常；不会建立基线、合并金额或确认安全事件。";
    case "persistenceRebaseline":
      return "无法验证的本地归因记录已原样隔离；现在从新的连续性切点重新等待额度与本机精确用量基线。";
    case "positiveResidual":
      return "账号下降幅度高于本机估算；超出误差带的部分可能来自其他使用者。";
    case "negativeResidual":
      return "保留负差额，不归零。常见原因包括价格模型、额度取整、刷新延迟或本机分桶误差。";
    case "indistinguishable":
      return "差额位于 ±2 个百分点误差带内，不能据此判断是否有人共同使用。";
    case "waitingQuotaRefresh":
      if (attribution.quotaDataStale) return "账号额度读取失败，当前显示旧快照；刷新成功后会自动重算。";
      if (attribution.radarDataStale) return "Radar 刷新失败，当前显示旧分母；刷新成功后会自动重算。";
      return "已经读到本机 token，但账号额度仍未体现变化；刷新后会自动重算。";
    case "preciseDataUnavailable":
      return "等待精确本地会话索引完成；不会用粗略会话大小替代。";
    case "preciseDataStale":
      return "完整精确时间序列必须晚于或等于额度快照；读取失败、紧凑快照或旧覆盖时间都只会等待。";
    case "quotaUnavailable":
      return "需要账号当前 7 天已用百分比，稍后刷新额度即可重算。";
    case "quotaResetUnavailable":
      return "需要 7 天重置时间来锁定本轮起点，避免把上个周期算进来。";
    case "identityUnavailable":
      return "原生额度读取尚未提供匿名稳定 scope；为避免串账号，当前不计算也不持久化。";
    case "quotaTimestampUnavailable":
      return "需要额度实际更新时间来排除与快照重叠的 5 分钟桶。";
    case "radarUnavailable":
      return "归因只订阅主界面已有的雷达共享状态，不会额外发起网络请求。";
    case "radarTierUnavailable":
      return "不会拿 5 小时金额冒充 7 天套餐总额；可在“监控与额度”切换套餐。";
    case "pricingVersionUnavailable":
      return "缺少可匹配的雷达日期，因此暂不把新旧价格基准混在同一次计算中。";
    case "awaitingAccountSwitchBaseline":
      if (attribution.cutoverReason === "continuityGap") {
        return "精确读取曾中断，未知区间已隔离。恢复点之后还需一份更新的额度快照固定安全基线，期间不会推断他人使用。";
      }
      if (attribution.cutoverReason === "legacyMigration") {
        return "旧预览记录缺少完整安全边界，已从升级切点重新等待额度基线，不会把旧周期直接当成可归因数据。";
      }
      if (attribution.cutoverReason === "initialActivation") {
        return "首次启用或进入新周期时没有可证明完整的历史基线；从安全切点后的下一份新鲜额度快照开始计算。";
      }
      return "已保存切号分段；首个越过 5 分钟边界的新鲜额度快照会成为基线，此前不会把边界内本机用量误算给他人。";
    case "localHistoryAmbiguous":
      return "当前桶缺少完整稳定的来源身份，或同一来源出现回退。保留本机金额诊断，但不计算“他人估算”差额。";
  }
}

function plainPercent(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return "--";
  return `${Math.abs(value) >= 100 ? value.toFixed(0) : value.toFixed(1)}%`;
}

function signedPercent(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return "--";
  const sign = value > 0 ? "+" : value < 0 ? "−" : "";
  return `${sign}${Math.abs(value).toFixed(1)}%`;
}

function money(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return "--";
  return `${value < 0 ? "−" : ""}$${Math.abs(value).toFixed(value >= 100 ? 0 : 2)}`;
}

function parsedUnix(value: string | undefined): number | null {
  if (!value) return null;
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) ? milliseconds / 1_000 : null;
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function localTimestamp(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return "--";
  return new Date(value * 1_000).toLocaleString("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function emptyBucketMergeResult(): AttributionBucketMergeResult {
  return {
    record: {
      buckets: {},
      updatedAt: "",
      provenanceEpoch: null,
      metadataObservedAtUnix: 0,
      coverageStartUnix: 0,
      coverageEndUnix: 0,
      ambiguityDetected: false,
      quotaObservationFresh: false,
    },
    effectiveBuckets: [],
    scannedBuckets: [],
    hasPendingUsage: false,
    usedHistoricalHighWater: false,
    ambiguityDetected: false,
    quotaObservationFresh: false,
    changed: false,
  };
}

export const QuotaStrip = memo(QuotaStripView);

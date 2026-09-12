import { DiagnosticNotice } from "./DiagnosticNotice";
import { ModelAmountPair } from "./ModelAmountPair";
import { memo, useEffect, useMemo, useState, type CSSProperties } from "react";
import type { DashboardStats, LocalDataWarning, ModelTokenBreakdown, RecentUsagePoint } from "../types/dashboard";
import { usagePrecisionWarnings } from "../state/dashboardWarnings";
import { formatTokens } from "../utils/format";
import type { OfficialAPIPriceModel } from "./recentUsageChart/model";
import {
  estimateLifetimeSavings,
  isOfficialAPIPriceModel,
  QUOTA_PRICE_MODEL_EVENT,
  lifetimeBreakdownFromStats,
  savingsPresentation,
} from "./statsStrip/savings";
import { readStoredQuotaPriceModel } from "../settings/quotaPriceModel";
import {
  dashboardPrimaryModelUsageItems,
  dashboardSecondaryModelUsageItems,
  normalizedMoneyText,
  floatingModelUsageValue,
  floatingTodayModelUsageItems,
  hasUnknownModelPrices,
} from "../floating/floatingModelUsage";
import { useQuotaCycleHistory } from "./statsStrip/useQuotaCycleHistory";
import { QuotaCycleControls, quotaCycleErrorStatus } from "./statsStrip/QuotaCycleControls";
import { QuotaCycleCalendar } from "./statsStrip/QuotaCycleCalendar";
import type { CodexHomeSourceToken, QuotaAttributionIdentity } from "../types/dashboard";
import { modelCostRowsAvailable } from "./tokenActivity/modelCostAvailability";

interface StatsStripProps {
  sourceToken?: CodexHomeSourceToken | null;
  attributionIdentity?: QuotaAttributionIdentity | null;
  quotaUpdatedAt?: string | null;
  stats: DashboardStats;
  todayModelBreakdowns?: ModelTokenBreakdown[];
  todayTokens?: number;
  /** Freshness of the lightweight today-model summary, independent of charts. */
  usageSummaryFresh?: boolean;
  /**
   * The native `recentUsage24h` compatibility field is the full 30-day,
   * five-minute canvas. Use it for the precise current 7d model-cost scope;
   * `recentUsage7d` is intentionally an hourly presentation series.
   */
  recentUsageFiveMinute?: RecentUsagePoint[];
  sevenDayResetAtUnix?: number | null;
  preciseDataFresh?: boolean;
  planLabel: string;
  warnings?: LocalDataWarning[];
}

const statsConfig: Array<[keyof DashboardStats, string, (value: number) => string]> = [
  ["totalTokens", "累计 Token 数", formatTokens],
  ["peakDayTokens", "峰值 Token 数", formatTokens],
  ["peakThreadTokens", "单会话最大 Token", formatTokens],
  ["currentStreakDays", "当前连续天数", (value) => `${value} 天`],
  ["longestStreakDays", "最长连续天数", (value) => `${value} 天`],
];

type ModelCostScope = "today" | "sevenDay" | "lifetime";
type ModelAttributionDisplayState = "current" | "stale" | "pending";

function StatsStripView({
  sourceToken = null,
  attributionIdentity = null,
  quotaUpdatedAt = null,
  stats,
  todayModelBreakdowns = [],
  todayTokens = 0,
  usageSummaryFresh = false,
  preciseDataFresh = true,
  planLabel,
  warnings = [],
}: StatsStripProps) {
  const usageWarnings = usagePrecisionWarnings(warnings);
  const [priceModel, setPriceModel] = useState<OfficialAPIPriceModel>("gpt56Sol");
  const [modelCostScope, setModelCostScope] = useState<ModelCostScope>("sevenDay");
  const [calendarExpanded, setCalendarExpanded] = useState(false);
  const lifetimeSavings = useMemo(() => savingsPresentation(estimateLifetimeSavings({
    breakdown: lifetimeBreakdownFromStats(stats),
    firstUsageAt: stats.firstUsageAt,
    planLabel,
    priceModel,
    modelBreakdowns: stats.modelBreakdowns,
  })), [planLabel, priceModel, stats]);
  const cycleHistory = useQuotaCycleHistory(sourceToken, attributionIdentity,
    `${quotaUpdatedAt ?? ""}|${preciseDataFresh}|${stats.totalTokens}`, modelCostScope === "sevenDay");
  const periodLabel = cycleHistory.selected?.current === false ? "历史周期" : "本期";
  const selectCycle = (id: string) => { cycleHistory.select(id); setCalendarExpanded(false); };
  useEffect(() => { setCalendarExpanded(false); }, [modelCostScope, sourceToken?.canonicalHomeKey, attributionIdentity?.scopeKey]);
  const cycleModelsIncomplete = cycleHistory.usage?.modelBreakdowns.some(row =>
    row.breakdown.totalTokens > 0 && (typeof row.model !== "string" || !row.model.trim()),
  ) ?? false;
  const sevenDayModelDisplayState: ModelAttributionDisplayState = cycleHistory.usage && !cycleModelsIncomplete
    ? (preciseDataFresh && !cycleHistory.refreshing ? "current" : "stale") : "pending";
  const todayModelDisplayState: ModelAttributionDisplayState = !usageSummaryFresh
    ? (todayModelBreakdowns.length > 0 ? "stale" : "pending")
    : todayTokens <= 0
      ? "current"
      : todayModelBreakdowns.length > 0
        ? "current"
        : "pending";
  const modelCostRows = modelCostScope === "today"
    ? todayModelBreakdowns
    : modelCostScope === "lifetime"
    ? stats.modelBreakdowns ?? []
    : sevenDayModelDisplayState === "current" || sevenDayModelDisplayState === "stale"
    ? cycleHistory.usage?.modelBreakdowns ?? []
    : [];
  const expectedModelTokens = modelCostScope === "today"
    ? todayTokens
    : modelCostScope === "lifetime"
    ? stats.totalTokens
    : cycleHistory.usage?.modelBreakdowns.reduce((total, row) => total + row.breakdown.totalTokens, 0) ?? 0;
  const modelCostDataAvailable = modelCostScope === "sevenDay"
    ? sevenDayModelDisplayState !== "pending"
    : modelCostScope === "today"
    ? todayModelDisplayState !== "pending"
    : modelCostRowsAvailable(modelCostRows, preciseDataFresh);
  const modelDetailAvailable = modelCostScope === "sevenDay"
    ? sevenDayModelDisplayState !== "pending"
    : modelCostScope === "today"
    ? todayModelDisplayState !== "pending"
    : expectedModelTokens <= 0 || modelCostRows.length > 0;
  const modelCostItems = useMemo(() => (
    modelCostDataAvailable && modelDetailAvailable
      ? floatingTodayModelUsageItems(modelCostRows, priceModel, { mergeAutoReview: false })
      : []
  ), [modelCostDataAvailable, modelCostRows, modelDetailAvailable, priceModel]);
  const modelCostTotal = modelCostItems.reduce((total, item) => total + (item.costUSD ?? 0), 0);
  const modelPricesIncomplete = hasUnknownModelPrices(modelCostItems);
  const selectedModelDisplayState = modelCostScope === "sevenDay"
    ? sevenDayModelDisplayState
    : modelCostScope === "today"
    ? todayModelDisplayState
    : "current";
  const independentReferenceSummary = modelCostItems
    .filter((item) => item.referenceCostUSD !== null)
    .map((item) => `${item.label} 参考 ${normalizedMoneyText(item.referenceCostUSD ?? 0, item.referenceCostUSD ?? 0)}`)
    .join(" · ");
  const boundaryTokens = cycleHistory.usage?.boundaryModelBreakdowns.reduce((sum,row)=>sum+row.breakdown.totalTokens,0) ?? 0;
  const boundaryTokenSummary = modelCostScope === "sevenDay" && boundaryTokens > 0
    ? `未确定所属周期 · ${formatTokens(boundaryTokens)} Token` : "";
  const boundaryItems = useMemo(() => floatingTodayModelUsageItems(
    cycleHistory.usage?.boundaryModelBreakdowns ?? [], priceModel, { mergeAutoReview: false },
  ).filter(item => item.tokens > 0).map(item => item.key === "unknown"
    ? { ...item, costUSD: null } : item), [cycleHistory.usage, priceModel]);
  const primaryModelCostItems = dashboardPrimaryModelUsageItems(modelCostItems);
  const secondaryModelCostItems = dashboardSecondaryModelUsageItems(modelCostItems);

  useEffect(() => {
    setPriceModel(readStoredQuotaPriceModel());
    const onPriceModel = (event: Event) => {
      const next = (event as CustomEvent<string>).detail;
      if (isOfficialAPIPriceModel(next)) setPriceModel(next);
    };
    window.addEventListener(QUOTA_PRICE_MODEL_EVENT, onPriceModel);
    return () => window.removeEventListener(QUOTA_PRICE_MODEL_EVENT, onPriceModel);
  }, []);

  return (
    <>
      <section className="stats-overview-card" aria-label="Token 总览">
        <div className="stats-strip">
          {statsConfig.slice(0, 1).map(([key, label, format]) => (
            <div className="stats-cell" key={key}>
              <strong>{format(Number(stats[key]))}</strong>
              <span>{label}</span>
            </div>
          ))}
          <div className="stats-cell stats-cell--savings" title={lifetimeSavings.helpText}>
            <strong>{lifetimeSavings.valueText}</strong>
            {lifetimeSavings.normalizedValueText ? <small className="stats-normalized-value">{lifetimeSavings.normalizedValueText}</small> : null}
            <span>{lifetimeSavings.labelText}</span>
          </div>
          {statsConfig.slice(1).map(([key, label, format]) => (
            <div className="stats-cell" key={key}>
              <strong>{format(Number(stats[key]))}</strong>
              <span>{label}</span>
            </div>
          ))}
        </div>

        <div className="stats-model-cost-row" aria-label={`${modelCostScope === "sevenDay" ? periodLabel : modelCostScope === "today" ? "今日" : "累计"}模型费用`}>
          <div className="stats-model-cost-header">
            <strong className="stats-model-cost-title">模型费用</strong>
            <div className="stats-model-cost-scope" role="group" aria-label="模型费用范围">
              <button
                aria-pressed={modelCostScope === "sevenDay"}
                className={modelCostScope === "sevenDay" ? "is-active" : undefined}
                onClick={() => { selectCycle("current"); setModelCostScope("sevenDay"); }}
                type="button"
              >
                {modelCostScope === "sevenDay" && periodLabel === "历史周期" ? "历史" : "本期"}
              </button>
              <button
                aria-pressed={modelCostScope === "today"}
                className={modelCostScope === "today" ? "is-active" : undefined}
                onClick={() => setModelCostScope("today")}
                type="button"
              >
                今日
              </button>
              <button
                aria-pressed={modelCostScope === "lifetime"}
                className={modelCostScope === "lifetime" ? "is-active" : undefined}
                onClick={() => setModelCostScope("lifetime")}
                type="button"
              >
                累计
              </button>
            </div>
            {modelCostScope === "sevenDay" ? <QuotaCycleControls cycles={cycleHistory.cycles}
              selected={cycleHistory.selected} onSelect={selectCycle}
              expanded={calendarExpanded} onToggle={() => setCalendarExpanded(value => !value)} /> : null}
            {selectedModelDisplayState !== "current" ? (
              <span className="stats-model-cost-status" role="status">
                {modelCostScope === "sevenDay" && selectedModelDisplayState === "pending" ? (cycleHistory.error ? quotaCycleErrorStatus(cycleHistory.error) : cycleModelsIncomplete ? "模型身份待补全" : "周期明细待读取") : "正在精准计算中…"}{selectedModelDisplayState === "stale" ? " 显示上次可信结果" : ""}
              </span>
            ) : null}
            {modelCostDataAvailable && modelDetailAvailable && modelCostItems.length > 0 ? (
              <span className="stats-model-cost-total-wrap">
                <strong className="stats-model-cost-total">
                  {modelPricesIncomplete ? "已知价格小计" : modelCostScope === "sevenDay" && cycleHistory.selected?.incomplete ? "已观测部分" : "合计"} API {normalizedMoneyText(modelCostTotal, modelCostItems.reduce((total, item) => total + (item.normalizedCostUSD ?? 0), 0))}
                </strong>
                {modelPricesIncomplete ? <small className="stats-model-cost-reference">部分模型价格未知，未计入金额</small> : null}
                {independentReferenceSummary ? (
                  <small className="stats-model-cost-reference">
                    {independentReferenceSummary}
                  </small>
                ) : null}

              </span>
            ) : null}
          </div>
          {modelCostScope === "sevenDay" && calendarExpanded ? <QuotaCycleCalendar cycles={cycleHistory.cycles}
            selected={cycleHistory.selected} onSelect={selectCycle} /> : null}
          {modelCostScope === "sevenDay" && boundaryItems.length > 0 ? (
            <details className="stats-quota-boundary-detail">
              <summary>{boundaryTokenSummary}</summary>
              <p>这些用量发生在周期切换附近，暂时无法确定属于哪一期，因此未计入周期合计。记录仍然保留。</p>
              {boundaryItems.map(item => <span key={item.key}>{item.label} · {formatTokens(item.tokens)} Token · {item.key === "unknown" ? "模型身份待补全" : `API 等值约 ${floatingModelUsageValue(item, "cost")}`}</span>)}
            </details>
          ) : null}
          {modelCostScope === "sevenDay" && selectedModelDisplayState === "pending" ? (
            <span className="stats-model-cost-empty">{cycleHistory.error ? quotaCycleErrorStatus(cycleHistory.error) : cycleModelsIncomplete ? `${formatTokens(expectedModelTokens)} Token · 模型身份待补全` : `${periodLabel}模型明细待读取`}</span>
          ) : modelCostScope === "today" && selectedModelDisplayState === "pending" ? (
            <span className="stats-model-cost-empty">今日模型明细待读取</span>
          ) : !modelCostDataAvailable ? (
            <span className="stats-model-cost-empty">模型费用待读取</span>
          ) : !modelDetailAvailable ? (
            <span className="stats-model-cost-empty">
              {modelCostScope === "today" ? "今日模型明细待读取" : "逐模型历史待读取"}
            </span>
          ) : modelCostItems.length === 0 ? (
            <span className="stats-model-cost-empty">
              {modelCostScope === "sevenDay" ? `${periodLabel}暂无模型用量` : modelCostScope === "today" ? "今日暂无模型用量" : "暂无逐模型历史"}
            </span>
          ) : (
            <div className="stats-model-cost-groups">
              <div className="stats-model-cost-group">
                <span className="stats-model-cost-group-label">主力</span>
                <div className="stats-model-cost-primary-grid">
                  {primaryModelCostItems.map((item) => (
                    <span
                      className="stats-model-cost-primary-card"
                      key={item.key}
                      style={{ "--model-color": item.color } as CSSProperties}
                    >
                      <i />
                      <em>{item.label}</em>
                      <b><ModelAmountPair item={item} /></b>
                      <small>{formatTokens(item.tokens)} · {floatingModelUsageValue(item, "share")}</small>
                    </span>
                  ))}
                </div>
              </div>
              {secondaryModelCostItems.length > 0 ? (
                <div className="stats-model-cost-group">
                  <span className="stats-model-cost-group-label">其他</span>
                  <div className="stats-model-cost-secondary-grid">
                    {secondaryModelCostItems.map((item) => (
                      <span className="stats-model-cost-secondary-chip" key={item.key}>
                        <i style={{ backgroundColor: item.color }} />
                        <em>{item.label}</em>
                        <b><ModelAmountPair item={item} /></b>
                        <small>{formatTokens(item.tokens)} · {floatingModelUsageValue(item, "share")}</small>
                      </span>
                    ))}
                  </div>
                </div>
              ) : null}
            </div>
          )}
        </div>
      </section>
      {usageWarnings.length > 0 ? (
        <section className="usage-precision-note" aria-label="Token 统计读取提示" role="status">
          <DiagnosticNotice summary="用量统计暂不完整" logs={JSON.stringify(usageWarnings, null, 2)} />
        </section>
      ) : null}
    </>
  );
}

export const StatsStrip = memo(StatsStripView);

import { clientCostGroups, clientModelCostItems, type ClientCostPeriods } from "../multiClient/originalDashboardProjection";
import { modelPresentationDetail } from "../domain/modelPresentationIdentity";
import { ClientColorSettings, ModelColorEditor, type ColorEditTarget } from "./liveRate/ModelColorEditor";
import { useSpeedPalette } from "./liveRate/useSpeedPalette";
import { dashboardModelUsageColor, floatingModelUsageKey } from "./modelUsagePresentation";
import { DiagnosticNotice } from "./DiagnosticNotice";
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
  floatingModelUsageMoneyText,
  floatingModelUsageKnownCostUSD,
  floatingModelUsageValue,
  isReferenceOnlyModelUsage,
  hasUnknownModelPrices,
} from "../floating/floatingModelUsage";
import { useQuotaCycleHistory } from "./statsStrip/useQuotaCycleHistory";
import { QuotaCycleControls, quotaCycleErrorStatus } from "./statsStrip/QuotaCycleControls";
import { QuotaCycleCalendar } from "./statsStrip/QuotaCycleCalendar";
import { ModelDayCalendar } from "./statsStrip/ModelDayCalendar";
import { useModelDayUsage } from "./statsStrip/useModelDayUsage";
import type { CodexHomeSourceToken, QuotaAttributionIdentity } from "../types/dashboard";
import { modelCostRowsAvailable } from "./tokenActivity/modelCostAvailability";

interface StatsStripProps {
  clientCosts?: ClientCostPeriods;
  dayClients?: readonly string[];
  dayRefreshKey?: string;
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
  clientCosts,
  dayClients = ["codex"],
  dayRefreshKey = "",
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
  const palette = useSpeedPalette();
  const [editingColor, setEditingColor] = useState<ColorEditTarget | null>(null);
  const usageWarnings = usagePrecisionWarnings(warnings);
  const [priceModel, setPriceModel] = useState<OfficialAPIPriceModel>("gpt56Sol");
  const [modelCostScope, setModelCostScope] = useState<ModelCostScope>("sevenDay");
  const [calendarExpanded, setCalendarExpanded] = useState(false);
  const [selectedDay, setSelectedDay] = useState<string|null>(null);
  const [dayCalendarExpanded, setDayCalendarExpanded] = useState(false);
  const dayUsage = useModelDayUsage(selectedDay, sourceToken, dayClients, dayRefreshKey);
  const leaveDay = () => {setSelectedDay(null);setDayCalendarExpanded(false);};
  const lifetimeSavings = useMemo(() => savingsPresentation(estimateLifetimeSavings({
    breakdown: lifetimeBreakdownFromStats(stats),
    firstUsageAt: stats.firstUsageAt,
    planLabel,
    priceModel,
    modelBreakdowns: stats.modelBreakdowns,
  })), [planLabel, priceModel, stats]);
  const cycleHistory = useQuotaCycleHistory(sourceToken, attributionIdentity,
    `${quotaUpdatedAt ?? ""}|${preciseDataFresh}|${stats.totalTokens}`, modelCostScope === "sevenDay" && !clientCosts && !selectedDay);
  const periodLabel = clientCosts ? "近7天" : cycleHistory.selected?.current === false ? "历史周期" : "本期";
  const selectCycle = (id: string) => { cycleHistory.select(id); };
  useEffect(() => { setEditingColor(null); setCalendarExpanded(false); }, [modelCostScope, sourceToken?.canonicalHomeKey, attributionIdentity?.scopeKey]);
  const sevenDayModelDisplayState: ModelAttributionDisplayState = cycleHistory.usage
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
  const modelCostDataAvailable = selectedDay ? Boolean(dayUsage.value?.availableClients.length) : clientCosts ? true : modelCostScope === "sevenDay"
    ? sevenDayModelDisplayState !== "pending"
    : modelCostScope === "today"
    ? todayModelDisplayState !== "pending"
    : modelCostRowsAvailable(modelCostRows, preciseDataFresh);
  const modelDetailAvailable = selectedDay ? Boolean(dayUsage.value) : clientCosts ? true : modelCostScope === "sevenDay"
    ? sevenDayModelDisplayState !== "pending"
    : modelCostScope === "today"
    ? todayModelDisplayState !== "pending"
    : expectedModelTokens <= 0 || modelCostRows.length > 0;
  const modelCostItems = useMemo(() => (
    selectedDay ? dayUsage.items : clientCosts ? clientCosts[modelCostScope] : modelCostDataAvailable && modelDetailAvailable
      ? clientModelCostItems([], modelCostRows, ['codex'], priceModel)
      : []
  ), [selectedDay, dayUsage.items, clientCosts, modelCostScope, modelCostDataAvailable, modelCostRows, modelDetailAvailable, priceModel, palette]);
  const modelCostTotal = floatingModelUsageKnownCostUSD(modelCostItems);
  const modelPricesIncomplete = hasUnknownModelPrices(modelCostItems);
  const selectedModelDisplayState = selectedDay ? (dayUsage.loading ? "pending" : dayUsage.refreshing ? "stale" : "current") : clientCosts ? (clientCosts.codexPendingScopes?.includes(modelCostScope as "today"|"sevenDay") ? "pending" : "current") : modelCostScope === "sevenDay"
    ? sevenDayModelDisplayState
    : modelCostScope === "today"
    ? todayModelDisplayState
    : "current";
  const referenceCostSummary = modelCostItems
    .filter((item) => item.referenceCostUSD !== null)
    .map((item) => `${item.label} 参考 ${floatingModelUsageMoneyText(item.referenceCostUSD ?? 0)}`)
    .join(" · ");
  const modelFamilies = useMemo(()=>clientCostGroups(modelCostItems),[modelCostItems]);
  const fillFirstModelRow = !selectedDay && modelCostScope !== "lifetime";

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
              <strong>{clientCosts && key === "peakThreadTokens" ? "—" : format(Number(stats[key]))}</strong>
              <span>{label}</span>
            </div>
          ))}
          <div className="stats-cell stats-cell--savings" title={clientCosts ? "标准API等值，非订阅扣费" : lifetimeSavings.helpText}>
            <strong>{clientCosts ? (floatingModelUsageKnownCostUSD(clientCosts.lifetime) === null ? "—" : floatingModelUsageMoneyText(floatingModelUsageKnownCostUSD(clientCosts.lifetime)!)) : lifetimeSavings.valueText}</strong>
            <span>{clientCosts ? "已知 API 等值" : lifetimeSavings.labelText}</span>
          </div>
          {statsConfig.slice(1).map(([key, label, format]) => (
            <div className="stats-cell" key={key}>
              <strong>{clientCosts && key === "peakThreadTokens" ? "—" : format(Number(stats[key]))}</strong>
              <span>{label}</span>
            </div>
          ))}
        </div>

        <div className="stats-model-cost-row" aria-label={`${selectedDay ?? (modelCostScope === "sevenDay" ? periodLabel : modelCostScope === "today" ? "今日" : "累计")}模型费用`}>
          <div className="model-day-controls">
            <button type="button" aria-expanded={dayCalendarExpanded} onClick={()=>setDayCalendarExpanded(value=>!value)}>单日金额 ▦</button>
            {selectedDay && <><span>{selectedDay}</span><button type="button" onClick={leaveDay}>返回汇总</button></>}
          </div>
          {dayCalendarExpanded && <ModelDayCalendar selected={selectedDay} onSelect={key=>{setSelectedDay(key);setCalendarExpanded(false);}}/>}
          <div className="stats-model-cost-header">
            <strong className="stats-model-cost-title">模型费用</strong>
            {!selectedDay && <div className="stats-model-cost-scope-and-hint">
              <div className="stats-model-cost-scope" role="group" aria-label="模型费用范围">
                <button
                  aria-pressed={modelCostScope === "sevenDay"}
                  className={modelCostScope === "sevenDay" ? "is-active" : undefined}
                  onClick={() => { selectCycle("current"); setModelCostScope("sevenDay"); }}
                  type="button"
                >
                  {clientCosts ? "近7天" : modelCostScope === "sevenDay" && periodLabel === "历史周期" ? "历史" : "本期"}
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
              {modelCostScope === "lifetime" && <span className="model-color-inline-hint">双击可修改模型配色</span>}
            </div>}
            {selectedDay && <span className="model-day-label">{selectedDay}</span>}
            {!selectedDay && !clientCosts && modelCostScope === "sevenDay" ? <QuotaCycleControls cycles={cycleHistory.cycles}
              selected={cycleHistory.selected} onSelect={selectCycle}
              expanded={calendarExpanded} onToggle={() => setCalendarExpanded(value => !value)} /> : null}
            {selectedModelDisplayState !== "current" ? (
              <span className="stats-model-cost-status" role="status">
                {selectedDay ? "正在读取单日金额…" : !clientCosts && modelCostScope === "sevenDay" && selectedModelDisplayState === "pending" ? (cycleHistory.error ? quotaCycleErrorStatus(cycleHistory.error) : "周期明细待读取") : "正在精准计算中…"}{selectedModelDisplayState === "stale" ? " 显示上次可信结果" : ""}
              </span>
            ) : null}
            {modelCostDataAvailable && modelDetailAvailable && modelCostItems.length > 0 ? (
              <span className="stats-model-cost-total-wrap">
                <strong className="stats-model-cost-total">
                  {modelPricesIncomplete || (selectedDay && dayUsage.value?.issues.length) ? "已知价格小计" : !selectedDay && modelCostScope === "sevenDay" && cycleHistory.selected?.incomplete ? "已观测部分" : "合计"} {modelCostTotal === null ? "—" : `API ${floatingModelUsageMoneyText(modelCostTotal)}`}
                </strong>
                {modelPricesIncomplete ? <small className="stats-model-cost-reference">部分模型价格未知，未计入金额</small> : null}
                {referenceCostSummary ? (
                  <small className="stats-model-cost-reference">
                    {referenceCostSummary}（不计入合计）
                  </small>
                ) : null}

              </span>
            ) : null}
          </div>
          {selectedDay && <div className="model-day-status">
            <span>{Intl.DateTimeFormat().resolvedOptions().timeZone} · 所选日期的已记录参考费用</span>
            {dayUsage.value?.issues.map(issue=><p key={issue}>{issue}</p>)}
            {dayUsage.error && <p role="alert">单日金额读取失败：{dayUsage.error}</p>}
            {(dayUsage.error || Boolean(dayUsage.value?.issues.length)) && <button type="button" onClick={dayUsage.retry}>重新读取单日</button>}
          </div>}
          {!selectedDay && !clientCosts && modelCostScope === "sevenDay" && calendarExpanded ? <QuotaCycleCalendar cycles={cycleHistory.cycles}
            selected={cycleHistory.selected} onSelect={selectCycle} /> : null}
          {selectedDay && dayUsage.loading ? <span className="stats-model-cost-empty">所选日期模型明细待读取</span>
          : selectedDay && !modelCostDataAvailable ? <span className="stats-model-cost-empty">单日金额暂不可用</span>
          : selectedDay && !modelCostItems.length ? <span className="stats-model-cost-empty">{dayUsage.value?.issues.length ? "已读到的来源暂无记录；部分来源待核验" : "该日暂无已记录用量 · $0.00"}</span>
          : !selectedDay && !clientCosts && modelCostScope === "sevenDay" && selectedModelDisplayState === "pending" ? (
            <span className="stats-model-cost-empty">{cycleHistory.error ? quotaCycleErrorStatus(cycleHistory.error) : `${periodLabel}模型明细待读取`}</span>
          ) : !selectedDay && modelCostScope === "today" && selectedModelDisplayState === "pending" ? (
            <span className="stats-model-cost-empty">{clientCosts ? "Codex 今日模型明细同步中" : "今日模型明细待读取"}</span>
          ) : !modelCostDataAvailable ? (
            <span className="stats-model-cost-empty">模型费用待读取</span>
          ) : !modelDetailAvailable ? (
            <span className="stats-model-cost-empty">
              {modelCostScope === "today" ? "今日模型明细待读取" : "逐模型历史待读取"}
            </span>
          ) : modelCostItems.length === 0 ? (
            fillFirstModelRow && !clientCosts?.codexPendingScopes?.includes(modelCostScope as "today"|"sevenDay") ? <div className="stats-model-cost-secondary-grid" aria-label="暂无模型用量">
              <span className="stats-model-cost-placeholder">暂无模型用量</span><span className="stats-model-cost-placeholder">暂无模型用量</span>
            </div> : <span className="stats-model-cost-empty">
              {clientCosts?.codexPendingScopes?.includes(modelCostScope as "today"|"sevenDay") ? "Codex 模型明细同步中" : modelCostScope === "sevenDay" ? `${periodLabel}暂无模型用量` : modelCostScope === "today" ? "今日暂无模型用量" : "暂无逐模型历史"}
            </span>
          ) : (
            <div className="stats-model-cost-groups">
              {modelFamilies.map(group => <div className="stats-model-cost-group" key={group.id}>
                <span className="stats-model-cost-group-label">{group.label}</span>
                <div className={group.id === "latest" ? "stats-model-cost-primary-grid" : "stats-model-cost-secondary-grid"}>
                  {group.items.map(item => {
                    const color = dashboardModelUsageColor(item.key, group.id === "latest");
                    const referenceOnly = isReferenceOnlyModelUsage(item);
                    const label = item.label.replace(/^GPT[- ]*/i, "");
                    const qualifiedLabel = label.match(/^(.*?)(（[^）]*）)$/);
                    const amount = item.tokens === 0 ? "—" : referenceOnly
                      ? (item.referenceCostUSD === null ? "—" : (item.key==='unknown-models'?'参考 ':'')+floatingModelUsageMoneyText(item.referenceCostUSD))
                      : floatingModelUsageValue(item,"cost");
                    const detail = item.tokens === 0 ? "暂无本地记录"
                      : `${referenceOnly ? "参考 · " : ""}${formatTokens(item.tokens)} · ${floatingModelUsageValue(item,"share")}`;
                    const description = item.tokens === 0 ? `${item.label} · 暂无本地记录`
                      : `${item.label} · ${floatingModelUsageValue(item,"cost")} · ${detail}`;
                    return <span className={group.id === "latest" ? "stats-model-cost-primary-card" : "stats-model-cost-secondary-chip"} key={item.key} style={{"--model-color":color} as CSSProperties}
                    aria-label={description} title={`${description}${item.key.includes('|')?' · 来源：'+item.key.split('|')[0]:''}${item.sourceModels?.length?' · 原始标识：'+item.sourceModels.map(modelPresentationDetail).join('、'):''} · 双击修改该模型颜色`}
                    role="button" tabIndex={0}
                    onDoubleClick={event => setEditingColor({ model: floatingModelUsageKey(item.key.split("|").at(-1)), x: event.clientX, y: event.clientY, grayDefault: group.id !== "latest" })}
                    onKeyDown={event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); const rect = event.currentTarget.getBoundingClientRect(); setEditingColor({ model: floatingModelUsageKey(item.key.split("|").at(-1)), x: rect.left, y: rect.bottom, grayDefault: group.id !== "latest" }); } }}>
                    <i style={{backgroundColor:color}}/><em><span className="model-cost-name">{qualifiedLabel ? qualifiedLabel[1] : label}</span>{qualifiedLabel && <span className="model-cost-name-suffix">{qualifiedLabel[2]}</span>}</em><small className="model-cost-tokens">{item.tokens === 0 ? "暂无记录" : formatTokens(item.tokens)}</small>{item.tokens > 0 && <small className="model-cost-share">{floatingModelUsageValue(item,"share")}</small>}<b>{amount}</b>
                  </span>;
                  })}
                  {fillFirstModelRow && group.items.length === 1 && <span className="stats-model-cost-placeholder">暂无其他模型用量</span>}
                </div>
              </div>)}
            </div>
          )}
          {modelCostScope === "lifetime" && <div className="model-color-footer"><span>双击模型修改颜色 · 全局同步</span><ClientColorSettings/></div>}
          <ModelColorEditor target={editingColor} onClose={() => setEditingColor(null)}/>
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

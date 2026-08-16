import { memo, useEffect, useMemo, useState, type CSSProperties } from "react";
import type { DashboardStats, LocalDataWarning, ModelTokenBreakdown, RecentUsagePoint } from "../types/dashboard";
import { usagePrecisionWarnings } from "../state/dashboardWarnings";
import { formatTokens } from "../utils/format";
import type { OfficialAPIPriceModel } from "./recentUsageChart/model";
import {
  estimateLifetimeSavings,
  estimateRecent7dAPICost,
  isOfficialAPIPriceModel,
  QUOTA_PRICE_MODEL_EVENT,
  lifetimeBreakdownFromStats,
  savingsPresentation,
} from "./statsStrip/savings";
import { readStoredQuotaPriceModel } from "../settings/quotaPriceModel";
import {
  dashboardPrimaryModelUsageItems,
  dashboardSecondaryModelUsageItems,
  floatingModelUsageMoneyText,
  floatingModelUsageValue,
  floatingTodayModelUsageItems,
} from "../floating/floatingModelUsage";
import { modelCostRowsAvailable } from "./tokenActivity/modelCostAvailability";

interface StatsStripProps {
  stats: DashboardStats;
  todayModelBreakdowns?: ModelTokenBreakdown[];
  todayTokens?: number;
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

function StatsStripView({
  stats,
  todayModelBreakdowns = [],
  todayTokens = 0,
  recentUsageFiveMinute = [],
  sevenDayResetAtUnix = null,
  preciseDataFresh = true,
  planLabel,
  warnings = [],
}: StatsStripProps) {
  const usageWarnings = usagePrecisionWarnings(warnings);
  const [priceModel, setPriceModel] = useState<OfficialAPIPriceModel>("gpt56Sol");
  const [modelCostScope, setModelCostScope] = useState<ModelCostScope>("sevenDay");
  const lifetimeSavings = useMemo(() => savingsPresentation(estimateLifetimeSavings({
    breakdown: lifetimeBreakdownFromStats(stats),
    firstUsageAt: stats.firstUsageAt,
    planLabel,
    priceModel,
    modelBreakdowns: stats.modelBreakdowns,
  })), [planLabel, priceModel, stats]);
  const recent7dModelCost = useMemo(() => estimateRecent7dAPICost({
    points: recentUsageFiveMinute,
    resetAtUnix: sevenDayResetAtUnix,
    priceModel,
  }), [priceModel, recentUsageFiveMinute, sevenDayResetAtUnix]);
  const modelCostRows = modelCostScope === "today"
    ? todayModelBreakdowns
    : modelCostScope === "lifetime"
    ? stats.modelBreakdowns ?? []
    : recent7dModelCost?.modelBreakdowns ?? [];
  const expectedModelTokens = modelCostScope === "today"
    ? todayTokens
    : modelCostScope === "lifetime"
    ? stats.totalTokens
    : recent7dModelCost?.modelBreakdowns.reduce((total, row) => total + row.breakdown.totalTokens, 0) ?? 0;
  const modelCostDataAvailable = modelCostScope === "sevenDay"
    ? recent7dModelCost !== null
    : modelCostRowsAvailable(modelCostRows, preciseDataFresh);
  const modelDetailAvailable = modelCostScope === "sevenDay"
    ? recent7dModelCost !== null
    : expectedModelTokens <= 0 || modelCostRows.length > 0;
  const modelCostItems = useMemo(() => (
    modelCostDataAvailable && modelDetailAvailable
      ? floatingTodayModelUsageItems(modelCostRows, priceModel)
      : []
  ), [modelCostDataAvailable, modelCostRows, modelDetailAvailable, priceModel]);
  const modelCostTotal = modelCostItems.reduce((total, item) => total + (item.costUSD ?? 0), 0);
  const independentReferenceSummary = modelCostItems
    .filter((item) => item.referenceCostUSD !== null)
    .map((item) => `${item.label} 参考 ${floatingModelUsageMoneyText(item.referenceCostUSD ?? 0)}`)
    .join(" · ");
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
            <span>{lifetimeSavings.labelText}</span>
          </div>
          {statsConfig.slice(1).map(([key, label, format]) => (
            <div className="stats-cell" key={key}>
              <strong>{format(Number(stats[key]))}</strong>
              <span>{label}</span>
            </div>
          ))}
        </div>

        <div className="stats-model-cost-row" aria-label={`${modelCostScope === "sevenDay" ? "本7d" : modelCostScope === "today" ? "今日" : "累计"}各模型 API 等值费用`}>
          <div className="stats-model-cost-header">
            <div className="stats-model-cost-scope" role="group" aria-label="模型费用范围">
              <button
                aria-pressed={modelCostScope === "sevenDay"}
                className={modelCostScope === "sevenDay" ? "is-active" : undefined}
                onClick={() => setModelCostScope("sevenDay")}
                type="button"
              >
                本7d
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
            <strong className="stats-model-cost-title">各模型 API 等值费用</strong>
            {modelCostDataAvailable && modelDetailAvailable && modelCostItems.length > 0 ? (
              <span className="stats-model-cost-total-wrap">
                <strong className="stats-model-cost-total">
                  合计 {floatingModelUsageMoneyText(modelCostTotal)}
                </strong>
                {independentReferenceSummary ? (
                  <small className="stats-model-cost-reference">
                    {independentReferenceSummary}
                  </small>
                ) : null}
              </span>
            ) : null}
          </div>
          {modelCostScope === "sevenDay" && recent7dModelCost === null ? (
            <span className="stats-model-cost-empty">本7d模型明细待读取</span>
          ) : !modelCostDataAvailable ? (
            <span className="stats-model-cost-empty">模型费用待读取</span>
          ) : !modelDetailAvailable ? (
            <span className="stats-model-cost-empty">
              {modelCostScope === "today" ? "今日模型明细待读取" : "逐模型历史待读取"}
            </span>
          ) : modelCostItems.length === 0 ? (
            <span className="stats-model-cost-empty">
              {modelCostScope === "sevenDay" ? "本7d暂无模型用量" : modelCostScope === "today" ? "今日暂无模型用量" : "暂无逐模型历史"}
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
                      <b>{floatingModelUsageValue(item, "cost")}</b>
                      <small>{floatingModelUsageValue(item, "share")}</small>
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
                        <b>{floatingModelUsageValue(item, "cost")}</b>
                        <small>{floatingModelUsageValue(item, "share")}</small>
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
          <strong>Token 统计准备中</strong>
          <span>{usageWarnings.map((warning) => warning.message).join("；")}</span>
        </section>
      ) : null}
    </>
  );
}

export const StatsStrip = memo(StatsStripView);

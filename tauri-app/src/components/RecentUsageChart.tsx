import { useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import type { RecentUsagePoint } from "../types/dashboard";
import { formatTokens } from "../utils/format";
import {
  normalizeOfficialAPIPriceModel,
  QUOTA_PRICE_MODEL_EVENT,
  readStoredQuotaPriceModel,
} from "../settings/quotaPriceModel";
import {
  activeQuotaSelectionEndIndex,
  clickQuotaSelection,
  clampQuotaSelection,
  DEFAULT_SERIES_VISIBILITY,
  hoverIndexForX,
  optionalSmoothPath,
  percentText,
  plotChartPoints,
  prepareRecentChartData,
  quotaConsumptionSelection,
  quotaSelectionAttribution,
  quotaSelectionDurationText,
  quotaEstimateWindowVisibility,
  recentChartScrollLayout,
  recentChartTimeMarkers,
  recentChartVisibleWindowLabel,
  smoothPath,
  tokenAreaPath,
  type OfficialAPIPriceModel,
  type QuotaConsumptionEstimate,
  type QuotaConsumptionSelection,
  type QuotaSelectionAttributionResult,
  type QuotaSelectionState,
  type RecentChartRange,
  type SeriesVisibility,
} from "./recentUsageChart/model";
import type { SharedAccountAttributionResult } from "./sharedAccountAttribution/model";
import { modelUsageSlices } from "./modelUsagePresentation.ts";

interface RecentUsageChartProps {
  recentUsage24h: RecentUsagePoint[];
  recentUsage7d: RecentUsagePoint[];
  recentUsage30d: RecentUsagePoint[];
  fiveHourQuotaPresent?: boolean;
  sevenDayQuotaPresent?: boolean;
  sharedAccountAttribution?: SharedAccountAttributionResult | null;
}

const CHART_WIDTH = 980;
const CHART_HEIGHT = 185;
const PLOT_TOP = 18;
const PLOT_HEIGHT = 143;
const RANGE_OPTIONS: RecentChartRange[] = ["24h", "7d", "30d"];
const VISIBILITY_STORAGE_KEY = "recentChartVisibility";
const RANGE_STORAGE_KEY = "recentChartRange";
export function RecentUsageChart({
  recentUsage24h,
  recentUsage7d,
  recentUsage30d,
  fiveHourQuotaPresent = true,
  sevenDayQuotaPresent = true,
  sharedAccountAttribution = null,
}: RecentUsageChartProps) {
  const [range, setRange] = useState<RecentChartRange>(() => readStoredRange());
  const [visibility, setVisibility] = useState<SeriesVisibility>(() => readStoredVisibility());
  const [hoveredIndex, setHoveredIndex] = useState<number | null>(null);
  const [quotaModel, setQuotaModel] = useState<OfficialAPIPriceModel>(() => readStoredQuotaModel());
  const [quotaSelectionState, setQuotaSelectionState] = useState<QuotaSelectionState>({ startIndex: null, fixedEndIndex: null });
  const svgRef = useRef<SVGSVGElement | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const [chartScrollLeft, setChartScrollLeft] = useState(0);
  const [chartViewportWidth, setChartViewportWidth] = useState(CHART_WIDTH);
  const data = useMemo(
    () => prepareRecentChartData(range, { recentUsage24h, recentUsage7d, recentUsage30d }),
    [range, recentUsage24h, recentUsage7d, recentUsage30d],
  );
  const scrollLayout = recentChartScrollLayout(data.range, data.points.length, data.bucketSeconds, CHART_WIDTH);
  const chartWidth = scrollLayout.contentWidth;
  const scrollContentStyle = {
    "--recent-chart-content-width": `${chartWidth}px`,
    "--recent-chart-aspect-ratio": `${chartWidth} / ${CHART_HEIGHT}`,
  } as CSSProperties;
  const visibleWindowLabel = recentChartVisibleWindowLabel(data, chartWidth, chartScrollLeft, chartViewportWidth);
  const plotData = useMemo(() => plotChartPoints(data, chartWidth, PLOT_HEIGHT), [data, chartWidth]);
  const activeIndex = hoveredIndex !== null && data.points[hoveredIndex] ? hoveredIndex : null;
  const activePoint = activeIndex !== null ? data.points[activeIndex] : null;
  const activeTokenPoint = activeIndex !== null ? plotData.tokenPoints[activeIndex] : null;
  const fixedSelectionEndIndex = quotaSelectionState.fixedEndIndex !== null && data.points[quotaSelectionState.fixedEndIndex]
    ? quotaSelectionState.fixedEndIndex
    : null;
  const quotaEndIndex = activeQuotaSelectionEndIndex(
    clampQuotaSelection(quotaSelectionState, data.points.length),
    activeIndex,
    Math.max(data.points.length - 1, 0),
  );
  const consumptionSelection = quotaSelectionState.startIndex !== null && quotaEndIndex !== null
    ? quotaConsumptionSelection(data, quotaSelectionState.startIndex, quotaEndIndex, quotaModel)
    : null;
  const selectionAttribution = range === "24h"
    && fixedSelectionEndIndex !== null
    && consumptionSelection !== null
    ? quotaSelectionAttribution(consumptionSelection, sharedAccountAttribution)
    : null;
  const quotaEstimateVisibility = quotaEstimateWindowVisibility(data);

  useLayoutEffect(() => {
    const scrollElement = scrollRef.current;
    if (!scrollElement) {
      return;
    }
    scrollElement.scrollLeft = scrollLayout.latestScrollLeft;
    setChartScrollLeft(scrollElement.scrollLeft);
    setChartViewportWidth(scrollElement.clientWidth || CHART_WIDTH);
  }, [scrollLayout.latestScrollLeft, data.range, data.points.length]);

  useEffect(() => {
    const onPriceModel = (event: Event) => {
      const next = normalizeOfficialAPIPriceModel((event as CustomEvent<unknown>).detail);
      if (next) setQuotaModel(next);
    };
    window.addEventListener(QUOTA_PRICE_MODEL_EVENT, onPriceModel);
    return () => window.removeEventListener(QUOTA_PRICE_MODEL_EVENT, onPriceModel);
  }, []);


  function updateRange(next: RecentChartRange) {
    setRange(next);
    setHoveredIndex(null);
    setQuotaSelectionState({ startIndex: null, fixedEndIndex: null });
    window.localStorage.setItem(RANGE_STORAGE_KEY, next);
  }

  function updateVisibility(key: keyof SeriesVisibility) {
    setVisibility((current) => {
      const next = { ...current, [key]: !current[key] };
      window.localStorage.setItem(VISIBILITY_STORAGE_KEY, JSON.stringify(next));
      return next;
    });
  }

  function handlePointerMove(event: React.PointerEvent<SVGSVGElement>) {
    const rect = svgRef.current?.getBoundingClientRect();
    if (!rect) {
      return;
    }
    const x = ((event.clientX - rect.left) / rect.width) * chartWidth;
    const y = ((event.clientY - rect.top) / rect.height) * CHART_HEIGHT;
    if (y < PLOT_TOP || y > PLOT_TOP + PLOT_HEIGHT) {
      setHoveredIndex(null);
      return;
    }
    setHoveredIndex(hoverIndexForX(x, chartWidth, data.points.length));
  }

  function handlePointerDown(event: React.PointerEvent<SVGSVGElement>) {
    const rect = svgRef.current?.getBoundingClientRect();
    if (!rect) {
      return;
    }
    const x = ((event.clientX - rect.left) / rect.width) * chartWidth;
    const y = ((event.clientY - rect.top) / rect.height) * CHART_HEIGHT;
    if (y < PLOT_TOP || y > PLOT_TOP + PLOT_HEIGHT) {
      return;
    }
    const clickedIndex = hoverIndexForX(x, chartWidth, data.points.length);
    if (clickedIndex === null) {
      return;
    }
    setHoveredIndex(clickedIndex);
    setQuotaSelectionState((current) => clickQuotaSelection(current, clickedIndex, data.points.length));
  }

  return (
    <section className="chart-section" aria-label={data.title}>
      <div className="recent-chart-head">
        <div className="recent-chart-title">
          <h2>{data.title}</h2>
          <span className="recent-estimate-hint">点击起点/终点可估算额度</span>
          <span>{data.subtitle}</span>
        </div>
        <div className="recent-range-tabs" aria-label="曲线范围">
          {RANGE_OPTIONS.map((option) => (
            <button
              aria-pressed={range === option}
              className={range === option ? "is-active" : ""}
              key={option}
              onClick={() => updateRange(option)}
              type="button"
            >
              {option}
            </button>
          ))}
        </div>
        <div className="recent-chart-controls">
          <div className="chart-legend">
            <LegendDot className="legend-dot--token" label="Token" value={formatTokens(data.tokenTotal)} />
            <LegendDot className="legend-dot--calls" label="调用" value={`${data.callTotal}`} />
            <LegendDot className="legend-dot--hit" label="命中率" value={percentText(data.cacheHitRate)} />
            {fiveHourQuotaPresent ? <LegendDot className="legend-dot--five" label="5h" value={percentText(data.latestFiveHourRemaining)} /> : null}
            {sevenDayQuotaPresent ? <LegendDot className="legend-dot--seven" label="7d" value={percentText(data.latestSevenDayRemaining)} /> : null}
          </div>
          <div className="chart-line-toggles" aria-label="曲线显示">
            <LineToggle active={visibility.tokens} className="toggle-token" label="Token" onClick={() => updateVisibility("tokens")} />
            <LineToggle active={visibility.calls} className="toggle-calls" label="调用" onClick={() => updateVisibility("calls")} />
            <LineToggle
              active={visibility.cacheHitRate}
              className="toggle-hit"
              label="命中率"
              onClick={() => updateVisibility("cacheHitRate")}
            />
            {fiveHourQuotaPresent ? <LineToggle active={visibility.fiveHourQuota} className="toggle-five" label="5h" onClick={() => updateVisibility("fiveHourQuota")} /> : null}
            {sevenDayQuotaPresent ? <LineToggle active={visibility.sevenDayQuota} className="toggle-seven" label="7d" onClick={() => updateVisibility("sevenDayQuota")} /> : null}
          </div>
        </div>
      </div>

      <div className="recent-chart-plot">
        <div
          className={scrollLayout.className}
          ref={scrollRef}
          aria-label={scrollLayout.isHorizontal ? "最近 24 小时图表可左右滚动" : undefined}
          onScroll={(event) => {
            setChartScrollLeft(event.currentTarget.scrollLeft);
            setChartViewportWidth(event.currentTarget.clientWidth || CHART_WIDTH);
          }}
          tabIndex={scrollLayout.isHorizontal ? 0 : undefined}
        >
          <div className="recent-chart-scroll-content" style={scrollContentStyle}>
            <svg
              ref={svgRef}
              className="usage-chart"
              onPointerDown={handlePointerDown}
              onPointerLeave={() => setHoveredIndex(null)}
              onPointerMove={handlePointerMove}
              role="img"
              viewBox={`0 0 ${chartWidth} ${CHART_HEIGHT}`}
            >
              <title>{chartAccessibility(data, visibility, fiveHourQuotaPresent, sevenDayQuotaPresent)}</title>
              <rect className="chart-plot-bg" x="0" y={PLOT_TOP} width={chartWidth} height={PLOT_HEIGHT} rx="8" />
              {consumptionSelection ? <SelectionRange chartWidth={chartWidth} pointCount={data.points.length} selection={consumptionSelection} /> : null}
              {[0, 1, 2, 3].map((line) => {
                const y = PLOT_TOP + (line * PLOT_HEIGHT) / 3;
                return <line className="chart-grid-line" key={line} x1="0" x2={chartWidth} y1={y} y2={y} />;
              })}
              {visibility.tokens ? (
                <>
                  <path className="chart-area" d={offsetPath(tokenAreaPath(plotData.tokenPoints, chartWidth, PLOT_HEIGHT))} />
                  <path className="chart-line chart-line--token" d={offsetPath(smoothPath(plotData.tokenPoints))} />
                </>
              ) : null}
              {visibility.calls ? (
                <path className="chart-line chart-line--calls" d={offsetPath(smoothPath(plotData.callPoints))} />
              ) : null}
              {visibility.cacheHitRate && data.hasCacheCalls ? (
                <g className="chart-observation-points chart-observation-points--hit">
                  {plotData.cachePoints.map((point, index) => point ? (
                    <circle
                      className="chart-observation-point chart-observation-point--hit"
                      cx={point.x}
                      cy={point.y + PLOT_TOP}
                      key={index}
                      r="1.6"
                    />
                  ) : null)}
                </g>
              ) : null}
              {fiveHourQuotaPresent && visibility.fiveHourQuota && data.hasFiveHourQuota ? (
                <path className="chart-line chart-line--five" d={offsetPath(optionalSmoothPath(plotData.fiveHourQuotaPoints))} />
              ) : null}
              {sevenDayQuotaPresent && visibility.sevenDayQuota && data.hasSevenDayQuota ? (
                <path className="chart-line chart-line--seven" d={offsetPath(optionalSmoothPath(plotData.sevenDayQuotaPoints))} />
              ) : null}
              {activeIndex !== null && activeTokenPoint ? (
                <HoverGuides
                  data={data}
                  fiveHourQuotaPresent={fiveHourQuotaPresent}
                  index={activeIndex}
                  plotData={plotData}
                  sevenDayQuotaPresent={sevenDayQuotaPresent}
                  visibility={visibility}
                />
              ) : null}
              <TimeMarkers chartWidth={chartWidth} data={data} />
            </svg>
          </div>
        </div>
        <div className="recent-chart-overlay-layer">
          {visibleWindowLabel ? (
            <div className="recent-chart-visible-window">当前窗口：{visibleWindowLabel}</div>
          ) : null}
          {fixedSelectionEndIndex !== null && consumptionSelection ? (
            <SelectionSummaryBubble
              selection={consumptionSelection}
              viewportWidth={chartViewportWidth}
              x={(plotData.tokenPoints[fixedSelectionEndIndex]?.x ?? 0) - chartScrollLeft}
            />
          ) : activePoint && activeTokenPoint ? (
            <HoverBubble
              bucketSeconds={data.bucketSeconds}
              cacheVisible={visibility.cacheHitRate}
              fiveHourRemaining={fiveHourQuotaPresent ? activePoint.fiveHourRemainingPercent : null}
              point={activePoint}
              sevenDayRemaining={sevenDayQuotaPresent ? activePoint.sevenDayRemainingPercent : null}
              viewportWidth={chartViewportWidth}
              x={activeTokenPoint.x - chartScrollLeft}
            />
          ) : null}
        </div>
      </div>
      {consumptionSelection ? (
        <RecentChartQuotaEstimateOverlay
          currentFiveHourQuotaPresent={fiveHourQuotaPresent}
          currentSevenDayQuotaPresent={sevenDayQuotaPresent}
          showsFiveHourQuota={quotaEstimateVisibility.fiveHour}
          selection={consumptionSelection}
          attribution={selectionAttribution}
          showsSevenDayQuota={quotaEstimateVisibility.sevenDay}
          onClose={() => setQuotaSelectionState({ startIndex: null, fixedEndIndex: null })}
        />
      ) : null}
    </section>
  );
}

function SelectionRange({ chartWidth, pointCount, selection }: { chartWidth: number; pointCount: number; selection: QuotaConsumptionSelection }) {
  const actualStep = chartWidth / Math.max(pointCount - 1, 1);
  const startX = selection.startIndex * actualStep;
  const endX = selection.endIndex * actualStep;
  const x = Math.min(startX, endX);
  const width = Math.max(Math.abs(endX - startX), 2);

  return (
    <g className="chart-selection-layer">
      <rect className="chart-selection-range" x={x} y={PLOT_TOP} width={width} height={PLOT_HEIGHT} />
      <line className="chart-selection-line" x1={startX} x2={startX} y1={PLOT_TOP} y2={PLOT_TOP + PLOT_HEIGHT} />
      <line className="chart-selection-line" x1={endX} x2={endX} y1={PLOT_TOP} y2={PLOT_TOP + PLOT_HEIGHT} />
    </g>
  );
}

function HoverGuides({
  data,
  fiveHourQuotaPresent,
  index,
  plotData,
  sevenDayQuotaPresent,
  visibility,
}: {
  data: ReturnType<typeof prepareRecentChartData>;
  fiveHourQuotaPresent: boolean;
  index: number;
  plotData: ReturnType<typeof plotChartPoints>;
  sevenDayQuotaPresent: boolean;
  visibility: SeriesVisibility;
}) {
  const tokenPoint = plotData.tokenPoints[index];
  const callPoint = plotData.callPoints[index];
  const cachePoint = plotData.cachePoints[index];
  const fiveHourPoint = plotData.fiveHourQuotaPoints[index];
  const sevenDayPoint = plotData.sevenDayQuotaPoints[index];
  const point = data.points[index];

  return (
    <g className="chart-hover-layer">
      <line className="chart-hover-line" x1={tokenPoint.x} x2={tokenPoint.x} y1={PLOT_TOP} y2={PLOT_TOP + PLOT_HEIGHT} />
      {visibility.tokens ? <HoverRing className="hover-token" point={offsetPoint(tokenPoint)} radius={4.5} /> : null}
      {visibility.calls ? <HoverRing className="hover-calls" point={offsetPoint(callPoint)} radius={4} /> : null}
      {visibility.cacheHitRate && point.calls > 0 && point.cacheHitRate !== null && cachePoint ? (
        <HoverRing className="hover-hit" point={offsetPoint(cachePoint)} radius={4} />
      ) : null}
      {fiveHourQuotaPresent && visibility.fiveHourQuota && fiveHourPoint ? <HoverRing className="hover-five" point={offsetPoint(fiveHourPoint)} radius={3.5} /> : null}
      {sevenDayQuotaPresent && visibility.sevenDayQuota && sevenDayPoint ? <HoverRing className="hover-seven" point={offsetPoint(sevenDayPoint)} radius={3.5} /> : null}
    </g>
  );
}

function HoverRing({ className, point, radius }: { className: string; point: { x: number; y: number }; radius: number }) {
  return <circle className={`chart-hover-ring ${className}`} cx={point.x} cy={point.y} r={radius} />;
}

function HoverBubble({
  bucketSeconds,
  cacheVisible,
  fiveHourRemaining,
  point,
  sevenDayRemaining,
  viewportWidth,
  x,
}: {
  bucketSeconds: number;
  cacheVisible: boolean;
  fiveHourRemaining: number | null;
  point: RecentUsagePoint;
  sevenDayRemaining: number | null;
  viewportWidth: number;
  x: number;
}) {
  const left = Math.min(Math.max(x, 92), Math.max(92, viewportWidth - 92));
  const average = point.calls > 0 ? Math.round(point.tokens / point.calls) : 0;
  const quotaParts = [
    fiveHourRemaining !== null ? `5h ${percentText(fiveHourRemaining)}` : null,
    sevenDayRemaining !== null ? `7d ${percentText(sevenDayRemaining)}` : null,
  ].filter(Boolean);

  return (
    <div className="chart-hover-bubble" style={{ left: `${left}px` }}>
      <div>
        <strong>当前点</strong>
        <span>{timeRange(point.startUnix, bucketSeconds)}</span>
      </div>
      <b>{formatTokens(point.tokens)}</b>
      <span>请求 {point.calls} 次 · avg {formatTokens(average)}</span>
      {cacheVisible && point.calls > 0 && point.cacheHitRate !== null ? (
        <em>缓存命中 {percentText(point.cacheHitRate)}</em>
      ) : null}
      <ModelUsageInline rows={point.modelBreakdowns} />
      {quotaParts.length > 0 ? <span>额度 {quotaParts.join(" · ")}</span> : null}
      <em>点击起点/终点可估算额度</em>
    </div>
  );
}

function SelectionSummaryBubble({
  selection,
  viewportWidth,
  x,
}: {
  selection: QuotaConsumptionSelection;
  viewportWidth: number;
  x: number;
}) {
  const left = Math.min(Math.max(x, 112), Math.max(112, viewportWidth - 112));
  const average = selection.calls > 0 ? Math.round(selection.totalTokens / selection.calls) : 0;
  return (
    <div className="chart-hover-bubble chart-selection-summary-bubble" style={{ left: `${left}px` }}>
      <div>
        <strong>选中区间</strong>
        <span>{timeRange(selection.startUnix, selection.endUnix - selection.startUnix)}</span>
      </div>
      <b>{formatTokens(selection.totalTokens)}</b>
      <span>请求 {selection.calls} 次 · avg {formatTokens(average)}</span>
      {selection.calls > 0 ? <em>缓存命中 {percentText(selection.cacheHitRate)}</em> : null}
      <ModelUsageInline rows={selection.modelBreakdowns} />
      <span>{quotaSelectionDurationText(selection)}</span>
    </div>
  );
}

function ModelUsageInline({
  rows,
}: {
  rows: RecentUsagePoint["modelBreakdowns"] | QuotaConsumptionSelection["modelBreakdowns"];
}) {
  const slices = modelUsageSlices(rows);
  if (slices.length === 0) return null;
  return (
    <div className="model-usage-inline" aria-label={`模型占比 ${slices.map((slice) => `${slice.label} ${Math.round(slice.share * 100)}%`).join("，")}`}>
      {slices.slice(0, 4).map((slice) => (
        <span key={slice.key}>
          <i style={{ backgroundColor: slice.color }} />
          {slice.label} {Math.round(slice.share * 100)}%
        </span>
      ))}
      {slices.length > 4 ? <span>+{slices.length - 4}</span> : null}
    </div>
  );
}

function RecentChartQuotaEstimateOverlay({
  attribution,
  currentFiveHourQuotaPresent,
  currentSevenDayQuotaPresent,
  showsFiveHourQuota,
  selection,
  showsSevenDayQuota,
  onClose,
}: {
  attribution: QuotaSelectionAttributionResult | null;
  currentFiveHourQuotaPresent: boolean;
  currentSevenDayQuotaPresent: boolean;
  showsFiveHourQuota: boolean;
  selection: QuotaConsumptionSelection;
  showsSevenDayQuota: boolean;
  onClose: () => void;
}) {
  const showsBudgetRatio = showsFiveHourQuota
    && showsSevenDayQuota
    && currentFiveHourQuotaPresent
    && currentSevenDayQuotaPresent;

  return (
    <div className="chart-quota-estimate-card" role="dialog" aria-label="额度估算">
      <div className="quota-estimate-main">
        <div className="quota-estimate-row">
          <span>本段消耗</span>
          <strong>{moneyText(selection.selectedCostUSD)}</strong>
          <b>{quotaSelectionDurationText(selection)}</b>
          <em>{timeRange(selection.startUnix, selection.endUnix - selection.startUnix)}</em>
          <b>命中 {percentText(selection.cacheHitRate)}</b>
        </div>
        <div className="quota-estimate-row">
          <span>反推总额度</span>
          {showsFiveHourQuota ? (
            <QuotaEstimateChip
              className="quota-chip--five"
              estimate={selection.fiveHour}
              isQuotaAvailable={currentFiveHourQuotaPresent}
              title="5h"
            />
          ) : null}
          {showsSevenDayQuota ? (
            <QuotaEstimateChip
              className="quota-chip--seven"
              estimate={selection.sevenDay}
              isQuotaAvailable={currentSevenDayQuotaPresent}
              title="7d"
            />
          ) : null}
        </div>
        {showsBudgetRatio ? (
          <div className="quota-estimate-row">
            <span>倍率</span>
            <strong className={selection.hasDivergentBudgetRatio ? "is-warning" : ""}>
              {selection.sevenDayToFiveHourBudgetRatio === null ? "--" : `${selection.sevenDayToFiveHourBudgetRatio.toFixed(1)}x`}
            </strong>
            <em>7d/5h，正常约 6x</em>
            {selection.hasDivergentBudgetRatio ? <b className="is-warning">偏离 6x，误差可能较大</b> : null}
          </div>
        ) : null}
        {attribution ? <QuotaSelectionAttributionRow attribution={attribution} /> : null}
      </div>
      <button aria-label="关闭额度估算" onClick={onClose} type="button">×</button>
    </div>
  );
}

function QuotaSelectionAttributionRow({ attribution }: { attribution: QuotaSelectionAttributionResult }) {
  const accountTitle = attribution.accountDropPercent === null ? "账号下降" : "账号实降";
  const differenceTitle = attribution.state === "suspectedNonLocalUsage"
    ? "疑似他人"
    : attribution.state === "localEstimateExceedsAccountDrop"
      ? "本机估高"
      : attribution.allowsAttributionConclusion ? "差额" : "暂算差额";
  const difference = attribution.nonLocalDifferencePercent;
  return (
    <>
      <div className="quota-estimate-row quota-estimate-attribution" aria-label="选区共享账号归因">
        <span>{accountTitle}</span>
        <strong>{oneDecimalPercent(attribution.accountDropPercent)}</strong>
        <i aria-hidden="true">｜</i>
        <span>本机折算</span>
        <strong>{attribution.localSharePercent === null ? "--" : `≈${oneDecimalPercent(attribution.localSharePercent)}`}</strong>
        <i aria-hidden="true">｜</i>
        <span>{differenceTitle}</span>
        <strong>{attribution.allowsAttributionConclusion && difference !== null
          ? `≈${signedOneDecimalPercent(difference)}`
          : signedOneDecimalPercent(difference)}</strong>
      </div>
      <div className="quota-estimate-row quota-estimate-attribution-detail" aria-label="选区本机 API 等价金额">
        <span>本机同基准 {moneyText(attribution.localComparableCostUSD)}</span>
        <em>当前 API {moneyText(attribution.localCurrentAPIEquivalentUSD)}</em>
      </div>
    </>
  );
}

function QuotaEstimateChip({
  title,
  estimate,
  className,
  isQuotaAvailable = true,
}: {
  title: string;
  estimate: QuotaConsumptionEstimate;
  className: string;
  isQuotaAvailable?: boolean;
}) {
  return (
    <span className={`quota-estimate-chip ${className}`}>
      <b>{title}</b>
      <span>{estimateText(estimate, title, isQuotaAvailable)}</span>
    </span>
  );
}

function TimeMarkers({ chartWidth, data }: { chartWidth: number; data: ReturnType<typeof prepareRecentChartData> }) {
  const markers = recentChartTimeMarkers(data, chartWidth);
  return (
    <>
      {markers.map((marker) => {
        return (
          <g className={`chart-time-marker-group chart-time-marker-group--${marker.kind}`} key={`${marker.kind}-${marker.index}`}>
            {marker.kind === "day" ? (
              <line
                className="chart-day-separator"
                x1={marker.x}
                x2={marker.x}
                y1={PLOT_TOP}
                y2={PLOT_TOP + PLOT_HEIGHT}
              />
            ) : null}
            <text
              className={`chart-time-marker chart-time-marker--${marker.kind}`}
              textAnchor={marker.kind === "day" ? "start" : "middle"}
              x={marker.kind === "day" ? marker.x + 6 : marker.x}
              y={PLOT_TOP + PLOT_HEIGHT + 24}
            >
              {marker.label}
            </text>
          </g>
        );
      })}
    </>
  );
}

function LegendDot({ className, label, value }: { className: string; label: string; value: string }) {
  return (
    <span className="chart-legend-item">
      <span className={`legend-dot ${className}`} />
      <span>{label}</span>
      <strong>{value}</strong>
    </span>
  );
}

function LineToggle({
  active,
  className,
  label,
  onClick,
}: {
  active: boolean;
  className: string;
  label: string;
  onClick: () => void;
}) {
  return (
    <button aria-pressed={active} className={`chart-line-toggle ${className} ${active ? "is-active" : ""}`} onClick={onClick} type="button">
      <span>{active ? "●" : "○"}</span>
      {label}
    </button>
  );
}

function offsetPath(path: string): string {
  if (!path) {
    return "";
  }
  return path.replace(/([A-Z]) ([^A-Z]+)/g, (_match, command: string, coordinates: string) => {
    const values = coordinates.trim().split(/\s+/).map(Number);
    for (let index = 1; index < values.length; index += 2) {
      values[index] += PLOT_TOP;
    }
    return `${command} ${values.map((value) => value.toFixed(1).replace(/\.0$/, "")).join(" ")}`;
  });
}

function offsetPoint(point: { x: number; y: number }) {
  return { x: point.x, y: point.y + PLOT_TOP };
}

function readStoredRange(): RecentChartRange {
  const stored = window.localStorage.getItem(RANGE_STORAGE_KEY);
  return stored === "7d" || stored === "30d" || stored === "24h" ? stored : "24h";
}

function readStoredVisibility(): SeriesVisibility {
  try {
    const parsed = JSON.parse(window.localStorage.getItem(VISIBILITY_STORAGE_KEY) ?? "{}") as Partial<SeriesVisibility>;
    return { ...DEFAULT_SERIES_VISIBILITY, ...parsed };
  } catch {
    return DEFAULT_SERIES_VISIBILITY;
  }
}

function readStoredQuotaModel(): OfficialAPIPriceModel {
  return readStoredQuotaPriceModel();
}

function chartAccessibility(
  data: ReturnType<typeof prepareRecentChartData>,
  visibility: SeriesVisibility,
  fiveHourQuotaPresent: boolean,
  sevenDayQuotaPresent: boolean,
): string {
  const visible = [
    visibility.tokens ? "Token" : null,
    visibility.calls ? "调用" : null,
    visibility.cacheHitRate && data.hasCacheCalls ? "命中率" : null,
    fiveHourQuotaPresent && visibility.fiveHourQuota && data.hasFiveHourQuota ? "5 小时额度" : null,
    sevenDayQuotaPresent && visibility.sevenDayQuota && data.hasSevenDayQuota ? "7 天额度" : null,
  ].filter(Boolean);

  return `${data.title}，${data.points.length} 个时间点，Token 总量 ${formatTokens(data.tokenTotal)}，调用 ${data.callTotal} 次，已显示 ${visible.join("、") || "无曲线"}`;
}

function estimateText(estimate: QuotaConsumptionEstimate, title: string, isQuotaAvailable: boolean): string {
  if (!isQuotaAvailable) {
    return `无 ${title} 额度`;
  }

  switch (estimate.confidence) {
    case "measured":
      return `${moneyText(estimate.impliedWindowBudgetUSD)} · 降 ${oneDecimalPercent(estimate.quotaDropPercent)}`;
    case "insufficientQuotaMovement":
      return `降 ${oneDecimalPercent(estimate.quotaDropPercent)} · 不反推`;
    case "noTokenUsage":
      return "无 token";
  }
}

function moneyText(value: number | null): string {
  if (value === null || !Number.isFinite(value)) {
    return "--";
  }
  if (value >= 100) {
    return `$${value.toFixed(0)}`;
  }
  if (value >= 10) {
    return `$${value.toFixed(1)}`;
  }
  return `$${value.toFixed(2)}`;
}

function oneDecimalPercent(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return "--";
  return Number.isInteger(value) ? `${value}%` : `${value.toFixed(1)}%`;
}

function signedOneDecimalPercent(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return "--";
  const sign = value >= 0 ? "+" : "";
  return `${sign}${oneDecimalPercent(value)}`;
}

function timeRange(startUnix: number, bucketSeconds: number): string {
  const start = new Date(startUnix * 1_000);
  const end = new Date((startUnix + bucketSeconds) * 1_000);
  if (bucketSeconds <= 60 * 60 && start.toDateString() === end.toDateString()) {
    return `${formatHourMinute(startUnix)} - ${formatHourMinute(startUnix + bucketSeconds)}`;
  }
  return `${formatMonthDayHour(startUnix)} - ${formatMonthDayHour(startUnix + bucketSeconds)}`;
}

function formatHourMinute(unix: number): string {
  const date = new Date(unix * 1_000);
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function formatMonthDay(unix: number): string {
  const date = new Date(unix * 1_000);
  return `${date.getMonth() + 1}月${date.getDate()}日`;
}

function formatMonthDayHour(unix: number): string {
  return `${formatMonthDay(unix)} ${formatHourMinute(unix)}`;
}

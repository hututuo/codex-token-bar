import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
} from "react";
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
  recentChartBucketCosts,
  recentChartFixedScaleMap,
  quotaConsumptionSelection,
  quotaComparisonScopeText,
  quotaSelectionAttribution,
  quotaSelectionDurationText,
  quotaEstimateWindowVisibility,
  recentChartGeometry,
  recentChartHoverBubbleCenter,
  recentChartScrollLayout,
  recentChartScrollbarThumb,
  recentChartScrollLeftForThumb,
  recentChartScrollPresentation,
  recentChartScrollTarget,
  recentChartTimeMarkers,
  recentChartVisibleWindowLabel,
  recentChartVisibleWindowSummary,
  smoothPath,
  shouldReopenPreviewOnHoverMove,
  tokenAreaPath,
  type OfficialAPIPriceModel,
  type QuotaConsumptionEstimate,
  type QuotaConsumptionSelection,
  type QuotaSelectionAttributionResult,
  type QuotaSelectionState,
  type Point,
  type RecentChartScrollDirection,
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
  fiveHourResetAtUnix?: number | null;
  sevenDayQuotaPresent?: boolean;
  sevenDayResetAtUnix?: number | null;
  sharedAccountAttribution?: SharedAccountAttributionResult | null;
}

const CHART_WIDTH = 980;
const COST_POINT_RADIUS = 1.68;
const CHART_HOVER_BUBBLE_FALLBACK_WIDTH = 260;
const RANGE_OPTIONS: RecentChartRange[] = ["24h", "7d", "30d"];
const VISIBILITY_STORAGE_KEY = "recentChartVisibility";
const RANGE_STORAGE_KEY = "recentChartRange";

function useChartBubbleWidth(fallbackWidth: number) {
  const bubbleRef = useRef<HTMLDivElement | null>(null);
  const [bubbleWidth, setBubbleWidth] = useState(fallbackWidth);

  useLayoutEffect(() => {
    const element = bubbleRef.current;
    if (!element) return;

    const updateWidth = () => {
      const measuredWidth = element.getBoundingClientRect().width || element.offsetWidth;
      if (!Number.isFinite(measuredWidth) || measuredWidth <= 0) return;
      setBubbleWidth((current) => Math.abs(current - measuredWidth) > 0.5 ? measuredWidth : current);
    };

    updateWidth();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(updateWidth);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  return [bubbleRef, bubbleWidth] as const;
}

export function RecentUsageChart({
  recentUsage24h,
  recentUsage7d,
  recentUsage30d,
  fiveHourQuotaPresent = true,
  fiveHourResetAtUnix = null,
  sevenDayQuotaPresent = true,
  sevenDayResetAtUnix = null,
  sharedAccountAttribution = null,
}: RecentUsageChartProps) {
  const [range, setRange] = useState<RecentChartRange>(() => readStoredRange());
  const [visibility, setVisibility] = useState<SeriesVisibility>(() => readStoredVisibility());
  const [hoveredIndex, setHoveredIndex] = useState<number | null>(null);
  const [previewDismissed, setPreviewDismissed] = useState(false);
  const [quotaModel, setQuotaModel] = useState<OfficialAPIPriceModel>(() => readStoredQuotaModel());
  const [quotaSelectionState, setQuotaSelectionState] = useState<QuotaSelectionState>({ startIndex: null, fixedEndIndex: null });
  const svgRef = useRef<SVGSVGElement | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const pendingScrollFrameRef = useRef<number | null>(null);
  const pendingScrollMetricsRef = useRef({ scrollLeft: 0, viewportWidth: CHART_WIDTH });
  const scrollbarDragRef = useRef<{ pointerId: number; grabOffset: number } | null>(null);
  const [chartScrollLeft, setChartScrollLeft] = useState(0);
  const [chartViewportWidth, setChartViewportWidth] = useState(CHART_WIDTH);
  const data = useMemo(
    () => prepareRecentChartData(range, { recentUsage24h, recentUsage7d, recentUsage30d }),
    [range, recentUsage24h, recentUsage7d, recentUsage30d],
  );
  const chartGeometry = recentChartGeometry(data.range);
  const { canvasHeight, plotTop, plotHeight, timeMarkerGap } = chartGeometry;
  const scrollLayout = recentChartScrollLayout(data.range, data.points.length, data.bucketSeconds, chartViewportWidth);
  const chartWidth = scrollLayout.contentWidth;
  const scrollPresentation = recentChartScrollPresentation(scrollLayout, chartScrollLeft);
  const scrollbarThumb = recentChartScrollbarThumb(scrollLayout, chartScrollLeft, chartViewportWidth);
  const scrollContentStyle = {
    "--recent-chart-content-width": `${chartWidth}px`,
    "--recent-chart-aspect-ratio": `${chartWidth} / ${canvasHeight}`,
  } as CSSProperties;
  const visibleWindowLabel = recentChartVisibleWindowLabel(data, chartWidth, chartScrollLeft, chartViewportWidth);
  const visibleWindowSummary = useMemo(
    () => recentChartVisibleWindowSummary(data, chartWidth, chartScrollLeft, chartViewportWidth),
    [data, chartWidth, chartScrollLeft, chartViewportWidth],
  );
  const bucketCostsUSD = useMemo(
    () => recentChartBucketCosts(data.points, quotaModel),
    [data.points, quotaModel],
  );
  const visibleWindowCostUSD = useMemo(() => {
    if (visibleWindowSummary.endIndex < visibleWindowSummary.startIndex) return 0;
    return bucketCostsUSD
      .slice(visibleWindowSummary.startIndex, visibleWindowSummary.endIndex + 1)
      .reduce((total, cost) => total + cost, 0);
  }, [bucketCostsUSD, visibleWindowSummary.startIndex, visibleWindowSummary.endIndex]);
  const fixedScaleMap = useMemo(
    () => recentChartFixedScaleMap(data.points.map((point) => point.calls)),
    [data.points],
  );
  const renderWindow = data.points.length === 0 || visibleWindowSummary.endIndex < visibleWindowSummary.startIndex
    ? null
    : {
      startIndex: Math.max(visibleWindowSummary.startIndex - 2, 0),
      endIndex: Math.min(visibleWindowSummary.endIndex + 2, data.points.length - 1),
    };
  const plotData = useMemo(
    () => plotChartPoints(data, chartWidth, plotHeight, quotaModel, {
      bucketCostsUSD,
      fixedScaleMap,
      renderWindow,
      scaleWindow: visibleWindowSummary.endIndex >= visibleWindowSummary.startIndex
        ? {
          startIndex: visibleWindowSummary.startIndex,
          endIndex: visibleWindowSummary.endIndex,
        }
        : null,
    }),
    [
      data,
      chartWidth,
      plotHeight,
      quotaModel,
      bucketCostsUSD,
      fixedScaleMap,
      renderWindow?.startIndex,
      renderWindow?.endIndex,
      visibleWindowSummary.startIndex,
      visibleWindowSummary.endIndex,
    ],
  );
  const renderedPaths = useMemo(() => ({
    tokenArea: offsetPath(
      tokenAreaPath(
        plotData.tokenPoints,
        plotData.tokenPoints.at(-1)?.x ?? 0,
        plotHeight,
      ),
      plotTop,
    ),
    tokens: offsetPath(smoothPath(plotData.tokenPoints), plotTop),
    calls: offsetPath(smoothPath(plotData.callPoints), plotTop),
    fiveHour: offsetPath(optionalSmoothPath(plotData.fiveHourQuotaPoints), plotTop),
    sevenDay: offsetPath(optionalSmoothPath(plotData.sevenDayQuotaPoints), plotTop),
  }), [plotData, plotHeight, plotTop]);
  const pointStep = chartWidth / Math.max(data.points.length - 1, 1);
  const renderLeft = plotData.renderStartIndex * pointStep;
  const renderRight = data.points.length === 0
    ? chartWidth
    : Math.max(plotData.renderEndIndex, plotData.renderStartIndex) * pointStep;
  const renderWidth = Math.max(renderRight - renderLeft, pointStep, 1);
  const activeIndex = hoveredIndex !== null && data.points[hoveredIndex] ? hoveredIndex : null;
  const activePoint = activeIndex !== null ? data.points[activeIndex] : null;
  const activeTokenPoint = activeIndex !== null
    ? visiblePlotPoint(plotData.tokenPoints, plotData.renderStartIndex, activeIndex)
    : null;
  const fixedSelectionEndIndex = quotaSelectionState.fixedEndIndex !== null && data.points[quotaSelectionState.fixedEndIndex]
    ? quotaSelectionState.fixedEndIndex
    : null;
  const quotaEndIndex = activeQuotaSelectionEndIndex(
    clampQuotaSelection(quotaSelectionState, data.points.length),
    activeIndex,
    Math.max(data.points.length - 1, 0),
  );
  const consumptionSelection = quotaSelectionState.startIndex !== null && quotaEndIndex !== null
    ? quotaConsumptionSelection(data, quotaSelectionState.startIndex, quotaEndIndex, quotaModel, {
      fiveHour: { resetAtUnix: fiveHourResetAtUnix, periodSeconds: 5 * 60 * 60 },
      sevenDay: { resetAtUnix: sevenDayResetAtUnix, periodSeconds: 7 * 24 * 60 * 60 },
    })
    : null;
  const selectionAttribution = fixedSelectionEndIndex !== null
    && consumptionSelection !== null
    ? quotaSelectionAttribution(consumptionSelection, sharedAccountAttribution)
    : null;
  const quotaEstimateVisibility = quotaEstimateWindowVisibility(data);

  useLayoutEffect(() => {
    const scrollElement = scrollRef.current;
    if (!scrollElement) {
      return;
    }
    if (pendingScrollFrameRef.current !== null) {
      window.cancelAnimationFrame(pendingScrollFrameRef.current);
      pendingScrollFrameRef.current = null;
    }

    // A dashboard snapshot can mount with a zero-valued placeholder before
    // the real chart content has been laid out.  Setting scrollLeft during
    // that first layout is silently clamped to 0 by the browser; when the
    // placeholder and the real series have the same point count, the old
    // effect dependencies never ran again.  Wait for the actual scrollWidth
    // to become available, then verify the browser kept the trailing offset.
    let cancelled = false;
    let retryFrame: number | null = null;
    let verificationFrame: number | null = null;
    let attemptsRemaining = 32;
    let resizeObserver: ResizeObserver | null = null;

    const cancelFrame = (frame: number | null) => {
      if (frame !== null) {
        window.cancelAnimationFrame(frame);
      }
    };

    const stopObservation = () => {
      resizeObserver?.disconnect();
      resizeObserver = null;
      cancelFrame(retryFrame);
      cancelFrame(verificationFrame);
      retryFrame = null;
      verificationFrame = null;
    };

    const applyLatestOffset = (): boolean => {
      if (cancelled) {
        return true;
      }

      const viewportWidth = scrollElement.clientWidth || CHART_WIDTH;
      const maxOffset = Math.max(scrollElement.scrollWidth - viewportWidth, 0);
      const requestedOffset = Math.max(scrollLayout.latestScrollLeft, 0);

      // A positive requested offset is not actionable until the DOM exposes
      // a real horizontal overflow range.  Returning false keeps the frame
      // retry/ResizeObserver path alive without publishing a bogus zero.
      if (requestedOffset > 0.5 && maxOffset <= 0.5) {
        return false;
      }

      const targetOffset = Math.min(requestedOffset, maxOffset);
      scrollElement.scrollLeft = targetOffset;
      setChartScrollLeft(scrollElement.scrollLeft);
      setChartViewportWidth(viewportWidth);

      return Math.abs(scrollElement.scrollLeft - targetOffset) <= 0.5;
    };

    const scheduleRetry = () => {
      if (cancelled || retryFrame !== null || attemptsRemaining <= 0) {
        return;
      }
      retryFrame = window.requestAnimationFrame(() => {
        retryFrame = null;
        attemptsRemaining -= 1;
        if (applyLatestOffset()) {
          verificationFrame = window.requestAnimationFrame(() => {
            verificationFrame = null;
            if (applyLatestOffset()) {
              stopObservation();
            } else {
              scheduleRetry();
            }
          });
        } else {
          scheduleRetry();
        }
      });
    };

    const scheduleVerification = () => {
      if (cancelled || verificationFrame !== null) {
        return;
      }
      verificationFrame = window.requestAnimationFrame(() => {
        verificationFrame = null;
        if (applyLatestOffset()) {
          stopObservation();
        } else {
          scheduleRetry();
        }
      });
    };

    if (typeof ResizeObserver !== "undefined") {
      resizeObserver = new ResizeObserver(() => {
        if (applyLatestOffset()) {
          scheduleVerification();
        } else {
          scheduleRetry();
        }
      });
      resizeObserver.observe(scrollElement);
      const scrollContent = scrollElement.firstElementChild;
      if (scrollContent instanceof HTMLElement) {
        resizeObserver.observe(scrollContent);
      }
    }

    if (applyLatestOffset()) {
      scheduleVerification();
    } else {
      scheduleRetry();
    }

    return () => {
      cancelled = true;
      stopObservation();
    };
  }, [scrollLayout.latestScrollLeft, data.range, data.points.length]);

  useEffect(() => () => {
    if (pendingScrollFrameRef.current !== null) {
      window.cancelAnimationFrame(pendingScrollFrameRef.current);
    }
  }, []);

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
    setPreviewDismissed(false);
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
    const y = ((event.clientY - rect.top) / rect.height) * canvasHeight;
    if (y < plotTop || y > plotTop + plotHeight) {
      setHoveredIndex(null);
      return;
    }
    const nextIndex = hoverIndexForX(x, chartWidth, data.points.length);
    if (shouldReopenPreviewOnHoverMove(fixedSelectionEndIndex, hoveredIndex, nextIndex)) {
      setPreviewDismissed(false);
    }
    setHoveredIndex(nextIndex);
  }

  function handlePointerDown(event: React.PointerEvent<SVGSVGElement>) {
    const rect = svgRef.current?.getBoundingClientRect();
    if (!rect) {
      return;
    }
    const x = ((event.clientX - rect.left) / rect.width) * chartWidth;
    const y = ((event.clientY - rect.top) / rect.height) * canvasHeight;
    if (y < plotTop || y > plotTop + plotHeight) {
      return;
    }
    const clickedIndex = hoverIndexForX(x, chartWidth, data.points.length);
    if (clickedIndex === null) {
      return;
    }
    setPreviewDismissed(false);
    setHoveredIndex(clickedIndex);
    setQuotaSelectionState((current) => clickQuotaSelection(current, clickedIndex, data.points.length));
  }

  function scrollChart(direction: RecentChartScrollDirection) {
    const scrollElement = scrollRef.current;
    if (!scrollElement || !scrollLayout.isHorizontal) {
      return;
    }
    const target = recentChartScrollTarget(scrollLayout, scrollElement.scrollLeft, direction);
    if (Math.abs(target - scrollElement.scrollLeft) < 0.5) {
      return;
    }
    scrollElement.scrollTo({ left: target, behavior: "smooth" });
  }

  function updateScrollbarDrag(clientX: number, track: HTMLDivElement) {
    const drag = scrollbarDragRef.current;
    const scrollElement = scrollRef.current;
    if (!drag || !scrollElement) return;
    const bounds = track.getBoundingClientRect();
    const thumb = recentChartScrollbarThumb(scrollLayout, scrollElement.scrollLeft, bounds.width);
    const thumbLeft = clientX - bounds.left - drag.grabOffset;
    scrollElement.scrollLeft = recentChartScrollLeftForThumb(thumbLeft, thumb, bounds.width);
  }

  function handleScrollbarPointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    if (!scrollLayout.isHorizontal) return;
    const bounds = event.currentTarget.getBoundingClientRect();
    const thumb = recentChartScrollbarThumb(scrollLayout, chartScrollLeft, bounds.width);
    const clickedThumb = (event.target as HTMLElement).classList.contains("recent-chart-persistent-scrollbar__thumb");
    scrollbarDragRef.current = {
      pointerId: event.pointerId,
      grabOffset: clickedThumb ? event.clientX - bounds.left - thumb.left : thumb.width / 2,
    };
    event.currentTarget.setPointerCapture(event.pointerId);
    updateScrollbarDrag(event.clientX, event.currentTarget);
  }

  function scheduleScrollState(scrollLeft: number, viewportWidth: number) {
    pendingScrollMetricsRef.current = { scrollLeft, viewportWidth };
    if (pendingScrollFrameRef.current !== null) {
      return;
    }
    pendingScrollFrameRef.current = window.requestAnimationFrame(() => {
      pendingScrollFrameRef.current = null;
      const pending = pendingScrollMetricsRef.current;
      const maximum = Math.max(chartWidth - pending.viewportWidth, 0);
      const clamped = Math.min(Math.max(pending.scrollLeft, 0), maximum);
      const step = chartWidth / Math.max(data.points.length - 1, 1);
      const aligned = clamped <= 0.5
        ? 0
        : maximum - clamped <= 0.5
          ? maximum
          : step > 0
            ? Math.min(Math.max(Math.round(clamped / step) * step, 0), maximum)
            : clamped;
      setChartScrollLeft((current) => Math.abs(current - aligned) < 0.25 ? current : aligned);
      setChartViewportWidth((current) => Math.abs(current - pending.viewportWidth) < 0.25
        ? current
        : pending.viewportWidth);
    });
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
            <LegendDot className="legend-dot--token" label="Token" value={formatTokens(visibleWindowSummary.tokenTotal)} />
            <LegendDot className="legend-dot--calls" label="调用" value={`${visibleWindowSummary.callTotal}`} />
            <LegendDot className="legend-dot--hit" label="命中率" value={percentText(visibleWindowSummary.cacheHitRate)} />
            <LegendDot className="legend-dot--cost" label="金额" value={moneyText(visibleWindowCostUSD)} />
            {fiveHourQuotaPresent ? <LegendDot className="legend-dot--five" label="5h" value={percentText(visibleWindowSummary.latestFiveHourRemaining)} /> : null}
            {sevenDayQuotaPresent ? <LegendDot className="legend-dot--seven" label="7d" value={percentText(visibleWindowSummary.latestSevenDayRemaining)} /> : null}
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
            <LineToggle active={visibility.cost} className="toggle-cost" label="金额" onClick={() => updateVisibility("cost")} />
            {fiveHourQuotaPresent ? <LineToggle active={visibility.fiveHourQuota} className="toggle-five" label="5h" onClick={() => updateVisibility("fiveHourQuota")} /> : null}
            {sevenDayQuotaPresent ? <LineToggle active={visibility.sevenDayQuota} className="toggle-seven" label="7d" onClick={() => updateVisibility("sevenDayQuota")} /> : null}
          </div>
        </div>
      </div>

      <div className="recent-chart-plot">
        <div
          className={scrollLayout.className}
          ref={scrollRef}
          aria-label={scrollLayout.isHorizontal ? `${data.title}图表可左右滚动` : undefined}
          onScroll={(event) => {
            scheduleScrollState(
              event.currentTarget.scrollLeft,
              event.currentTarget.clientWidth || CHART_WIDTH,
            );
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
              viewBox={`0 0 ${chartWidth} ${canvasHeight}`}
            >
              <title>{chartAccessibility(data, visibleWindowSummary, visibility, fiveHourQuotaPresent, sevenDayQuotaPresent)}</title>
              <rect className="chart-plot-bg" x={renderLeft} y={plotTop} width={renderWidth} height={plotHeight} rx="8" />
              {consumptionSelection ? (
                <SelectionRange
                  chartWidth={chartWidth}
                  plotHeight={plotHeight}
                  plotTop={plotTop}
                  pointCount={data.points.length}
                  selection={consumptionSelection}
                />
              ) : null}
              {[0, 1, 2, 3].map((line) => {
                const y = plotTop + (line * plotHeight) / 3;
                return <line className="chart-grid-line" key={line} x1={renderLeft} x2={renderRight} y1={y} y2={y} />;
              })}
              {visibility.tokens ? (
                <>
                  <path className="chart-area" d={renderedPaths.tokenArea} />
                  <path className="chart-line chart-line--token" d={renderedPaths.tokens} />
                </>
              ) : null}
              {visibility.calls ? (
                <path className="chart-line chart-line--calls" d={renderedPaths.calls} />
              ) : null}
              {visibility.cacheHitRate && data.hasCacheCalls ? (
                <g className="chart-observation-points chart-observation-points--hit">
                  {plotData.cachePoints.map((point, index) => point ? (
                    <circle
                      className="chart-observation-point chart-observation-point--hit"
                      cx={point.x}
                      cy={point.y + plotTop}
                      key={plotData.renderStartIndex + index}
                      r="1.6"
                    />
                  ) : null)}
                </g>
              ) : null}
              {visibility.cost ? <g className="chart-observation-points chart-observation-points--cost">
                {plotData.costPoints.map((point, index) => point ? (
                  <circle
                    className="chart-observation-point chart-observation-point--cost"
                    cx={point.x}
                    cy={point.y + plotTop}
                    key={plotData.renderStartIndex + index}
                    r={COST_POINT_RADIUS}
                  />
                ) : null)}
              </g> : null}
              {fiveHourQuotaPresent && visibility.fiveHourQuota && data.hasFiveHourQuota ? (
                <path className="chart-line chart-line--five" d={renderedPaths.fiveHour} />
              ) : null}
              {sevenDayQuotaPresent && visibility.sevenDayQuota && data.hasSevenDayQuota ? (
                <path className="chart-line chart-line--seven" d={renderedPaths.sevenDay} />
              ) : null}
              {activeIndex !== null && activeTokenPoint ? (
                <HoverGuides
                  data={data}
                  fiveHourQuotaPresent={fiveHourQuotaPresent}
                  index={activeIndex}
                  plotHeight={plotHeight}
                  plotTop={plotTop}
                  plotData={plotData}
                  sevenDayQuotaPresent={sevenDayQuotaPresent}
                  visibility={visibility}
                />
              ) : null}
              <TimeMarkers
                chartWidth={chartWidth}
                data={data}
                endIndex={plotData.renderEndIndex}
                plotHeight={plotHeight}
                plotTop={plotTop}
                startIndex={plotData.renderStartIndex}
                timeMarkerGap={timeMarkerGap}
              />
            </svg>
          </div>
        </div>
        {scrollLayout.isHorizontal ? (
          <div
            aria-label="曲线水平滚动位置"
            aria-valuemax={Math.round(scrollbarThumb.maxScrollLeft)}
            aria-valuemin={0}
            aria-valuenow={Math.round(chartScrollLeft)}
            className="recent-chart-persistent-scrollbar"
            onKeyDown={(event) => {
              if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
              event.preventDefault();
              const scrollElement = scrollRef.current;
              if (!scrollElement) return;
              const delta = Math.max(chartViewportWidth / 10, 1) * (event.key === "ArrowLeft" ? -1 : 1);
              scrollElement.scrollLeft = Math.min(
                Math.max(scrollElement.scrollLeft + delta, 0),
                scrollbarThumb.maxScrollLeft,
              );
            }}
            onPointerCancel={() => { scrollbarDragRef.current = null; }}
            onPointerDown={handleScrollbarPointerDown}
            onPointerMove={(event) => {
              if (scrollbarDragRef.current?.pointerId === event.pointerId) {
                updateScrollbarDrag(event.clientX, event.currentTarget);
              }
            }}
            onPointerUp={(event) => {
              if (scrollbarDragRef.current?.pointerId === event.pointerId) {
                scrollbarDragRef.current = null;
                event.currentTarget.releasePointerCapture(event.pointerId);
              }
            }}
            role="scrollbar"
            tabIndex={0}
          >
            <div
              className="recent-chart-persistent-scrollbar__thumb"
              style={{ left: scrollbarThumb.left, width: scrollbarThumb.width }}
            />
          </div>
        ) : null}
        <div className="recent-chart-overlay-layer">
          {visibleWindowLabel ? (
            <div className="recent-chart-visible-window">当前窗口：{visibleWindowLabel}</div>
          ) : null}
          {!previewDismissed && fixedSelectionEndIndex !== null && consumptionSelection ? (
            <SelectionSummaryBubble
              onClose={() => setPreviewDismissed(true)}
              selection={consumptionSelection}
              viewportWidth={chartViewportWidth}
              x={(visiblePlotPoint(
                plotData.tokenPoints,
                plotData.renderStartIndex,
                fixedSelectionEndIndex,
              )?.x ?? fixedSelectionEndIndex * pointStep) - chartScrollLeft}
            />
          ) : !previewDismissed && activePoint && activeTokenPoint ? (
            <HoverBubble
              bucketSeconds={data.bucketSeconds}
              cacheVisible={visibility.cacheHitRate}
              costUSD={activeIndex === null ? 0 : plotData.bucketCostsUSD[activeIndex] ?? 0}
              fiveHourRemaining={fiveHourQuotaPresent ? activePoint.fiveHourRemainingPercent : null}
              onClose={() => setPreviewDismissed(true)}
              point={activePoint}
              sevenDayRemaining={sevenDayQuotaPresent ? activePoint.sevenDayRemainingPercent : null}
              viewportWidth={chartViewportWidth}
              x={activeTokenPoint.x - chartScrollLeft}
            />
          ) : null}
          {scrollLayout.isHorizontal ? (
            <div className="recent-chart-page-controls" aria-label="曲线分页">
              <button
                aria-label="向前翻页"
                className="recent-chart-page-button recent-chart-page-button--backward"
                disabled={scrollPresentation.isAtOldest}
                onClick={() => scrollChart("backward")}
                type="button"
              >
                ‹
              </button>
              <button
                aria-label="向后翻页"
                className="recent-chart-page-button recent-chart-page-button--forward"
                disabled={scrollPresentation.isAtLatest}
                onClick={() => scrollChart("forward")}
                type="button"
              >
                ›
              </button>
            </div>
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

function SelectionRange({
  chartWidth,
  plotHeight,
  plotTop,
  pointCount,
  selection,
}: {
  chartWidth: number;
  plotHeight: number;
  plotTop: number;
  pointCount: number;
  selection: QuotaConsumptionSelection;
}) {
  const actualStep = chartWidth / Math.max(pointCount - 1, 1);
  const startX = selection.startIndex * actualStep;
  const endX = selection.endIndex * actualStep;
  const x = Math.min(startX, endX);
  const width = Math.max(Math.abs(endX - startX), 2);

  return (
    <g className="chart-selection-layer">
      <rect className="chart-selection-range" x={x} y={plotTop} width={width} height={plotHeight} />
      <line className="chart-selection-line" x1={startX} x2={startX} y1={plotTop} y2={plotTop + plotHeight} />
      <line className="chart-selection-line" x1={endX} x2={endX} y1={plotTop} y2={plotTop + plotHeight} />
    </g>
  );
}

function HoverGuides({
  data,
  fiveHourQuotaPresent,
  index,
  plotHeight,
  plotTop,
  plotData,
  sevenDayQuotaPresent,
  visibility,
}: {
  data: ReturnType<typeof prepareRecentChartData>;
  fiveHourQuotaPresent: boolean;
  index: number;
  plotHeight: number;
  plotTop: number;
  plotData: ReturnType<typeof plotChartPoints>;
  sevenDayQuotaPresent: boolean;
  visibility: SeriesVisibility;
}) {
  const tokenPoint = visiblePlotPoint(plotData.tokenPoints, plotData.renderStartIndex, index);
  const callPoint = visiblePlotPoint(plotData.callPoints, plotData.renderStartIndex, index);
  const cachePoint = visiblePlotPoint(plotData.cachePoints, plotData.renderStartIndex, index);
  const costPoint = visiblePlotPoint(plotData.costPoints, plotData.renderStartIndex, index);
  const fiveHourPoint = visiblePlotPoint(plotData.fiveHourQuotaPoints, plotData.renderStartIndex, index);
  const sevenDayPoint = visiblePlotPoint(plotData.sevenDayQuotaPoints, plotData.renderStartIndex, index);
  const point = data.points[index];

  if (!tokenPoint || !callPoint || !point) {
    return null;
  }

  return (
    <g className="chart-hover-layer">
      <line className="chart-hover-line" x1={tokenPoint.x} x2={tokenPoint.x} y1={plotTop} y2={plotTop + plotHeight} />
      {visibility.tokens ? <HoverRing className="hover-token" point={offsetPoint(tokenPoint, plotTop)} radius={4.5} /> : null}
      {visibility.calls ? <HoverRing className="hover-calls" point={offsetPoint(callPoint, plotTop)} radius={4} /> : null}
      {visibility.cacheHitRate && point.calls > 0 && point.cacheHitRate !== null && cachePoint ? (
        <HoverRing className="hover-hit" point={offsetPoint(cachePoint, plotTop)} radius={4} />
      ) : null}
      {visibility.cost && costPoint ? (
        <HoverRing
          className="hover-cost"
          point={offsetPoint(costPoint, plotTop)}
          radius={4}
        />
      ) : null}
      {fiveHourQuotaPresent && visibility.fiveHourQuota && fiveHourPoint ? <HoverRing className="hover-five" point={offsetPoint(fiveHourPoint, plotTop)} radius={3.5} /> : null}
      {sevenDayQuotaPresent && visibility.sevenDayQuota && sevenDayPoint ? <HoverRing className="hover-seven" point={offsetPoint(sevenDayPoint, plotTop)} radius={3.5} /> : null}
    </g>
  );
}

function HoverRing({ className, point, radius }: { className: string; point: { x: number; y: number }; radius: number }) {
  return <circle className={`chart-hover-ring ${className}`} cx={point.x} cy={point.y} r={radius} />;
}

function HoverBubble({
  bucketSeconds,
  cacheVisible,
  costUSD,
  fiveHourRemaining,
  onClose,
  point,
  sevenDayRemaining,
  viewportWidth,
  x,
}: {
  bucketSeconds: number;
  cacheVisible: boolean;
  costUSD: number;
  fiveHourRemaining: number | null;
  onClose: () => void;
  point: RecentUsagePoint;
  sevenDayRemaining: number | null;
  viewportWidth: number;
  x: number;
}) {
  const [bubbleRef, bubbleWidth] = useChartBubbleWidth(CHART_HOVER_BUBBLE_FALLBACK_WIDTH);
  const left = recentChartHoverBubbleCenter(x, viewportWidth, bubbleWidth);
  const average = point.calls > 0 ? Math.round(point.tokens / point.calls) : 0;
  const quotaParts = [
    fiveHourRemaining !== null ? `5h ${percentText(fiveHourRemaining)}` : null,
    sevenDayRemaining !== null ? `7d ${percentText(sevenDayRemaining)}` : null,
  ].filter(Boolean);

  return (
    <div ref={bubbleRef} className="chart-hover-bubble" style={{ left: `${left}px` }}>
      <div className="chart-hover-heading">
        <strong>当前点</strong>
        <span>{timeRange(point.startUnix, bucketSeconds)}</span>
        <PreviewCloseButton ariaLabel="关闭当前点预览" onClose={onClose} />
      </div>
      <b>{formatTokens(point.tokens)}</b>
      <span className="chart-hover-row">请求 {point.calls} 次 · avg {formatTokens(average)}</span>
      <span className="chart-hover-row chart-hover-row--cost">金额 {moneyText(costUSD)}</span>
      {cacheVisible && point.calls > 0 && point.cacheHitRate !== null ? (
        <em className="chart-hover-row chart-hover-row--cache">
          缓存命中 {percentText(point.cacheHitRate)} · 命中 {formatTokens(point.cachedInputTokens)}
        </em>
      ) : null}
      <ModelUsageInline rows={point.modelBreakdowns} eventStartUnix={point.startUnix} />
      {quotaParts.length > 0 ? <span className="chart-hover-row">额度 {quotaParts.join(" · ")}</span> : null}
      <em className="chart-hover-row chart-hover-row--action">点击起点/终点可估算额度</em>
    </div>
  );
}

function SelectionSummaryBubble({
  onClose,
  selection,
  viewportWidth,
  x,
}: {
  onClose: () => void;
  selection: QuotaConsumptionSelection;
  viewportWidth: number;
  x: number;
}) {
  const [bubbleRef, bubbleWidth] = useChartBubbleWidth(CHART_HOVER_BUBBLE_FALLBACK_WIDTH);
  const left = recentChartHoverBubbleCenter(x, viewportWidth, bubbleWidth);
  const average = selection.calls > 0 ? Math.round(selection.totalTokens / selection.calls) : 0;
  return (
    <div ref={bubbleRef} className="chart-hover-bubble chart-selection-summary-bubble" style={{ left: `${left}px` }}>
      <div className="chart-hover-heading">
        <strong>选中区间</strong>
        <span>{timeRange(selection.startUnix, selection.endUnix - selection.startUnix)}</span>
        <PreviewCloseButton ariaLabel="关闭选中区间预览" onClose={onClose} />
      </div>
      <b>{formatTokens(selection.totalTokens)}</b>
      <span className="chart-hover-row">请求 {selection.calls} 次 · avg {formatTokens(average)}</span>
      <span className="chart-hover-row chart-hover-row--cost">金额 {moneyText(selection.selectedCostUSD)}</span>
      {selection.calls > 0 ? (
        <em className="chart-hover-row chart-hover-row--cache">
          缓存命中 {percentText(selection.cacheHitRate)} · 命中 {formatTokens(selection.cachedInputTokens)}
        </em>
      ) : null}
      <ModelUsageInline rows={selection.modelBreakdowns} />
      <span className="chart-hover-row">{quotaSelectionDurationText(selection)}</span>
    </div>
  );
}

function PreviewCloseButton({ ariaLabel, onClose }: { ariaLabel: string; onClose: () => void }) {
  return (
    <button
      aria-label={ariaLabel}
      className="chart-preview-close"
      onClick={(event) => {
        event.stopPropagation();
        onClose();
      }}
      type="button"
    >
      ×
    </button>
  );
}

function ModelUsageInline({
  rows,
  eventStartUnix,
}: {
  rows: RecentUsagePoint["modelBreakdowns"] | QuotaConsumptionSelection["modelBreakdowns"];
  eventStartUnix?: number;
}) {
  const timedRows = rows?.map((row) => (
    row.eventStartUnix === undefined && eventStartUnix !== undefined
      ? { ...row, eventStartUnix }
      : row
  ));
  const slices = modelUsageSlices(timedRows);
  if (slices.length === 0) return null;
  return (
    <div className="model-usage-inline chart-hover-row" aria-label={`模型占比 ${slices.map((slice) => `${slice.label} ${Math.round(slice.share * 100)}%`).join("，")}`}>
      {slices.slice(0, 3).map((slice) => (
        <span key={slice.key}>
          <i style={{ backgroundColor: slice.color }} />
          {slice.label} {Math.round(slice.share * 100)}%
        </span>
      ))}
      {slices.length > 3 ? <span>+{slices.length - 3}</span> : null}
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
  const comparisonScopeText = quotaComparisonScopeText(selection, {
    fiveHour: showsFiveHourQuota,
    sevenDay: showsSevenDayQuota,
  });

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
        {selection.excludedModels.length > 0 ? (
          <div className="quota-estimate-row quota-estimate-attribution-detail" aria-label="独立额度说明">
            <span>{selection.excludedModels.join("、")} {selection.excludedCalls} 次调用</span>
            <em>独立额度，不参与 API 等值</em>
          </div>
        ) : null}
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
        {comparisonScopeText ? (
          <div className="quota-estimate-scope-note">{comparisonScopeText}</div>
        ) : null}
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
      {attribution.excludedModels.length > 0 ? (
        <div className="quota-estimate-row quota-estimate-attribution-detail" aria-label="独立额度说明">
          <span>{attribution.excludedModels.join("、")} {attribution.excludedCalls} 次调用</span>
          <em>独立额度，不参与 API 等值</em>
        </div>
      ) : null}
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

function TimeMarkers({
  chartWidth,
  data,
  endIndex,
  plotHeight,
  plotTop,
  startIndex,
  timeMarkerGap,
}: {
  chartWidth: number;
  data: ReturnType<typeof prepareRecentChartData>;
  endIndex: number;
  plotHeight: number;
  plotTop: number;
  startIndex: number;
  timeMarkerGap: number;
}) {
  const markers = recentChartTimeMarkers(data, chartWidth)
    .filter((marker) => marker.index >= startIndex && marker.index <= endIndex);
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
                y1={plotTop}
                y2={plotTop + plotHeight}
              />
            ) : null}
            <text
              className={`chart-time-marker chart-time-marker--${marker.kind}`}
              textAnchor={marker.kind === "day" ? "start" : "middle"}
              x={marker.kind === "day" ? marker.x + 6 : marker.x}
              y={plotTop + plotHeight + timeMarkerGap}
            >
              {marker.label}
            </text>
          </g>
        );
      })}
    </>
  );
}

function visiblePlotPoint<T extends Point | null>(
  points: T[],
  renderStartIndex: number,
  globalIndex: number,
): T | null {
  return points[globalIndex - renderStartIndex] ?? null;
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

function offsetPath(path: string, plotTop: number): string {
  if (!path) {
    return "";
  }
  return path.replace(/([A-Z]) ([^A-Z]+)/g, (_match, command: string, coordinates: string) => {
    const values = coordinates.trim().split(/\s+/).map(Number);
    for (let index = 1; index < values.length; index += 2) {
      values[index] += plotTop;
    }
    return `${command} ${values.map((value) => value.toFixed(1).replace(/\.0$/, "")).join(" ")}`;
  });
}

function offsetPoint(point: { x: number; y: number }, plotTop: number) {
  return { x: point.x, y: point.y + plotTop };
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
  windowSummary: ReturnType<typeof recentChartVisibleWindowSummary>,
  visibility: SeriesVisibility,
  fiveHourQuotaPresent: boolean,
  sevenDayQuotaPresent: boolean,
): string {
  const visible = [
    visibility.tokens ? "Token" : null,
    visibility.calls ? "调用" : null,
    visibility.cacheHitRate && windowSummary.hasCacheCalls ? "命中率" : null,
    visibility.cost && data.points.length > 0 ? "每桶金额" : null,
    fiveHourQuotaPresent && visibility.fiveHourQuota && data.hasFiveHourQuota ? "5 小时额度" : null,
    sevenDayQuotaPresent && visibility.sevenDayQuota && data.hasSevenDayQuota ? "7 天额度" : null,
  ].filter(Boolean);

  return `${data.title}，${data.points.length} 个时间点，当前窗口 Token 总量 ${formatTokens(windowSummary.tokenTotal)}，当前窗口调用 ${windowSummary.callTotal} 次，已显示 ${visible.join("、") || "无曲线"}`;
}

function estimateText(estimate: QuotaConsumptionEstimate, title: string, isQuotaAvailable: boolean): string {
  if (!isQuotaAvailable) {
    return `无 ${title} 额度`;
  }

  const excludedNote = estimate.excludedModels.length > 0 ? " · 独立额度不计入" : "";
  const boundaryNote = estimate.boundaryBreakdown.leading.totalTokens > 0
    || estimate.boundaryBreakdown.trailing.totalTokens > 0
    ? ` · 边缘另计 ${formatTokens(estimate.boundaryBreakdown.leading.totalTokens + estimate.boundaryBreakdown.trailing.totalTokens)}`
    : "";
  switch (estimate.confidence) {
    case "measured":
      return `${moneyText(estimate.impliedWindowBudgetUSD)} · 降 ${oneDecimalPercent(estimate.quotaDropPercent)}${boundaryNote}${excludedNote}`;
    case "insufficientQuotaMovement":
      return `降 ${oneDecimalPercent(estimate.quotaDropPercent)} · 不反推${boundaryNote}${excludedNote}`;
    case "noTokenUsage":
      return `无 token${excludedNote}`;
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

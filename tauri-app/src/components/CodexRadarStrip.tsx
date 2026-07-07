import { memo, startTransition, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { readCodexRadarFullSnapshot } from "../api/codexRadarDetailClient";
import {
  CODEX_RADAR_DETAIL_ATTEMPT_STORAGE_KEY,
  CODEX_RADAR_DETAIL_REFRESH_STORAGE_KEY,
  latestCodexRadarDetailSlot,
  millisecondsUntilNextCodexRadarDetailSlot,
  shouldRefreshCodexRadarDetail,
} from "../api/codexRadarDetailRefreshPlan";
import { readCodexRadarState } from "../api/codexRadarClient";
import {
  codexRadarDiagnosticLabel,
  codexRadarSurfaceStatus,
  type CodexRadarChartSeries,
  type CodexRadarDiagnostic,
  type CodexRadarModelIQComparisonRow,
  type CodexRadarModelIQPoint,
  type CodexRadarQuotaWindow,
  displayRadarNumber,
  environmentCount,
  modelDisplayName,
  modelIqChartSeries,
  percentText,
  primaryModelRow,
  quotaChartSeries,
  selectCodexRadarDetailSnapshot,
  secondaryModelRows,
  shortDateLabel,
  type CodexRadarSnapshot,
} from "./codexRadar/model";

const RADAR_REFRESH_INTERVAL_MS = 600_000;
const RADAR_CHART_COLORS = ["#18a7f2", "#ff8a2c", "#2f7df6", "#32b85f", "#a65af5"];

interface CodexRadarStripProps {
  refreshGeneration?: number;
}

function CodexRadarStripView({ refreshGeneration = 0 }: CodexRadarStripProps) {
  const [snapshot, setSnapshot] = useState<CodexRadarSnapshot | null>(null);
  const [diagnostics, setDiagnostics] = useState<CodexRadarDiagnostic[]>([]);
  const [status, setStatus] = useState("Codex 雷达待读取");
  const [refreshing, setRefreshing] = useState(false);
  const [showDetails, setShowDetails] = useState(false);
  const [detailSnapshot, setDetailSnapshot] = useState<CodexRadarSnapshot | null>(null);
  const [detailStatus, setDetailStatus] = useState("详细信息待读取");
  const [detailRefreshing, setDetailRefreshing] = useState(false);
  const lastExternalRefreshGeneration = useRef(0);
  const refreshingRef = useRef(false);
  const detailRefreshingRef = useRef(false);
  const snapshotRef = useRef<CodexRadarSnapshot | null>(null);
  const detailSnapshotRef = useRef<CodexRadarSnapshot | null>(null);
  const detailAttemptedSlotRef = useRef<string | null>(null);

  async function refresh(force = false) {
    if (refreshingRef.current) {
      return;
    }
    refreshingRef.current = true;
    startTransition(() => {
      setRefreshing(true);
      setStatus(snapshotRef.current ? "正在更新 Codex 雷达..." : "正在读取 Codex 雷达...");
    });
    try {
      const next = await readCodexRadarState(snapshotRef.current, { force });
      snapshotRef.current = next.snapshot;
      startTransition(() => {
        setSnapshot(next.snapshot);
        setDiagnostics(next.diagnostics);
        setStatus(next.statusText);
      });
    } catch (error) {
      startTransition(() => {
        setStatus(`Codex 雷达读取失败：${error instanceof Error ? error.message : String(error)}`);
      });
    } finally {
      refreshingRef.current = false;
      startTransition(() => {
        setRefreshing(false);
      });
    }
  }

  async function refreshDetail(mode: "automatic" | "manual" = "manual", attemptedSlotAt?: string) {
    if (detailRefreshingRef.current) {
      return;
    }
    detailRefreshingRef.current = true;
    if (mode === "automatic" && attemptedSlotAt) {
      detailAttemptedSlotRef.current = attemptedSlotAt;
      writeLastDetailAttemptedSlotAt(attemptedSlotAt);
    }
    startTransition(() => {
      setDetailRefreshing(true);
      setDetailStatus(detailSnapshotRef.current ? "正在更新详细信息..." : "正在读取详细信息...");
    });
    try {
      const next = await readCodexRadarFullSnapshot();
      detailSnapshotRef.current = next;
      writeLastDetailRefreshAt(new Date().toISOString());
      startTransition(() => {
        setDetailSnapshot(next);
        setDetailStatus("详细信息已更新");
      });
    } catch {
      startTransition(() => {
        setDetailStatus(detailSnapshotRef.current
          ? "详细信息刷新失败，继续显示上次详细信息。"
          : "详细信息暂不可用，继续显示公开摘要。");
      });
    } finally {
      detailRefreshingRef.current = false;
      startTransition(() => {
        setDetailRefreshing(false);
      });
    }
  }

  function refreshDetailIfDue() {
    const now = new Date();
    const latestSlot = latestCodexRadarDetailSlot(now).toISOString();
    if (shouldRefreshCodexRadarDetail({
      lastAttemptedSlotAt: detailAttemptedSlotRef.current ?? readLastDetailAttemptedSlotAt(),
      lastSuccessfulRefreshAt: readLastDetailRefreshAt(),
      now,
    })) {
      void refreshDetail("automatic", latestSlot);
    }
  }

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(false), RADAR_REFRESH_INTERVAL_MS);
    return () => window.clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    refreshDetailIfDue();
    let timer: number | undefined;
    const scheduleNext = () => {
      timer = window.setTimeout(() => {
        refreshDetailIfDue();
        scheduleNext();
      }, millisecondsUntilNextCodexRadarDetailSlot(new Date()) + 1_000);
    };
    const onForeground = () => {
      if (!document.hidden) {
        refreshDetailIfDue();
      }
    };
    scheduleNext();
    window.addEventListener("focus", refreshDetailIfDue);
    document.addEventListener("visibilitychange", onForeground);
    return () => {
      if (timer !== undefined) {
        window.clearTimeout(timer);
      }
      window.removeEventListener("focus", refreshDetailIfDue);
      document.removeEventListener("visibilitychange", onForeground);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (refreshGeneration <= 0 || refreshGeneration === lastExternalRefreshGeneration.current) {
      return;
    }
    lastExternalRefreshGeneration.current = refreshGeneration;
    void refresh(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshGeneration]);

  const primary = useMemo(() => (snapshot ? primaryModelRow(snapshot.modelIq) : null), [snapshot]);
  const secondary = useMemo(() => (snapshot ? secondaryModelRows(snapshot.modelIq).slice(0, 3) : []), [snapshot]);
  const allModels = useMemo(() => (snapshot ? [primaryModelRow(snapshot.modelIq), ...secondaryModelRows(snapshot.modelIq)] : []), [snapshot]);
  const quotaRows = snapshot?.modelIq.quotaRadar?.rows ?? [];
  const probability24h = snapshot?.prediction.probability24H ?? snapshot?.prediction.probability24h;
  const probability48h = snapshot?.prediction.probability48H ?? snapshot?.prediction.probability48h;
  const environment = snapshot?.codexEnvironment;

  return (
    <section className={showDetails ? "codex-radar-strip codex-radar-strip--details-open" : "codex-radar-strip"} aria-label="Codex 雷达">
      <div className="codex-radar-head">
        <div>
          <h2>Codex 雷达</h2>
          <span>{status}</span>
        </div>
        <a className="codex-radar-source-credit" href={snapshot?.links.html ?? "https://codexradar.com"} rel="noreferrer" target="_blank">
          <span>感谢</span>
          <strong>Codex 雷达</strong>
          <em>codexradar.com</em>
        </a>
        <button
          aria-expanded={showDetails}
          className="radar-detail-toggle"
          onClick={() => setShowDetails((value) => !value)}
          type="button"
        >
          <span>详情</span>
          <b aria-hidden="true">{showDetails ? "⌃" : "⌄"}</b>
        </button>
        <button disabled={refreshing} onClick={() => void refresh(true)} type="button">
          {refreshing ? "刷新中" : "刷新"}
        </button>
      </div>
      <CodexRadarDiagnosticsNotice diagnostics={diagnostics} snapshot={snapshot} />

      <div className="codex-radar-grid">
        <RadarBlock icon="W" title="速蹬窗口">
          <strong>{snapshot?.window.message ?? "等待 Codex 雷达"}</strong>
          <div className="radar-mini-row">
            <RadarMini label="建议" value={snapshot?.recommendedAction ?? "--"} />
            <RadarMini label="24h" value={percentText(probability24h)} />
            <RadarMini label="48h" value={percentText(probability48h)} />
          </div>
        </RadarBlock>

        <RadarBlock icon="IQ" title="今日主模型">
          <div className="radar-score-row">
            <strong>{primary ? `IQ ${displayRadarNumber(primary.point.score)}` : "IQ --"}</strong>
            <span>{primary ? modelDisplayName(primary.point) : "待读取"}</span>
          </div>
          <div className="radar-model-row">
            {secondary.length > 0
              ? secondary.map((row) => (
                  <span key={row.label}>
                    {row.label.replace("GPT-", "")} {displayRadarNumber(row.point.score)}
                  </span>
                ))
              : <span>等待模型对比</span>}
          </div>
        </RadarBlock>

        <RadarBlock icon="$" title="预估额度">
          {quotaRows.slice(0, 3).map((row) => (
            <div className="radar-quota-row" key={row.tier}>
              <b>{row.tier}</b>
              <span>5h ${displayRadarNumber(row.fiveH, 2)}</span>
              <span>7d ${displayRadarNumber(row.sevenD, 2)}</span>
            </div>
          ))}
          {snapshot?.modelIq.quotaRadar ? null : <span className="radar-muted">暂无额度雷达数据</span>}
        </RadarBlock>

        <RadarBlock icon="E" title="环境压力">
          <div className="radar-score-row">
            <strong>{environment?.complaintPressure ?? "--"}</strong>
            <span>异常 {environmentCount(environment, "issueOrLimitAnomalies")}</span>
          </div>
          <div className="radar-mini-row">
            <RadarMini label="官方" value={`${environmentCount(environment, "officialUpdates")}`} />
            <RadarMini label="社区" value={`${environmentCount(environment, "communityMentions")}`} />
            <RadarMini label="事故" value={`${environmentCount(environment, "statusIncidents")}`} />
          </div>
        </RadarBlock>
      </div>
      {showDetails ? (
        <CodexRadarDetailOverlay
          allModels={allModels}
          diagnostics={diagnostics}
          detailSnapshot={detailSnapshot}
          detailStatus={detailStatus}
          isDetailRefreshing={detailRefreshing}
          isRefreshing={refreshing}
          onClose={() => setShowDetails(false)}
          onRefresh={() => void refreshDetail("manual")}
          primary={primary}
          probability24h={probability24h}
          probability48h={probability48h}
          quotaRows={quotaRows}
          snapshot={snapshot}
          status={status}
        />
      ) : null}
    </section>
  );
}

export const CodexRadarStrip = memo(CodexRadarStripView);

export function CodexRadarDetailOverlay({
  allModels,
  diagnostics,
  detailSnapshot,
  detailStatus,
  isDetailRefreshing,
  isRefreshing,
  onClose,
  onRefresh,
  primary,
  probability24h,
  probability48h,
  quotaRows,
  snapshot,
  status,
}: {
  allModels: CodexRadarModelIQComparisonRow[];
  diagnostics: CodexRadarDiagnostic[];
  detailSnapshot: CodexRadarSnapshot | null;
  detailStatus: string;
  isDetailRefreshing: boolean;
  isRefreshing: boolean;
  onClose: () => void;
  onRefresh: () => void;
  primary: CodexRadarModelIQComparisonRow | null;
  probability24h: number | undefined;
  probability48h: number | undefined;
  quotaRows: { tier: string; basis: string; fiveH: number; sevenD: number }[];
  snapshot: CodexRadarSnapshot | null;
  status: string;
}) {
  const displaySnapshot = selectCodexRadarDetailSnapshot(snapshot, detailSnapshot);
  const displayPrimary = displaySnapshot ? primaryModelRow(displaySnapshot.modelIq) : primary;
  const displaySecondary = displaySnapshot ? secondaryModelRows(displaySnapshot.modelIq) : [];
  const displayAllModels = displaySnapshot ? [primaryModelRow(displaySnapshot.modelIq), ...displaySecondary] : allModels;
  const displayQuotaRows = displaySnapshot?.modelIq.quotaRadar?.rows ?? quotaRows;
  const displayProbability24h = displaySnapshot?.prediction.probability24H ?? displaySnapshot?.prediction.probability24h ?? probability24h;
  const displayProbability48h = displaySnapshot?.prediction.probability48H ?? displaySnapshot?.prediction.probability48h ?? probability48h;

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  return (
    <div className="codex-radar-detail-layer" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget) {
        onClose();
      }
    }}>
      <div className="codex-radar-detail-card" role="dialog" aria-modal="true" aria-label="Codex 雷达详细信息">
        <div className="codex-radar-detail-head">
          <div>
            <strong>Codex 雷达详细信息</strong>
            <span>{displaySnapshot ? `${detailStatus} · ${displaySnapshot.monitoredAt}` : status}</span>
          </div>
          <button className="codex-radar-detail-refresh" disabled={isDetailRefreshing || isRefreshing} onClick={onRefresh} type="button">
            {isDetailRefreshing ? "刷新中" : "刷新详细"}
          </button>
          <button aria-label="关闭 Codex 雷达详情" className="codex-radar-detail-close" onClick={onClose} type="button">×</button>
        </div>

        <div className="codex-radar-detail-scroll">
          {displaySnapshot ? (
            <CodexRadarDetailBody
              allModels={displayAllModels}
              primary={displayPrimary}
              probability24h={displayProbability24h}
              probability48h={displayProbability48h}
              quotaRows={displayQuotaRows}
              snapshot={displaySnapshot}
            />
          ) : (
            <div className="codex-radar-detail-loading">
              <span className="codex-radar-spinner" aria-hidden="true" />
              <CodexRadarDiagnosticsNotice diagnostics={diagnostics} snapshot={snapshot} />
              <p>{status}</p>
            </div>
          )}
        </div>

        <a className="codex-radar-thanks" href={displaySnapshot?.links.html ?? "https://codexradar.com"} rel="noreferrer" target="_blank">
          感谢 Codex Radar 提供公开雷达数据
        </a>
      </div>
    </div>
  );
}

function readLastDetailRefreshAt(): string | null {
  try {
    return window.localStorage.getItem(CODEX_RADAR_DETAIL_REFRESH_STORAGE_KEY);
  } catch {
    return null;
  }
}

function readLastDetailAttemptedSlotAt(): string | null {
  try {
    return window.localStorage.getItem(CODEX_RADAR_DETAIL_ATTEMPT_STORAGE_KEY);
  } catch {
    return null;
  }
}

function writeLastDetailRefreshAt(value: string): void {
  try {
    window.localStorage.setItem(CODEX_RADAR_DETAIL_REFRESH_STORAGE_KEY, value);
  } catch {
    // Non-secret cache metadata only; ignore storage denial.
  }
}

function writeLastDetailAttemptedSlotAt(value: string): void {
  try {
    window.localStorage.setItem(CODEX_RADAR_DETAIL_ATTEMPT_STORAGE_KEY, value);
  } catch {
    // Non-secret cache metadata only; the in-memory marker still prevents loops for this mount.
  }
}

const CodexRadarDetailBody = memo(function CodexRadarDetailBody({
  allModels,
  primary,
  probability24h,
  probability48h,
  quotaRows,
  snapshot,
}: {
  allModels: CodexRadarModelIQComparisonRow[];
  primary: CodexRadarModelIQComparisonRow | null;
  probability24h: number | undefined;
  probability48h: number | undefined;
  quotaRows: { tier: string; basis: string; fiveH: number; sevenD: number }[];
  snapshot: CodexRadarSnapshot;
}) {
  const [selectedModelSeriesIds, setSelectedModelSeriesIds] = useState<Set<string>>(new Set());
  const [selectedQuotaWindow, setSelectedQuotaWindow] = useState<CodexRadarQuotaWindow>("fiveHour");
  const [selectedQuotaTierIds, setSelectedQuotaTierIds] = useState<Set<string>>(new Set(["quota-plus", "quota-5x", "quota-20x"]));
  const modelSeries = useMemo(() => modelIqChartSeries(snapshot.modelIq), [snapshot.modelIq]);
  const activeModelSeriesIds = activeChartIds(modelSeries, selectedModelSeriesIds, modelSeries.slice(0, 2).map((series) => series.id));
  const quotaSeries = useMemo(
    () => (snapshot.modelIq.quotaRadar ? quotaChartSeries(snapshot.modelIq.quotaRadar, selectedQuotaWindow) : []),
    [selectedQuotaWindow, snapshot.modelIq.quotaRadar],
  );
  const activeQuotaSeriesIds = activeChartIds(quotaSeries, selectedQuotaTierIds, quotaSeries.map((series) => series.id));

  return (
    <div className="codex-radar-detail-stack">
      <CodexRadarDiagnosticsNotice snapshot={snapshot} />
      <RadarDetailSection icon="bolt.badge.clock" title="速蹬窗口与预测">
        <RadarDetailSubsection title="窗口摘要">
          <RadarKeyValueGrid rows={[
            ["窗口状态", snapshot.window.message || "--"],
            ["建议动作", snapshot.recommendedAction || "--"],
            ["24h 概率", percentText(probability24h)],
            ["48h 概率", percentText(probability48h)],
            ["预计窗口", snapshot.prediction.expectedWindow || "--"],
            ["范围", snapshot.window.scope || "--"],
            ["上次关闭", snapshot.window.closedAt || "--"],
            ["来源", snapshot.window.sourceUrl || "--"],
          ]} />
        </RadarDetailSubsection>
        <RadarDetailSubsection title="预测说明">
          <p className="codex-radar-paragraph">{snapshot.prediction.summary || "--"}</p>
        </RadarDetailSubsection>
        <RadarDetailSubsection title="信号拆分">
          <div className="codex-radar-signal-grid">
            <RadarSignalList title="积极信号" items={snapshot.prediction.positiveSignals} />
            <RadarSignalList title="降温信号" items={snapshot.prediction.negativeSignals} />
          </div>
        </RadarDetailSubsection>
        {snapshot.tiboPresence?.shouldDisplay ? (
          <RadarDetailSubsection title="Tibo 观察">
            <RadarKeyValueGrid rows={[
              ["Tibo 位置/时区", snapshot.tiboPresence.locationLabelZh || "--"],
              ["概率", percentText(snapshot.tiboPresence.probability)],
              ["置信度", snapshot.tiboPresence.confidence || "--"],
              ["观察数", `${snapshot.tiboPresence.observationsConsidered ?? 0}`],
            ]} />
            <p className="codex-radar-paragraph">{snapshot.tiboPresence.safetyNoteZh || ""}</p>
          </RadarDetailSubsection>
        ) : null}
      </RadarDetailSection>

      <RadarDetailSection icon="brain.head.profile" title="降智雷达">
        <RadarDetailSubsection title="IQ 趋势">
          <RadarChartToggleRow
            activeIds={activeModelSeriesIds}
            onToggle={(id, isOn) => setSelectedModelSeriesIds((current) => toggleChartId(current, modelSeries, id, isOn, modelSeries.slice(0, 2).map((series) => series.id)))}
            series={modelSeries}
          />
          <RadarLineChart
            highlightRange={[90, 110]}
            series={modelSeries}
            valuePrefix="IQ "
            visibleSeriesIds={activeModelSeriesIds}
            xAxisTitle="评测日期"
            yAxisTitle="IQ 指数"
            yDomain={[50, 130]}
            yTickValues={[120, 100, 80, 60]}
          />
        </RadarDetailSubsection>
        <RadarDetailSubsection title="模型对比">
          <RadarTable
            headers={["模型", "IQ", "通过", "状态", "费用", "耗时", "Tokens"]}
            rows={(allModels.length > 0 ? allModels : primary ? [primary] : []).map((row) => [
              row.label,
              displayRadarNumber(row.point.score),
              `${row.point.passed}/${row.point.tasks}`,
              row.point.status || "--",
              formatCost(row.point.costUsd),
              row.point.wallTimeHuman || formatSeconds(row.point.wallSeconds),
              formatTokens(row.point.totalTokens),
            ])}
          />
        </RadarDetailSubsection>
        <RadarDetailSubsection title="近日日志">
          <RadarTable
            headers={["日期", "IQ", "通过", "状态", "耗时", "Tokens"]}
            rows={snapshot.modelIq.recentDays.map((point) => [
              point.date || "--",
              displayRadarNumber(point.score),
              `${point.passed}/${point.tasks}`,
              point.status || "--",
              point.wallTimeHuman || formatSeconds(point.wallSeconds),
              formatTokens(point.totalTokens),
            ])}
            emptyText="暂无近日日志"
          />
        </RadarDetailSubsection>
      </RadarDetailSection>

      <RadarDetailSection icon="gauge.with.dots.needle.67percent" title="预估额度">
        {snapshot.modelIq.quotaRadar ? (
          <>
            <RadarDetailSubsection title="额度基准">
              <RadarKeyValueGrid rows={[
                ["依据窗口", snapshot.modelIq.quotaRadar.basisWindowLabel || "--"],
                ["本轮成本", formatCost(snapshot.modelIq.quotaRadar.costUsd)],
                ["本轮 tokens", formatTokens(snapshot.modelIq.quotaRadar.totalTokens)],
                ["原始变化", `${snapshot.modelIq.quotaRadar.rawDelta}%`],
                ["修正变化", `${snapshot.modelIq.quotaRadar.adjustedDelta}%`],
                ["rate", formatCost(snapshot.modelIq.quotaRadar.rate)],
              ]} />
            </RadarDetailSubsection>
            <RadarDetailSubsection title={`${quotaWindowTitle(selectedQuotaWindow)} 额度趋势`}>
              <div className="codex-radar-chart-toolbar">
                <RadarQuotaWindowSelector selection={selectedQuotaWindow} onSelect={setSelectedQuotaWindow} />
                <RadarChartToggleRow
                  activeIds={activeQuotaSeriesIds}
                  onToggle={(id, isOn) => setSelectedQuotaTierIds((current) => toggleChartId(current, quotaSeries, id, isOn, quotaSeries.map((series) => series.id)))}
                  series={quotaSeries}
                />
              </div>
              <RadarLineChart
                series={quotaSeries}
                valuePrefix="$"
                visibleSeriesIds={activeQuotaSeriesIds}
                xAxisTitle="日期"
                yAxisTitle={`${quotaWindowTitle(selectedQuotaWindow)}美元额度`}
              />
            </RadarDetailSubsection>
            <RadarDetailSubsection title="套餐预估">
              <RadarTable
                headers={["套餐", "5h", "7d", "依据"]}
                rows={quotaRows.map((row) => [row.tier, formatCost(row.fiveH), formatCost(row.sevenD), row.basis || "--"])}
              />
            </RadarDetailSubsection>
            <RadarDetailSubsection title="趋势明细">
              <RadarTable
                headers={["日期", "20x 5h", "20x 7d", "5x 5h", "Plus 5h", "依据"]}
                rows={snapshot.modelIq.quotaRadar.trend.slice(-8).map((point) => [
                  point.date,
                  formatCost(point.fiveHour20x),
                  formatCost(point.sevenDay20x),
                  formatCost(point.fiveHour5x),
                  formatCost(point.fiveHourPlus),
                  point.basisWindowLabel || "--",
                ])}
                emptyText="暂无趋势明细"
              />
            </RadarDetailSubsection>
          </>
        ) : (
          <p className="codex-radar-paragraph">暂无额度雷达数据</p>
        )}
      </RadarDetailSection>

      <RadarDetailSection icon="waveform.path.ecg" title="环境压力与资讯">
        <RadarDetailSubsection title="压力指标">
          <RadarKeyValueGrid rows={[
            ["官方动态 24h", `${environmentCount(snapshot.codexEnvironment, "officialUpdates")}`],
            ["社区提及 24h", `${environmentCount(snapshot.codexEnvironment, "communityMentions")}`],
            ["异常/限额反馈", `${environmentCount(snapshot.codexEnvironment, "issueOrLimitAnomalies")}`],
            ["Status 事故", `${environmentCount(snapshot.codexEnvironment, "statusIncidents")}`],
            ["抱怨压力", snapshot.codexEnvironment.complaintPressure || "--"],
            ["RSS", snapshot.links.rss || "--"],
          ]} />
        </RadarDetailSubsection>
        <RadarDetailSubsection title="角色分布">
          <RadarRoleCounts roleCounts={snapshot.codexEnvironment.roleCounts} />
        </RadarDetailSubsection>
        <RadarArticleList
          emptyText="暂无官方动态"
          items={snapshot.codexEnvironment.officialNews.map((item) => ({
            title: item.titleZh || "Codex 官方动态",
            subtitle: `@${item.account || "--"} · ${item.summaryZh || item.summaryEn || item.text || ""}`,
            url: item.url,
          }))}
          title="官方动态"
        />
        <RadarArticleList
          emptyText="暂无社区反馈样本"
          items={snapshot.codexEnvironment.complaintExamples.map((item) => ({
            title: `@${item.account || "--"}`,
            subtitle: item.summaryZh || item.summaryEn || "",
            url: item.url,
          }))}
          title="社区反馈样本"
        />
        <RadarArticleList
          emptyText="暂无 RSS 提醒历史"
          items={snapshot.feedItems.map((item) => ({
            title: item.title,
            subtitle: `${item.pubDate} · ${item.description}`,
            url: item.link,
          }))}
          title="RSS 提醒历史"
        />
        <RadarDetailSubsection title="来源">
          <RadarKeyValueGrid rows={[
            ["网页", snapshot.links.html || "https://codexradar.com"],
            ["订阅", snapshot.links.rss || "--"],
            ["服务", snapshot.service || "--"],
            ["时区", snapshot.timezone || "--"],
          ]} />
        </RadarDetailSubsection>
      </RadarDetailSection>
    </div>
  );
});

export function CodexRadarDiagnosticsNotice({
  diagnostics = [],
  snapshot,
}: {
  diagnostics?: CodexRadarDiagnostic[];
  snapshot: CodexRadarSnapshot | null;
}) {
  const label = codexRadarDiagnosticLabel(snapshot, diagnostics);
  if (!label) {
    return null;
  }

  return (
    <div className="codex-radar-diagnostics" role="status">
      <strong>{label}</strong>
      <span>{codexRadarSurfaceStatus(snapshot, diagnostics)}</span>
    </div>
  );
}

function RadarBlock({ children, icon, title }: { children: ReactNode; icon: string; title: string }) {
  return (
    <article className="codex-radar-block">
      <span className="radar-block-title">
        <i aria-hidden="true">{icon}</i>
        {title}
      </span>
      {children}
    </article>
  );
}

function RadarMini({ label, value }: { label: string; value: string }) {
  return (
    <span>
      <em>{label}</em>
      <b>{value}</b>
    </span>
  );
}

function RadarDetailItem({ label, value }: { label: string; value: string }) {
  return (
    <span>
      <em>{label}</em>
      <b>{value}</b>
    </span>
  );
}

function RadarDetailSection({ children, icon, title }: { children: ReactNode; icon: string; title: string }) {
  return (
    <section className="codex-radar-detail-section">
      <h3>
        <RadarIcon name={icon} />
        {title}
      </h3>
      <div className="codex-radar-detail-section-body">{children}</div>
    </section>
  );
}

function RadarDetailSubsection({ children, title }: { children: ReactNode; title: string }) {
  return (
    <section className="codex-radar-detail-subsection">
      <h4>{title}</h4>
      {children}
    </section>
  );
}

function RadarKeyValueGrid({ rows }: { rows: Array<[string, string]> }) {
  return (
    <div className="codex-radar-kv-grid">
      {rows.map(([label, value]) => <RadarDetailItem key={label} label={label} value={value} />)}
    </div>
  );
}

function RadarSignalList({ items, title }: { items: string[]; title: string }) {
  return (
    <div className="codex-radar-signal-list">
      <strong>{title}</strong>
      {items.length > 0 ? items.map((item, index) => <p key={`${title}-${index}`}>· {item}</p>) : <p>暂无</p>}
    </div>
  );
}

function RadarTable({ emptyText = "暂无数据", headers, rows }: { emptyText?: string; headers: string[]; rows: string[][] }) {
  if (rows.length === 0) {
    return <p className="codex-radar-paragraph">{emptyText}</p>;
  }

  return (
    <div className="codex-radar-table-wrap">
      <table className="codex-radar-table">
        <thead>
          <tr>
            {headers.map((header) => <th key={header}>{header}</th>)}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, rowIndex) => (
            <tr key={rowIndex}>
              {row.map((cell, cellIndex) => <td key={`${rowIndex}-${cellIndex}`}>{cell}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function RadarChartToggleRow({
  activeIds,
  onToggle,
  series,
}: {
  activeIds: Set<string>;
  onToggle: (id: string, isOn: boolean) => void;
  series: CodexRadarChartSeries[];
}) {
  if (series.length === 0) {
    return null;
  }

  return (
    <div className="codex-radar-chart-toggle-row">
      {series.map((item, index) => {
        const isActive = activeIds.has(item.id);
        return (
          <button
            className={isActive ? "codex-radar-chart-toggle is-active" : "codex-radar-chart-toggle"}
            key={item.id}
            onClick={() => onToggle(item.id, !isActive)}
            style={{ borderColor: isActive ? RADAR_CHART_COLORS[index % RADAR_CHART_COLORS.length] : undefined }}
            type="button"
          >
            <i style={{ background: RADAR_CHART_COLORS[index % RADAR_CHART_COLORS.length] }} />
            {compactModelLabel(item.label)}
          </button>
        );
      })}
    </div>
  );
}

function RadarQuotaWindowSelector({
  onSelect,
  selection,
}: {
  onSelect: (selection: CodexRadarQuotaWindow) => void;
  selection: CodexRadarQuotaWindow;
}) {
  return (
    <div className="codex-radar-window-selector" role="tablist" aria-label="额度窗口">
      {(["fiveHour", "sevenDay"] as CodexRadarQuotaWindow[]).map((window) => (
        <button
          aria-selected={selection === window}
          className={selection === window ? "is-active" : undefined}
          key={window}
          onClick={() => onSelect(window)}
          role="tab"
          type="button"
        >
          {window === "fiveHour" ? "5h" : "7d"}
        </button>
      ))}
    </div>
  );
}

function RadarLineChart({
  highlightRange,
  series,
  valuePrefix,
  visibleSeriesIds,
  xAxisTitle,
  yAxisTitle,
  yDomain,
  yTickValues,
}: {
  highlightRange?: [number, number];
  series: CodexRadarChartSeries[];
  valuePrefix: string;
  visibleSeriesIds: Set<string>;
  xAxisTitle: string;
  yAxisTitle: string;
  yDomain?: [number, number];
  yTickValues?: number[];
}) {
  const visibleSeries = series.map((item, index) => ({ index, item })).filter(({ item }) => visibleSeriesIds.has(item.id));
  const xLabels = uniqueLabels(visibleSeries.flatMap(({ item }) => item.points.map((point) => point.rawLabel)));
  const values = visibleSeries.flatMap(({ item }) => item.points.map((point) => point.value)).filter(Number.isFinite);

  if (visibleSeries.length === 0 || xLabels.length === 0 || values.length === 0) {
    return <p className="codex-radar-paragraph">暂无趋势数据</p>;
  }

  const width = 760;
  const height = 155;
  const plot = { x: 52, y: 18, width: 684, height: 94 };
  const axis = buildChartAxis(values, yDomain, yTickValues);
  const xIndex = new Map(xLabels.map((label, index) => [label, index]));
  const xPosition = (rawLabel: string) => plot.x + (plot.width * (xIndex.get(rawLabel) ?? 0)) / Math.max(xLabels.length - 1, 1);
  const yPosition = (value: number) => {
    const clamped = Math.min(Math.max(value, axis.min), axis.max);
    return plot.y + plot.height - ((clamped - axis.min) / Math.max(axis.max - axis.min, 1)) * plot.height;
  };

  return (
    <svg className="codex-radar-line-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${yAxisTitle}趋势图`}>
      <rect className="codex-radar-chart-bg" x={plot.x} y={plot.y} width={plot.width} height={plot.height} rx="8" />
      {highlightRange ? (
        <rect
          className="codex-radar-chart-highlight"
          x={plot.x}
          y={Math.min(yPosition(highlightRange[0]), yPosition(highlightRange[1]))}
          width={plot.width}
          height={Math.max(1, Math.abs(yPosition(highlightRange[0]) - yPosition(highlightRange[1])))}
          rx="0"
        />
      ) : null}
      {axis.ticks.map((tick) => {
        const y = yPosition(tick);
        return (
          <g key={tick}>
            <line className="codex-radar-chart-grid" x1={plot.x} x2={plot.x + plot.width} y1={y} y2={y} />
            <text className="codex-radar-chart-y-label" x={plot.x - 8} y={y + 3} textAnchor="end">
              {valuePrefix}{displayRadarNumber(tick, 2)}
            </text>
          </g>
        );
      })}
      {visibleSeries.map(({ index, item }) => {
        const points = item.points
          .filter((point) => xIndex.has(point.rawLabel) && Number.isFinite(point.value))
          .map((point) => ({ x: xPosition(point.rawLabel), y: yPosition(point.value), raw: point.rawLabel, value: point.value }));
        const color = RADAR_CHART_COLORS[index % RADAR_CHART_COLORS.length];
        const polyline = points.map((point) => `${point.x.toFixed(2)},${point.y.toFixed(2)}`).join(" ");
        return (
          <g key={item.id}>
            {points.length > 1 ? <polyline className="codex-radar-chart-line" fill="none" points={polyline} stroke={color} /> : null}
            {points.map((point) => (
              <circle className="codex-radar-chart-point" cx={point.x} cy={point.y} fill="var(--panel-solid)" key={`${item.id}-${point.raw}`} r="3.1" stroke={color} />
            ))}
          </g>
        );
      })}
      {xLabels.map((label, index) => {
        if (xLabels.length > 8 && index % Math.ceil(xLabels.length / 6) !== 0 && index !== xLabels.length - 1) {
          return null;
        }
        return (
          <text className="codex-radar-chart-x-label" key={label} x={xPosition(label)} y={plot.y + plot.height + 20} textAnchor="middle">
            {shortDateLabel(label)}
          </text>
        );
      })}
      <text className="codex-radar-chart-axis-title" x={plot.x} y={height - 5}>{xAxisTitle}</text>
      <text className="codex-radar-chart-axis-title" x={plot.x + plot.width} y={height - 5} textAnchor="end">{yAxisTitle}</text>
    </svg>
  );
}

function activeChartIds(series: CodexRadarChartSeries[], selectedIds: Set<string>, fallbackIds: string[]): Set<string> {
  const validIds = new Set(series.map((item) => item.id));
  const active = new Set([...selectedIds].filter((id) => validIds.has(id)));
  if (active.size > 0) {
    return active;
  }
  return new Set(fallbackIds.filter((id) => validIds.has(id)));
}

function toggleChartId(
  selectedIds: Set<string>,
  series: CodexRadarChartSeries[],
  id: string,
  isOn: boolean,
  fallbackIds: string[],
): Set<string> {
  const next = activeChartIds(series, selectedIds, fallbackIds);
  if (isOn) {
    next.add(id);
  } else {
    next.delete(id);
    if (next.size === 0) {
      next.add(id);
    }
  }
  return next;
}

function buildChartAxis(values: number[], yDomain?: [number, number], yTickValues?: number[]): { min: number; max: number; ticks: number[] } {
  if (yDomain) {
    return {
      min: yDomain[0],
      max: yDomain[1],
      ticks: yTickValues ?? [yDomain[1], (yDomain[0] + yDomain[1]) / 2, yDomain[0]],
    };
  }

  const rawMin = Math.min(...values);
  const rawMax = Math.max(...values);
  const span = Math.max(rawMax - rawMin, 1);
  const paddedMin = Math.max(0, rawMin - span * 0.12);
  const paddedMax = rawMax + span * 0.12;
  const min = Math.floor(paddedMin / 10) * 10;
  const max = Math.ceil(paddedMax / 10) * 10;
  return {
    min,
    max,
    ticks: evenlySpacedTicks(min, max),
  };
}

function evenlySpacedTicks(min: number, max: number): number[] {
  const count = 4;
  if (max <= min) {
    return [max];
  }
  return Array.from({ length: count }, (_, index) => max - ((max - min) * index) / (count - 1));
}

function uniqueLabels(labels: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const label of labels) {
    if (!seen.has(label)) {
      seen.add(label);
      result.push(label);
    }
  }
  return result;
}

function quotaWindowTitle(window: CodexRadarQuotaWindow): string {
  return window === "fiveHour" ? "5 小时" : "7 天";
}

function compactModelLabel(label: string): string {
  return label.replaceAll("GPT-", "").replaceAll(" ", "-");
}

function RadarRoleCounts({ roleCounts }: { roleCounts: Record<string, number> }) {
  const rows = Object.entries(roleCounts).sort((a, b) => b[1] - a[1]);
  if (rows.length === 0) {
    return <p className="codex-radar-paragraph">暂无角色分布</p>;
  }
  return (
    <div className="codex-radar-role-counts">
      {rows.map(([role, count]) => (
        <span key={role}>
          <em>{role}</em>
          <b>{count}</b>
        </span>
      ))}
    </div>
  );
}

function RadarArticleList({
  emptyText,
  items,
  title,
}: {
  emptyText: string;
  items: Array<{ title: string; subtitle: string; url: string }>;
  title: string;
}) {
  return (
    <RadarDetailSubsection title={title}>
      <div className="codex-radar-article-list">
        {items.length > 0 ? items.slice(0, 5).map((item, index) => (
          <a href={item.url || undefined} key={`${item.url}-${index}`} rel="noreferrer" target="_blank">
            <strong>{item.title}</strong>
            <span>{item.subtitle || "--"}</span>
          </a>
        )) : <p className="codex-radar-paragraph">{emptyText}</p>}
      </div>
    </RadarDetailSubsection>
  );
}

function RadarIcon({ name }: { name: string }) {
  return (
    <span className="codex-radar-section-icon" aria-hidden="true">
      <svg viewBox="0 0 24 24" focusable="false">
        {radarIconPath(name)}
      </svg>
    </span>
  );
}

function radarIconPath(systemImage: string): ReactNode {
  switch (systemImage) {
    case "bolt.badge.clock":
      return (
        <>
          <path d="M12.6 2.4 5.7 13h5.2l-1.4 8.6 7.2-11.3h-5.1l1-7.9Z" />
          <circle cx="16.6" cy="15.9" r="4.2" fill="none" stroke="currentColor" strokeWidth="1.7" />
          <path d="M16.6 13.5v2.7l1.8 1.1" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
        </>
      );
    case "brain.head.profile":
      return (
        <>
          <path d="M8.7 18.8c-2.8-.8-4.7-3.2-4.7-6.2 0-3.7 2.8-6.7 6.6-6.7 4.2 0 7.4 3.4 7.4 7.5 0 2.2-.8 4-2.1 5.2" fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="1.9" />
          <path d="M8.5 9.2c.6-1.3 2.2-1.5 3.1-.6.8-1.1 2.6-.7 3 .7 1.4.2 2 2 .9 3 .8 1.4-.2 3-1.8 2.9-.6 1.1-2.3 1.2-3.1.1-1.2.5-2.6-.5-2.5-1.9-1.3-.7-1.3-2.9.4-4.2Z" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" />
          <path d="M12 15.6v4.1h3" fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="1.7" />
        </>
      );
    case "gauge.with.dots.needle.67percent":
      return (
        <>
          <path d="M4.3 16.7a8.3 8.3 0 1 1 15.4 0" fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="1.9" />
          <path d="M12 16.3 16.7 10" fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="1.9" />
          <circle cx="12" cy="16.6" r="1.4" />
          <circle cx="6.9" cy="16.1" r="1" />
          <circle cx="8.1" cy="9.2" r="1" />
          <circle cx="15.9" cy="9.2" r="1" />
          <circle cx="17.1" cy="16.1" r="1" />
        </>
      );
    case "waveform.path.ecg":
      return (
        <path d="M2.5 12h4l1.7-5.2 3.1 10.4L14 8.7l1.5 3.3h6" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
      );
    default:
      return <circle cx="12" cy="12" r="5" />;
  }
}

function formatTokens(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return "-- token";
  }
  if (value >= 100_000_000) {
    return `${displayRadarNumber(value / 100_000_000, 1)}亿 token`;
  }
  if (value >= 10_000) {
    return `${displayRadarNumber(value / 10_000, 1)}万 token`;
  }
  return `${Math.round(value)} token`;
}

function formatCost(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return "成本 --";
  }
  return `$${displayRadarNumber(value, 2)}`;
}

function formatSeconds(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return "-- 秒";
  }
  if (value >= 3600) {
    return `${displayRadarNumber(value / 3600, 1)} 小时`;
  }
  if (value >= 60) {
    return `${displayRadarNumber(value / 60, 1)} 分钟`;
  }
  return `${Math.round(value)} 秒`;
}

function modelPointSummary(point: CodexRadarModelIQPoint): string {
  return [
    `IQ ${displayRadarNumber(point.score)} ${point.status || ""}`.trim(),
    `通过 ${point.passed}/${point.tasks}`,
    `有效 ${point.validTasks}`,
    `无效 ${point.invalid}`,
    `总 ${formatTokens(point.totalTokens)}`,
    `输入 ${formatTokens(point.inputTokens)}`,
    `缓存 ${formatTokens(point.cachedInputTokens)}`,
    `输出 ${formatTokens(point.outputTokens)}`,
    point.wallTimeHuman || formatSeconds(point.wallSeconds),
    formatCost(point.costUsd),
  ].filter(Boolean).join(" · ");
}

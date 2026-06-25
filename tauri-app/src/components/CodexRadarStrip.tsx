import { useEffect, useMemo, useState, type ReactNode } from "react";
import { readCodexRadarSnapshot } from "../api/codexRadarClient";
import {
  type CodexRadarModelIQComparisonRow,
  type CodexRadarModelIQPoint,
  displayRadarNumber,
  environmentCount,
  modelDisplayName,
  percentText,
  primaryModelRow,
  secondaryModelRows,
  type CodexRadarSnapshot,
} from "./codexRadar/model";

const RADAR_REFRESH_INTERVAL_MS = 600_000;

export function CodexRadarStrip() {
  const [snapshot, setSnapshot] = useState<CodexRadarSnapshot | null>(null);
  const [status, setStatus] = useState("Codex 雷达待读取");
  const [refreshing, setRefreshing] = useState(false);
  const [showDetails, setShowDetails] = useState(false);

  async function refresh(force = false) {
    if (refreshing) {
      return;
    }
    setRefreshing(true);
    setStatus(snapshot ? "正在更新 Codex 雷达..." : "正在读取 Codex 雷达...");
    try {
      const next = await readCodexRadarSnapshot({ force });
      setSnapshot(next);
      setStatus(`10分钟刷新 · ${next.monitoredAt}`);
    } catch (error) {
      setStatus(`Codex 雷达读取失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setRefreshing(false);
    }
  }

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(false), RADAR_REFRESH_INTERVAL_MS);
    return () => window.clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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
        <a href={snapshot?.links.html ?? "https://codexradar.com"} rel="noreferrer" target="_blank">
          codexradar.com
        </a>
        <button
          aria-expanded={showDetails}
          className="radar-detail-toggle"
          onClick={() => setShowDetails((value) => !value)}
          type="button"
        >
          详情 {showDetails ? "⌃" : "⌄"}
        </button>
        <button disabled={refreshing} onClick={() => void refresh(true)} type="button">
          {refreshing ? "刷新中" : "刷新"}
        </button>
      </div>

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
          isRefreshing={refreshing}
          onClose={() => setShowDetails(false)}
          onRefresh={() => void refresh(true)}
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

function CodexRadarDetailOverlay({
  allModels,
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
            <span>{snapshot ? `10分钟刷新 · ${snapshot.monitoredAt}` : status}</span>
          </div>
          <button className="codex-radar-detail-refresh" disabled={isRefreshing} onClick={onRefresh} type="button">
            {isRefreshing ? "刷新中" : "刷新"}
          </button>
          <button aria-label="关闭 Codex 雷达详情" className="codex-radar-detail-close" onClick={onClose} type="button">×</button>
        </div>

        <div className="codex-radar-detail-scroll">
          {snapshot ? (
            <div className="codex-radar-detail-stack">
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
                  <RadarTrendSummary points={snapshot.modelIq.recentDays} />
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
          ) : (
            <div className="codex-radar-detail-loading">
              <span className="codex-radar-spinner" aria-hidden="true" />
              <p>{status}</p>
            </div>
          )}
        </div>

        <a className="codex-radar-thanks" href={snapshot?.links.html ?? "https://codexradar.com"} rel="noreferrer" target="_blank">
          感谢 Codex Radar 提供公开雷达数据
        </a>
      </div>
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
        <i aria-hidden="true">{radarIconText(icon)}</i>
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

function RadarTrendSummary({ points }: { points: CodexRadarModelIQPoint[] }) {
  const recent = points.slice(-6);
  return (
    <div className="codex-radar-trend-summary">
      {recent.length > 0 ? recent.map((point) => (
        <span key={`${point.date}-${point.model ?? ""}-${point.reasoningEffort ?? ""}`}>
          <em>{point.date || "--"}</em>
          <b>IQ {displayRadarNumber(point.score)}</b>
        </span>
      )) : <p className="codex-radar-paragraph">暂无 IQ 趋势数据</p>}
    </div>
  );
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

function radarIconText(systemImage: string): string {
  switch (systemImage) {
    case "bolt.badge.clock":
      return "↯";
    case "brain.head.profile":
      return "IQ";
    case "gauge.with.dots.needle.67percent":
      return "%";
    case "waveform.path.ecg":
      return "~";
    default:
      return "•";
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

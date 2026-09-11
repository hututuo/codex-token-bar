import { getCurrentWindow } from "@tauri-apps/api/window";
import { radarSpeedWindowDeadlineMs } from "../domain/codexRadar/model";
import { subscribeRadarCountdown } from "../domain/codexRadar/countdown";
import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState, type CSSProperties, type PointerEvent } from "react";
import { invoke } from "@tauri-apps/api/core";
import { emitTo, listen } from "@tauri-apps/api/event";
import { readAppSettings } from "../api/client";
import { desktopPlatform } from "../platform/desktop";
import { sanitizeDisplaySurfaces, INACTIVE_DISPLAY_SURFACES } from "../settings/displaySettings";
import { DEFAULT_QUOTA_REFRESH_INTERVAL_MS, sanitizeQuotaRefreshIntervalMs } from "../settings/quotaRefreshCadence";
import { useCompactPanelData, type CompactPanelData } from "../surfaces/useCompactPanelData";
import { useCompactPanelSource } from "../surfaces/useCompactPanelSource";
import type { DisplaySurfaceSettings, RunningThreadMember } from "../types/dashboard";
import { initialSidebarState, sidebarRailClassName, hasFiveHourQuota, isSidebarAction, quotaPercent, quotaText, sidebarReducer, type SidebarAction, type SidebarState } from "./model";
import { useFloatingRadar, useFloatingCrowdRadar } from "../floating/useFloatingRadar";
import { sidebarRadarSnapshot, sidebarRadarCompact, sidebarRadarIsActive, type SidebarRadar } from "./radarModel";
import { sidebarLocalTime, sidebarMetricValue } from "./detailsModel";
import { formatTokens } from "../utils/format";
import { isSidebarDragTarget, createSidebarDragSession } from "./drag";
import { sanitizeRateFullScale, formatLiveRateValue } from "../components/liveRate/rateDisplay";
import { sidebarRatePercent } from "./rateModel";
import { createSidebarPublisher, sidebarVisualPercent } from "./presentation";
import { createSidebarNativeCoordinator } from "./nativeCoordinator";
import { monitorSidebarPresence } from "./presence";
import { floatingTodayModelUsageItems, floatingModelUsageValue } from "../floating/floatingModelUsage";
import { sidebarExpectedFraction, flashSidebarButton } from "./meterFeedback";

import { prepareResetCreditsForDisplay } from "../components/quota/resetCredits";
import type { SidebarSection } from "./model";
import { SidebarTrend, type TrendPoint } from "./SidebarTrend";

type SidebarData = Pick<CompactPanelData, "snapshot" | "runningThreads"> & {
  trend?: TrendPoint[];
  quota: Pick<CompactPanelData["quota"], "updatedAt" | "account" | "quota">;
};
function sidebarData(data: CompactPanelData): SidebarData {
  return { snapshot: data.snapshot, runningThreads: data.runningThreads,
    quota: { updatedAt: data.quota.updatedAt, account: data.quota.account, quota: data.quota.quota } };
}
interface Presentation { data: SidebarData; radar: SidebarRadar; state: SidebarState; side: "left" | "right"; error: string | null }
const railLabel = "quota-sidebar";
const detailLabel = "quota-sidebar-detail";

export function QuotaSidebarApp() {
  return new URLSearchParams(location.search).get("surface") === detailLabel ? <DetailSurface /> : <RailSurface />;
}

function RailSurface() {
  const [display, setDisplay] = useState(INACTIVE_DISPLAY_SURFACES);
  const [rateFullScale, setRateFullScale] = useState(() => sanitizeRateFullScale(200));
  const [cadence, setCadence] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const [state, dispatch] = useReducer(sidebarReducer, initialSidebarState);
  const [error, setError] = useState<string | null>(null);
  const { sourceReady, sourceToken } = useCompactPanelSource(display.quotaSidebarEnabled);
  const data = useCompactPanelData({ active: display.quotaSidebarEnabled && sourceReady,
    liveRateEnabled: display.liveRateEnabled, liveRateOwnerToken: "quota-sidebar-live-rate",
    quotaSource: "direct", quotaInitialDelayMs: 0, quotaIntervalMs: cadence,
    backgroundAggregateEnabled: true, sourceToken });
  const [trendTokens, setTrendTokens] = useState<[number, number][]>([]);
  useEffect(() => {
    setTrendTokens([]);
    if (!display.quotaSidebarEnabled || state.mode !== "detail" || !sourceToken) return;
    let cancelled = false; let busy = false;
    const refresh = async () => {
      if (busy) return; busy = true;
      try { const rows = await invoke<[number, number][]>("read_sidebar_trend", { sourceToken });
        if (!cancelled) setTrendTokens(rows);
      } catch { /* Empty chart is preferable to an invented history. */ }
      finally { busy = false; }
    };
    void refresh(); const timer = setInterval(() => void refresh(), 300_000);
    return () => { cancelled = true; clearInterval(timer); };
  }, [display.quotaSidebarEnabled, state.mode, sourceToken]);
  const trend = useMemo(() => {
    const quotas = new Map(data.quota.quotaHistory24h.map(point => [point.startUnix, point]));
    return trendTokens.map(([at, tokens]) => ({ at, tokens,
      five: quotas.get(at)?.fiveHourRemainingPercent ?? null,
      seven: quotas.get(at)?.sevenDayRemainingPercent ?? null }));
  }, [trendTokens, data.quota.quotaHistory24h]);
  const officialRadar = useFloatingRadar(display.quotaSidebarEnabled);
  const crowdRadar = useFloatingCrowdRadar(display.quotaSidebarEnabled, { clearOnError: true });
  const [radarNow, setRadarNow] = useState(Date.now);
  const deadline = radarSpeedWindowDeadlineMs(officialRadar);
  useEffect(() => display.quotaSidebarEnabled ? subscribeRadarCountdown(deadline, setRadarNow) : undefined, [deadline, display.quotaSidebarEnabled]);
  useEffect(() => {
    if (!display.quotaSidebarEnabled) return;
    setRadarNow(Date.now());
    const timer = setInterval(() => setRadarNow(Date.now()), 30_000);
    return () => clearInterval(timer);
  }, [display.quotaSidebarEnabled]);
  const radar = useMemo(() => sidebarRadarSnapshot(officialRadar, crowdRadar, Math.max(radarNow, Date.now())), [officialRadar, crowdRadar, radarNow]);
  const compactData = useMemo(() => ({ ...sidebarData(data), trend }), [data.snapshot, data.runningThreads, data.quota.updatedAt, data.quota.account, data.quota.quota, trend]);
  const showsFiveHour = hasFiveHourQuota(data.snapshot.fiveHourAvailability, data.snapshot.fiveHourRemainingPercent);
  const coordinator = useRef<ReturnType<typeof createSidebarNativeCoordinator> | null>(null);
  if (coordinator.current === null) coordinator.current = createSidebarNativeCoordinator(
    (mode, showsFiveHour, refreshGeometry) => invoke("set_quota_sidebar_mode", { mode, showsFiveHour, refreshGeometry, reducedMotion: window.matchMedia("(prefers-reduced-motion: reduce)").matches }),
    reason => setError(reason === null ? null : `窗口更新失败：${String(reason)}`),
  );
  const dragSession = useRef<ReturnType<typeof createSidebarDragSession> | null>(null);
  const [dragging, setDragging] = useState(false);
  const leaveRevision = useRef(0);
  const leaveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const cancelLeave = useCallback(() => { leaveRevision.current++; if (leaveTimer.current !== null) clearTimeout(leaveTimer.current); leaveTimer.current = null; }, []);
  const enter = useCallback(() => { if (dragSession.current?.active) return; cancelLeave(); dispatch({ type: "enter" }); }, [cancelLeave]);
  const leave = useCallback(() => {
    if (dragSession.current?.active) return;
    cancelLeave();
    const revision = leaveRevision.current;
    leaveTimer.current = setTimeout(() => {
      void invoke<boolean>("quota_sidebar_pointer_inside").then((inside) => {
        if (!inside && revision === leaveRevision.current) dispatch({ type: "leave" });
      }).catch(() => { if (revision === leaveRevision.current) dispatch({ type: "leave" }); });
    }, 300);
  }, [cancelLeave]);
  if (!dragSession.current) dragSession.current = createSidebarDragSession(
    () => invoke<boolean>("drag_quota_sidebar"),
    () => {
      setDragging(false);
      const epoch = dragSession.current!.epoch;
      void invoke<boolean>("quota_sidebar_pointer_inside").then(inside => {
        if (dragSession.current?.isCurrent(epoch) && !dragSession.current.active) inside ? enter() : leave();
      }).catch(() => { if (dragSession.current?.isCurrent(epoch) && !dragSession.current.active) leave(); });
    },
    reason => setError(`位置调整失败：${String(reason)}`),
  );
  useEffect(() => {
    dragSession.current?.setEnabled(display.quotaSidebarEnabled);
    if (!display.quotaSidebarEnabled) setDragging(false);
    return () => dragSession.current?.setEnabled(false);
  }, [display.quotaSidebarEnabled]);
  useEffect(() => {
    if (!display.quotaSidebarEnabled || state.mode === "rest" || state.pinned || dragging) return;
    return monitorSidebarPresence(
      () => invoke<boolean>("quota_sidebar_pointer_inside"),
      () => { cancelLeave(); dispatch({ type: "leave" }); },
    );
  }, [display.quotaSidebarEnabled, state.mode, state.pinned, dragging, cancelLeave]);
  const startDrag = (event: PointerEvent<HTMLElement>) => {
    if (event.button !== 0 || dragSession.current?.active || !isSidebarDragTarget(event.target as Element)) return;
    event.preventDefault(); cancelLeave();
    if (dragSession.current?.start()) setDragging(true);
  };
  const presentation = useMemo<Presentation>(() => ({ data: compactData, radar, state, side: display.quotaSidebarSide, error }), [compactData, radar, state, display.quotaSidebarSide, error]);
  const publisher = useRef<ReturnType<typeof createSidebarPublisher<Presentation>> | null>(null);
  if (!publisher.current) publisher.current = createSidebarPublisher(value => { void emitTo(detailLabel, "quota-sidebar-presentation", value).catch(() => {}); });
  useEffect(() => {
    let disposed = false; const cleanup: (() => void)[] = [];
    const add = (promise: Promise<() => void>) => void promise.then((unlisten) => disposed ? unlisten() : cleanup.push(unlisten));
    let revision = 0;
    const apply = (value: DisplaySurfaceSettings) => { revision++; setDisplay(sanitizeDisplaySurfaces(value)); };
    const refresh = async () => {
      const generation = revision;
      try { const settings = await readAppSettings(); if (!disposed && settings && generation === revision) {
        setDisplay(sanitizeDisplaySurfaces(settings.displaySurfaces));
        setCadence(sanitizeQuotaRefreshIntervalMs(settings.quotaRefreshIntervalMs));
        setRateFullScale(sanitizeRateFullScale(settings.floatingWindow.tokenRateFullScale));
      } } catch (reason) { if (!disposed) setError(`设置读取失败：${String(reason)}`); }
    };
    add(listen<DisplaySurfaceSettings>("quota-sidebar-settings-changed", e => apply(e.payload)));
    add(desktopPlatform.onDisplaySurfacesChanged(apply));
    add(desktopPlatform.onAppSettingsChanged(settings => { revision++; setRateFullScale(sanitizeRateFullScale(settings.floatingWindow.tokenRateFullScale)); }));
    add(listen("quota-sidebar-drag-started", () => dispatch({ type: "drag" })));
    add(listen<boolean>("quota-sidebar-native-hover", e => e.payload ? enter() : leave()));
    add(listen<boolean>("quota-sidebar-union-hover", e => e.payload ? enter() : leave()));
    add(listen<SidebarAction>("quota-sidebar-action", e => { if (isSidebarAction(e.payload)) dispatch(e.payload); }));
    add(listen("quota-sidebar-detail-ready", () => publisher.current?.ready()));
    add(listen("quota-sidebar-environment-changed", () => coordinator.current?.refresh()));
    const clip = (size: { width: number; height: number }) => {
      const scale = window.devicePixelRatio || 1;
      document.documentElement.style.setProperty("--qs-native-width", `${size.width / scale}px`);
      document.documentElement.style.setProperty("--qs-native-height", `${size.height / scale}px`);
    };
    add(getCurrentWindow().onResized(event => clip(event.payload)));
    void getCurrentWindow().innerSize().then(size => { if (!disposed) clip(size); }).catch(() => {});
    void refresh(); const timer = setInterval(() => void refresh(), 15_000);
    return () => { disposed = true; cleanup.forEach(fn => fn()); clearInterval(timer); cancelLeave(); };
  }, [cancelLeave, enter, leave]);
  useEffect(() => {
    if (!display.quotaSidebarEnabled) { cancelLeave(); dispatch({ type: "disable" }); }
  }, [display.quotaSidebarEnabled, cancelLeave]);
  useEffect(() => {
    coordinator.current?.update(state.mode, showsFiveHour);
  }, [state.mode, showsFiveHour]);
  useEffect(() => {
    coordinator.current?.setEnabled(display.quotaSidebarEnabled);
    return () => coordinator.current?.setEnabled(false);
  }, [display.quotaSidebarEnabled]);
  useEffect(() => {
    if (!display.quotaSidebarEnabled) return;
    const refresh = () => coordinator.current?.refresh();
    // Covers same-DPI monitor/workarea changes without continuous native polling.
    const timer = setInterval(refresh, 30_000);
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
    reduced.addEventListener("change", refresh);
    return () => { clearInterval(timer); reduced.removeEventListener("change", refresh); };
  }, [display.quotaSidebarEnabled, display.quotaSidebarSide]);
  useEffect(() => { publisher.current?.update(presentation, display.quotaSidebarEnabled && state.mode === "detail"); }, [presentation, display.quotaSidebarEnabled, state.mode]);
  if (!display.quotaSidebarEnabled) return null;
  return <main className={sidebarRailClassName(display.quotaSidebarSide, state.mode)} onPointerDown={startDrag} onPointerEnter={enter} onPointerLeave={leave} data-dragging={dragging} aria-label="额度侧栏">
    <SidebarRailContent data={compactData} radar={radar} rateFullScale={rateFullScale} liveRateEnabled={display.liveRateEnabled} state={state} error={error} onOpen={(tab, section) => dispatch({ type: "open", tab, section })} />
  </main>;
}
export function SidebarRailContent({ data, radar, state, rateFullScale = 200, liveRateEnabled = true, error = null, onOpen }: {
  data: SidebarData; radar?: SidebarRadar; state: SidebarState; rateFullScale?: number; liveRateEnabled?: boolean; error?: string | null; onOpen: (tab: SidebarState["tab"], section?: SidebarSection) => void;
}) {
  const ratePercent = sidebarRatePercent(data.snapshot, liveRateEnabled, rateFullScale);
  const rateLabel = !liveRateEnabled ? "实时速率已关闭" : ratePercent === null ? "实时速率不可用" : `实时速率 ${formatLiveRateValue(data.snapshot.tokensPerSecond)} t/s · 量程 ${sanitizeRateFullScale(rateFullScale)} t/s`;
  const five = sidebarVisualPercent(quotaPercent(data.snapshot.fiveHourAvailability, data.snapshot.fiveHourRemainingPercent));
  const seven = sidebarVisualPercent(quotaPercent(data.snapshot.sevenDayAvailability, data.snapshot.sevenDayRemainingPercent));
  const showsFiveHour = hasFiveHourQuota(data.snapshot.fiveHourAvailability, data.snapshot.fiveHourRemainingPercent);
  const expectedFive = sidebarExpectedFraction(five, data.snapshot.fiveHourExpectedRemainingPercent, data.snapshot.quotaDataStale);
  const expectedSeven = sidebarExpectedFraction(seven, data.snapshot.sevenDayExpectedRemainingPercent, data.snapshot.quotaDataStale);
  const models = useMemo(() => floatingTodayModelUsageItems(data.snapshot.todayModelBreakdowns, "gpt56Sol", { showPlaceholders: false }).filter(item => item.share > 0), [data.snapshot.todayModelBreakdowns]);
  const nearestCredit = prepareResetCreditsForDisplay(data.quota?.quota?.resetCredit?.credits ?? []).find(item => item.isCountdownEligible)?.credit;
  const modelTitle = models.length ? `今日模型 Token 占比：${models.map(item => `${item.label} ${(item.share * 100).toFixed(1)}%`).join("，")}` : "今日模型占比待读取";
  const modelStrip = (vertical: boolean) => <div className={`qs-model-strip ${vertical ? "qs-model-strip-vertical" : ""}`} title={modelTitle} aria-label={modelTitle}>{models.map(item => <i key={item.key} style={{ flexGrow: item.share, background: item.color }} />)}</div>;
  return <>
    <span className="qs-radar-edge" data-active={sidebarRadarIsActive(radar)} aria-hidden="true" />
    <div className="qs-bars" data-visible={state.mode === "rest"} aria-hidden={state.mode !== "rest"} aria-label="悬停查看额度">
      <span className="qs-bar qs-rate-bar" data-known={ratePercent !== null} aria-label={rateLabel} title={rateLabel}><i style={{ transform: `scaleY(${(ratePercent ?? 0) / 100})`, background: "#78b7ff" }} /></span>
      {showsFiveHour && <Bar percent={five} color="#b6ef75" expected={expectedFive} />}<Bar percent={seven} color="#b4acff" expected={expectedSeven} />{modelStrip(true)}
    </div><div className="qs-summary" onClickCapture={event => flashSidebarButton(event.target)} data-visible={state.mode !== "rest"} aria-hidden={state.mode === "rest"} inert={state.mode === "rest"}>
      <span className="qs-caption">速览</span>
            <button className="qs-quota-trigger qs-rate-trigger" onClick={() => onOpen("quota", "usage")} aria-label="查看实时速率详情" title={rateLabel}><Ring label="t/s" percent={ratePercent} color="#78b7ff" /><Value value={ratePercent === null ? "—" : formatLiveRateValue(data.snapshot.tokensPerSecond)} /></button>
      {showsFiveHour && <button className="qs-quota-trigger" onClick={() => onOpen("quota", "five")} aria-label="查看五小时额度详情"><Ring label="5h" percent={five} color="#b6ef75" expected={expectedFive} /><Value value={quotaText(five)} /></button>}
      <button className="qs-quota-trigger" onClick={() => onOpen("quota", "seven")} aria-label="查看七天额度详情"><Ring label="7d" percent={seven} color="#b4acff" expected={expectedSeven} /><Value value={quotaText(seven)} /></button>
      <button className="qs-model-trigger" onClick={() => onOpen("quota", "models")} aria-label="查看今日模型 Token 占比" title={modelTitle}>{modelStrip(false)}<span>模型占比</span></button>
      <div className="qs-divider" />
      <button className="qs-running-trigger" onClick={() => onOpen("running", "top")}><span className="qs-task-ring"><Value value={String(data.runningThreads.total ?? "—")} /></span><span>{data.runningThreads.status === "ready" ? `${data.runningThreads.mainThreads ?? "—"} 主 · ${data.runningThreads.subagents ?? "—"} 子` : data.runningThreads.status === "stale" ? "运行·过期" : "运行·未知"}</span></button>
      <button className="qs-recommendations" onClick={() => onOpen("radar", "ranking")}><small title="每 5 分钟刷新；缓存标记表示来源服务器返回缓存，并非本机停止刷新">众测推荐</small>{radar?.crowd.rows.slice(0, 3).map(row => <span key={row.rank} title={`${row.model} ${row.effort} · IQ ${row.iq.toFixed(1)}`}>{row.model.replace(/^gpt-[\d.]+-/, "")} {row.effort}</span>)}</button>
      <div className="qs-divider" />
      <button className="qs-window-status" data-active={sidebarRadarIsActive(radar)} onClick={() => onOpen("radar", "top")}><span>{sidebarRadarCompact(radar)}</span>{sidebarRadarIsActive(radar) && radar?.official.deadlineMs && <small>{radar.official.countdown}</small>}</button>
      {data.quota?.quota?.resetCredit?.updatedAt && <button className="qs-reset-count" onClick={() => onOpen("credits", "top")}>重置卡 {data.quota.quota.resetCredit.availableCount} 张{nearestCredit && <small>{sidebarLocalTime(nearestCredit.expiresAt, nearestCredit.expiresAtUnix)}</small>}</button>}
      {data.snapshot.quotaDataStale && <span className="qs-warning">额度已过期</span>}
      {error && <span className="qs-warning" title={error}>窗口异常</span>}
    </div>
  </>;
}

function Value({ value }: { value: string }) {
  const [frame, setFrame] = useState({ current: value, previous: null as string | null, revision: 0 });
  const known = (text: string) => text !== "—" && text !== "未知";
  if (frame.current !== value) {
    setFrame({ current: value, previous: known(value) && known(frame.current) ? frame.current : null, revision: frame.revision + 1 });
  }
  return <strong className="qs-value-change" aria-label={value} data-known={known(value)}>
    {frame.previous !== null && <span key={`old-${frame.revision}`} className="qs-digit-old" aria-hidden="true">{frame.previous}</span>}
    <span key={frame.revision} className={frame.previous !== null ? "qs-digit-new" : undefined} aria-hidden="true"
      onAnimationEnd={() => setFrame(current => current.revision === frame.revision ? { ...current, previous: null } : current)}>{value}</span>
  </strong>;
}
function Bar({ percent, color, expected }: { percent: number | null; color: string; expected?: number | null }) {
  return <span className={`qs-bar ${percent === null ? "qs-unknown" : ""}`}><i style={{ transform: `scaleY(${(percent ?? 100) / 100})`, background: color }} />{expected != null && <b className="qs-pace-mark" style={{ bottom: `${expected * 100}%` }} title={`均匀用量参考：预期剩余 ${Math.round(expected * 100)}%`} />}</span>;
}
function Ring({ label, percent, color, expected }: { label: string; percent: number | null; color: string; expected?: number | null }) {
  return <div className="qs-ring" data-known={percent !== null} title={expected != null ? `白线为均匀使用参考：预期剩余 ${Math.round(expected * 100)}%` : undefined}><svg viewBox="0 0 52 52" aria-hidden="true"><circle cx="26" cy="26" r="22" className="qs-track" /><circle cx="26" cy="26" r="22" fill="none" stroke={color} strokeWidth="4" strokeLinecap="round" className="qs-ring-value" strokeDasharray="138.23" strokeDashoffset={138.23 * (1 - (percent ?? 0) / 100)} transform="rotate(-90 26 26)" />{expected != null && <line className="qs-pace-tick" x1="26" y1="0" x2="26" y2="8" transform={`rotate(${expected * 360} 26 26)`} />}</svg><span>{label}</span></div>;
}
function DetailSurface() {
  const [value, setValue] = useState<Presentation | null>(null);
  useEffect(() => {
    let disposed = false; const cleanup: (() => void)[] = [];
    const add = (p: Promise<() => void>) => void p.then(fn => disposed ? fn() : cleanup.push(fn));
    void listen<Presentation>("quota-sidebar-presentation", e => { setValue(e.payload); }).then(unlisten => {
      if (disposed) { unlisten(); return; }
      cleanup.push(unlisten);
      // Announce only after the presentation listener is installed.
      void emitTo(railLabel, "quota-sidebar-detail-ready");
    });
    add(listen<boolean>("quota-sidebar-detail-native-hover", e => { void emitTo(railLabel, "quota-sidebar-union-hover", e.payload); }));
    const escape = (e: KeyboardEvent) => { if (e.key === "Escape") void emitTo(railLabel, "quota-sidebar-action", { type: "close" }); };
    window.addEventListener("keydown", escape);
    return () => { disposed = true; cleanup.forEach(fn => fn()); window.removeEventListener("keydown", escape); };
  }, []);
  useLayoutEffect(() => {
    if (!value || value.state.mode !== "detail") return;
    const container = document.querySelector<HTMLElement>(".qs-detail-content");
    const target = document.getElementById(`qs-section-${value.state.section || "top"}`);
    if (container) container.scrollTop = target ? target.getBoundingClientRect().top - container.getBoundingClientRect().top + container.scrollTop : 0;
  }, [value?.state.mode, value?.state.tab, value?.state.section, value?.state.focusRevision, value?.data.trend?.length]);
  const action = (action: SidebarAction) => void emitTo(railLabel, "quota-sidebar-action", action.type === "open" ? { ...action, section: action.section || "top" } : action);
  return <main key={value?.state.mode === "detail" ? "open" : "closed"} className={`qs-detail qs-${value?.side ?? "right"}`} onPointerEnter={() => void emitTo(railLabel, "quota-sidebar-union-hover", true)} onPointerLeave={() => void emitTo(railLabel, "quota-sidebar-union-hover", false)}>
    {value === null ? <p className="qs-muted">正在读取侧栏快照…</p> : <>
      <header><div><strong>Codex</strong><span className="qs-plan">{value.data.quota.account.planLabel || "套餐未知"}</span><small className="qs-account">{value.data.quota.account.displayName || "账户待读取"}</small><small className="qs-update" title={value.data.quota.updatedAt}>更新 {sidebarLocalTime(value.data.quota.updatedAt, null, true)}</small></div><div className="qs-actions"><button aria-label="打开主界面" title="打开主界面" onClick={() => void desktopPlatform.showDashboardWindow()}>主界面 ↗</button><button className="qs-pin" aria-label={value.state.pinned ? "取消固定详情" : "固定详情"} title={value.state.pinned ? "取消固定详情" : "固定详情"} aria-pressed={value.state.pinned} onClick={() => action({ type: "pin" })}><svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill={value.state.pinned ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M9 3h6l-1 7 4 4v2H6v-2l4-4-1-7Z"/><path d="M12 16v6"/></svg></button><button aria-label="关闭详情" onClick={() => action({ type: "close" })}>×</button></div></header>
      <nav><button aria-selected={value.state.tab === "quota"} onClick={() => action({ type: "open", tab: "quota" })}>额度概览</button><button aria-selected={value.state.tab === "running"} onClick={() => action({ type: "open", tab: "running" })}>运行会话 <b>{value.data.runningThreads.total ?? "—"}</b></button><button aria-selected={value.state.tab === "radar"} onClick={() => action({ type: "open", tab: "radar" })}>雷达</button><button aria-selected={value.state.tab === "credits"} onClick={() => action({ type: "open", tab: "credits" })}>重置卡</button></nav>
      <div className="qs-detail-content">{value.state.tab === "quota" ? <QuotaDetails data={value.data} onOpenRunning={() => action({ type: "open", tab: "running" })} /> : value.state.tab === "credits" ? <ResetCreditDetails data={value.data} /> : value.state.tab === "running" ? <RunningDetails data={value.data} /> : <RadarDetails key={value.state.section || "official"} radar={value.radar} initialRanking={value.state.section === "ranking" ? "crowd" : "official"} />}</div>
      <footer><span>额度 · 用量 · 会话</span><span>{value.state.pinned ? "已固定 · 点击 × 收起" : "移出后收起 · 点击固定"}</span></footer>
      {value.error && <details className="qs-diagnostic"><summary>窗口状态说明</summary><p>{value.error}</p></details>}
    </>}
  </main>;
}
export function ResetCreditDetails({ data }: { data: SidebarData }) {
  const { quota } = data;
  return <section className="qs-reset-cards" id="qs-section-top"><div className="qs-section-heading"><h3>重置卡</h3><span>可用 {quota.quota.resetCredit?.availableCount ?? "—"} 张</span></div>
      {quota.quota.resetCredit?.credits.map((card,index) => <div className="qs-reset-card" key={card.cardId || index}>
        <div><strong>重置卡 {index+1}</strong><span>{card.status}</span></div>
        <p>发放　{sidebarLocalTime(card.issuedAt,card.grantedAtUnix)}</p><p>到期　{sidebarLocalTime(card.expiresAt,card.expiresAtUnix)}</p>
        {card.redeemedAt && <p>使用　{card.redeemedAt}</p>}
      </div>)}
      {!quota.quota.resetCredit?.credits.length && <p className="qs-muted">{quota.quota.resetCredit?.status || "重置卡待读取"}</p>}
    </section>;
}

export function QuotaDetails({ data, onOpenRunning }: { data: SidebarData; onOpenRunning?: () => void }) {
  const { quota, snapshot, runningThreads } = data;
  const models = floatingTodayModelUsageItems(snapshot.todayModelBreakdowns, "gpt56Sol", { showPlaceholders: false }).filter(item => item.share > 0);
  const expectedSeven = sidebarExpectedFraction(
    quotaPercent(snapshot.sevenDayAvailability, snapshot.sevenDayRemainingPercent),
    snapshot.sevenDayExpectedRemainingPercent, snapshot.quotaDataStale,
  );
  const sevenDayReference = expectedSeven === null ? null : expectedSeven * 100;
  const tokenParts = (snapshot.todayModelBreakdowns ?? []).reduce((sum, row) => ({
    input: sum.input + row.breakdown.inputTokens,
    cached: sum.cached + row.breakdown.cachedInputTokens,
    output: sum.output + row.breakdown.outputTokens,
  }), { input: 0, cached: 0, output: 0 });
  const breakdownKnown = (snapshot.todayModelBreakdowns?.length ?? 0) > 0 && Object.values(tokenParts).every(Number.isFinite);
  const inputParts = [
    { label: "未缓存输入", value: Math.max(0, tokenParts.input - tokenParts.cached), color: "#78b7ff" },
    { label: "缓存输入", value: tokenParts.cached, color: "#b4acff" },
    { label: "输出", value: tokenParts.output, color: "#b6ef75" },
  ];
  const unread = snapshot.unreadSummary;
  const unreadLabel = unread.source.includes("pending") ? "未读状态未知" : unread.label || "未读状态未知";
  return <>
    {snapshot.quotaDataStale && <p className="qs-warning">额度已过期 · 显示上次成功读取的结果</p>}
    <div className="qs-quota-group" id="qs-section-top">
      {([ ["5 小时额度", quota.quota.fiveHour, "#b6ef75"], ["7 天额度", quota.quota.sevenDay, "#b4acff"] ] as const)
        .filter(([label, limit]) => label !== "5 小时额度" || hasFiveHourQuota(limit.availability, limit.remainingPercent))
        .map(([label, limit, color]) => {
          const percent = quotaPercent(limit.availability, limit.remainingPercent);
          const expected = sidebarExpectedFraction(percent, label === "5 小时额度" ? snapshot.fiveHourExpectedRemainingPercent : snapshot.sevenDayExpectedRemainingPercent, snapshot.quotaDataStale);
          return <section className="qs-limit" key={label} id={`qs-section-${label === "5 小时额度" ? "five" : "seven"}`}>
            <div><span><i style={{ background: color }} />{label}</span><strong>{quotaText(percent)}<small> 剩余</small></strong></div>
            <div className="qs-detail-quota-meter">
              <progress max={100} value={percent ?? 0} style={{ "--qs-accent": color } as CSSProperties} />
              {expected !== null && <i className="qs-detail-pace-mark" style={{ left: `${expected * 100}%` }} aria-label={`均匀使用参考：预期剩余 ${Math.round(expected * 100)}%`} />}
            </div>
            <p><span>{percent === null ? "暂不可用" : "重置时间"}</span><time title={limit.resetsAt}>{sidebarLocalTime(limit.resetsAt, limit.resetsAtUnix)}</time></p>
            {label === "7 天额度" && <p className="qs-pace-line"><span className="qs-pace-message" title={snapshot.trendLabel}>{snapshot.trendLabel}</span>{sevenDayReference !== null && <span className="qs-pace-reference">均匀使用参考 · 余量应为 {quotaText(sevenDayReference)}</span>}</p>}
          </section>;
        })}
    </div>
    <section className="qs-usage" id="qs-section-usage"><div className="qs-section-heading"><h3>Token 用量</h3><span>今日 / 累计</span></div>
      <div className="qs-metrics">
        <Metric label="今日 Tokens" value={snapshot.todayTokensLabel} />
        <Metric label="累计 Tokens" value={snapshot.totalTokensLabel} />
        <Metric label="今日请求" value={snapshot.requestsLabel} />
        <Metric label="实时速率 · 估算" value={snapshot.liveRateStatusLabel || (snapshot.liveRateAvailable ? `${snapshot.tokensPerSecond.toFixed(1)} t/s` : "不可用")} />
      <Metric label="今日缓存命中 · 按输入" value={breakdownKnown && tokenParts.input > 0 ? `${(tokenParts.cached / tokenParts.input * 100).toFixed(1)}%` : "—"} />
      <Metric label={models.some(model => !model.usesIndependentQuota && model.costUSD === null) ? "今日 API 等值 · 已知小计" : "今日 API 等值"} value={models.length ? `$${models.reduce((sum, model) => sum + (model.costUSD ?? 0), 0).toFixed(2)}` : "—"} />
      </div>
    </section>
    <section className="qs-model-usage" id="qs-section-models"><div className="qs-section-heading"><h3>今日模型用量</h3><span>今日占比 · 全部模型为分母</span></div>
      {models.length === 0 ? <p className="qs-empty">暂无可信的今日模型用量</p> : models.map(model => <div className="qs-model-row" key={model.key}>
        <div><strong title={model.key}>{model.label}</strong><span>{formatTokens(model.tokens)} <small>{(model.share * 100).toFixed(1)}%</small></span></div>
        <div className="qs-model-cost">API 等值 {floatingModelUsageValue(model, "cost")}</div>
        <progress max={100} value={model.share * 100} style={{ "--qs-accent": model.color } as CSSProperties} />
      </div>)}
    </section>
    <SidebarTrend points={data.trend ?? []} />
    <section className="qs-token-composition">
      <div className="qs-section-heading"><h3>今日 Token 构成</h3><span>缓存包含在输入内</span></div>
      <div className="qs-composition-chart" role="img" aria-label="今日输入、缓存和输出占比">{breakdownKnown && inputParts.map(part => <i key={part.label} style={{ flexGrow: part.value, background: part.color }} />)}</div>
      <div className="qs-token-legend">{inputParts.map(part => <div key={part.label}><span><i style={{background:part.color}} />{part.label}</span><strong>{breakdownKnown ? formatTokens(part.value) : "—"}</strong></div>)}</div>

    </section>
    <button className="qs-activity" onClick={onOpenRunning} type="button" aria-label="查看运行主会话和子代理">
      <div><strong>运行 {runningThreads.total ?? "未知"}</strong><span>主会话 {runningThreads.mainThreads ?? "—"} · 子代理 {runningThreads.subagents ?? "—"}</span></div>
      <div><span className="qs-unread">{unreadLabel}</span><span>{runningThreads.status === "ready" ? "查看会话 →" : runningThreads.status === "stale" ? "运行快照已过期 →" : "运行状态未知 →"}</span></div>
    </button>
    {unread.detail && !unread.source.includes("pending") && <details className="qs-diagnostic"><summary>未读状态说明</summary><p>{unread.detail}</p></details>}
  </>;
}
function Metric({ label, value }: { label: string; value: string }) {
  return <div><strong title={value}>{sidebarMetricValue(value)}</strong><span>{label}</span></div>;
}

export function RunningDetails({ data }: { data: SidebarData }) {
  const running = data.runningThreads;
  return <>
    <div className="qs-task-totals"><span>主任务 <strong>{running.mainThreads ?? "未知"}</strong></span><span>子代理 <strong>{running.subagents ?? "未知"}</strong></span></div>
    {running.status !== "ready" && <p className="qs-warning">{running.status === "stale" ? "运行快照已过期" : "运行状态尚不可用"}</p>}
    {running.groups.map(group => <section className="qs-task-group" key={group.mainThread.threadId}>
      <div className="qs-main-task">
        <div className="qs-task-heading"><span className="qs-role-label">主任务</span><span>{group.subagents.length} 个子代理</span></div>
        <TaskMember member={group.mainThread} fallbackTitle="未命名主任务" />
      </div>
      {group.subagents.length > 0 && <div className="qs-child-tasks">
        {group.subagents.map(member => <section className="qs-child-task" key={member.threadId}>
          <span className="qs-role-label qs-child-label">子代理</span>
          <TaskMember member={member} fallbackTitle="未命名子代理" />
        </section>)}
      </div>}
    </section>)}
    {running.unassignedSubagents.length > 0 && <section className="qs-unassigned-tasks">
      <div className="qs-task-heading"><strong>未关联主任务</strong><span>{running.unassignedSubagents.length} 个子代理</span></div>
      <p className="qs-muted">未获得可靠的主任务关联。</p>
      {running.unassignedSubagents.map(member => <section className="qs-child-task" key={member.threadId}>
        <span className="qs-role-label qs-child-label">子代理</span>
        <TaskMember member={member} fallbackTitle="未命名子代理" />
      </section>)}
    </section>}
    {running.status === "ready" && running.total === 0 && <p className="qs-empty">当前没有运行中的会话</p>}
    {running.detail && <details className="qs-diagnostic"><summary>运行状态说明</summary><p>{running.detail}</p></details>}
  </>;
}
function TaskMember({ member, fallbackTitle }: { member: RunningThreadMember; fallbackTitle: string }) {
  return <>
    <h4 className="qs-task-title" title={member.title || fallbackTitle}>{member.title || fallbackTitle}</h4>
    <div className="qs-task-metadata">
      <div><span>模型</span><strong>{member.model || "模型未知"}</strong></div>
      <div><span>推理强度</span><strong>{member.reasoningEffort || "未知"}</strong></div>
    </div>
  </>;
}

export function RadarDetails({ radar, initialRanking = "official" }: { radar: SidebarRadar; initialRanking?: "official" | "crowd" }) {
  const { official, crowd } = radar;
  const [ranking, setRanking] = useState<"official" | "crowd">(initialRanking);
  return <>
    <section className="qs-radar-window">
      <div className="qs-section-heading"><h3>速登状态</h3><span>{!official.available ? "未知" : !official.fresh ? "已过期或待确认" : "已读取"}</span></div>
      <div className="qs-radar-window-title"><span className="qs-radar-status-dot" />{sidebarRadarCompact(radar)}</div>
      {official.available && <p>{official.windowSummary}</p>}
      <div className="qs-radar-action"><span>建议动作</span><strong>{official.action}</strong></div>
      <small title={official.source}>来源：Codex Radar · 更新 {sidebarLocalTime(official.updatedAt, null, true)}</small>
    </section>
    <section className="qs-radar-iq"><div className="qs-section-heading"><h3>测评 IQ 摘要</h3><span>{official.stale ? "上次数据" : "Codex Radar 测评"}</span></div>
      {official.primary ? <><div><strong>{official.primary.iq.toFixed(1)}</strong><span>IQ</span><small>{official.primary.passed}/{official.primary.tasks} 通过</small></div><p>{official.primary.model}</p><small>推理强度 {official.primary.effort}</small></> : <p className="qs-muted">暂无可信 IQ 测评</p>}
    </section>
    <div id="qs-section-ranking" className="qs-ranking-tabs" role="tablist" aria-label="模型排名来源"><button role="tab" aria-selected={ranking === "official"} onClick={() => setRanking("official")}>雷达站</button><button role="tab" aria-selected={ranking === "crowd"} onClick={() => setRanking("crowd")}>众测雷达</button></div>
    {ranking === "official" ? <section className="qs-radar-ranking"><div className="qs-section-heading"><h3>雷达站模型排行</h3><span>按测评 IQ 排序</span></div>
      {!(official.rows?.length) ? <p className="qs-muted">暂无测评排名</p> : <ol>{official.rows.map(row => <li key={`${row.model}:${row.effort}`}><span className="qs-rank-number">{row.rank}</span><div><strong>{row.model}</strong><span>推理 {row.effort} · {row.passed}/{row.samples} 通过</span></div><b>{row.iq.toFixed(1)}<small>IQ</small></b></li>)}</ol>}
    </section> : <section className="qs-radar-ranking"><div className="qs-section-heading"><h3>众测实时排行</h3><span>{!crowd.available ? "未知" : "每 5 分钟刷新"}</span></div>
      <p className="qs-radar-basis">本机读取 {sidebarLocalTime(crowd.checkedAt, null, true)} · 每 5 分钟刷新<br />每格最新一次 · 至少 {crowd.minimumSamples} 个样本 · 沿用雷达排序</p>
      {crowd.rows.length === 0 ? <p className="qs-empty">暂无达到样本门槛的实时排行</p> : <ol>{crowd.rows.map(row => <li key={`${row.model}:${row.effort}`}>
        <span className="qs-rank-number">{row.rank}</span><div><strong>{row.model}</strong><span>推理 {row.effort || "未知"} · {row.passed}/{row.samples}</span></div><b>{row.iq.toFixed(1)}<small>IQ</small></b>
      </li>)}</ol>}
      <p className="qs-radar-source" title={crowd.source}>来源：Codex Radar 众测 · 数据时间 {sidebarLocalTime(crowd.updatedAt, null, true)}</p>
    </section>}
  </>;
}

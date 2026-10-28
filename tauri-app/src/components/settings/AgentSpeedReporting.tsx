import { useEffect, useRef, useState } from "react";
import { callCommandStrict } from "../../api/command";
import { isTauriRuntimeAvailable } from "../../platform/runtime";
import { publishAgentSpeedStatus, useAgentSpeedStatus } from "./agentSpeedStatusStore";

export interface AgentSpeedReportingStatus {
  enabled: boolean;
  transport: "http" | "websocket";
  invitationHandled: boolean;
  username: string;
  phase: string;
  message: string;
  liveOutputTps: number;
  estimatedShare: number;
  lastReportAt: string | null;
  profileUrl: string | null;
  sources: { id: string; name: string; tps: number }[];
}
const website = "https://deng.codexradar.com/";
const privacy = `${website}agent-speed/privacy/`;
const terms = `${website}agent-speed/terms/`;
const disclosure = "仅上报速度、Token、估算费用、模型、Harness 和运行统计，以及昵称、设备标识和客户端版本信息；不上传对话、文件路径或账号凭据。Claude Code／Desktop 始终只在本地读取，不参与上报。关闭后停止榜单上报；本地速度显示由速度算法设置独立控制。";
const duplicateNotice = "同一台电脑的同一数据源，请只在 Agent Speed 或 Token Bar 中开启一处上报，避免重复累计。";
export const supportedHarnesses = "Codex、Claude Code、Claude Desktop（本地 Code／Agent 会话）、DSH、OpenCode、Gemini CLI、omp、Antigravity、WorkBuddy、WorkBuddy AI、ZCode、Kimi Code、Grok Build";
function read() { return callCommandStrict<AgentSpeedReportingStatus>("read_agent_speed_reporting_status"); }
export function safeSpeedProfile(url: string | null): string | null {
  try {
    const parsed = new URL(url ?? "");
    return parsed.protocol === "https:" && parsed.hostname === "deng.codexradar.com" && !parsed.username && !parsed.password
      ? parsed.href : null;
  } catch { return null; }
}

export function AgentSpeedReportingSettings() {
  const status = useAgentSpeedStatus();
  const [nickname, setNickname] = useState("");
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [nameStep, setNameStep] = useState(false);
  const [error, setError] = useState("");
  const runtime = isTauriRuntimeAvailable();
  const nicknameSeeded = useRef(false);
  useEffect(() => {
    if (!nicknameSeeded.current && status.username) { setNickname(status.username); nicknameSeeded.current=true; }
  }, [status.username]);
  async function change(enabled: boolean) {
    setBusy(true); setError("");
    try {
      const next = await callCommandStrict<AgentSpeedReportingStatus>("set_agent_speed_reporting_enabled", {
        enabled, ...(enabled ? { username: nickname.trim() } : {}),
      });
      publishAgentSpeedStatus(next); setNickname(next.username); setConfirming(false);
    } catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  }
  const profile = safeSpeedProfile(status.profileUrl);
  return <section className="speed-report-settings" aria-label="速蹬排行榜设置">
    <div className="speed-report-heading">
      <h3>速蹬排行榜</h3>
      <label className="speed-report-toggle">
        <input type="checkbox" checked={status.enabled} disabled={busy || !runtime}
          onChange={(event) => { if (event.target.checked) { setNameStep(false); setConfirming(true); } else void change(false); }} />
        参加排行榜
      </label>
    </div>
    <p>按 Agent Speed 标准统计各软件的请求速度，与你的正文 TPS 独立。</p>
    <label className="speed-report-name">上报方式
      <select value={status.transport ?? "http"} disabled={busy || !runtime} onChange={async event => {
        const transport = event.target.value; setBusy(true); setError("");
        try { publishAgentSpeedStatus(await callCommandStrict<AgentSpeedReportingStatus>("set_agent_speed_reporting_transport", { transport })); }
        catch (e) { setError(String(e)); } finally { setBusy(false); }
      }}><option value="http">HTTP（默认）</option><option value="websocket">WebSocket 即时</option></select>
    </label>
    <p className="speed-report-note">WebSocket 网络连接失败时自动回退 HTTP；手动重试可再尝试 WebSocket。日志写入仍可能延迟。</p>
    <label className="speed-report-name">公开昵称
      <input value={nickname} maxLength={32} disabled={status.enabled || busy || !runtime}
        onChange={(event) => setNickname(event.target.value)} placeholder="排行榜昵称" />
    </label>
    <p className="speed-report-note">{disclosure}</p>
    <p className="speed-report-note">{duplicateNotice}</p>
    {confirming && <div className="speed-report-consent" role="group" aria-label="确认参加排行榜">
      <strong>{nameStep ? "设置您的排行榜昵称" : "参加速蹬排行榜？"}</strong>
      {nameStep ? <label className="speed-report-name">公开昵称<input autoFocus value={nickname} maxLength={32}
        placeholder="请输入您的昵称" onChange={event => setNickname(event.target.value)} /></label>
        : <p>请确认以上数据范围和重复上报说明；下一步填写公开昵称，完成后才开始榜单上报。</p>}
      <div className="speed-report-actions">
        <button type="button" disabled={busy} onClick={() => nameStep ? setNameStep(false) : setConfirming(false)}>{nameStep ? "上一步" : "暂不参加"}</button>
        <button type="button" className="speed-report-primary" disabled={busy || (nameStep && Array.from(nickname.trim()).length < 2)}
          onClick={() => nameStep ? void change(true) : setNameStep(true)}>{nameStep ? "开启并参加" : "同意参加，下一步"}</button>
      </div>
    </div>}
    <div className="speed-report-status" role="status">
      <span className={status.phase === "error" ? "speed-report-dot is-error" : status.enabled ? "speed-report-dot is-on" : "speed-report-dot"} />
      <span>{status.message}</span>
      {status.enabled && status.phase === "error" && <button type="button" disabled={busy}
        onClick={() => void change(true)}>重试连接</button>}
    </div>
    {error && <p role="alert" className="speed-report-error">{error}</p>}
    {status.enabled && ["running", "reporting", "connected"].includes(status.phase) && <>
      <div className="speed-report-reading"><strong>{status.liveOutputTps.toFixed(1)}</strong> Token/s
        <span>估算占比 {Math.round(status.estimatedShare * 100)}%</span>
      </div>
      <div className="speed-report-sources">{status.sources.map(source => <div key={source.id}>
        <span>{source.name}</span><span>{source.tps.toFixed(1)} Token/s</span>
      </div>)}</div>
      {status.lastReportAt && <p className="speed-report-note">最近上报 {new Date(status.lastReportAt).toLocaleTimeString()}</p>}
    </>}
    <details><summary>支持的软件</summary><p>{supportedHarnesses}。自动发现本地默认目录及环境变量指定的目录；云端未落地的会话无法统计。</p></details>
    <div className="speed-report-links">
      <a href={website} target="_blank" rel="noreferrer">查看排行榜 ↗</a>
      <a href={privacy} target="_blank" rel="noreferrer">隐私说明</a>
      <a href={terms} target="_blank" rel="noreferrer">服务条款</a>
      {profile && <a href={profile} target="_blank" rel="noreferrer">我的资料与设备 ↗</a>}
    </div>
  </section>;
}

export function AgentSpeedReportingNotice({status,busy=false,onRetry,onOpenSettings}:{
  status:AgentSpeedReportingStatus;busy?:boolean;onRetry:()=>void;onOpenSettings:()=>void;
}) {
  if(!status.enabled) return null;
  const failed=status.phase === "error";
  return <div className={`speed-report-dashboard-status${failed?" is-error":""}`} role={failed?"alert":"status"}>
    <span className={failed?"speed-report-dot is-error":"speed-report-dot is-on"}/>
    <strong>速蹬上报</strong><span>{status.message}</span>
    {status.phase === "running" && status.lastReportAt && <span className="speed-report-last">最近上报 {new Date(status.lastReportAt).toLocaleTimeString()}</span>}
    <span className="speed-report-dashboard-actions">{failed && <button type="button" disabled={busy} onClick={onRetry}>重试连接</button>}
      <button type="button" onClick={onOpenSettings}>设置</button></span>
  </div>;
}

export function AgentSpeedReportingDashboardStatus({onOpenSettings}:{onOpenSettings:()=>void}) {
  const status=useAgentSpeedStatus();
  const [busy,setBusy]=useState(false);
  async function retry() {
    setBusy(true);
    try { publishAgentSpeedStatus(await callCommandStrict<AgentSpeedReportingStatus>("set_agent_speed_reporting_enabled",{enabled:true,username:status.username})); }
    catch { publishAgentSpeedStatus({...status,phase:"error",message:"无法重试连接，请在设置中查看"}); }
    finally {setBusy(false);}
  }
  return <AgentSpeedReportingNotice status={status} busy={busy} onRetry={()=>void retry()} onOpenSettings={onOpenSettings}/>;
}

/** A local recording: displaying the invitation does not contact the leaderboard. */
export function SpeedLeaderboardMovie() {
  const video = useRef<HTMLVideoElement>(null);
  const intent = useRef<"automatic" | "play" | "pause">("automatic");
  const [playing, setPlaying] = useState(false);
  useEffect(() => {
    const element = video.current;
    if (!element) return;
    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)");
    const reconcile = () => {
      if (!document.hidden && intent.current !== "pause" && (intent.current === "play" || !reduced?.matches)) {
        void element.play().catch(() => {});
      } else element.pause();
    };
    reconcile();
    document.addEventListener("visibilitychange", reconcile);
    reduced?.addEventListener("change", reconcile);
    return () => {
      element.pause();
      document.removeEventListener("visibilitychange", reconcile);
      reduced?.removeEventListener("change", reconcile);
    };
  }, []);
  return <div className="speed-report-movie">
    <video ref={video} src="/speed-leaderboard/leaderboard.mp4" poster="/speed-leaderboard/poster.jpg"
      muted loop playsInline preload="metadata" aria-label="速蹬排行榜真实录屏"
      onPlay={() => setPlaying(true)} onPause={() => setPlaying(false)} onEnded={() => setPlaying(false)} />
    <div className="speed-report-movie-caption"><span>排行榜实录 · 非当前实时数据</span>
      <button type="button" aria-label={playing ? "暂停排行榜演示" : "播放排行榜演示"} onClick={() => {
        const element = video.current;
        if (!element) return;
        intent.current = playing ? "pause" : "play";
        if (playing) element.pause();
        else if (!document.hidden) { if (element.ended) element.currentTime = 0; void element.play().catch(() => {}); }
      }}>{playing ? "Ⅱ" : "▷"}</button>
    </div>
  </div>;
}

export function AgentSpeedInvitationCard({ username, busy = false, error = "", onJoin, onDismiss, onOpenSettings }: {
  username: string; busy?: boolean; error?: string; onJoin: (nickname: string) => void; onDismiss: () => void; onOpenSettings: () => void;
}) {
  const [joining, setJoining] = useState(false);
  const [step, setStep] = useState<1 | 2>(1);
  const [nickname, setNickname] = useState(username.startsWith("TokenBar-") ? "" : username);
  const validName = Array.from(nickname.trim()).length >= 2 && Array.from(nickname.trim()).length <= 32;
  return <aside className="speed-report-invitation" role="dialog" aria-label="速蹬排行榜邀请">
    <div className="speed-report-heading"><strong>Codex 雷达站 · 邀请你一起上榜</strong>
      <button type="button" aria-label="暂不参加速蹬排行榜" onClick={onDismiss}>×</button>
    </div>
    {step === 1 ? <>
      <SpeedLeaderboardMovie />
      <h3>加入速蹬 Token 排行榜</h3>
      <p>加入 Token 排行榜，看看各软件、各模型的速度。</p>
      <label className="speed-report-invitation-switch" data-joining={joining}><span>① 参加速蹬排行榜</span>
        <input type="checkbox" role="switch" aria-describedby="speed-report-join-hint" checked={joining} disabled={busy}
          onChange={event => setJoining(event.target.checked)} />
      </label>
      <p className="speed-report-join-hint" id="speed-report-join-hint">{joining ? "已选择参加 → 下一步填写您的昵称" : "↑ 先打开上方开关，再点右下角“下一步”"}</p>
      <p className="speed-report-note">仅上报 Token、速度、估算费用、模型和软件统计，以及公开昵称、设备标识和客户端版本信息；不上传对话内容、文件路径或账号凭据。可随时在设置中关闭。</p>
      <p className="speed-report-note speed-report-public-name">下一步设置公开昵称。{duplicateNotice}</p>
    </> : <div className="speed-report-nickname-step">
      <span className="speed-report-step">② 设置排行榜昵称</span>
      <h3>怎么称呼您？</h3>
      <p>这个昵称会公开显示在排行榜上。</p>
      <label className="speed-report-name">公开昵称<input autoFocus value={nickname} maxLength={32} disabled={busy}
        placeholder="请输入您的昵称" onChange={event => setNickname(event.target.value)} /></label>
      <p className="speed-report-note">2–32 个字符。上报方式默认 HTTP，可在设置中选择 WebSocket。</p>
    </div>}
    {error && <p role="alert" className="speed-report-error">{error}</p>}
    <div className="speed-report-actions">
      {step === 1 ? <><button type="button" className="speed-report-text-button" onClick={onOpenSettings}>设置与说明</button>
        <button type="button" onClick={onDismiss}>暂不参加</button>
        <button type="button" className="speed-report-primary" disabled={!joining || busy} onClick={() => setStep(2)}>同意参加，下一步</button></>
        : <><button type="button" disabled={busy} onClick={() => setStep(1)}>上一步</button>
          <button type="button" className="speed-report-primary" disabled={!validName || busy} onClick={() => onJoin(nickname.trim())}>
            {busy ? "正在开启…" : "开启并参加"}
          </button></>}
    </div>
  </aside>;
}

export function AgentSpeedReportingInvitation({ onOpenSettings }: { onOpenSettings: () => void }) {
  const [visible, setVisible] = useState(false);
  const [username, setUsername] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    if (!isTauriRuntimeAvailable()) return;
    let disposed = false;
    let pending = false;
    const offerWhenVisible = () => {
      if (document.hidden || pending || disposed) return;
      pending = true;
      void read().then(async status => {
        if (disposed || document.hidden || status.enabled || status.invitationHandled) return;
        await callCommandStrict("dismiss_agent_speed_invitation");
        if (!disposed) { setUsername(status.username); setVisible(true); }
      }).catch(() => {}).finally(() => { pending = false; });
    };
    offerWhenVisible();
    document.addEventListener("visibilitychange", offerWhenVisible);
    return () => { disposed = true; document.removeEventListener("visibilitychange", offerWhenVisible); };
  }, []);
  async function join(nickname: string) {
    setBusy(true); setError("");
    try {
      const next=await callCommandStrict<AgentSpeedReportingStatus>("set_agent_speed_reporting_enabled", { enabled: true, username: nickname });
      publishAgentSpeedStatus(next);
      setVisible(false);
    } catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  }
  if (!visible) return null;
  return <AgentSpeedInvitationCard username={username} busy={busy} error={error} onJoin={nickname => void join(nickname)}
    onDismiss={() => setVisible(false)} onOpenSettings={() => { setVisible(false); onOpenSettings(); }} />;
}

import { useEffect, useRef, useState } from "react";
import { callCommandStrict } from "../../api/command";
import { isTauriRuntimeAvailable } from "../../platform/runtime";

export interface AgentSpeedReportingStatus {
  enabled: boolean;
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
const disclosure = "仅上报速度、Token、模型、Harness 和运行统计，以及昵称、设备标识和客户端版本信息；不上传对话、文件路径或账号凭据。关闭后停止这条链路的采集和上报。";
const duplicateNotice = "同一台电脑的同一数据源，请只在 Agent Speed 或 Token Bar 中开启一处上报，避免重复累计。";
export const supportedHarnesses = "Codex、Claude Code、Claude Desktop（本地 Code／Agent 会话）、DSH、OpenCode、Gemini CLI、omp、Antigravity、WorkBuddy、WorkBuddy AI、ZCode、Kimi Code、Grok Build";
const initial: AgentSpeedReportingStatus = {
  enabled: false, invitationHandled: true, username: "", phase: "off",
  message: "未参加 · 采集与上报已关闭", liveOutputTps: 0, estimatedShare: 0,
  lastReportAt: null, profileUrl: null, sources: [],
};
function read() { return callCommandStrict<AgentSpeedReportingStatus>("read_agent_speed_reporting_status"); }
export function safeSpeedProfile(url: string | null): string | null {
  try {
    const parsed = new URL(url ?? "");
    return parsed.protocol === "https:" && parsed.hostname === "deng.codexradar.com" && !parsed.username && !parsed.password
      ? parsed.href : null;
  } catch { return null; }
}

export function AgentSpeedReportingSettings() {
  const [status, setStatus] = useState(initial);
  const [nickname, setNickname] = useState("");
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState("");
  const runtime = isTauriRuntimeAvailable();
  useEffect(() => {
    if (!runtime) return;
    let disposed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let seeded = false;
    const poll = async () => {
      try {
        const next = await read();
        if (disposed) return;
        setStatus(next);
        if (!seeded) { setNickname(next.username); seeded = true; }
      } catch (e) { if (!disposed) setError(String(e)); }
      if (!disposed) timer = setTimeout(() => {
        if (document.hidden) timer = setTimeout(poll, 5000);
        else void poll();
      }, 2000);
    };
    void poll();
    return () => { disposed = true; clearTimeout(timer); };
  }, [runtime]);
  async function change(enabled: boolean) {
    setBusy(true); setError("");
    try {
      const next = await callCommandStrict<AgentSpeedReportingStatus>("set_agent_speed_reporting_enabled", {
        enabled, ...(enabled ? { username: nickname.trim() } : {}),
      });
      setStatus(next); setNickname(next.username); setConfirming(false);
    } catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  }
  const profile = safeSpeedProfile(status.profileUrl);
  return <section className="speed-report-settings" aria-label="速蹬排行榜设置">
    <div className="speed-report-heading">
      <h3>速蹬排行榜</h3>
      <label className="speed-report-toggle">
        <input type="checkbox" checked={status.enabled} disabled={busy || !runtime}
          onChange={(event) => { if (event.target.checked) setConfirming(true); else void change(false); }} />
        参加排行榜
      </label>
    </div>
    <p>按 Agent Speed 标准统计各软件的请求速度，与你的正文 TPS 独立。</p>
    <label className="speed-report-name">公开昵称
      <input value={nickname} maxLength={32} disabled={status.enabled || busy || !runtime}
        onChange={(event) => setNickname(event.target.value)} placeholder="排行榜昵称" />
    </label>
    <p className="speed-report-note">{disclosure}</p>
    <p className="speed-report-note">{duplicateNotice}</p>
    {confirming && <div className="speed-report-consent" role="group" aria-label="确认参加排行榜">
      <strong>参加速蹬排行榜？</strong>
      <p>开启后将以“{nickname}”公开参与排行榜。请确认以上数据范围和重复上报说明；你可以随时关闭。</p>
      <div className="speed-report-actions">
        <button type="button" disabled={busy} onClick={() => setConfirming(false)}>暂不参加</button>
        <button type="button" className="speed-report-primary" disabled={busy || !nickname.trim()}
          onClick={() => void change(true)}>同意并开启</button>
      </div>
    </div>}
    <div className="speed-report-status" role="status">
      <span className={status.enabled ? "speed-report-dot is-on" : "speed-report-dot"} />
      <span>{status.message}</span>
      {status.enabled && status.phase === "error" && <button type="button" disabled={busy}
        onClick={() => void change(true)}>重试连接</button>}
    </div>
    {error && <p role="alert" className="speed-report-error">{error}</p>}
    {status.enabled && status.phase === "running" && <>
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

/** A local recording: displaying the invitation does not contact the leaderboard. */
export function SpeedLeaderboardMovie() {
  const video = useRef<HTMLVideoElement>(null);
  const [playing, setPlaying] = useState(false);
  useEffect(() => {
    const element = video.current;
    if (!element) return;
    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    if (!reduced && !document.hidden) void element.play().catch(() => {});
    const pauseHidden = () => { if (document.hidden) element.pause(); };
    document.addEventListener("visibilitychange", pauseHidden);
    return () => { element.pause(); document.removeEventListener("visibilitychange", pauseHidden); };
  }, []);
  return <div className="speed-report-movie">
    <video ref={video} src="/speed-leaderboard/leaderboard.mp4" poster="/speed-leaderboard/poster.jpg"
      muted playsInline preload="metadata" aria-label="速蹬排行榜真实录屏"
      onPlay={() => setPlaying(true)} onPause={() => setPlaying(false)} onEnded={() => setPlaying(false)} />
    <div className="speed-report-movie-caption"><span>排行榜实录 · 非当前实时数据</span>
      <button type="button" aria-label={playing ? "暂停排行榜演示" : "播放排行榜演示"} onClick={() => {
        const element = video.current;
        if (!element) return;
        if (playing) element.pause();
        else { if (element.ended) element.currentTime = 0; void element.play().catch(() => {}); }
      }}>{playing ? "Ⅱ" : "▷"}</button>
    </div>
  </div>;
}

export function AgentSpeedInvitationCard({ username, busy = false, error = "", onJoin, onDismiss, onOpenSettings }: {
  username: string; busy?: boolean; error?: string; onJoin: () => void; onDismiss: () => void; onOpenSettings: () => void;
}) {
  const [joining, setJoining] = useState(false);
  return <aside className="speed-report-invitation" role="dialog" aria-label="速蹬排行榜邀请">
    <div className="speed-report-heading"><strong>Codex 雷达站 · 邀请你一起上榜</strong>
      <button type="button" aria-label="暂不参加速蹬排行榜" onClick={onDismiss}>×</button>
    </div>
    <SpeedLeaderboardMovie />
    <h3>加入速蹬 Token 排行榜</h3>
    <p>加入 Token 排行榜，看看各软件、各模型的速度。</p>
    <label className="speed-report-invitation-switch" data-joining={joining}><span>① 参加速蹬排行榜</span>
      <input type="checkbox" role="switch" aria-describedby="speed-report-join-hint" checked={joining} disabled={busy}
        onChange={event => setJoining(event.target.checked)} />
    </label>
    <p className="speed-report-join-hint" id="speed-report-join-hint">{joining ? "已选择参加 → 点击右下角“开启并参加”完成" : "↑ 先打开上方开关，再点右下角“开启并参加”"}</p>
    <p className="speed-report-note">仅上报 Token、速度、模型和软件统计，以及公开昵称、设备标识和客户端版本信息；不上传对话内容、文件路径或账号凭据。可随时在设置中关闭。</p>
    <p className="speed-report-note speed-report-public-name">公开昵称：<span title={username}>{username}</span>。同一数据源请勿与 Agent Speed 重复上报。</p>
    {error && <p role="alert" className="speed-report-error">{error}</p>}
    <div className="speed-report-actions">
      <button type="button" className="speed-report-text-button" onClick={onOpenSettings}>设置与说明</button>
      <button type="button" onClick={onDismiss}>暂不参加</button>
      <button type="button" className="speed-report-primary" title={!joining ? "先打开上方“参加速蹬排行榜”开关" : "确认参加并开始上报"} disabled={!joining || busy} onClick={onJoin}>
        {busy ? "正在开启…" : "开启并参加"}
      </button>
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
  async function join() {
    setBusy(true); setError("");
    try {
      await callCommandStrict("set_agent_speed_reporting_enabled", { enabled: true, username });
      setVisible(false);
    } catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  }
  if (!visible) return null;
  return <AgentSpeedInvitationCard username={username} busy={busy} error={error} onJoin={() => void join()}
    onDismiss={() => setVisible(false)} onOpenSettings={() => { setVisible(false); onOpenSettings(); }} />;
}

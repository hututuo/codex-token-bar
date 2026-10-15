import { useEffect, useState } from "react";
import { cancelPlan, startPlan } from "./client";
import { activePlan, DEFAULT_MODEL, modelLabel, percent, statusLabel, topCandidates } from "./model";
import type { TraceRun, TraceSnapshot } from "./types";
import { useModelTrace } from "./useModelTrace";

const ROUNDS_STORAGE_KEY = "modeltrace-rounds";

function readStoredRounds(): number {
  try {
    const rounds = Number(window.localStorage.getItem(ROUNDS_STORAGE_KEY));
    return Number.isInteger(rounds) && rounds >= 1 && rounds <= 5 ? rounds : 1;
  } catch {
    return 1;
  }
}

export function ModelTracePanel() {
  const {snapshot, error, refresh} = useModelTrace();
  return <ModelTracePanelView snapshot={snapshot} error={error} onStart={async (model, rounds) => {await startPlan(model, rounds); await refresh();}}
    onCancel={async planId => {await cancelPlan(planId); await refresh();}} />;
}

export function ModelTracePanelView({snapshot, error, onStart, onCancel}: {
  snapshot: TraceSnapshot | null; error: string | null;
  onStart: (model: string, rounds: number) => Promise<void>; onCancel: (planId: string) => Promise<void>;
}) {
  const [model, setModel] = useState(DEFAULT_MODEL);
  const [rounds, setRounds] = useState(readStoredRounds);
  const [pending, setPending] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const plan = snapshot?.plan;
  const active = activePlan(plan);
  const selectedRounds = active && plan ? plan.totalRounds : rounds;
  useEffect(() => { if (active && plan) setModel(plan.model); }, [active, plan?.model]);
  const selectRounds = (value: number) => {
    setRounds(value);
    try { window.localStorage.setItem(ROUNDS_STORAGE_KEY, String(value)); }
    catch { /* The current selection remains usable if local storage is unavailable. */ }
  };
  const action = async () => {
    if (pending) return;
    setPending(true); setActionError(null);
    try { if (active && plan) await onCancel(plan.id); else await onStart(model, rounds); }
    catch (reason) {setActionError(String(reason));}
    finally {setPending(false);}
  };
  return <section className="modeltrace-panel" aria-label="模型检测">
    <div className="modeltrace-heading"><span className="modeltrace-star" aria-hidden="true">✦</span><div><h3>模型检测</h3><p>ModelTrace</p></div></div>
    <div className="modeltrace-controls">
    <label className="modeltrace-model-label">测试模型<select aria-label="测试模型" value={model} disabled={active || pending || !snapshot}
      onChange={event => setModel(event.currentTarget.value)}>{(snapshot?.models ?? [DEFAULT_MODEL]).map(item => <option key={item} value={item}>{modelLabel(item)}</option>)}</select></label>
    <label className="modeltrace-model-label">检测轮数<select aria-label="检测轮数" value={selectedRounds} disabled={active || pending || !snapshot}
      onChange={event => selectRounds(Number(event.currentTarget.value))}>{[1, 2, 3, 4, 5].map(value => <option key={value} value={value}>{value} 轮</option>)}</select></label>
    </div>
    {selectedRounds > 1 && <p className="modeltrace-note">每轮间隔 1 小时</p>}
    <button className={`modeltrace-start${active ? " modeltrace-stop" : ""}`} type="button"
      disabled={pending || !snapshot || plan?.status === "cancelling"} onClick={() => void action()}>
      {pending ? "正在处理…" : plan?.status === "cancelling" ? "正在停止…" : active ? "停止本次计划" : "开始检测"}
    </button>
    {(error || actionError) && <p className="modeltrace-error" role="alert">{actionError || error}</p>}
    {plan && <div className="modeltrace-progress" role="status" aria-live="polite">
      <strong>{statusLabel(plan.status)}</strong>
      <span>测试：{modelLabel(plan.model)} · 已处理 {plan.completedRounds}/{plan.totalRounds} 轮</span>
      {plan.status === "running" && <span>第 {plan.completedRounds + 1} 轮 · 有效回答 {plan.validSamples}/3 · 尝试 {plan.currentAttempt}/6</span>}
      {plan.nextRunAt != null && <span>下次：{new Date(plan.nextRunAt * 1000).toLocaleString()}</span>}
      {plan.error && <span className="modeltrace-error">{plan.error}</span>}
    </div>}
    {snapshot?.latest ? <TraceResult run={snapshot.latest} /> : <p className="modeltrace-empty">暂无检测结果，开始后将在这里显示。</p>}
  </section>;
}

export function TraceResult({run}: {run: TraceRun}) {
  const [expanded, setExpanded] = useState(false);
  const candidates = topCandidates(run.attribution?.candidates ?? [], expanded ? 5 : 3);
  return <div className="modeltrace-result">
    <div className="modeltrace-result-heading"><strong>本轮结果</strong><span className="modeltrace-badge" data-status={run.status}>{statusLabel(run.status)}</span></div>
    <dl className="modeltrace-facts"><div><dt>标称模型</dt><dd>{modelLabel(run.model)}</dd></div>
      <div><dt>第一候选</dt><dd>{run.attribution ? modelLabel(run.attribution.prediction) : "暂无可判定结果"}</dd></div>
      <div><dt>检测时间</dt><dd><time dateTime={new Date(run.startedAt * 1000).toISOString()}>{new Date(run.startedAt * 1000).toLocaleString()}</time></dd></div>
      <div><dt>有效回答</dt><dd>{run.validSamples}/3 · 尝试 {run.attempts} 次</dd></div></dl>
    {candidates.length > 0 && <><table className="modeltrace-candidates"><caption>归因结果</caption>
      <thead><tr><th>候选模型</th><th>归因概率</th><th>分布相似度</th></tr></thead>
      <tbody>{candidates.map(item => <tr key={item.model}><th scope="row">{modelLabel(item.displayName)}</th>
        <td><strong>{percent(item.probability)}</strong><span className="modeltrace-probability-track" aria-hidden="true"><i style={{width: percent(item.probability).startsWith("<") ? "0.01%" : `${item.probability * 100}%`}} /></span></td>
        <td>{percent(item.profileSimilarity)}</td></tr>)}</tbody></table>
      <button type="button" className="modeltrace-expand" aria-expanded={expanded} onClick={() => setExpanded(value => !value)}>{expanded ? "收起为前三名" : "查看前五名"}</button></>}
    {run.message && <details className="modeltrace-diagnostic"><summary>采样说明</summary><p>{run.message}</p></details>}
  </div>;
}

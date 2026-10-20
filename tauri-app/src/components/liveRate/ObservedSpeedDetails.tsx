import { observedSpeedWindowInfo } from "./observedSpeedPresentation";
import { useObservedSpeedWindow } from "./observedSpeedWindow";
import { useState } from "react";
import type { LiveThreadOption, ModelSpeedSummary, SpeedSample } from "../../types/live";

export interface ObservedSpeedData {
  modelSpeeds?: ModelSpeedSummary[];
  modelSpeeds15m?: ModelSpeedSummary[];
  modelSpeeds30m?: ModelSpeedSummary[];
  speedSamples?: SpeedSample[];
  measurementStatus?: string;
}
const confidenceLabel = (value: string) => value === "high" ? "较高" : value === "medium" ? "中等" : "较低";

export function ObservedSpeedDetails({ data, threads = [] }: { data: ObservedSpeedData; threads?: LiveThreadOption[] }) {
  const [limit, setLimit] = useState(30);
  const [minutes, setMinutes] = useObservedSpeedWindow();
  const models = (minutes === 15 ? data.modelSpeeds15m : data.modelSpeeds30m) ?? [];
  const samples = data.speedSamples ?? [];
  const windowInfo = observedSpeedWindowInfo(samples, minutes);
  const statusText = data.measurementStatus === "observed_storage_error"
    ? "测速记录读写失败，原有文件已保留；请查看完整日志。"
    : data.measurementStatus === "observing_deltas"
      ? "正在接收流式输出，参考均速每秒更新，结束后校准。"
      : samples.length
        ? "接收计时 · token 本地估算 · 同模型短片段合并参考"
        : "等待 Codex Desktop 正文流或可关联的日志增量。";
  return <section className="observed-speed" aria-label="真实测速" id="qs-section-speeds">
    <div className="observed-speed-heading"><h3>真实测速</h3><span>最近 {minutes} 分钟 · 接收速度</span></div>
    <div className="observed-speed-window">{([15, 30] as const).map(value => <button key={value} type="button" aria-pressed={minutes === value} onClick={() => setMinutes(value)}>{value} 分钟</button>)}</div>
    <p className={data.measurementStatus === "observed_storage_error" ? "observed-speed-warning" : "observed-speed-note"}>{statusText}</p>
    {models.length ? <div className="observed-speed-models">{models.map(model => <div key={model.model}><strong>{model.model}</strong><b>{model.tokensPerSecond.toFixed(1)} <small>tok/s</small></b><span>{model.activeSampleCount ? "接收中 · " : "参考均速 · "}{model.sampleCount} 段 · {model.outputTokens.toLocaleString()} token（估） / {model.durationSeconds.toFixed(2)} 秒 · 单段达标 {model.qualifiedSampleCount ?? 0} 段 · 汇总质量{confidenceLabel(model.confidence ?? "low")}</span></div>)}</div> : <p className="observed-speed-empty">{windowInfo.emptyLabel}</p>}
    <p className="observed-speed-note">{windowInfo.explanation}</p>
    <p className="observed-speed-note">Desktop 接口测正文更新，原始流日志可用时也测模型生成的工具输入；工具执行结果、隐藏思考与结算均速不混入。参考均速 = 同模型采样 token 总量 ÷ 采样时长总和，每秒更新。接收中使用增量估算，结束后校准；有停顿或缺少开始标记的片段仅列明细。</p>
    <details><summary>采样明细（{samples.length} 段，按轮次追溯）</summary>
      <div className="observed-speed-samples">{samples.slice(0, limit).map(sample => <article key={sample.id}>
        <header><strong>{sample.model || "未知模型"}</strong><b>{sample.tokensPerSecond.toFixed(1)} tok/s</b><span data-confidence={sample.confidence}>置信度 {confidenceLabel(sample.confidence)}</span></header>
        {threads.find(thread => thread.id === sample.threadId)?.title && <p className="observed-speed-session">{threads.find(thread => thread.id === sample.threadId)?.title}</p>}
        <dl><dt>会话 ID</dt><dd>{sample.threadId}</dd><dt>轮次 ID</dt><dd>{sample.turnId}</dd><dt>输出项</dt><dd>{sample.itemId}</dd></dl>
        <p>{sample.outputTokens.toLocaleString()} token（估） · {sample.outputCharacters.toLocaleString()} 字符 / {sample.outputBytes.toLocaleString()} 字节 · {sample.chunkCount} 次更新 · {sample.durationSeconds.toFixed(2)} 秒</p>
        <time dateTime={new Date(sample.endedAt * 1000).toISOString()}>{new Date(sample.endedAt * 1000).toLocaleString()}</time>
        <p className={sample.networkWarning ? "observed-speed-warning" : "observed-speed-note"}>{typeof sample.networkWarning === "string" ? sample.networkWarning : sample.networkWarning ? "采样存在接收停顿、重试或覆盖不完整，可能受网络或服务端批量发送影响。" : "未发现明显接收停顿；仍无法排除网络缓冲和服务端批量发送。"}</p>
        <p className="observed-speed-note">{sample.source === "codex_desktop.forwarded_text_stream" ? "Codex Desktop 正文事件流 · 转发接收计时 / 本地分词估算" : sample.source}</p>
      </article>)}</div>
      {!samples.length && <p className="observed-speed-empty">不会把历史整段输出伪装成实时流式样本。</p>}
      {samples.length > limit && <button type="button" onClick={() => setLimit(limit + 30)}>再显示 30 段</button>}
    </details>
    <p className="observed-speed-note">计时从首次到末次更新，首次更新的 token 不计入分子。Desktop 事件经过本机转发和短时合并，不能视为服务器原始网络包。≥500 token、≥5秒、≥10次更新且无明显停顿评为较高；≥100 token、≥2秒、≥4次更新评为中等。评级表示样本质量，不是统计概率。</p>
  </section>;
}

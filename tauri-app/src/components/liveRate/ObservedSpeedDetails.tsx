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
    : data.measurementStatus === "completed_body_ready"
      ? "正文计时测速可用，每秒检查更新；实时流式采样作为补充保留。"
      : "等待带起止时间的正文完成记录；历史增量采样保留在明细。";
  return <section className="observed-speed" aria-label="真实测速" id="qs-section-speeds">
    <div className="observed-speed-heading"><h3>真实测速</h3><span>最近 {minutes} 分钟 · 正文计时速度</span></div>
    <div className="observed-speed-window">{([15, 30] as const).map(value => <button key={value} type="button" aria-pressed={minutes === value} onClick={() => setMinutes(value)}>{value} 分钟</button>)}</div>
    <p className={data.measurementStatus === "observed_storage_error" ? "observed-speed-warning" : "observed-speed-note"}>{statusText}</p>
    {models.length ? <div className="observed-speed-models">{models.map(model => <div key={model.model}><strong>{model.model}</strong><b>{model.tokensPerSecond.toFixed(1)} <small>tok/s</small></b><span>{model.activeSampleCount ? "接收中 · " : "参考均速 · "}{model.sampleCount} 段 · {model.outputTokens.toLocaleString()} token（估） / {model.durationSeconds.toFixed(2)} 秒 · 单段达标 {model.qualifiedSampleCount ?? 0} 段 · 汇总质量{confidenceLabel(model.confidence ?? "low")}</span></div>)}</div> : <p className="observed-speed-empty">{windowInfo.emptyLabel}</p>}
    <p className="observed-speed-note">{windowInfo.explanation}</p>
    <p className="observed-speed-note">参考均速 = 同模型完整正文的 o200k token 总量 ÷ 正文起止时长总和。包括中间说明与最终回复，每秒检查，正文完成后更新；不混入思考、工具执行结果和请求等待。历史流式采样保留在明细，不重复计入均速。</p>
    <details><summary>采样明细（{samples.length} 段，按轮次追溯）</summary>
      <div className="observed-speed-samples">{samples.slice(0, limit).map(sample => <article key={sample.id}>
        <header><strong>{sample.model || "未知模型"}</strong><b>{sample.tokensPerSecond.toFixed(1)} tok/s</b><span data-confidence={sample.confidence}>置信度 {confidenceLabel(sample.confidence)}</span></header>
        {threads.find(thread => thread.id === sample.threadId)?.title && <p className="observed-speed-session">{threads.find(thread => thread.id === sample.threadId)?.title}</p>}
        <dl><dt>会话 ID</dt><dd>{sample.threadId}</dd><dt>轮次 ID</dt><dd>{sample.turnId}</dd><dt>输出项</dt><dd>{sample.itemId}</dd></dl>
        <p>{sample.measurementKind === "completed_body" ? "正文计时 · 离线 o200k_base 分词" : "历史实时增量采样 · 原分词口径"}</p>
        <p>{sample.outputTokens.toLocaleString()} token（估） · {sample.outputCharacters.toLocaleString()} 字符 / {sample.outputBytes.toLocaleString()} 字节 · {sample.durationSeconds.toFixed(2)} 秒{sample.measurementKind !== "completed_body" && ` · ${sample.chunkCount} 次更新`}</p>
        <time dateTime={new Date(sample.endedAt * 1000).toISOString()}>{new Date(sample.endedAt * 1000).toLocaleString()}</time>
        <p className={sample.networkWarning ? "observed-speed-warning" : "observed-speed-note"}>{sample.measurementKind === "completed_body" ? "只有正文起止计时，无法判断中途的网络或服务端停顿；短文本误差较大。" : typeof sample.networkWarning === "string" ? sample.networkWarning : sample.networkWarning ? "采样存在接收停顿、重试或覆盖不完整，可能受网络或服务端批量发送影响。" : "未发现明显接收停顿；仍无法排除网络缓冲和服务端批量发送。"}</p>
        <p className="observed-speed-note">{sample.source === "codex_desktop.forwarded_text_stream" ? "Codex Desktop 正文事件流 · 转发接收计时 / 本地分词估算" : sample.source}</p>
      </article>)}</div>
      {!samples.length && <p className="observed-speed-empty">等待带开始和结束时间的正文记录。</p>}
      {samples.length > limit && <button type="button" onClick={() => setLimit(limit + 30)}>再显示 30 段</button>}
    </details>
    <p className="observed-speed-note">正文计时按同一会话、轮次、输出 ID 配对正文与 started_at_ms / completed_at_ms。≥500 token 且≥5秒评为较高，≥100 token 且≥2秒评为中等，其余较低；评级反映样本长度，不证明没有网络干扰。o200k 分词不等于服务端计费量。历史增量采样仍按首次至末次更新计时并扣除首段。</p>
  </section>;
}

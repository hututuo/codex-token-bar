import type { SpeedSample } from "../../types/live";
export function bodySpeedQuality(s: SpeedSample) {
    const low = (reason: string) => ({ confidence: "low", reason, included: false });
    const rate = s.outputTokens / s.durationSeconds;
    if (!(s.outputTokens > 0) || !(s.durationSeconds > 0) || !(s.endedAt > s.startedAt) || ![s.durationSeconds, s.tokensPerSecond, s.startedAt, s.endedAt].every(Number.isFinite))
        return low("计时无效");
    if (Math.abs(s.endedAt - s.startedAt - s.durationSeconds) > .01 || Math.abs(rate - s.tokensPerSecond) > Math.max(.01, rate * .001))
        return low("数量与计时不一致");
    const elapsedMs = Math.round(s.endedAt * 1000) - Math.round(s.startedAt * 1000);
    if (elapsedMs <= 400)
        return low("采样时长不超过 0.4 秒");
    if (rate > 500)
        return low("速率异常偏高");
    if (rate < 2)
        return low("速率异常偏低");
    if (s.networkWarning)
        return low("采样存在异常标记");
    return { confidence: s.durationSeconds >= 5 ? "high" : "medium", reason: null, included: true };
}
export const bodyTypeLabel = (s: SpeedSample) => s.bodyPhase === "commentary" ? "中间消息" : s.bodyPhase === "final_answer" ? "最终文本" : "正文";
export const isBodySample = (s: SpeedSample) => s.measurementKind === "completed_body" && s.tokenizer === "o200k_base";

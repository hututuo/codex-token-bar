import type { SpeedSample } from "../../types/live";

export function observedSpeedWindowInfo(samples: SpeedSample[], minutes: number, now = Date.now() / 1000) {
  const recent = samples.filter(sample => sample.endedAt >= now - minutes * 60 && sample.endedAt <= now);
  const unknown = recent.filter(sample => !sample.model || sample.model === "unknown").length;
  const warned = recent.filter(sample => Boolean(sample.networkWarning)).length;
  return {
    recent: recent.length,
    unknown,
    warned,
    emptyLabel: unknown ? `${unknown}段待识别` : warned ? `${warned}段待核验` : "等待正文",
    explanation: `近 ${minutes} 分钟 ${recent.length} 段 · ${unknown} 段模型待识别 · ${warned} 段有停顿或采样不完整`,
  };
}

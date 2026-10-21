import type { ModelSpeedSummary, SpeedSample } from "../../types/live";
import { bodySpeedQuality, isBodySample } from "./bodySpeedQuality";

export const hasKnownSpeedModel = (model: string | null | undefined): model is string =>
    !!model?.trim() && model.trim().toLowerCase() !== "unknown";

export function recentBodySpeedSamples(samples: SpeedSample[], limit = 6) {
    return samples.filter(s => isBodySample(s) && hasKnownSpeedModel(s.model) && Number.isFinite(s.endedAt))
        .sort((a, b) => b.endedAt - a.endedAt || a.id.localeCompare(b.id)).slice(0, limit);
}

export function modelSpeedReadings(recent: ModelSpeedSummary[], retained: ModelSpeedSummary[]) {
    const readings = new Map<string, ModelSpeedSummary & { historical: boolean }>();
    for (const [models, historical] of [[retained, true], [recent, false]] as const) {
        for (const model of models) {
            if (hasKnownSpeedModel(model.model) && model.sampleCount > 0 && Number.isFinite(model.tokensPerSecond) && model.tokensPerSecond > 0)
                readings.set(model.model, { ...model, historical });
        }
    }
    return [...readings.values()].sort((a, b) => Number(a.historical) - Number(b.historical)
        || (b.lastMeasuredAt ?? 0) - (a.lastMeasuredAt ?? 0) || a.model.localeCompare(b.model));
}

export function bodySpeedStatus(sample: SpeedSample) {
    const quality = bodySpeedQuality(sample);
    const label = quality.included ? "计入均速"
        : quality.reason === "采样时长不超过 0.55 秒" ? "时长≤0.55秒"
        : quality.reason === "速率异常偏高" || quality.reason === "速率异常偏低" ? "速率待核查"
        : quality.reason === "采样存在异常标记" ? "采样告警" : "计时待核查";
    return { ...quality, label };
}

export function speedTimestamp(timestamp: number | null | undefined) {
    if (timestamp == null || !Number.isFinite(timestamp)) return "采样时间未知";
    return new Date(timestamp * 1000).toLocaleString("zh-CN", {
        month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
    });
}

/** Sidebar receives one qualified body per model from the complete backend history. */
export function latestSidebarModelSpeeds(readings: ModelSpeedSummary[], now = Date.now() / 1000) {
    return readings.filter(s => hasKnownSpeedModel(s.model) && s.sampleCount === 1
        && Number.isFinite(s.tokensPerSecond) && s.tokensPerSecond > 0
        && s.lastMeasuredAt != null && Number.isFinite(s.lastMeasuredAt)
        && s.lastMeasuredAt >= now - 1800 && s.lastMeasuredAt <= now)
        .sort((a, b) => b.lastMeasuredAt! - a.lastMeasuredAt! || a.model.localeCompare(b.model));
}

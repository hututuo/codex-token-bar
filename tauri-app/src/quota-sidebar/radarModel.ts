import {
  rankedModelRows, modelPointHasMeasurement, radarIsSpeedWindow, radarSpeedWindowDeadlineMs, primaryModelMeasurementRow, radarActionDisplayTextForSnapshot, radarWindowSummaryDisplayText,
  type CodexRadarSnapshot,
} from "../domain/codexRadar/model.ts";
import {
  rankedCodexCrowdRadarModels, CROWD_RADAR_MINIMUM_RANKED_SAMPLE_COUNT,
  type CodexCrowdRadarSnapshot,
} from "../api/codexCrowdRadarClient.ts";

export interface SidebarRadar {
  official: {
    available: boolean; stale: boolean; fresh: boolean; windowOpen: boolean | null; windowSummary: string;
    deadlineMs: number | null; countdown: string; action: string; updatedAt: string; source: string;
    rows?: { rank: number; model: string; effort: string; iq: number; passed: number; samples: number }[];
    primary: { model: string; effort: string; iq: number; passed: number; tasks: number } | null;
  };
  crowd: {
    checkedAt?: string; available: boolean; stale: boolean | null; updatedAt: string; source: string; minimumSamples: number;
    rows: { rank: number; model: string; effort: string; iq: number; passed: number; samples: number }[];
  };
}
export function sidebarRadarSnapshot(official: CodexRadarSnapshot | null, crowd: CodexCrowdRadarSnapshot | null, nowMs = Date.now()): SidebarRadar {
  const lastSuccessMs = Date.parse(official?.lastSuccessfulRefreshAt || "");
  const fresh = official !== null && !official.staleDataDisplayed && Number.isFinite(lastSuccessMs) && nowMs >= lastSuccessMs && nowMs - lastSuccessMs <= 15 * 60_000;
  const primary = official ? primaryModelMeasurementRow(official.modelIq) : null;
  const provenance = crowd?.provenance?.table;
  const stale = provenance?.stale === true || provenance?.fresh === false ? true
    : provenance?.stale === false || provenance?.fresh === true ? false : null;
  const rows = rankedCodexCrowdRadarModels(crowd, 8, "realtime")
    .filter(row => Number.isFinite(row.passRate))
    .map((row, index) => ({ rank: index + 1, model: row.model, effort: row.effort,
      iq: row.passRate * 150, passed: row.scorePassed, samples: row.scoreSamples }));
  return {
    official: { available: official !== null, fresh, stale: official?.staleDataDisplayed ?? false,
      windowOpen: official ? radarIsSpeedWindow(official, nowMs) : null,
      deadlineMs: radarSpeedWindowDeadlineMs(official), countdown: radarActionDisplayTextForSnapshot(official, nowMs).replace(/^速登 /, ""),
      windowSummary: official ? sidebarRadarWording(radarWindowSummaryDisplayText(official)) : "雷达待读取",
      action: official ? sidebarRadarWording(radarActionDisplayTextForSnapshot(official)) : "建议动作暂不可用",
      updatedAt: official?.monitoredAt || "", source: official?.links.html || "https://codexradar.com/",
      rows: official ? rankedModelRows(official.modelIq).filter(row => modelPointHasMeasurement(row.point)).map((row,index) => ({rank:index+1,model:row.model || row.point.model || row.label,effort:row.reasoningEffort || row.point.reasoningEffort || "未知",iq:row.point.score,passed:row.point.passed,samples:row.point.tasks})) : [],
      primary: primary ? { model: primary.model || primary.point.model || primary.label,
        effort: primary.reasoningEffort || primary.point.reasoningEffort || "未知",
        iq: primary.point.score, passed: primary.point.passed, tasks: primary.point.tasks } : null,
    },
    crowd: { checkedAt: crowd?.provenance?.observedAt || "", available: crowd !== null && crowd.realtimeAvailable, stale,
      updatedAt: crowd?.generatedAt || "", source: provenance?.endpoint || "Codex Radar 众测实时表",
      minimumSamples: CROWD_RADAR_MINIMUM_RANKED_SAMPLE_COUNT, rows },
  };
}
// A stale retained window must never activate the edge signal.
export function sidebarRadarIsActive(radar?: SidebarRadar): boolean {
  return radar?.official.available === true && radar.official.stale === false && radar.official.fresh === true && radar.official.windowOpen === true;
}
export function sidebarRadarCompact(radar?: SidebarRadar): string {
  if (!radar?.official.available || !radar.official.fresh || radar.official.stale || radar.official.windowOpen === null) return "雷达待读取";
  return sidebarRadarIsActive(radar) ? "速登窗口" : "等待";
}
function sidebarRadarWording(value: string): string {
  return value.replace(/窗口(?:已)?关闭/g, "等待").replace(/窗口开放/g, "速登窗口");
}

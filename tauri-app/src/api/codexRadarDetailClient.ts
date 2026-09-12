import { diagnosticJournal } from "../diagnostics/diagnosticJournal.ts";
import { codexRadarSnapshotHasContent, normalizeCodexRadarSnapshot, type CodexRadarSnapshot } from "../domain/codexRadar/model";
import { callCommandStrict } from "./command";

const CODEX_RADAR_FULL_DETAIL_TIMEOUT_MS = 20_000;

export async function readCodexRadarFullSnapshot(): Promise<CodexRadarSnapshot> {
  try {
  const raw = await callCommandStrict<unknown>(
    "read_codex_radar_full_snapshot",
    undefined,
    CODEX_RADAR_FULL_DETAIL_TIMEOUT_MS,
  );
  const snapshot = normalizeCodexRadarSnapshot(raw);
  if (!codexRadarSnapshotHasContent(snapshot)) {
    throw new Error("Codex Radar 详细数据为空");
  }
  diagnosticJournal.update("radar-detail", "", "");
  return snapshot;
  } catch (error) {
    diagnosticJournal.update("radar-detail", "雷达详情读取失败", String(error));
    throw error;
  }
}

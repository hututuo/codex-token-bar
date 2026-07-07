import { normalizeCodexRadarSnapshot, type CodexRadarSnapshot } from "../components/codexRadar/model";
import { callCommandStrict } from "./command";

const CODEX_RADAR_FULL_DETAIL_TIMEOUT_MS = 20_000;

export async function readCodexRadarFullSnapshot(): Promise<CodexRadarSnapshot> {
  const raw = await callCommandStrict<unknown>(
    "read_codex_radar_full_snapshot",
    undefined,
    CODEX_RADAR_FULL_DETAIL_TIMEOUT_MS,
  );
  return normalizeCodexRadarSnapshot(raw);
}

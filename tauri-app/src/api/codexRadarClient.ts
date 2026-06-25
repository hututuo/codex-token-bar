import {
  normalizeCodexRadarSnapshot,
  parseCodexRadarFeedXml,
  type CodexRadarFeedItem,
  type CodexRadarSnapshot,
} from "../components/codexRadar/model";
import { withTimeout } from "../platform/runtime";

const CODEX_RADAR_ENDPOINT = "https://codexradar.com/current.json";
const CODEX_RADAR_CACHE_MS = 600_000;

let cachedSnapshot: { snapshot: CodexRadarSnapshot; readAt: number } | null = null;
let inFlightRead: Promise<CodexRadarSnapshot> | null = null;

export async function readCodexRadarSnapshot(options: { force?: boolean } = {}): Promise<CodexRadarSnapshot> {
  const now = Date.now();
  if (!options.force && cachedSnapshot && now - cachedSnapshot.readAt < CODEX_RADAR_CACHE_MS) {
    return cachedSnapshot.snapshot;
  }
  if (!options.force && inFlightRead) {
    return inFlightRead;
  }

  inFlightRead = fetchCodexRadarSnapshot().finally(() => {
    inFlightRead = null;
  });
  return inFlightRead;
}

async function fetchCodexRadarSnapshot(): Promise<CodexRadarSnapshot> {
  const response = await withTimeout(
    fetch(CODEX_RADAR_ENDPOINT, {
      cache: "no-store",
      headers: {
        Accept: "application/json",
      },
    }),
    18_000,
  );

  if (!response.ok) {
    throw new Error(`Codex Radar HTTP ${response.status}`);
  }

  const baseSnapshot = normalizeCodexRadarSnapshot(await response.json());
  const feedItems = await fetchCodexRadarFeed(baseSnapshot.links.rss);
  const snapshot = {
    ...baseSnapshot,
    feedItems,
  };
  cachedSnapshot = {
    snapshot,
    readAt: Date.now(),
  };
  return snapshot;
}

async function fetchCodexRadarFeed(feedUrl: string): Promise<CodexRadarFeedItem[]> {
  if (!feedUrl) {
    return [];
  }

  try {
    const response = await withTimeout(
      fetch(feedUrl, {
        cache: "no-store",
        headers: {
          Accept: "application/rss+xml, application/xml, text/xml",
        },
      }),
      18_000,
    );
    if (!response.ok) {
      return [];
    }
    return parseCodexRadarFeedXml(await response.text());
  } catch {
    return [];
  }
}

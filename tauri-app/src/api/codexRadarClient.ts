import {
  codexRadarSnapshotHasContent,
  codexRadarSurfaceStatus,
  normalizeCodexRadarSnapshot,
  parseCodexRadarFeedXml,
  type CodexRadarDiagnostic,
  type CodexRadarFeedItem,
  type CodexRadarReadState,
  type CodexRadarSnapshot,
} from "../domain/codexRadar/model";
import { isTauriRuntimeAvailable, withTimeout } from "../platform/runtime";
import { recordPerformanceEvent } from "./startupClient";

const CODEX_RADAR_ENDPOINT = "https://codexradar.com/current.json";
const CODEX_RADAR_CACHE_MS = 600_000;

let cachedSnapshot: { snapshot: CodexRadarSnapshot; readAt: number } | null = null;
let inFlightStateRead: Promise<CodexRadarReadState> | null = null;
const stateListeners = new Set<(state: CodexRadarReadState) => void>();

export function subscribeCodexRadarState(listener: (state: CodexRadarReadState) => void): () => void {
  stateListeners.add(listener);
  if (cachedSnapshot) {
    listener(stateFromSnapshot(cachedSnapshot.snapshot));
  }
  return () => stateListeners.delete(listener);
}

export async function readCodexRadarSnapshot(options: { force?: boolean } = {}): Promise<CodexRadarSnapshot> {
  const state = await readCodexRadarState(cachedSnapshot?.snapshot ?? null, options);
  if (!state.snapshot) {
    throw new Error(state.statusText);
  }
  return state.snapshot;
}

export async function readCodexRadarState(
  previousSnapshot: CodexRadarSnapshot | null = null,
  options: { force?: boolean } = {},
): Promise<CodexRadarReadState> {
  const now = Date.now();
  if (!options.force && cachedSnapshot && now - cachedSnapshot.readAt < CODEX_RADAR_CACHE_MS) {
    return stateFromSnapshot(cachedSnapshot.snapshot);
  }
  if (inFlightStateRead) {
    return inFlightStateRead;
  }

  inFlightStateRead = fetchCodexRadarState(previousSnapshot ?? cachedSnapshot?.snapshot ?? null).finally(() => {
    inFlightStateRead = null;
  });
  return inFlightStateRead;
}

async function fetchCodexRadarState(previousSnapshot: CodexRadarSnapshot | null): Promise<CodexRadarReadState> {
  const refreshedAt = new Date().toISOString();
  const startedAt = performance.now();
  traceRadarPerformance(`radar_state start has_previous=${previousSnapshot ? 1 : 0}`);
  try {
    const baseSnapshot = await fetchCodexRadarRootSnapshot();
    const feed = await fetchCodexRadarFeedState(baseSnapshot.links.rss, previousSnapshot);
    const snapshot = withRadarState({
      ...baseSnapshot,
      feedItems: feed.items,
    }, {
      diagnostics: feed.diagnostics,
      feedStaleDataDisplayed: feed.staleDataDisplayed,
      lastSuccessfulRefreshAt: refreshedAt,
    });
    cachedSnapshot = {
      snapshot,
      readAt: Date.now(),
    };
    traceRadarPerformance(
      `radar_state success elapsed_ms=${Math.round(performance.now() - startedAt)} feed_items=${feed.items.length}`,
    );
    return publishState(stateFromSnapshot(snapshot));
  } catch (error) {
    const diagnostic = diagnosticFromError(error, "root");
    traceRadarPerformance(
      `radar_state failure elapsed_ms=${Math.round(performance.now() - startedAt)} category=${diagnostic.category} has_previous=${previousSnapshot ? 1 : 0}`,
    );
    if (previousSnapshot) {
      const snapshot = withRadarState(previousSnapshot, {
        diagnostics: [
          diagnostic,
          {
            category: "stale_cached_data",
            source: "cache",
            message: "Codex 雷达暂时无法刷新，正在显示上次成功数据。",
            rawCause: diagnostic.rawCause,
            retryable: true,
          },
        ],
        lastFailureAt: refreshedAt,
        staleDataDisplayed: true,
      });
      cachedSnapshot = {
        snapshot,
        readAt: Date.now(),
      };
      return publishState(stateFromSnapshot(snapshot));
    }
    return publishState({
      snapshot: null,
      diagnostics: [diagnostic],
      statusText: diagnostic.message,
      lastSuccessfulRefreshAt: null,
      lastFailureAt: refreshedAt,
      staleDataDisplayed: false,
      feedStaleDataDisplayed: false,
    });
  }
}

function publishState(state: CodexRadarReadState): CodexRadarReadState {
  for (const listener of [...stateListeners]) {
    listener(state);
  }
  return state;
}

async function fetchCodexRadarRootSnapshot(): Promise<CodexRadarSnapshot> {
  const startedAt = performance.now();
  traceRadarPerformance("radar_root start");
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

  const raw = await response.json();
  const snapshot = normalizeCodexRadarSnapshot(raw);
  if (!codexRadarSnapshotHasContent(snapshot)) {
    throw new Error("Codex Radar 空数据");
  }
  traceRadarPerformance(
    `radar_root success elapsed_ms=${Math.round(performance.now() - startedAt)} http=${response.status}`,
  );
  return snapshot;
}

async function fetchCodexRadarFeedState(
  feedUrl: string,
  previousSnapshot: CodexRadarSnapshot | null,
): Promise<{ diagnostics: CodexRadarDiagnostic[]; items: CodexRadarFeedItem[]; staleDataDisplayed: boolean }> {
  if (!feedUrl) {
    return { diagnostics: [], items: [], staleDataDisplayed: false };
  }

  const startedAt = performance.now();
  traceRadarPerformance("radar_feed start");
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
      throw new Error(`Codex Radar RSS HTTP ${response.status}`);
    }
    const items = parseCodexRadarFeedXml(await response.text());
    traceRadarPerformance(
      `radar_feed success elapsed_ms=${Math.round(performance.now() - startedAt)} http=${response.status} items=${items.length}`,
    );
    return { diagnostics: [], items, staleDataDisplayed: false };
  } catch (error) {
    const previousItems = previousSnapshot?.feedItems ?? [];
    const diagnostic = diagnosticFromError(error, "feed");
    traceRadarPerformance(
      `radar_feed failure elapsed_ms=${Math.round(performance.now() - startedAt)} category=${diagnostic.category} has_previous=${previousItems.length > 0 ? 1 : 0}`,
    );
    return {
      diagnostics: [diagnostic],
      items: previousItems,
      staleDataDisplayed: previousItems.length > 0,
    };
  }
}

function traceRadarPerformance(label: string): void {
  if (isTauriRuntimeAvailable()) {
    void recordPerformanceEvent(label);
  }
}

function stateFromSnapshot(snapshot: CodexRadarSnapshot): CodexRadarReadState {
  const diagnostics = snapshot.diagnostics ?? [];
  return {
    snapshot,
    diagnostics,
    statusText: codexRadarSurfaceStatus(snapshot, diagnostics),
    lastSuccessfulRefreshAt: snapshot.lastSuccessfulRefreshAt ?? null,
    lastFailureAt: snapshot.lastFailureAt ?? null,
    staleDataDisplayed: snapshot.staleDataDisplayed,
    feedStaleDataDisplayed: snapshot.feedStaleDataDisplayed,
  };
}

function withRadarState(
  snapshot: CodexRadarSnapshot,
  overrides: {
    diagnostics?: CodexRadarDiagnostic[];
    feedStaleDataDisplayed?: boolean;
    lastFailureAt?: string;
    lastSuccessfulRefreshAt?: string;
    staleDataDisplayed?: boolean;
  } = {},
): CodexRadarSnapshot {
  return {
    ...snapshot,
    diagnostics: overrides.diagnostics ?? [],
    lastFailureAt: overrides.lastFailureAt ?? null,
    lastSuccessfulRefreshAt: overrides.lastSuccessfulRefreshAt ?? snapshot.lastSuccessfulRefreshAt ?? null,
    staleDataDisplayed: overrides.staleDataDisplayed ?? false,
    feedStaleDataDisplayed: overrides.feedStaleDataDisplayed ?? false,
  };
}

function diagnosticFromError(error: unknown, source: "root" | "feed"): CodexRadarDiagnostic {
  const rawCause = error instanceof Error ? error.message : String(error);
  const category = source === "feed" ? "rss_failure" : categoryFromError(rawCause);
  return {
    category,
    source,
    message: source === "feed"
      ? `Codex 雷达 RSS 读取失败：${rawCause}`
      : `Codex 雷达读取失败：${rawCause}`,
    rawCause,
    retryable: true,
  };
}

function categoryFromError(rawCause: string): CodexRadarDiagnostic["category"] {
  if (/timed out|timeout/i.test(rawCause)) {
    return "timeout";
  }
  const httpStatus = /HTTP\s+(\d{3})/i.exec(rawCause)?.[1];
  if (httpStatus) {
    const status = Number(httpStatus);
    if (status === 401 || status === 403) {
      return "http_auth";
    }
    if (status === 429) {
      return "http_rate_limited";
    }
    if (status >= 500) {
      return "http_server";
    }
    return "http_other";
  }
  if (/json|parse|syntax/i.test(rawCause)) {
    return "parse_failure";
  }
  if (/empty payload|空数据/i.test(rawCause)) {
    return "empty_radar_payload";
  }
  if (/fetch|network|failed to fetch/i.test(rawCause)) {
    return "network_fetch";
  }
  return "unknown";
}

export function __resetCodexRadarCacheForTests(): void {
  cachedSnapshot = null;
  inFlightStateRead = null;
  stateListeners.clear();
}

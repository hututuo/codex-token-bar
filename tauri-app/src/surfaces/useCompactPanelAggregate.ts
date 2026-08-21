import { useEffect, useState } from "react";
import { readAppSettings, schedulePreciseDashboardAggregate } from "../api/client";
import { desktopPlatform } from "../platform/desktop";
import {
  DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES,
  sanitizeUsageBackgroundAggregateIntervalMinutes,
} from "../settings/usageRefreshCadence";
import type { CodexHomeSourceToken } from "../types/dashboard";
import { codexHomeSourceTokenKey } from "./useCompactPanelSource";
import { nextAggregateFireAtMs } from "../utils/usageRefreshCadence";

interface CompactPanelAggregateOptions {
  active: boolean;
  sourceToken: CodexHomeSourceToken | null;
}

interface CompactAggregateEntry {
  sourceToken: CodexHomeSourceToken;
  consumers: Set<symbol>;
  intervalMinutes: number;
  timer: number | null;
}

/**
 * Floating and status surfaces can be mounted at the same time. Keep one
 * background aggregate timer per Home instead of one timer per WebView. The
 * native coordinator still serializes the actual work, but deduping here
 * avoids duplicate IPC requests and keeps cadence diagnostics meaningful.
 */
const compactAggregateEntries = new Map<string, CompactAggregateEntry>();

function scheduleCompactAggregate(key: string, entry: CompactAggregateEntry): void {
  if (entry.timer !== null) {
    window.clearTimeout(entry.timer);
  }
  const scheduledAt = Date.now();
  const fireAt = nextAggregateFireAtMs(scheduledAt, entry.intervalMinutes);
  entry.timer = window.setTimeout(() => {
    entry.timer = null;
    if (entry.consumers.size === 0 || compactAggregateEntries.get(key) !== entry) {
      return;
    }
    void schedulePreciseDashboardAggregate(entry.sourceToken, "cadence")
      .catch(() => {
        // Native diagnostics retain the real failure; the compact surface
        // keeps its last trusted summary and retries at the next boundary.
      })
      .finally(() => {
        if (entry.consumers.size > 0 && compactAggregateEntries.get(key) === entry) {
          scheduleCompactAggregate(key, entry);
        }
      });
  }, Math.max(0, fireAt - scheduledAt));
}

function acquireCompactAggregate(
  sourceToken: CodexHomeSourceToken,
  intervalMinutes: number,
): () => void {
  const key = codexHomeSourceTokenKey(sourceToken);
  if (key === null) {
    return () => {};
  }
  const consumer = Symbol("compact-aggregate-consumer");
  let entry = compactAggregateEntries.get(key);
  if (entry === undefined) {
    entry = {
      sourceToken,
      consumers: new Set(),
      intervalMinutes,
      timer: null,
    };
    compactAggregateEntries.set(key, entry);
  }
  entry.sourceToken = sourceToken;
  entry.intervalMinutes = intervalMinutes;
  entry.consumers.add(consumer);
  scheduleCompactAggregate(key, entry);

  return () => {
    const current = compactAggregateEntries.get(key);
    if (current !== entry) {
      return;
    }
    current.consumers.delete(consumer);
    if (current.consumers.size === 0) {
      if (current.timer !== null) {
        window.clearTimeout(current.timer);
      }
      compactAggregateEntries.delete(key);
    }
  };
}

/**
 * Keeps the process-level background aggregate owner alive when the main
 * dashboard WebView is not mounted (for example, autostart with only the
 * floating panel).  This is deliberately separate from the compact summary
 * timer: it fires only at the configured background cadence and delegates to
 * the native serialized precise owner.
 */
export function useCompactPanelAggregate({
  active,
  sourceToken,
}: CompactPanelAggregateOptions): void {
  const [intervalMinutes, setIntervalMinutes] = useState(
    DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES,
  );

  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | null = null;

    void readAppSettings().then((settings) => {
      if (!cancelled && settings !== null) {
        setIntervalMinutes(
          sanitizeUsageBackgroundAggregateIntervalMinutes(
            settings.usageBackgroundAggregateIntervalMinutes,
          ),
        );
      }
    }).catch(() => {});

    void desktopPlatform.onAppSettingsChanged((settings) => {
      if (cancelled) {
        return;
      }
      setIntervalMinutes(
        sanitizeUsageBackgroundAggregateIntervalMinutes(
          settings.usageBackgroundAggregateIntervalMinutes,
        ),
      );
    }).then((listener) => {
      if (cancelled) listener();
      else unlisten = listener;
    });

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    if (!active || sourceToken === null) {
      return undefined;
    }
    return acquireCompactAggregate(sourceToken, intervalMinutes);
  }, [active, intervalMinutes, sourceToken]);
}

import { useEffect, useMemo, useState } from "react";
import type { CodexHomeSourceToken, ModelTokenBreakdown } from "../../types/dashboard";
import type { Summary } from "../../multiClient/MultiClientUsage";
import { callCommandStrict } from "../../api/command";
import { clientModelCostItems } from "../../multiClient/originalDashboardProjection";
import { modelDayBounds } from "./ModelDayCalendar";
import { useSpeedPalette } from "../liveRate/useSpeedPalette";

export interface ModelDayUsage {
  codexRows: ModelTokenBreakdown[];
  clientRows: Summary[];
  availableClients: string[];
  issues: string[];
}

export function modelDayRequestKey(
  day: string | null, source: CodexHomeSourceToken | null, clients: readonly string[], refreshKey: string,
): string {
  return JSON.stringify([day, day ? modelDayBounds(day) : null, source, [...clients].sort(), refreshKey]);
}

export function useModelDayUsage(
  day: string | null, sourceToken: CodexHomeSourceToken | null, clients: readonly string[], refreshKey: string,
) {
  const palette = useSpeedPalette();
  const [retry, setRetry] = useState(0);
  const [response, setResponse] = useState<{
    key: string; selectionKey: string; value?: ModelDayUsage; error?: string;
  }>();
  const selectionKey = modelDayRequestKey(day, sourceToken, clients, "");
  const key = modelDayRequestKey(day, sourceToken, clients, `${refreshKey}|${retry}`);

  useEffect(() => {
    if (!day) return;
    const bounds = modelDayBounds(day);
    if (!bounds) return;
    let cancelled = false;
    callCommandStrict<ModelDayUsage>("read_model_day_usage", {
      ...bounds, sourceToken, clients: [...new Set(clients)],
    }, null)
      .then(value => { if (!cancelled) setResponse({ key, selectionKey, value }); })
      .catch(error => { if (!cancelled) setResponse({ key, selectionKey, error: String(error) }); });
    return () => { cancelled = true; };
  }, [key]);

  // Routine refreshes retain only the same date/source/client selection.
  const value = response?.selectionKey === selectionKey ? response.value : undefined;
  const error = response?.key === key ? response.error : undefined;
  const items = useMemo(() => value ? clientModelCostItems(value.clientRows, value.codexRows, clients) : [],
    [value, clients.join("|"), palette]);
  return {
    items, value, error,
    loading: Boolean(day && !value && !error),
    refreshing: Boolean(value && response?.key !== key),
    retry: () => setRetry(n => n + 1),
  };
}

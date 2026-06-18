import type { Dispatch, SetStateAction } from "react";
import {
  getCommandDiagnosticsSnapshot,
  recordStartupEvent,
} from "../api/client";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { DashboardAppState } from "./dashboardState";

interface InitialDashboardLoadOptions {
  source: Pick<
    DashboardDataSource,
    "getCodexHome" | "readPlatformCapabilities" | "readDashboardSnapshot"
  >;
  isCancelled: () => boolean;
  setState: Dispatch<SetStateAction<DashboardAppState>>;
  onFastSnapshotLoaded: () => void;
}

export async function loadInitialDashboardState({
  source,
  isCancelled,
  setState,
  onFastSnapshotLoaded,
}: InitialDashboardLoadOptions): Promise<void> {
  void source.getCodexHome().then((codexHome) => {
    if (!isCancelled()) {
      setState((current) => ({ ...current, codexHome }));
      void recordStartupEvent("codex home ready");
    }
  });

  void source.readPlatformCapabilities().then((platform) => {
    if (!isCancelled()) {
      setState((current) => ({ ...current, platform }));
      void recordStartupEvent("platform ready");
    }
  });

  await source.readDashboardSnapshot().then((dashboard) => {
    if (!isCancelled()) {
      setState((current) => ({
        ...current,
        dashboard,
        diagnostics: getCommandDiagnosticsSnapshot(),
        loading: false,
      }));
      onFastSnapshotLoaded();
      void recordStartupEvent("dashboard snapshot ready");
    }
  });
}

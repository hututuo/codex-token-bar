import type { Dispatch, SetStateAction } from "react";
import { recordStartupEvent } from "../api/client";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { DashboardSourceToken } from "./dashboardSourceTransition";
import type { DashboardAppState } from "./dashboardState";

interface InitialDashboardLoadOptions {
  source: Pick<
    DashboardDataSource,
    "readPlatformCapabilities" | "readDashboardSnapshot"
  >;
  sourceToken: DashboardSourceToken;
  isCancelled: () => boolean;
  isSourceCurrent: (token: DashboardSourceToken) => boolean;
  setState: Dispatch<SetStateAction<DashboardAppState>>;
  onFastSnapshotLoaded: () => void;
}

export async function loadInitialDashboardState({
  source,
  sourceToken,
  isCancelled,
  isSourceCurrent,
  setState,
  onFastSnapshotLoaded,
}: InitialDashboardLoadOptions): Promise<void> {
  void source.readPlatformCapabilities().then((platform) => {
    if (!isCancelled() && isSourceCurrent(sourceToken)) {
      setState((current) => isSourceCurrent(sourceToken)
        ? { ...current, platform }
        : current);
      void recordStartupEvent("platform ready");
    }
  });

  await source.readDashboardSnapshot(sourceToken).then((dashboard) => {
    if (!isCancelled() && isSourceCurrent(sourceToken)) {
      setState((current) => isSourceCurrent(sourceToken)
        ? {
            ...current,
            dashboard,
            loading: false,
          }
        : current);
      onFastSnapshotLoaded();
      void recordStartupEvent("dashboard snapshot ready");
    }
  });
}

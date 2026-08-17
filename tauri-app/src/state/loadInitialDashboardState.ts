import type { Dispatch, SetStateAction } from "react";
import { recordStartupEvent } from "../api/client";
import type { DashboardStartupRead } from "../api/dashboardClient";
import type { DashboardSnapshot } from "../types/dashboard";
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

  try {
    const raw = await source.readDashboardSnapshot(sourceToken);
    // Keep compatibility with small test/in-process sources that still return
    // the historical bare snapshot. Native startup reads are now explicitly
    // success/stale/unavailable, so an IPC rejection can never become a fake
    // zero dashboard that flips loading off.
    const candidate = raw as DashboardStartupRead | DashboardSnapshot;
    const startup = isDashboardStartupRead(candidate)
      ? candidate
      : {
          status: candidate.preciseRecentUsageFresh ? "success" : "stale",
          snapshot: candidate,
        } satisfies DashboardStartupRead;
    if (startup.snapshot !== null) {
      if (!isCancelled() && isSourceCurrent(sourceToken)) {
        setState((current) => isSourceCurrent(sourceToken)
          ? {
              ...current,
              dashboard: startup.snapshot,
              loading: false,
            }
          : current);
        onFastSnapshotLoaded();
        void recordStartupEvent("dashboard snapshot ready");
      }
      return;
    }
    // Keep the source load pending. The precise retry effect can still run
    // once the native owner becomes available, while diagnostics expose the
    // unavailable command to the user.
    if (!isCancelled() && isSourceCurrent(sourceToken)) {
      void recordStartupEvent("dashboard snapshot unavailable");
    }
  } catch {
    if (!isCancelled() && isSourceCurrent(sourceToken)) {
      void recordStartupEvent("dashboard snapshot unavailable");
    }
  }
}

function isDashboardStartupRead(
  value: DashboardStartupRead | DashboardSnapshot,
): value is DashboardStartupRead {
  return typeof value === "object"
    && value !== null
    && "status" in value
    && "snapshot" in value;
}

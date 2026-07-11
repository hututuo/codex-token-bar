import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import {
  manualUpdateFailureMessage,
  UNSUPPORTED_UPDATE_MESSAGE,
} from "./updateModel";

export { isUnsupportedUpdaterError } from "./updateModel";

export type AppUpdateSnapshot = {
  status: "idle" | "available" | "error";
  message: string;
  version: string | null;
  body: string | null;
  date: string | null;
};

export type UpdateAvailability =
  | { status: "unsupported"; message: string }
  | { status: "none"; message: string }
  | { status: "available"; version: string; body: string; date: string | null };

function normalize(snapshot: AppUpdateSnapshot): UpdateAvailability {
  if (snapshot.status === "available" && snapshot.version) {
    return { status: "available", version: snapshot.version, body: snapshot.body ?? "", date: snapshot.date };
  }
  return { status: "none", message: snapshot.message || "已是最新版" };
}

export async function readCachedAppUpdate(): Promise<UpdateAvailability> {
  if (!isTauriRuntimeAvailable()) return { status: "unsupported", message: UNSUPPORTED_UPDATE_MESSAGE };
  return normalize(await invoke<AppUpdateSnapshot>("read_app_update_state"));
}

export async function checkAppUpdate(): Promise<UpdateAvailability> {
  if (!isTauriRuntimeAvailable()) return { status: "unsupported", message: UNSUPPORTED_UPDATE_MESSAGE };
  return normalize(await invoke<AppUpdateSnapshot>("check_app_update"));
}

export async function listenForAppUpdateState(listener: (state: UpdateAvailability) => void): Promise<UnlistenFn> {
  if (!isTauriRuntimeAvailable()) return () => {};
  return listen<AppUpdateSnapshot>("app-update-state-changed", event => listener(normalize(event.payload)));
}

export async function installAppUpdate(version: string, onProgress?: (message: string) => void) {
  let unlisten: UnlistenFn | null = null;
  try {
    unlisten = await listen<{ chunkLength?: number; contentLength?: number; finished?: boolean }>(
      "app-update-install-progress",
      event => onProgress?.(event.payload.finished ? "正在安装更新..." : "正在下载更新..."),
    );
    await invoke("install_app_update", { version });
  } finally {
    unlisten?.();
  }
}

export { manualUpdateFailureMessage };

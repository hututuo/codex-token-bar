import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { isTauriRuntimeAvailable, withTimeout } from "../platform/runtime";
import {
  isUnsupportedUpdaterError,
  manualUpdateFailureMessage,
  UNSUPPORTED_UPDATE_MESSAGE,
} from "./updateModel";

export { isUnsupportedUpdaterError, manualUpdateFailureMessage } from "./updateModel";

export type UpdateAvailability =
  | { status: "unsupported"; message: string }
  | { status: "none"; message: string }
  | { status: "available"; version: string; body: string; update: Update };

export async function checkAppUpdate(timeoutMs = 15_000): Promise<UpdateAvailability> {
  if (!isTauriRuntimeAvailable()) {
    return {
      status: "unsupported",
      message: UNSUPPORTED_UPDATE_MESSAGE,
    };
  }

  let update: Update | null;
  try {
    update = await withTimeout(check({ timeout: timeoutMs }), timeoutMs + 1_000);
  } catch (error) {
    if (isUnsupportedUpdaterError(error)) {
      return { status: "unsupported", message: UNSUPPORTED_UPDATE_MESSAGE };
    }
    throw error;
  }
  if (!update) {
    return {
      status: "none",
      message: "已是最新版",
    };
  }

  return {
    status: "available",
    version: update.version,
    body: update.body ?? "",
    update,
  };
}

export async function installAppUpdate(update: Update, onProgress?: (message: string) => void) {
  let downloaded = 0;
  await update.downloadAndInstall((event) => {
    if (event.event === "Started") {
      downloaded = 0;
      onProgress?.("正在下载更新...");
      return;
    }
    if (event.event === "Progress") {
      downloaded += event.data.chunkLength;
      const mb = downloaded / 1024 / 1024;
      onProgress?.(`正在下载更新 ${mb.toFixed(1)} MB`);
      return;
    }
    onProgress?.("正在安装更新...");
  });

  await relaunch();
}

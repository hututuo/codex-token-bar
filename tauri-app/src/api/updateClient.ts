import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { createUpdateClient } from "./updateClientCore";
import { manualUpdateFailureMessage, UNSUPPORTED_UPDATE_MESSAGE } from "./updateModel";

export { isUnsupportedUpdaterError } from "./updateModel";
export type { AppUpdateSnapshot, UpdateAvailability } from "./updateClientCore";
import type { UpdateAvailability } from "./updateClientCore";

const client = createUpdateClient({
  invoke,
  listen,
  runtime: isTauriRuntimeAvailable,
  unsupportedMessage: UNSUPPORTED_UPDATE_MESSAGE,
});

export async function readCachedAppUpdate(): Promise<UpdateAvailability> {
  return client.read();
}

export async function checkAppUpdate(): Promise<UpdateAvailability> {
  return client.check();
}

export async function listenForAppUpdateState(listener: (state: UpdateAvailability) => void): Promise<() => void> {
  return client.listen(listener);
}

export async function installAppUpdate(version: string, onProgress?: (message: string) => void) {
  return client.install(version, onProgress);
}

export { manualUpdateFailureMessage };

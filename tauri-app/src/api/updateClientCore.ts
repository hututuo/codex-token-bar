export type AppUpdateSnapshot = {
  status: "none" | "available" | "error";
  message: string;
  version: string | null;
  body: string | null;
  date: string | null;
  revision: number;
};

export type UpdateAvailability =
  | { status: "unsupported"; message: string }
  | { status: "none"; message: string; revision?: number }
  | { status: "available"; message: string; version: string; body: string; date: string | null; revision: number };

interface UpdateBridge {
  invoke: <T>(command: string, payload?: Record<string, unknown>) => Promise<T>;
  listen: <T>(event: string, listener: (event: { payload: T }) => void) => Promise<() => void>;
  runtime: () => boolean;
  unsupportedMessage: string;
}

function normalize(snapshot: AppUpdateSnapshot): UpdateAvailability {
  if (snapshot.status === "available" && snapshot.version) {
    return { status: "available", message: snapshot.message, version: snapshot.version, body: snapshot.body ?? "", date: snapshot.date, revision: snapshot.revision };
  }
  return { status: "none", message: snapshot.message || "已是最新版", revision: snapshot.revision };
}

export function createUpdateClient(bridge: UpdateBridge) {
  return {
    read: async () => {
      if (!bridge.runtime()) return { status: "unsupported", message: bridge.unsupportedMessage } as UpdateAvailability;
      return normalize(await bridge.invoke<AppUpdateSnapshot>("read_app_update_state"));
    },
    check: async () => {
      if (!bridge.runtime()) return { status: "unsupported", message: bridge.unsupportedMessage } as UpdateAvailability;
      return normalize(await bridge.invoke<AppUpdateSnapshot>("check_app_update"));
    },
    listen: async (listener: (state: UpdateAvailability) => void) => {
      if (!bridge.runtime()) return () => {};
      return bridge.listen<AppUpdateSnapshot>("app-update-state-changed", event => listener(normalize(event.payload)));
    },
    install: async (version: string, onProgress?: (message: string) => void) => {
      let unlisten: (() => void) | null = null;
      try {
        unlisten = await bridge.listen<{ finished?: boolean }>(
          "app-update-install-progress",
          event => onProgress?.(event.payload.finished ? "正在安装更新..." : "正在下载更新..."),
        );
        await bridge.invoke("install_app_update", { version });
      } finally {
        unlisten?.();
      }
    },
  };
}

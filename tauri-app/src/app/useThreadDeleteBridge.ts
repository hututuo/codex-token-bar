import { useCallback, useEffect, useState } from "react";
import {
  idleThreadDeleteBridgeStatus,
  readThreadDeleteBridgeStatus,
  reconnectThreadDeleteBridge,
  type ThreadDeleteBridgeStatus,
} from "../api/threadDeleteClient";

const STATUS_REFRESH_INTERVAL_MS = 3_000;

export function useThreadDeleteBridge() {
  const [status, setStatus] = useState<ThreadDeleteBridgeStatus>(idleThreadDeleteBridgeStatus);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      const next = await readThreadDeleteBridgeStatus();
      if (!cancelled) setStatus(next);
    };
    void refresh();
    const timer = window.setInterval(() => {
      void refresh();
    }, STATUS_REFRESH_INTERVAL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, []);

  const reconnect = useCallback(async () => {
    try {
      setStatus(await reconnectThreadDeleteBridge());
    } catch (error) {
      setStatus({
        connected: false,
        debugPort: null,
        message: `重连失败：${error instanceof Error ? error.message : String(error)}`,
      });
    }
  }, []);

  return { reconnect, status };
}

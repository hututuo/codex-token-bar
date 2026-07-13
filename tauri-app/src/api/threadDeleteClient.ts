import { callCommand, callCommandStrict } from "./command";

export interface ThreadDeleteBridgeStatus {
  connected: boolean;
  debugPort: number | null;
  message: string;
}

export const idleThreadDeleteBridgeStatus: ThreadDeleteBridgeStatus = {
  connected: false,
  debugPort: null,
  message: "等待 Codex 调试连接（需以调试模式启动 Codex）",
};

export async function readThreadDeleteBridgeStatus(): Promise<ThreadDeleteBridgeStatus> {
  return callCommand(
    "read_thread_delete_bridge_status",
    idleThreadDeleteBridgeStatus,
  );
}

export async function reconnectThreadDeleteBridge(): Promise<ThreadDeleteBridgeStatus> {
  return callCommandStrict("reconnect_thread_delete_bridge");
}

export async function enableThreadDeleteBridge(): Promise<ThreadDeleteBridgeStatus> {
  return callCommandStrict("enable_thread_delete_bridge");
}

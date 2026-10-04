import type { UpdateAvailability } from "../api/updateClientCore";

// Events received while installing are suppressed; reconcile on every return.
export async function finishUpdateInstall(
  install: () => Promise<"started" | "alreadyLatest">,
  read: () => Promise<UpdateAvailability>,
): Promise<UpdateAvailability | { status: "error"; message: string }> {
  let failure: string | null = null;
  let result: "started" | "alreadyLatest" | undefined;
  try { result = await install(); } catch (error) {
    failure = "更新未完成：" + String(error).slice(0, 240);
  }
  try {
    const state = await read();
    if (state.status === "available") return { ...state, message: failure ?? state.message };
    if (!failure) return { ...state, message: result === "alreadyLatest" ? "已是最新版" : state.message };
    return { status: "error", message: failure };
  } catch {
    return { status: "error", message: failure ?? "无法确认更新状态，请重新检查更新" };
  }
}

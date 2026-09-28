import { useSyncExternalStore } from "react";
import { invokePlatformCommandResult, listenToEvent } from "./platform/desktopBridge";

export interface QuotaAccounts { revision: number; selectedId: string | null; accounts: { id: string; label: string }[] }
const initial: QuotaAccounts = { revision: 0, selectedId: null, accounts: [] };
let state = initial;
let failure = "";
const subscribers = new Set<() => void>();
let cleanup: (() => void) | null = null;
export function quotaAccountKey(): string { return failure ? "unavailable" : state.revision + ":" + (state.selectedId ?? "local"); }
function setFailure(message: string) {
  if (failure !== message) { failure = message; subscribers.forEach(notify => notify()); }
}
function isQuotaAccounts(value: unknown): value is QuotaAccounts {
  if (!value || typeof value !== "object") return false;
  const next = value as QuotaAccounts;
  if (!Number.isSafeInteger(next.revision) || next.revision < 0 || !Array.isArray(next.accounts)) return false;
  if (!next.accounts.every(account => account && typeof account.id === "string" && account.id.length > 0 && typeof account.label === "string")) return false;
  return next.selectedId === null || (typeof next.selectedId === "string" && next.accounts.some(account => account.id === next.selectedId));
}
function accept(next: QuotaAccounts): boolean {
  if (!isQuotaAccounts(next)) { setFailure("额度账号配置读取失败，请重新读取"); return false; }
  if (next.revision < state.revision) return true;
  if (!failure && JSON.stringify(next) === JSON.stringify(state)) return true;
  failure = ""; state = next;
  subscribers.forEach(notify => notify());
  return true;
}
async function refresh() {
  const result = await invokePlatformCommandResult<QuotaAccounts>("list_quota_accounts", initial, undefined, 10_000);
  if (result.ok) accept(result.value);
  else if (result.error !== "Tauri runtime is not available" && failure !== result.error) {
    setFailure(result.error);
  }
}
function subscribe(notify: () => void) {
  subscribers.add(notify);
  if (subscribers.size === 1 && typeof window !== "undefined" && "__TAURI_INTERNALS__" in window) {
    let disposed = false;
    let stop: (() => void) | undefined;
    void listenToEvent<QuotaAccounts>("quota-accounts-changed", accept).then(unlisten => {
      if (disposed) unlisten(); else stop = unlisten;
    }).then(refresh);
    window.addEventListener("focus", refresh);
    const timer = window.setInterval(refresh, 15_000);
    cleanup = () => { disposed = true; stop?.(); window.clearInterval(timer); window.removeEventListener("focus", refresh); };
  }
  return () => { subscribers.delete(notify); if (!subscribers.size) { cleanup?.(); cleanup = null; } };
}
export function useQuotaAccounts() {
  const accounts = useSyncExternalStore(subscribe, () => state, () => initial);
  const error = useSyncExternalStore(subscribe, () => failure, () => "");
  return { accounts, error, key: error ? "unavailable" : accounts.revision + ":" + (accounts.selectedId ?? "local") };
}
export async function changeQuotaAccount(command: string, args?: Record<string, unknown>) {
  const result = await invokePlatformCommandResult<QuotaAccounts>(command, initial, args, null);
  if (!result.ok) throw new Error(result.error);
  if (!accept(result.value)) throw new Error(failure);
}

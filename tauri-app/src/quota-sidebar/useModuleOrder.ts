import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { DEFAULT_MODULE_ORDER, sanitizeModuleOrder, type SidebarModule } from "./moduleVisibility";

/** Read once, then synchronize by events; only explicit edits write settings. */
export function useModuleOrder() {
  const [order, setOrder] = useState<SidebarModule[]>(() => [...DEFAULT_MODULE_ORDER]);
  const [ready, setReady] = useState(false), [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const apply = useCallback((value: unknown) => {
    const next = sanitizeModuleOrder(value);
    setOrder(previous => JSON.stringify(previous) === JSON.stringify(next) ? previous : next);
    setReady(true);
  }, []);
  useEffect(() => {
    let disposed = false, revision = 0;
    const listener = listen<string[]>("sidebar-module-order-changed", event => {
      revision++; if (!disposed) apply(event.payload);
    }).then(async stop => {
      if (disposed) { stop(); return () => {}; }
      const atRead = revision;
      try { const value = await invoke("read_sidebar_module_order"); if (!disposed && revision === atRead) apply(value); }
      catch (e) { if (!disposed) setError(`侧栏顺序读取失败：${String(e)}`); }
      return stop;
    }).catch(e => { if (!disposed) setError(`侧栏顺序连接失败：${String(e)}`); return () => {}; });
    return () => { disposed = true; void listener.then(stop => stop()); };
  }, [apply]);
  const save = async (next: readonly SidebarModule[]) => {
    if (pending || !ready) return;
    setPending(true); setError(null);
    try { apply(await invoke("save_sidebar_module_order", { order: next })); }
    catch (e) { setError(`侧栏顺序保存失败：${String(e)}`); }
    finally { setPending(false); }
  };
  return { order, ready, pending, error, save };
}

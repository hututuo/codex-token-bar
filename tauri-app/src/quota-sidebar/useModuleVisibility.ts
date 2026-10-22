import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { DEFAULT_MODULE_VISIBILITY, sanitizeModuleVisibility, type SidebarModule, type SidebarModuleVisibility } from "./moduleVisibility";

/** Persist once per click; native events keep the rail and detail webviews in sync. */
export function useModuleVisibility() {
  const [visibility, setVisibility] = useState(DEFAULT_MODULE_VISIBILITY);
  const [ready, setReady] = useState(false), [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const apply = useCallback((value: unknown) => {
    const next = sanitizeModuleVisibility(value);
    setVisibility(previous => JSON.stringify(previous) === JSON.stringify(next) ? previous : next);
    setReady(true);
  }, []);
  useEffect(() => {
    let disposed = false, revision = 0;
    const listener = listen<SidebarModuleVisibility>("sidebar-module-visibility-changed", event => {
      revision++; if (!disposed) apply(event.payload);
    }).then(async stop => {
      if (disposed) { stop(); return () => {}; }
      const atRead = revision;
      try { const value = await invoke("read_sidebar_module_visibility"); if (!disposed && revision === atRead) apply(value); }
      catch (e) { if (!disposed) setError(`侧栏设置读取失败：${String(e)}`); }
      return stop;
    }).catch(e => { if (!disposed) setError(`侧栏设置连接失败：${String(e)}`); return () => {}; });
    return () => { disposed = true; void listener.then(stop => stop()); };
  }, [apply]);
  const save = async (module: SidebarModule, visible: boolean) => {
    if (pending || !ready) return;
    setPending(true); setError(null);
    try { apply(await invoke("save_sidebar_module_visibility", { module, visible })); }
    catch (e) { setError(`侧栏设置保存失败：${String(e)}`); }
    finally { setPending(false); }
  };
  return { visibility, ready, pending, error, save };
}

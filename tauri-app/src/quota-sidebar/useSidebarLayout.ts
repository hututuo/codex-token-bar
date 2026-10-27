import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { decodeQuotaSelection, quotaSelectionKey } from "../multiClient/integratedClientModel";
import { migrateSidebarLayout, normalizeSidebarLayout, type SidebarLayout, type SidebarLayoutConfig } from "./sidebarLayoutModel";

/** Events invalidate a snapshot; the atomic settings file remains authoritative.
 * Legacy keys are read only for migration and are never removed or rewritten. */
export function useSidebarLayout() {
  const [layout, setLayout] = useState<SidebarLayout>(() => normalizeSidebarLayout(null));
  const [ready, setReady] = useState(false), [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null), [attempt, setAttempt] = useState(0);
  const saving = useRef(false), sequence = useRef(0);
  const refresh = useRef<(clearError?: boolean) => Promise<boolean>>(async () => false);
  const apply = useCallback((raw: unknown) => {
    const next = normalizeSidebarLayout(raw);
    setLayout(old => JSON.stringify(old) === JSON.stringify(next) ? old : next);
    setReady(true);
  }, []);
  useEffect(() => {
    let disposed = false;
    const reconcile = async (clearError = true): Promise<boolean> => {
      const generation = ++sequence.current;
      if (saving.current || disposed) return false;
      try {
        let value = await invoke<SidebarLayout | null>("read_sidebar_layout");
        if (disposed || generation !== sequence.current || saving.current) return false;
        if (value === null) {
          const [order, visibility] = await Promise.all([
            invoke("read_sidebar_module_order"), invoke("read_sidebar_module_visibility"),
          ]);
          if (disposed || generation !== sequence.current || saving.current) return false;
          let raw = "";
          try { raw = window.localStorage.getItem(quotaSelectionKey) ?? ""; } catch { /* New profile. */ }
          value = await invoke<SidebarLayout>("save_sidebar_layout", {
            layout: migrateSidebarLayout(order, visibility, decodeQuotaSelection(raw).order),
            initializeOnly: true,
          });
        }
        if (disposed || generation !== sequence.current || saving.current) return false;
        apply(value);
        if (clearError) setError(null);
        return true;
      } catch (reason) {
        if (!disposed && generation === sequence.current) {
          setReady(false); setError("侧栏设置读取失败：" + String(reason));
        }
        return false;
      }
    };
    refresh.current = reconcile;
    const listener = listen("sidebar-layout-changed", () => {
      // A late event/command reply can contain an older value. Re-read rather
      // than applying its payload, and defer this read during a local write.
      sequence.current++;
      if (!disposed && !saving.current) void reconcile();
    }).then(async stop => {
      if (disposed) { stop(); return () => {}; }
      await reconcile();
      return stop;
    }).catch(reason => {
      if (!disposed) { setReady(false); setError("侧栏设置连接失败：" + String(reason)); }
      return () => {};
    });
    return () => {
      disposed = true; sequence.current++; refresh.current = async () => false;
      void listener.then(stop => stop());
    };
  }, [apply, attempt]);
  const save = async (next: SidebarLayoutConfig) => {
    if (!ready || saving.current) return;
    saving.current = true; sequence.current++; setPending(true); setError(null);
    apply(next);
    let succeeded = false;
    try {
      await invoke("save_sidebar_layout", { layout: normalizeSidebarLayout(next) });
      succeeded = true;
    } catch (reason) { setError("侧栏设置保存失败：" + String(reason)); }
    finally {
      saving.current = false;
      // Disable edits until the authoritative read completes. An event can
      // supersede this read; its newer read then owns re-enabling controls.
      // Never roll back over a newer event with a captured pre-save snapshot.
      setReady(false);
      await refresh.current(succeeded);
      setPending(false);
    }
  };
  return { layout, ready, pending, error, save, retry: () => setAttempt(value => value + 1) };
}

import { useEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { callCommandStrict } from "../api/command";
import { checkAppUpdate, installAppUpdate, manualUpdateFailureMessage, type UpdateAvailability } from "../api/updateClient";

interface MigrationDiagnostics {
  attemptId: string | null;
  path: string | null;
  persistenceError: string | null;
  totalEvents: number;
  preview: string[];
}

/** No dashboard, settings owner or business DB is needed to diagnose/update. */
export function BusinessRecoveryActions({ onRetry }: { onRetry: () => void }) {
  const [diagnostics, setDiagnostics] = useState<MigrationDiagnostics | null>(null);
  const [message, setMessage] = useState("");
  const [logMessage, setLogMessage] = useState("");
  const [update, setUpdate] = useState<Extract<UpdateAvailability, { status: "available" }> | null>(null);
  const [working, setWorking] = useState(false);
  const [exporting, setExporting] = useState(false);
  // Refs close the double-click window before React commits disabled=true.
  const busy = useRef(false), exportingRef = useRef(false), mounted = useRef(true);
  const primary = (() => { try { return getCurrentWindow().label === "main"; } catch { return false; } })();
  useEffect(() => {
    mounted.current = true;
    if (primary) {
      void callCommandStrict<MigrationDiagnostics>("read_business_migration_diagnostics").then(
        state => { if (mounted.current) setDiagnostics(state); },
        error => { if (mounted.current) setLogMessage(`读取诊断失败：${String(error)}`); },
      );
    }
    return () => { mounted.current = false; };
  }, [primary]);

  async function check() {
    if (busy.current) return;
    busy.current = true; setWorking(true); setMessage("正在检查软件更新…"); setUpdate(null);
    try {
      const result = await checkAppUpdate();
      if (mounted.current) {
        setMessage(result.message || (result.status === "available" ? `发现新版本 ${result.version}` : "更新检查完成"));
        setUpdate(result.status === "available" ? result : null);
      }
    } catch (error) { if (mounted.current) setMessage(manualUpdateFailureMessage(error)); }
    finally { busy.current = false; if (mounted.current) setWorking(false); }
  }
  async function install() {
    if (!update || busy.current) return;
    if (!window.confirm(`安装 Codex Token Bar ${update.version}？安装时应用会重启。现有账本与备份不会由此按钮删除。`)) return;
    busy.current = true; setWorking(true); setMessage("正在请求安装软件更新…");
    let started = false;
    try {
      const result = await installAppUpdate(update.version, text => { if (mounted.current) setMessage(text); });
      started = result === "started";
      if (mounted.current) {
        setMessage(started ? "安装已启动，等待应用重启。" : "该更新已不再可用，请重新检查软件更新。");
        if (!started) setUpdate(null);
      }
    } catch (error) { if (mounted.current) setMessage(manualUpdateFailureMessage(error)); }
    finally {
      // Do not start a new DB retry while a native installer is taking over.
      if (!started) { busy.current = false; if (mounted.current) setWorking(false); }
    }
  }
  async function exportLogs() {
    if (exportingRef.current) return;
    exportingRef.current = true; setExporting(true); setLogMessage("正在导出所有保留的迁移日志…");
    try {
      const result = await callCommandStrict<{ path: string; revealError: string | null }>("export_business_migration_diagnostics", undefined, null);
      if (mounted.current) setLogMessage(`日志已保存：${result.path}${result.revealError ? `；打开文件夹失败：${result.revealError}` : ""}`);
    } catch (error) { if (mounted.current) setLogMessage(`导出失败，原日志未删除：${String(error)}`); }
    finally { exportingRef.current = false; if (mounted.current) setExporting(false); }
  }
  if (!primary) return <p>请打开应用主窗口重试、导出日志或检查软件更新。</p>;
  return <div className="business-recovery">
    <div className="business-recovery-actions">
      <button type="button" disabled={working} onClick={() => { if (!busy.current) onRetry(); }}>重试账本准备</button>
      <button type="button" disabled={working} onClick={() => void check()}>检查软件更新</button>
      {update && <button type="button" disabled={working} onClick={() => void install()}>下载并安装 {update.version}</button>}
      <button type="button" disabled={exporting} onClick={() => void exportLogs()}>导出完整迁移日志</button>
    </div>
    {message && <p role="status" aria-live="polite">{message}</p>}
    {logMessage && <p role="status" className="business-recovery-path">{logMessage}</p>}
    {diagnostics?.persistenceError && <p role="alert">日志未能完整写入磁盘：{diagnostics.persistenceError}。下方仅为内存中的最近记录，请先保存这些内容。</p>}
    {diagnostics && <details><summary>本次迁移诊断（最近 {diagnostics.preview.length} / {diagnostics.totalEvents} 条）</summary>
      <p>每次尝试分别保留。导出包含全部已保存的尝试；日志可能包含本机路径，分享前请检查。</p>
      <pre tabIndex={0}>{diagnostics.preview.join("\n") || "尚无日志记录"}</pre>
    </details>}
  </div>;
}

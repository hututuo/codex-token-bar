import { createPortal } from "react-dom";
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { diagnosticJournal, diagnosticEntryText, diagnosticReport } from "../diagnostics/diagnosticJournal";

export function DiagnosticNotice({ summary, logs, buttonOnly = false }: { summary: string; logs: string; buttonOnly?: boolean }) {
  const state = useSyncExternalStore(diagnosticJournal.subscribe, diagnosticJournal.getSnapshot, diagnosticJournal.getSnapshot);
  const [open, setOpen] = useState(false);
  const [copyState, setCopyState] = useState("");
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { if (open) { setCopyState(""); dialog.current?.showModal(); } }, [open]);
  // A local operation outside the shared collector still has an inspectable cause.
  const extra = logs && !state.current.some(entry => entry.detail === logs || entry.detail.includes(logs)) ? logs : "";
  const currentText = state.current.map(diagnosticEntryText).join("\n\n") || "暂无已记录的当前问题";
  const historyText = state.history.map(diagnosticEntryText).join("\n\n") || "暂无历史记录";
  const report = diagnosticReport() + (extra ? `\n\n【当前页面补充诊断】\n${extra}` : "");
  const areaStyle = { width: "100%", height: 150, resize: "vertical" as const, boxSizing: "border-box" as const, fontFamily: "monospace", fontSize: 12 };
  return <div role={buttonOnly ? undefined : "status"} style={{ width: buttonOnly ? "auto" : "100%", minWidth: 0 }}>
    <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
      {!buttonOnly && <span style={{ flex: 1 }}>{summary}</span>}
      <button className={buttonOnly ? "dash-head__action" : undefined} type="button" aria-expanded={open} onClick={() => setOpen(!open)}>{buttonOnly ? "完整日志" : "查看日志"}</button>
    </div>
    {open && createPortal(<dialog ref={dialog} aria-label="完整日志" onCancel={() => setOpen(false)}
      style={{ width: "min(720px, 90vw)", maxHeight: "85vh", overflow: "auto", padding: 20, border: "1px solid var(--border)", borderRadius: 14, background: "var(--panel-solid, white)", color: "var(--text, black)" }}>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 12 }}><strong>完整日志</strong><button type="button" onClick={() => setOpen(false)}>关闭</button></div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
        <small>本次运行 · 历史最多 100 条</small>
        <button type="button" onClick={async () => {
          try { await navigator.clipboard.writeText(report); setCopyState("已复制全部日志"); }
          catch { setCopyState("复制失败，请选中日志手动复制"); }
        }}>一键复制全部日志</button>
      </div>
      <strong>当前问题（{state.current.length}）</strong>
      <textarea aria-label="当前问题日志" readOnly value={currentText + (extra ? `\n\n当前页面补充诊断：\n${extra}` : "")} style={areaStyle} />
      <strong>历史记录（{state.history.length}）</strong>
      <textarea aria-label="历史日志" readOnly value={historyText} style={areaStyle} />
      <span>{copyState}</span>
    </dialog>, document.body)}
  </div>;
}

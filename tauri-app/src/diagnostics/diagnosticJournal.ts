export interface DiagnosticEntry {
  source: string; summary: string; detail: string;
  firstAt: string; lastAt: string; count: number; endedAt?: string;
  outcome?: "recovered" | "changed" | "handled";
}
export function createDiagnosticJournal(now = () => new Date().toISOString()) {
  const active = new Map<string, DiagnosticEntry>();
  let history: DiagnosticEntry[] = [];
  const listeners = new Set<() => void>();
  let state = { current: [] as DiagnosticEntry[], history };
  function emit() {
    history = history.slice(-100);
    state = { current: [...active.values()].sort((a,b) => b.lastAt.localeCompare(a.lastAt)), history: [...history].reverse() };
    listeners.forEach(listener => listener());
  }
  return {
    subscribe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener); }; },
    getSnapshot: () => state,
    update(source: string, summary: string, detail: string, occurredAt?: string, outcome: "recovered" | "handled" = "recovered") {
      const previous = active.get(source);
      const at = occurredAt && Number.isFinite(Date.parse(occurredAt)) ? occurredAt : now();
      if (!detail) {
        if (!previous) return;
        history.push({...previous, endedAt: now(), outcome}); active.delete(source); emit(); return;
      }
      // The same observation can reach this collector through two promise handlers.
      if (previous?.detail === detail && Date.parse(at) - Date.parse(previous.lastAt) < 1000) return;
      if (previous?.detail === detail) {
        active.set(source, {...previous, lastAt: at, count: previous.count + 1});
      } else {
        if (previous) history.push({...previous, endedAt: now(), outcome: "changed"});
        active.set(source, {source, summary, detail, firstAt: at, lastAt: at, count: 1});
      }
      emit();
    },
  };
}
export const diagnosticJournal = createDiagnosticJournal();
export function diagnosticEntryText(entry: DiagnosticEntry) {
  return `${entry.summary}\n来源：${entry.source}\n首次：${entry.firstAt}\n最近：${entry.lastAt} · 次数：${entry.count}${entry.endedAt ? `\n${entry.outcome === "recovered" ? "恢复" : entry.outcome === "handled" ? "已转交处理（不代表恢复）" : "错误变化"}：${entry.endedAt}` : ""}\n${entry.detail}`;
}
export function diagnosticReport() {
  const {current, history} = diagnosticJournal.getSnapshot();
  return `Codex Token Bar · 跨平台端\n环境：${typeof navigator === "undefined" ? "test" : navigator.userAgent}\n导出时间：${new Date().toISOString()}\n记录范围：本次运行；历史最多 100 条\n\n【当前问题】\n${current.map(diagnosticEntryText).join("\n\n") || "暂无已记录的当前问题"}\n\n【历史记录】\n${history.map(diagnosticEntryText).join("\n\n") || "暂无历史记录"}`;
}

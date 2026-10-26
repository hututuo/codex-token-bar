import { useEffect, useRef, useState, type KeyboardEvent, type PointerEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { clientBrand, quotaWindowTitle, type QuotaItem, type QuotaSelection } from "../multiClient/integratedClientModel";
import { clientTitle } from "../multiClient/useClientScope";
import { DEFAULT_SIDEBAR_LAYOUT, isSidebarItemVisible, moveSidebarItem, normalizeSidebarLayout, setSidebarItemLevelVisible, type SidebarLayoutConfig } from "./sidebarLayoutModel";
import { quotaWindowsForClient, sidebarItemTitle, sidebarLayoutItems } from "./sidebarLayoutPresentation";

type Target = { id: string; after: boolean };
type PointerDrag = { id: string; pointer: number; x: number; y: number; active: boolean; handle: HTMLButtonElement };
export function SidebarModuleSettings({ layout, catalog, selection, disabled = false, hasCodex = true,
  onLayout, onSelection, onHighlight, onDragState, compactPreview, colorSettings }: {
  layout: SidebarLayoutConfig; catalog: readonly QuotaItem[]; selection: QuotaSelection;
  disabled?: boolean; hasCodex?: boolean;
  onLayout: (next: SidebarLayoutConfig) => void; onSelection: (next: QuotaSelection) => void;
  onHighlight?: (id: string | null) => void; onDragState?: (active: boolean) => void; compactPreview?: ReactNode; colorSettings?: ReactNode;
}) {
  const items = sidebarLayoutItems(layout, catalog, hasCodex);
  const [selected, setSelected] = useState(() => items.find(id => id.startsWith("quota:")) ?? items[0] ?? null);
  const [dragging, setDragging] = useState<string | null>(null), [target, setTarget] = useState<Target | null>(null);
  const [ghost, setGhost] = useState<{ x: number; y: number; title: string } | null>(null);
  const [keyboardDraft, setKeyboardDraft] = useState<SidebarLayoutConfig | null>(null);
  const pointer = useRef<PointerDrag | null>(null), frame = useRef<number | null>(null), hoverLockUntil = useRef(0);
  const keyboard = useRef<{ id: string; draft: SidebarLayoutConfig } | null>(null);
  const root = useRef<HTMLElement>(null);
  const draftItems = keyboardDraft ? sidebarLayoutItems(keyboardDraft, catalog, hasCodex) : items;
  const title = (id: string) => sidebarItemTitle(id, clientTitle);
  useEffect(() => { onHighlight?.(selected); }, [selected, onHighlight]);
  useEffect(() => { onDragState?.(dragging !== null); }, [dragging, onDragState]);
  useEffect(() => () => onDragState?.(false), [onDragState]);
  useEffect(() => () => { if (frame.current !== null) cancelAnimationFrame(frame.current); onHighlight?.(null); }, [onHighlight]);
  const pickTarget = (x: number, y: number): Target | null => {
    const row = document.elementFromPoint(x, y)?.closest<HTMLElement>("[data-layout-item]");
    if (!row || !root.current?.contains(row) || row.dataset.layoutItem === pointer.current?.id) return null;
    const rect = row.getBoundingClientRect();
    return { id: row.dataset.layoutItem!, after: y > rect.top + rect.height / 2 };
  };
  const updatePointer = (x: number, y: number) => {
    const drag = pointer.current;
    if (!drag || (!drag.active && Math.hypot(x - drag.x, y - drag.y) < 4)) return;
    drag.active = true; setDragging(drag.id); setGhost({ x: x + 9, y: y - 18, title: title(drag.id) });
    setTarget(pickTarget(x, y));
  };
  const finishPointer = (apply: boolean, x?: number, y?: number) => {
    const drag = pointer.current;
    if (!drag) return;
    if (frame.current !== null) { cancelAnimationFrame(frame.current); frame.current = null; }
    const at = x == null || y == null ? null : pickTarget(x, y);
    if (apply && drag.active && at) onLayout(moveSidebarItem(layout, drag.id, at.id, at.after));
    if (drag.handle.hasPointerCapture?.(drag.pointer)) drag.handle.releasePointerCapture(drag.pointer);
    pointer.current = null; setDragging(null); setGhost(null); setTarget(null);
    hoverLockUntil.current = performance.now() + 500; setSelected(drag.id);
  };
  const beginPointer = (event: PointerEvent<HTMLButtonElement>, id: string) => {
    if (disabled || event.button !== 0) return;
    event.preventDefault(); event.stopPropagation(); event.currentTarget.focus(); setSelected(id);
    keyboard.current = null; setKeyboardDraft(null);
    pointer.current = { id, pointer: event.pointerId, x: event.clientX, y: event.clientY, active: false, handle: event.currentTarget };
    event.currentTarget.setPointerCapture(event.pointerId);
  };
  const keyboardMove = (event: KeyboardEvent<HTMLButtonElement>, id: string) => {
    if (disabled) return;
    if (event.key === " " || event.key === "Enter") {
      event.preventDefault();
      if (keyboard.current) { onLayout(keyboard.current.draft); keyboard.current = null; setKeyboardDraft(null); setDragging(null); }
      else { keyboard.current = { id, draft: normalizeSidebarLayout(layout) }; setKeyboardDraft(keyboard.current.draft); setDragging(id); }
      setSelected(id);
    } else if (keyboard.current && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
      event.preventDefault();
      const order = sidebarLayoutItems(keyboard.current.draft, catalog, hasCodex), from = order.indexOf(id);
      const at = order[from + (event.key === "ArrowUp" ? -1 : 1)];
      if (at) { keyboard.current.draft = moveSidebarItem(keyboard.current.draft, id, at, event.key === "ArrowDown"); setKeyboardDraft(keyboard.current.draft); }
    } else if (keyboard.current && event.key === "Escape") {
      event.preventDefault(); keyboard.current = null; setKeyboardDraft(null); setDragging(null);
    }
  };
  return <section className="qs-module-settings qs-linked-settings" aria-label="侧栏设置" ref={root}
    onPointerMove={event => {
      if (pointer.current) {
        if (frame.current !== null) cancelAnimationFrame(frame.current);
        const x = event.clientX, y = event.clientY;
        frame.current = requestAnimationFrame(() => { frame.current = null; updatePointer(x, y); });
      } else if (!keyboard.current && performance.now() >= hoverLockUntil.current) {
        const row = (event.target as Element).closest<HTMLElement>("[data-layout-item]");
        if (row) setSelected(row.dataset.layoutItem!);
      }
    }}
    onPointerUp={event => finishPointer(true, event.clientX, event.clientY)}
    onPointerCancel={() => finishPointer(false)}>
    <div className="qs-section-heading"><h3>侧栏设置</h3><button disabled={disabled} onClick={() => {
      const extras = layout.order.filter(id => !DEFAULT_SIDEBAR_LAYOUT.order.includes(id));
      const order = [...DEFAULT_SIDEBAR_LAYOUT.order]; order.splice(5, 0, ...extras);
      onLayout({ ...layout, order });
    }}>恢复默认顺序</button></div>
    <p>拖动排序；一级、二级分别勾选。指向一行，侧栏对应模块高亮。</p>
    <details className="qs-compact-details"><summary>查看收起后的一级外观 <small>仅预览</small></summary>
      <CompactPreview>{compactPreview}</CompactPreview>
    </details>
    <ol>{draftItems.map(id => {
      const windows = id.startsWith("quota:") ? quotaWindowsForClient(catalog, id.slice(6)) : [];
      const supportsCompact = id === "speed" || id === "models" || id === "tasks" || id.startsWith("quota:");
      const compactVisible = supportsCompact && isSidebarItemVisible(layout, id, "compact"), expandedVisible = isSidebarItemVisible(layout, id, "expanded"), active = selected === id;
      return <li key={id} data-layout-item={id} data-highlighted={active} data-dragging={dragging === id}
        data-insert={target?.id === id ? target.after ? "after" : "before" : undefined}>
        <div className="qs-layout-row">
          <button className="qs-reorder-handle" disabled={disabled} aria-label={"拖动排序：" + title(id)}
            aria-pressed={dragging === id} onPointerDown={event => beginPointer(event, id)}
            onKeyDown={event => keyboardMove(event, id)} onFocus={() => setSelected(id)}>
            <svg viewBox="0 0 10 18" width="10" height="18" aria-hidden="true">{[4, 9, 14].map(y => <g key={y}><circle cx="3" cy={y} r="1.1"/><circle cx="7" cy={y} r="1.1"/></g>)}</svg>
          </button>
          <span className="qs-layout-name">{id.startsWith("quota:") && <i className="qs-client-dot" style={{ background: clientBrand[id.slice(6)] ?? "#888" }}/>}<span>{title(id)}</span></span>
          <span className="qs-level-toggles">
            {supportsCompact ? <label><input type="checkbox" checked={compactVisible} disabled={disabled} aria-label={"一级显示" + title(id)} onChange={event => {
              setSelected(id); onLayout(setSidebarItemLevelVisible(layout, id, "compact", event.target.checked));
            }}/>一级</label> : <span title="此模块只在二级菜单显示">—</span>}
            <label><input type="checkbox" checked={expandedVisible} disabled={disabled} aria-label={"二级显示" + title(id)} onChange={event => {
              setSelected(id); onLayout(setSidebarItemLevelVisible(layout, id, "expanded", event.target.checked));
            }}/>二级</label>
          </span>
        </div>
        {!!windows.length && <div className="qs-layout-windows">{windows.map(window => <label key={window.id}><input type="checkbox" disabled={disabled || (!compactVisible && !expandedVisible)}
          checked={!selection.hidden.includes(window.id)} aria-label={title(id) + " " + quotaWindowTitle(window.window)}
          onChange={event => {
            setSelected(id); onSelection({ ...selection,
              hidden: event.target.checked ? selection.hidden.filter(v => v !== window.id) : [...new Set([...selection.hidden, window.id])],
              enabled: event.target.checked ? [...new Set([...selection.enabled, window.id])] : selection.enabled.filter(v => v !== window.id),
            });
          }}/>{quotaWindowTitle(window.window)}</label>)}</div>}
      </li>;
    })}</ol>
    <p>显示范围跟随主页面；隐藏项目保留顺序，设置入口固定在底部。</p>
    {colorSettings && <details><summary>额度填充颜色</summary>{colorSettings}</details>}
    {ghost && createPortal(<div className="qs-layout-drag-ghost" aria-hidden="true" style={{ left: ghost.x, top: ghost.y }}>{ghost.title}</div>, document.body)}
  </section>;
}
function CompactPreview({ children }: { children: ReactNode }) {
  const [open, setOpen] = useState(false), ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const detail = ref.current?.closest("details");
    if (!detail) return;
    const update = () => setOpen(detail.open);
    detail.addEventListener("toggle", update); update();
    return () => detail.removeEventListener("toggle", update);
  }, []);
  return <div className="qs-compact-preview" ref={ref}>{open && <>{children}<span>仅预览收起状态。<br/>设置打开时，侧栏保持二级菜单。</span></>}</div>;
}

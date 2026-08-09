import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type DragEvent,
  type KeyboardEvent,
} from "react";
import type {
  FloatingContentGroup,
  FloatingContentVisibility,
  FloatingPanelSnapshot,
  RunningThreadSummary,
} from "../../types/dashboard";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import {
  DEFAULT_FLOATING_CONTENT_VISIBILITY,
  FLOATING_CONTENT_LABELS,
  FLOATING_PAGE_CAPABLE_GROUPS,
  editorGroupsForFloatingRow,
  isFloatingGroupVisible,
  layoutFloatingContentRows,
  mergeFloatingPage,
  moveFloatingRow,
  placeFloatingPageAfterTarget,
  sanitizeFloatingContentVisibility,
  setFloatingGroupsVisible,
  splitFloatingPage,
  swapFloatingDefaultPage,
  type FloatingContentLayoutRow,
  type FloatingContentRowPlacement,
} from "../../floating/floatingContent";
import { FloatingPanelSurface } from "../../floating/FloatingPanelPreview";

interface FloatingStructureEditorProps {
  settings: FloatingWindowSettings;
  snapshot: FloatingPanelSnapshot;
  runningThreads: RunningThreadSummary;
  visibility: FloatingContentVisibility;
  onChange: (visibility: FloatingContentVisibility) => void;
}

type EditorDragState =
  | { kind: "row"; groups: FloatingContentGroup[]; rowId: string }
  | { kind: "page"; group: FloatingContentGroup };

interface EditorRow {
  id: string;
  layoutRow: FloatingContentLayoutRow;
  groups: FloatingContentGroup[];
}

interface UndoState {
  previous: FloatingContentVisibility;
  message: string;
  token: number;
}

export function FloatingStructureEditor({
  settings,
  snapshot,
  runningThreads,
  visibility: rawVisibility,
  onChange,
}: FloatingStructureEditorProps) {
  const visibility = sanitizeFloatingContentVisibility(rawVisibility);
  const rows = useMemo<EditorRow[]>(() => layoutFloatingContentRows(visibility).map((layoutRow) => ({
    id: layoutRow.id,
    layoutRow,
    groups: editorGroupsForFloatingRow(visibility, layoutRow),
  })), [visibility]);
  const hiddenRows = useMemo(() => hiddenEditorRows(visibility), [visibility]);
  const [dragState, setDragState] = useState<EditorDragState | null>(null);
  const [dropTargetId, setDropTargetId] = useState<string | null>(null);
  const [menuRowId, setMenuRowId] = useState<string | null>(null);
  const [selectedRowId, setSelectedRowId] = useState<string | null>(rows[0]?.id ?? null);
  const [undoState, setUndoState] = useState<UndoState | null>(null);
  const [resetPending, setResetPending] = useState(false);
  const rowRefs = useRef(new Map<string, HTMLDivElement>());
  const menuRootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (selectedRowId !== null && rows.some((row) => row.id === selectedRowId)) return;
    setSelectedRowId(rows[0]?.id ?? null);
  }, [rows, selectedRowId]);

  useEffect(() => {
    if (undoState === null) return undefined;
    const token = undoState.token;
    const timer = window.setTimeout(() => {
      setUndoState((current) => current?.token === token ? null : current);
    }, 3_000);
    return () => window.clearTimeout(timer);
  }, [undoState]);

  useEffect(() => {
    if (menuRowId === null) return undefined;
    const close = (event: PointerEvent) => {
      if (!menuRootRef.current?.contains(event.target as Node)) setMenuRowId(null);
    };
    document.addEventListener("pointerdown", close);
    return () => document.removeEventListener("pointerdown", close);
  }, [menuRowId]);

  const commit = (nextValue: FloatingContentVisibility, message: string) => {
    const next = sanitizeFloatingContentVisibility(nextValue);
    if (JSON.stringify(next) === JSON.stringify(visibility)) return;
    setUndoState({ previous: visibility, message, token: Date.now() });
    onChange(next);
  };

  const selectPreviewRow = (rowId: string) => {
    setSelectedRowId(rowId);
    rowRefs.current.get(rowId)?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  };

  const moveRowRelative = (row: EditorRow, target: EditorRow, placement: FloatingContentRowPlacement) => {
    commit({
      ...visibility,
      order: moveFloatingRow(visibility.order, row.groups, target.groups, placement),
    }, `已移动「${rowTitle(row)}」`);
  };

  const clearDragState = () => {
    setDragState(null);
    setDropTargetId(null);
  };

  const canDropIntoGap = (target: EditorRow, placement: FloatingContentRowPlacement) => {
    if (dragState?.kind === "page") {
      const nextPairs = splitFloatingPage(visibility.pagePairs, dragState.group);
      const nextOrder = moveFloatingRow(visibility.order, [dragState.group], target.groups, placement);
      return JSON.stringify(nextPairs) !== JSON.stringify(visibility.pagePairs)
        || JSON.stringify(nextOrder) !== JSON.stringify(visibility.order);
    }
    if (dragState?.kind !== "row") return false;
    const source = rows.find((row) => row.id === dragState.rowId);
    if (!source || source.id === target.id) return false;
    const nextOrder = moveFloatingRow(visibility.order, source.groups, target.groups, placement);
    return JSON.stringify(nextOrder) !== JSON.stringify(visibility.order);
  };

  const canMergePageInto = (group: FloatingContentGroup, target: FloatingContentGroup) => {
    if (
      group === target
      || !FLOATING_PAGE_CAPABLE_GROUPS.includes(group)
      || !FLOATING_PAGE_CAPABLE_GROUPS.includes(target)
    ) return false;
    const next = setFloatingGroupsVisible({
      ...visibility,
      order: placeFloatingPageAfterTarget(visibility.order, group, target),
      pagePairs: mergeFloatingPage(visibility.pagePairs, group, target),
    }, [group, target], true);
    return JSON.stringify(next) !== JSON.stringify(visibility);
  };

  const moveRowBy = (row: EditorRow, delta: -1 | 1) => {
    const index = rows.findIndex((candidate) => candidate.id === row.id);
    const target = rows[index + delta];
    if (!target) return;
    moveRowRelative(row, target, delta < 0 ? "before" : "after");
    setMenuRowId(null);
  };

  const mergePageInto = (group: FloatingContentGroup, target: FloatingContentGroup) => {
    if (
      group === target
      || !FLOATING_PAGE_CAPABLE_GROUPS.includes(group)
      || !FLOATING_PAGE_CAPABLE_GROUPS.includes(target)
    ) return;
    const oldPartner = visibility.pagePairs.find((pair) => pair.includes(target))
      ?.find((candidate) => candidate !== target);
    const nextPairs = mergeFloatingPage(visibility.pagePairs, group, target);
    const next = setFloatingGroupsVisible({
      ...visibility,
      order: placeFloatingPageAfterTarget(visibility.order, group, target),
      pagePairs: nextPairs,
    }, [group, target], true);
    commit(next, oldPartner
      ? `已将「${title(group)}」与「${title(target)}」成组，「${title(oldPartner)}」已恢复单独显示`
      : `已将「${title(group)}」与「${title(target)}」成组`);
  };

  const splitPage = (group: FloatingContentGroup) => {
    commit({
      ...visibility,
      pagePairs: splitFloatingPage(visibility.pagePairs, group),
    }, `已拆分「${title(group)}」所在的翻页行`);
    setMenuRowId(null);
  };

  const hideRow = (row: EditorRow) => {
    commit(setFloatingGroupsVisible(visibility, row.groups, false), `已隐藏「${rowTitle(row)}」`);
    setMenuRowId(null);
  };

  const restoreHidden = (groups: FloatingContentGroup[]) => {
    commit(setFloatingGroupsVisible(visibility, groups, true), `已恢复「${groups.map(title).join("、")}」`);
  };

  const swapDefault = (group: FloatingContentGroup) => {
    commit({
      ...visibility,
      pagePairs: swapFloatingDefaultPage(visibility.pagePairs, group),
    }, `已将「${title(group)}」设为默认页`);
    setMenuRowId(null);
  };

  const dropOnRow = (event: DragEvent<HTMLDivElement>, target: EditorRow) => {
    event.preventDefault();
    event.stopPropagation();
    if (dragState?.kind === "row") {
      const source = rows.find((row) => row.id === dragState.rowId);
      if (source && source.id !== target.id) {
        const rect = event.currentTarget.getBoundingClientRect();
        moveRowRelative(source, target, event.clientY < rect.top + rect.height / 2 ? "before" : "after");
      }
    } else if (dragState?.kind === "page" && canMergePageInto(dragState.group, target.layoutRow.groups[0])) {
      mergePageInto(dragState.group, target.layoutRow.groups[0]);
    }
    clearDragState();
  };

  const dropIntoGap = (
    event: DragEvent<HTMLDivElement>,
    target: EditorRow,
    placement: FloatingContentRowPlacement,
  ) => {
    event.preventDefault();
    event.stopPropagation();
    if (dragState?.kind === "row") {
      const source = rows.find((row) => row.id === dragState.rowId);
      if (source && source.id !== target.id) moveRowRelative(source, target, placement);
    } else if (dragState?.kind === "page") {
      const nextPairs = splitFloatingPage(visibility.pagePairs, dragState.group);
      const nextOrder = moveFloatingRow(
        visibility.order,
        [dragState.group],
        target.groups,
        placement,
      );
      commit({ ...visibility, order: nextOrder, pagePairs: nextPairs }, `已将「${title(dragState.group)}」拆成单独一行`);
    }
    clearDragState();
  };

  const dropIntoHidden = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    event.stopPropagation();
    if (dragState?.kind === "row") {
      commit(
        setFloatingGroupsVisible(visibility, dragState.groups, false),
        `已隐藏「${dragState.groups.map(title).join(" · ")}」`,
      );
    } else if (dragState?.kind === "page") {
      commit(
        setFloatingGroupsVisible(visibility, [dragState.group], false),
        `已隐藏「${title(dragState.group)}」`,
      );
    }
    clearDragState();
  };

  return (
    <div className={`floating-structure-shell${dragState ? " is-dragging" : ""}`}>
      <header className="floating-structure-intro">
        <div>
          <strong>悬浮窗布局</strong>
          <span>每一行就是悬浮窗的一行；拖动行排序，拖到“已隐藏”即可隐藏。</span>
        </div>
        <div className="floating-structure-actions">
          <label className="fs-arrow-toggle">
            <input
              checked={visibility.showPageNavigationArrows}
              onChange={(event) => commit(
                { ...visibility, showPageNavigationArrows: event.currentTarget.checked },
                event.currentTarget.checked ? "已显示翻页箭头" : "已隐藏翻页箭头",
              )}
              type="checkbox"
            />
            <span>显示翻页箭头</span>
          </label>
          <button onClick={() => setResetPending(true)} type="button">恢复默认布局</button>
        </div>
      </header>

      <div className="floating-structure-grid">
        <section aria-label="悬浮窗结构编辑器" className="floating-structure-editor">
          <div className="floating-structure-editor__label">结构编辑器</div>
          <div className="floating-structure-rows">
            {rows.map((row, index) => {
              const paged = row.layoutRow.groups.length > 1;
              const inline = row.groups.length > row.layoutRow.groups.length;
              return (
                <div key={row.id}>
                  <div
                    aria-hidden="true"
                    className={`fs-drop-gap${dropTargetId === `gap:${row.id}:before` ? " is-target" : ""}`}
                    onDragEnter={() => canDropIntoGap(row, "before") && setDropTargetId(`gap:${row.id}:before`)}
                    onDragOver={(event) => {
                      if (!canDropIntoGap(row, "before")) return;
                      event.preventDefault();
                      setDropTargetId(`gap:${row.id}:before`);
                    }}
                    onDrop={(event) => dropIntoGap(event, row, "before")}
                  />
                  <div
                    className={`fs-row${paged ? " is-paged" : ""}${inline ? " is-inline" : ""}${selectedRowId === row.id ? " is-selected" : ""}${dropTargetId === `row:${row.id}` ? " is-drop-target" : ""}`}
                    data-row-id={row.id}
                    onDragOver={(event) => {
                      if (dragState?.kind === "row") {
                        const rect = event.currentTarget.getBoundingClientRect();
                        const placement = event.clientY < rect.top + rect.height / 2 ? "before" : "after";
                        if (!canDropIntoGap(row, placement)) return;
                        event.preventDefault();
                        setDropTargetId(`gap:${row.id}:${placement}`);
                      } else if (
                        dragState?.kind === "page"
                        && canMergePageInto(dragState.group, row.layoutRow.groups[0])
                      ) {
                        event.preventDefault();
                        setDropTargetId(`row:${row.id}`);
                      }
                    }}
                    onDrop={(event) => dropOnRow(event, row)}
                    onMouseEnter={() => setSelectedRowId(row.id)}
                    ref={(node) => {
                      if (node) rowRefs.current.set(row.id, node);
                      else rowRefs.current.delete(row.id);
                    }}
                  >
                    {paged ? <span className="fs-row-badge">翻页行 · 2 页</span> : null}
                    <button
                      aria-label={`拖动整行：${rowTitle(row)}`}
                      className="fs-row-handle"
                      draggable
                      onDragEnd={clearDragState}
                      onDragStart={(event) => {
                        event.dataTransfer.effectAllowed = "move";
                        event.dataTransfer.setData("text/plain", `row:${row.id}`);
                        setDragState({ kind: "row", groups: row.groups, rowId: row.id });
                      }}
                      onKeyDown={(event: KeyboardEvent<HTMLButtonElement>) => {
                        if (!event.ctrlKey) return;
                        if (event.key === "ArrowUp") {
                          event.preventDefault();
                          moveRowBy(row, -1);
                        } else if (event.key === "ArrowDown") {
                          event.preventDefault();
                          moveRowBy(row, 1);
                        }
                      }}
                      type="button"
                    >拖动</button>
                    <div className="fs-row-pages">
                      {row.groups.map((group, groupIndex) => {
                        const isInline = inline && !row.layoutRow.groups.includes(group);
                        const canPage = FLOATING_PAGE_CAPABLE_GROUPS.includes(group) && !isInline;
                        const isDefault = paged && groupIndex === 0;
                        return (
                          <button
                            className={`fs-chip${isDefault ? " is-default" : ""}${isInline ? " is-inline" : ""}${canPage ? " is-draggable" : ""}`}
                            draggable={canPage}
                            key={group}
                            onDragEnd={clearDragState}
                            onDragStart={canPage ? (event) => {
                              event.stopPropagation();
                              event.dataTransfer.effectAllowed = "move";
                              event.dataTransfer.setData("text/plain", `page:${group}`);
                              setDragState({ kind: "page", group });
                            } : undefined}
                            onDoubleClick={!isDefault && paged ? () => swapDefault(group) : undefined}
                            title={canPage ? "拖到另一行成组，拖到行间拆分" : "内联内容随整行移动"}
                            type="button"
                          >
                            {isDefault ? <span aria-hidden="true">★</span> : null}
                            <strong>{title(group)}</strong>
                            {isDefault ? <em>默认页</em> : null}
                            {isInline ? <em>内联</em> : null}
                          </button>
                        );
                      })}
                    </div>
                    {paged ? <span aria-label="悬浮窗内可左右翻页" className="fs-page-mark">‹ ›</span> : null}
                    <button aria-label={`隐藏${rowTitle(row)}`} className="fs-visibility" onClick={() => hideRow(row)} type="button">隐藏</button>
                    <div className="fs-menu-root" ref={menuRowId === row.id ? menuRootRef : undefined}>
                      <button
                        aria-expanded={menuRowId === row.id}
                        aria-haspopup="menu"
                        aria-label={`${rowTitle(row)}更多操作`}
                        className="fs-more"
                        onClick={() => setMenuRowId((current) => current === row.id ? null : row.id)}
                        type="button"
                      >更多</button>
                      {menuRowId === row.id ? (
                        <div className="fs-row-menu" role="menu">
                          <button disabled={index === 0} onClick={() => moveRowBy(row, -1)} role="menuitem" type="button">整行上移</button>
                          <button disabled={index === rows.length - 1} onClick={() => moveRowBy(row, 1)} role="menuitem" type="button">整行下移</button>
                          {paged ? <button onClick={() => splitPage(row.layoutRow.groups[1])} role="menuitem" type="button">拆分组合</button> : null}
                          {paged ? <button onClick={() => swapDefault(row.layoutRow.groups[1])} role="menuitem" type="button">交换默认页</button> : null}
                          <button onClick={() => hideRow(row)} role="menuitem" type="button">隐藏此行</button>
                        </div>
                      ) : null}
                    </div>
                  </div>
                </div>
              );
            })}
            {rows.length > 0 ? (
              <div
                aria-hidden="true"
                className={`fs-drop-gap fs-drop-gap--last${dropTargetId === `gap:${rows[rows.length - 1].id}:after` ? " is-target" : ""}`}
                onDragEnter={() => canDropIntoGap(rows[rows.length - 1], "after") && setDropTargetId(`gap:${rows[rows.length - 1].id}:after`)}
                onDragOver={(event) => {
                  const target = rows[rows.length - 1];
                  if (!canDropIntoGap(target, "after")) return;
                  event.preventDefault();
                  setDropTargetId(`gap:${target.id}:after`);
                }}
                onDrop={(event) => dropIntoGap(event, rows[rows.length - 1], "after")}
              />
            ) : null}
          </div>

          <div
            className={`fs-hidden-zone${dropTargetId === "hidden" ? " is-drop-target" : ""}`}
            onDragEnter={() => dragState && setDropTargetId("hidden")}
            onDragOver={(event) => {
              if (!dragState) return;
              event.preventDefault();
              setDropTargetId("hidden");
            }}
            onDrop={dropIntoHidden}
          >
            <div>
              <strong>已隐藏</strong>
              <span>{dropTargetId === "hidden" ? "松手即可隐藏" : "拖到这里隐藏；恢复后回到原位置。"}</span>
            </div>
            {hiddenRows.length === 0 ? <p>没有隐藏内容</p> : hiddenRows.map((groups) => (
              <button key={groups.join("|")} onClick={() => restoreHidden(groups)} type="button">
                <span>{groups.map(title).join(" · ")}</span>
                <strong>恢复</strong>
              </button>
            ))}
          </div>
        </section>

        <section aria-label="悬浮窗实时预览" className="floating-structure-preview">
          <div className="floating-structure-preview__label">
            <strong>实时预览</strong>
            <span>点击预览中的行可定位左侧结构</span>
          </div>
          <div className="floating-structure-preview__stage">
            <FloatingPanelSurface
              previewMode
              onPreviewRowSelect={selectPreviewRow}
              runningThreads={runningThreads}
              selectedPreviewRowId={selectedRowId}
              settings={{ ...settings, contentVisibility: visibility }}
              snapshot={snapshot}
              unreadEffect="off"
            />
          </div>
        </section>
      </div>

      <footer className="floating-structure-footer">
        <span>费用口径：真实模型与缓存价格；未知模型使用回退模型，Spark 为独立额度。</span>
      </footer>

      {undoState ? (
        <div aria-live="polite" className="fs-undo-bar">
          <span>{undoState.message}</span>
          <button onClick={() => {
            onChange(undoState.previous);
            setUndoState(null);
          }} type="button">撤销</button>
        </div>
      ) : null}

      {resetPending ? (
        <div className="fs-reset-confirm" role="alertdialog" aria-label="恢复默认布局确认">
          <span>恢复默认显示、顺序、翻页箭头和“模型占比 → 模型费用”组合？</span>
          <button onClick={() => setResetPending(false)} type="button">取消</button>
          <button onClick={() => {
            setResetPending(false);
            commit(DEFAULT_FLOATING_CONTENT_VISIBILITY, "已恢复默认悬浮窗布局");
          }} type="button">恢复</button>
        </div>
      ) : null}
    </div>
  );
}

function hiddenEditorRows(visibility: FloatingContentVisibility): FloatingContentGroup[][] {
  const hidden = new Set(visibility.order.filter((group) => !isFloatingGroupVisible(visibility, group)));
  const consumed = new Set<FloatingContentGroup>();
  const result: FloatingContentGroup[][] = [];
  for (const group of visibility.order) {
    if (!hidden.has(group) || consumed.has(group)) continue;
    const pair = visibility.pagePairs.find((candidate) => candidate.includes(group));
    if (pair && pair.every((candidate) => hidden.has(candidate))) {
      result.push([...pair]);
      pair.forEach((candidate) => consumed.add(candidate));
      continue;
    }
    const inlinePartner = inlinePartnerForHiddenGroup(visibility, group);
    if (inlinePartner && hidden.has(inlinePartner) && !consumed.has(inlinePartner)) {
      const ordered = visibility.order.filter((candidate) => candidate === group || candidate === inlinePartner);
      result.push(ordered);
      ordered.forEach((candidate) => consumed.add(candidate));
      continue;
    }
    result.push([group]);
    consumed.add(group);
  }
  return result;
}

function inlinePartnerForHiddenGroup(
  visibility: FloatingContentVisibility,
  group: FloatingContentGroup,
): FloatingContentGroup | null {
  const partner = group === "rateAndBar" ? "usageStatus"
    : group === "usageStatus" ? "rateAndBar"
      : group === "metrics" ? "runningThreads"
        : group === "runningThreads" ? "metrics"
          : null;
  if (partner === null) return null;
  const first = visibility.order.indexOf(group);
  const second = visibility.order.indexOf(partner);
  return first >= 0 && second >= 0 && Math.abs(first - second) === 1 ? partner : null;
}

function rowTitle(row: EditorRow): string {
  return row.groups.map(title).join(" · ");
}

function title(group: FloatingContentGroup): string {
  return FLOATING_CONTENT_LABELS[group].title;
}

import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type DragEvent,
  type KeyboardEvent,
  type PointerEvent as ReactPointerEvent,
} from "react";
import type {
  FloatingContentGroup,
  FloatingContentVisibility,
  FloatingPanelSnapshot,
  RunningThreadSummary,
} from "../../types/dashboard";
import type { CodexRadarSnapshot } from "../../domain/codexRadar/model";
import type { CodexCrowdRadarSnapshot } from "../../api/codexCrowdRadarClient";
import type { OfficialAPIPriceModel } from "../../settings/quotaPriceModel";
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
  showPreview?: boolean;
  selectedRowId?: string | null;
  onSelectedRowIdChange?: (rowId: string | null) => void;
  radarSnapshot?: CodexRadarSnapshot | null;
  crowdRadarSnapshot?: CodexCrowdRadarSnapshot | null;
  priceModel?: OfficialAPIPriceModel;
}

type EditorDragState =
  | { kind: "row"; groups: FloatingContentGroup[]; rowId: string }
  | { kind: "page"; group: FloatingContentGroup };

interface PointerDragSession {
  active: boolean;
  pointerId: number;
  source: EditorDragState;
  startX: number;
  startY: number;
  grabOffsetX: number;
  grabOffsetY: number;
  ghostWidth: number;
  ghostHeight: number;
  visualElement: HTMLElement;
  geometry: PointerDropGeometry;
}

interface ClientRectSnapshot {
  bottom: number;
  height: number;
  left: number;
  right: number;
  top: number;
  width: number;
}

interface PointerDropRowGeometry {
  rowId: string;
  rect: ClientRectSnapshot;
  pagesRect: ClientRectSnapshot | null;
}

interface PointerDropGeometry {
  rowsRect: ClientRectSnapshot | null;
  rows: PointerDropRowGeometry[];
}

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
  showPreview = true,
  selectedRowId: controlledSelectedRowId,
  onSelectedRowIdChange,
  radarSnapshot,
  crowdRadarSnapshot,
  priceModel,
}: FloatingStructureEditorProps) {
  const rawVisibilitySignature = JSON.stringify(sanitizeFloatingContentVisibility(rawVisibility));
  const normalizedRawVisibility = useMemo(
    () => sanitizeFloatingContentVisibility(JSON.parse(rawVisibilitySignature) as FloatingContentVisibility),
    [rawVisibilitySignature],
  );
  const [draftVisibility, setDraftVisibility] = useState(normalizedRawVisibility);
  const visibility = draftVisibility;
  const rows = useMemo<EditorRow[]>(() => layoutFloatingContentRows(visibility).map((layoutRow) => ({
    id: layoutRow.id,
    layoutRow,
    groups: editorGroupsForFloatingRow(visibility, layoutRow),
  })), [visibility]);
  const hiddenRows = useMemo(() => hiddenEditorRows(visibility), [visibility]);
  const [dragState, setDragState] = useState<EditorDragState | null>(null);
  const [dropTargetId, setDropTargetId] = useState<string | null>(null);
  const [menuRowId, setMenuRowId] = useState<string | null>(null);
  const [internalSelectedRowId, setInternalSelectedRowId] = useState<string | null>(rows[0]?.id ?? null);
  const selectedRowId = controlledSelectedRowId === undefined
    ? internalSelectedRowId
    : controlledSelectedRowId;
  const [undoState, setUndoState] = useState<UndoState | null>(null);
  const [resetPending, setResetPending] = useState(false);
  const rowRefs = useRef(new Map<string, HTMLDivElement>());
  const rowsContainerRef = useRef<HTMLDivElement>(null);
  const hiddenZoneRef = useRef<HTMLDivElement>(null);
  const pointerDragRef = useRef<PointerDragSession | null>(null);
  const dragGhostRef = useRef<HTMLDivElement | null>(null);
  const pointerWindowCleanupRef = useRef<(() => void) | null>(null);
  const dropTargetIdRef = useRef<string | null>(null);
  const menuRootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    setDraftVisibility((current) => (
      JSON.stringify(current) === rawVisibilitySignature ? current : normalizedRawVisibility
    ));
  }, [normalizedRawVisibility, rawVisibilitySignature]);

  useEffect(() => {
    if (selectedRowId !== null && rows.some((row) => row.id === selectedRowId)) return;
    const next = rows[0]?.id ?? null;
    setInternalSelectedRowId(next);
    onSelectedRowIdChange?.(next);
  }, [onSelectedRowIdChange, rows, selectedRowId]);

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

  useEffect(() => () => {
    pointerWindowCleanupRef.current?.();
    pointerWindowCleanupRef.current = null;
    dragGhostRef.current?.remove();
    dragGhostRef.current = null;
  }, []);

  const commit = (nextValue: FloatingContentVisibility, message: string) => {
    const next = sanitizeFloatingContentVisibility(nextValue);
    if (JSON.stringify(next) === JSON.stringify(visibility)) return;
    setUndoState({ previous: visibility, message, token: Date.now() });
    setDraftVisibility(next);
    onChange(next);
  };

  const selectPreviewRow = (rowId: string) => {
    setInternalSelectedRowId(rowId);
    onSelectedRowIdChange?.(rowId);
    rowRefs.current.get(rowId)?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  };

  const selectEditorRow = (rowId: string) => {
    setInternalSelectedRowId(rowId);
    onSelectedRowIdChange?.(rowId);
  };

  const moveRowRelative = (row: EditorRow, target: EditorRow, placement: FloatingContentRowPlacement) => {
    commit({
      ...visibility,
      order: moveFloatingRow(visibility.order, row.groups, target.groups, placement),
    }, `已移动「${rowTitle(row)}」`);
  };

  const setActiveDropTarget = (targetId: string | null) => {
    if (dropTargetIdRef.current === targetId) return;
    dropTargetIdRef.current = targetId;
    setDropTargetId(targetId);
  };

  const removeDragGhost = () => {
    dragGhostRef.current?.remove();
    dragGhostRef.current = null;
  };

  const clearDragState = () => {
    pointerWindowCleanupRef.current?.();
    pointerWindowCleanupRef.current = null;
    removeDragGhost();
    pointerDragRef.current = null;
    setDragState(null);
    setActiveDropTarget(null);
  };

  const canDragStateDropIntoGap = (
    source: EditorDragState,
    target: EditorRow,
    placement: FloatingContentRowPlacement,
  ) => {
    if (source.kind === "page") {
      const nextPairs = splitFloatingPage(visibility.pagePairs, source.group);
      const nextOrder = moveFloatingRow(visibility.order, [source.group], target.groups, placement);
      return JSON.stringify(nextPairs) !== JSON.stringify(visibility.pagePairs)
        || JSON.stringify(nextOrder) !== JSON.stringify(visibility.order);
    }
    const sourceRow = rows.find((row) => row.id === source.rowId);
    if (!sourceRow || sourceRow.id === target.id) return false;
    const nextOrder = moveFloatingRow(visibility.order, sourceRow.groups, target.groups, placement);
    return JSON.stringify(nextOrder) !== JSON.stringify(visibility.order);
  };

  const canDropIntoGap = (target: EditorRow, placement: FloatingContentRowPlacement) => (
    dragState !== null && canDragStateDropIntoGap(dragState, target, placement)
  );

  const mergeTargetForRow = (group: FloatingContentGroup, row: EditorRow) => (
    row.layoutRow.groups.find((candidate) => candidate !== group)
      ?? row.layoutRow.groups[0]
  );

  const canMergePageInto = (
    group: FloatingContentGroup,
    row: EditorRow,
    placement: FloatingContentRowPlacement,
  ) => {
    const target = mergeTargetForRow(group, row);
    if (
      target === undefined
      || group === target
      || !FLOATING_PAGE_CAPABLE_GROUPS.includes(group)
      || !FLOATING_PAGE_CAPABLE_GROUPS.includes(target)
    ) return false;
    let nextPairs = mergeFloatingPage(visibility.pagePairs, group, target);
    if (placement === "before") nextPairs = swapFloatingDefaultPage(nextPairs, group);
    const next = setFloatingGroupsVisible({
      ...visibility,
      order: moveFloatingRow(visibility.order, [group], [target], placement),
      pagePairs: nextPairs,
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

  const mergePageInto = (
    group: FloatingContentGroup,
    row: EditorRow,
    placement: FloatingContentRowPlacement,
  ) => {
    const target = mergeTargetForRow(group, row);
    if (
      target === undefined
      || group === target
      || !FLOATING_PAGE_CAPABLE_GROUPS.includes(group)
      || !FLOATING_PAGE_CAPABLE_GROUPS.includes(target)
    ) return;
    const oldPartner = visibility.pagePairs.find((pair) => pair.includes(target))
      ?.find((candidate) => candidate !== target);
    let nextPairs = mergeFloatingPage(visibility.pagePairs, group, target);
    if (placement === "before") nextPairs = swapFloatingDefaultPage(nextPairs, group);
    const next = setFloatingGroupsVisible({
      ...visibility,
      order: moveFloatingRow(visibility.order, [group], [target], placement),
      pagePairs: nextPairs,
    }, [group, target], true);
    commit(next, oldPartner && oldPartner !== group
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
    } else if (dragState?.kind === "page") {
      const placement = pagePlacementForRow(event.currentTarget, event.clientX);
      if (canMergePageInto(dragState.group, target, placement)) {
        mergePageInto(dragState.group, target, placement);
      }
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

  const capturePointerDropGeometry = (): PointerDropGeometry => ({
    rowsRect: snapshotClientRect(rowsContainerRef.current?.getBoundingClientRect()),
    rows: rows.flatMap((row) => {
      const node = rowRefs.current.get(row.id);
      if (!node) return [];
      return [{
        rowId: row.id,
        rect: snapshotClientRect(node.getBoundingClientRect())!,
        pagesRect: snapshotClientRect(node.querySelector<HTMLElement>(".fs-row-pages")?.getBoundingClientRect()),
      }];
    }),
  });

  const pointerDropTarget = (
    source: EditorDragState,
    clientX: number,
    clientY: number,
    geometry: PointerDropGeometry,
  ): string | null => {
    const liveHiddenRect = snapshotClientRect(hiddenZoneRef.current?.getBoundingClientRect());
    if (liveHiddenRect && pointInsideRect(clientX, clientY, liveHiddenRect)) return "hidden";

    // Resolve against the geometry captured before the drag changes any visual
    // state. This keeps insertion slots stable and makes the horizontal editor
    // padding a deliberate cancellation area.
    if (!geometry.rowsRect || !pointInsideRect(clientX, clientY, geometry.rowsRect)) return null;
    if (!geometry.rows.some(({ rect }) => pointInsideHorizontalRect(clientX, rect))) return null;

    const targetForGapIndex = (gapIndex: number): string | null => {
      if (geometry.rows.length === 0 || gapIndex < 0 || gapIndex > geometry.rows.length) return null;
      const targetGeometry = gapIndex === geometry.rows.length
        ? geometry.rows[geometry.rows.length - 1]
        : geometry.rows[gapIndex];
      const placement: FloatingContentRowPlacement = gapIndex === geometry.rows.length ? "after" : "before";
      const target = rows.find((row) => row.id === targetGeometry.rowId);
      if (!target || !canDragStateDropIntoGap(source, target, placement)) return null;
      return `gap:${target.id}:${placement}`;
    };

    const hoveredRowIndex = geometry.rows.findIndex(({ rect }) => pointInsideRect(clientX, clientY, rect));
    if (hoveredRowIndex >= 0) {
      const hoveredGeometry = geometry.rows[hoveredRowIndex];
      const target = rows.find((row) => row.id === hoveredGeometry.rowId);
      if (!target) return null;
      if (source.kind === "page") {
        // Releasing inside the source row is a no-op. Releasing on row actions
        // outside the page strip is also a cancellation, not an implicit merge.
        if (target.groups.includes(source.group)) return null;
        const pagesRect = hoveredGeometry.pagesRect ?? hoveredGeometry.rect;
        if (!pointInsideHorizontalRect(clientX, pagesRect)) return null;
        const placement = pagePlacementForRect(pagesRect, clientX);
        return canMergePageInto(source.group, target, placement)
          ? `page:${target.id}:${placement}`
          : null;
      }
      return targetForGapIndex(
        clientY < hoveredGeometry.rect.top + hoveredGeometry.rect.height / 2
          ? hoveredRowIndex
          : hoveredRowIndex + 1,
      );
    }

    const first = geometry.rows[0];
    if (!first) return null;
    if (clientY < first.rect.top) return targetForGapIndex(0);
    for (let index = 1; index < geometry.rows.length; index += 1) {
      const previous = geometry.rows[index - 1];
      const current = geometry.rows[index];
      if (clientY >= previous.rect.bottom && clientY <= current.rect.top) {
        return targetForGapIndex(index);
      }
    }
    const last = geometry.rows[geometry.rows.length - 1];
    return clientY > last.rect.bottom ? targetForGapIndex(geometry.rows.length) : null;
  };

  const updateDragGhost = (session: PointerDragSession, clientX: number, clientY: number) => {
    const ghost = dragGhostRef.current;
    if (!ghost) return;
    const viewportWidth = Math.max(document.documentElement.clientWidth, window.innerWidth, session.ghostWidth + 16);
    const viewportHeight = Math.max(document.documentElement.clientHeight, window.innerHeight, session.ghostHeight + 16);
    const left = clampDragGhostPosition(
      clientX - session.grabOffsetX,
      session.ghostWidth,
      viewportWidth,
    );
    const top = clampDragGhostPosition(
      clientY - session.grabOffsetY,
      session.ghostHeight,
      viewportHeight,
    );
    ghost.style.transform = `translate3d(${Math.round(left)}px, ${Math.round(top)}px, 0)`;
  };

  const createDragGhost = (session: PointerDragSession, clientX: number, clientY: number) => {
    removeDragGhost();
    const ghost = document.createElement("div");
    ghost.className = `fs-drag-ghost fs-drag-ghost--${session.source.kind}`;
    ghost.setAttribute("aria-hidden", "true");
    ghost.style.width = `${session.ghostWidth}px`;
    ghost.style.height = `${session.ghostHeight}px`;

    const clone = session.visualElement.cloneNode(true) as HTMLElement;
    clone.classList.remove("is-selected", "is-drag-source", "is-drop-target");
    clone.querySelector(".fs-row-menu")?.remove();
    if (clone.matches("button, input, select, textarea, [tabindex]")) clone.tabIndex = -1;
    clone.querySelectorAll<HTMLElement>("button, input, select, textarea, [tabindex]").forEach((node) => {
      node.tabIndex = -1;
    });
    ghost.append(clone);
    document.body.append(ghost);
    dragGhostRef.current = ghost;
    updateDragGhost(session, clientX, clientY);
  };

  const commitPointerDrop = (source: EditorDragState, targetId: string | null) => {
    if (targetId === null) return;
    if (targetId === "hidden") {
      if (source.kind === "row") {
        commit(
          setFloatingGroupsVisible(visibility, source.groups, false),
          `已隐藏「${source.groups.map(title).join(" · ")}」`,
        );
      } else {
        commit(
          setFloatingGroupsVisible(visibility, [source.group], false),
          `已隐藏「${title(source.group)}」`,
        );
      }
      return;
    }

    const [kind, rowId, rawPlacement] = targetId.split(":");
    const placement = rawPlacement === "before" ? "before" : "after";
    const target = rows.find((row) => row.id === rowId);
    if (!target) return;
    if (kind === "page" && source.kind === "page") {
      mergePageInto(source.group, target, placement);
      return;
    }
    if (kind !== "gap") return;
    if (source.kind === "row") {
      const sourceRow = rows.find((row) => row.id === source.rowId);
      if (sourceRow && sourceRow.id !== target.id) moveRowRelative(sourceRow, target, placement);
      return;
    }
    const nextPairs = splitFloatingPage(visibility.pagePairs, source.group);
    const nextOrder = moveFloatingRow(visibility.order, [source.group], target.groups, placement);
    commit(
      { ...visibility, order: nextOrder, pagePairs: nextPairs },
      `已将「${title(source.group)}」拆成单独一行`,
    );
  };

  const beginPointerDrag = (
    event: ReactPointerEvent<HTMLButtonElement>,
    source: EditorDragState,
  ) => {
    if (event.button !== 0 || event.isPrimary === false) return;
    const visualElement = source.kind === "row"
      ? event.currentTarget.closest<HTMLElement>(".fs-row") ?? event.currentTarget
      : event.currentTarget;
    const visualRect = snapshotClientRect(visualElement.getBoundingClientRect());
    const ownerRect = snapshotClientRect(
      event.currentTarget.closest<HTMLElement>(".fs-row")?.getBoundingClientRect(),
    );
    const ownerWidth = ownerRect && ownerRect.width > 0 ? ownerRect.width : 320;
    const ownerHeight = ownerRect && ownerRect.height > 0 ? ownerRect.height : 43;
    const ghostWidth = visualRect && visualRect.width > 0
      ? visualRect.width
      : source.kind === "page" ? Math.min(180, ownerWidth) : ownerWidth;
    const ghostHeight = visualRect && visualRect.height > 0
      ? visualRect.height
      : source.kind === "page" ? Math.min(30, ownerHeight) : ownerHeight;
    const visualLeft = visualRect && visualRect.width > 0
      ? visualRect.left
      : event.clientX - Math.min(ghostWidth / 2, source.kind === "page" ? 24 : ghostWidth / 2);
    const visualTop = visualRect && visualRect.height > 0
      ? visualRect.top
      : event.clientY - Math.min(ghostHeight / 2, 12);
    pointerDragRef.current = {
      active: false,
      pointerId: event.pointerId,
      source,
      startX: event.clientX,
      startY: event.clientY,
      grabOffsetX: Math.max(0, Math.min(ghostWidth, event.clientX - visualLeft)),
      grabOffsetY: Math.max(0, Math.min(ghostHeight, event.clientY - visualTop)),
      ghostWidth,
      ghostHeight,
      visualElement,
      geometry: capturePointerDropGeometry(),
    };
    installPointerWindowListeners();
    try {
      event.currentTarget.setPointerCapture(event.pointerId);
    } catch {
      // Older macOS WebViews may expose PointerEvent without pointer capture.
    }
  };

  const movePointerDragAt = (pointerId: number, clientX: number, clientY: number) => {
    const session = pointerDragRef.current;
    if (!session || session.pointerId !== pointerId) return false;
    if (!session.active) {
      const distance = Math.hypot(clientX - session.startX, clientY - session.startY);
      if (distance < 4) return false;
      session.active = true;
      setDragState(session.source);
      setMenuRowId(null);
      createDragGhost(session, clientX, clientY);
    }
    updateDragGhost(session, clientX, clientY);
    setActiveDropTarget(pointerDropTarget(session.source, clientX, clientY, session.geometry));
    return true;
  };

  const finishPointerDragAt = (pointerId: number, clientX: number, clientY: number) => {
    const session = pointerDragRef.current;
    if (!session || session.pointerId !== pointerId) return false;
    if (session.active) {
      updateDragGhost(session, clientX, clientY);
      // Commit the last target the user actually saw. Switching from a gap
      // preview to the hidden zone can collapse the item-sized gap and move
      // the hidden zone before pointerup is delivered; recomputing here would
      // otherwise turn a visible “松手即可隐藏” state into a silent no-op.
      const finalTarget = dropTargetIdRef.current
        ?? pointerDropTarget(session.source, clientX, clientY, session.geometry);
      commitPointerDrop(session.source, finalTarget);
    }
    const wasActive = session.active;
    clearDragState();
    return wasActive;
  };

  const movePointerDrag = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (!movePointerDragAt(event.pointerId, event.clientX, event.clientY)) return;
    event.preventDefault();
    event.stopPropagation();
  };

  const endPointerDrag = (event: ReactPointerEvent<HTMLButtonElement>) => {
    const handled = finishPointerDragAt(event.pointerId, event.clientX, event.clientY);
    if (handled) {
      event.preventDefault();
      event.stopPropagation();
    }
    try {
      event.currentTarget.releasePointerCapture(event.pointerId);
    } catch {
      // Pointer capture is optional in older macOS WebViews.
    }
  };

  const cancelPointerDrag = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (pointerDragRef.current?.pointerId === event.pointerId) clearDragState();
  };

  const installPointerWindowListeners = () => {
    pointerWindowCleanupRef.current?.();
    // WKWebView versions differ in pointer-capture support. Window listeners
    // keep the drag alive when capture is unavailable and the pointer leaves
    // the small handle/chip that initiated it.
    const move = (event: PointerEvent) => {
      if (movePointerDragAt(event.pointerId, event.clientX, event.clientY)) event.preventDefault();
    };
    const end = (event: PointerEvent) => {
      if (finishPointerDragAt(event.pointerId, event.clientX, event.clientY)) event.preventDefault();
    };
    const cancel = (event: PointerEvent) => {
      if (pointerDragRef.current?.pointerId === event.pointerId) clearDragState();
    };
    const cancelOnBlur = () => clearDragState();
    window.addEventListener("pointermove", move, { passive: false });
    window.addEventListener("pointerup", end, { passive: false });
    window.addEventListener("pointercancel", cancel);
    window.addEventListener("blur", cancelOnBlur);
    pointerWindowCleanupRef.current = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", end);
      window.removeEventListener("pointercancel", cancel);
      window.removeEventListener("blur", cancelOnBlur);
    };
  };

  return (
    <div className={`floating-structure-shell${dragState ? " is-dragging" : ""}`}>
      <header className="floating-structure-intro">
        <div>
          <strong>悬浮窗布局</strong>
          <span>每一行就是悬浮窗的一行；拖动行排序，拖到“已隐藏”即可隐藏。</span>
        </div>
        <div className="floating-structure-actions">
          <label className="fs-arrow-toggle" title="关闭后只隐藏箭头图案，左右边缘仍可点击翻页">
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

      <div className={`floating-structure-grid${showPreview ? "" : " is-controls-only"}`}>
        <section aria-label="悬浮窗结构编辑器" className="floating-structure-editor">
          <div className="floating-structure-editor__label">结构编辑器</div>
          <div className="floating-structure-rows" ref={rowsContainerRef}>
            {rows.map((row, index) => {
              const paged = row.layoutRow.groups.length > 1;
              const inline = row.groups.length > row.layoutRow.groups.length;
              const pagePlacement = dropTargetId === `page:${row.id}:before`
                ? "before"
                : dropTargetId === `page:${row.id}:after`
                  ? "after"
                  : null;
              const draggedPage = dragState?.kind === "page" ? dragState.group : null;
              const pageMergeTarget = draggedPage && pagePlacement
                ? mergeTargetForRow(draggedPage, row)
                : null;
              const inlineGroups = row.groups.filter((group) => !row.layoutRow.groups.includes(group));
              const pageItems: Array<{ group: FloatingContentGroup; placeholder: boolean }> = (
                draggedPage && pagePlacement && pageMergeTarget && pageMergeTarget !== draggedPage
              )
                ? [
                    ...(pagePlacement === "before"
                      ? [
                          { group: draggedPage, placeholder: true },
                          { group: pageMergeTarget, placeholder: false },
                        ]
                      : [
                          { group: pageMergeTarget, placeholder: false },
                          { group: draggedPage, placeholder: true },
                        ]),
                    ...inlineGroups
                      .filter((group) => group !== draggedPage && group !== pageMergeTarget)
                      .map((group) => ({ group, placeholder: false })),
                  ]
                : row.groups.map((group) => ({ group, placeholder: false }));
              const displayPaged = paged || pagePlacement !== null;
              return (
                <div className="fs-row-slot" key={row.id}>
                  <div
                    aria-hidden="true"
                    className={`fs-drop-gap fs-drop-gap--before${dropTargetId === `gap:${row.id}:before` ? " is-target" : ""}`}
                    onDragEnter={() => canDropIntoGap(row, "before") && setDropTargetId(`gap:${row.id}:before`)}
                    onDragOver={(event) => {
                      if (!canDropIntoGap(row, "before")) return;
                      event.preventDefault();
                      setDropTargetId(`gap:${row.id}:before`);
                    }}
                    onDrop={(event) => dropIntoGap(event, row, "before")}
                  >
                    {dropTargetId === `gap:${row.id}:before` ? (
                      <span className="fs-row-placeholder">{draggedItemLabel(dragState)}</span>
                    ) : null}
                  </div>
                  <div
                    className={`fs-row${displayPaged ? " is-paged" : ""}${inline ? " is-inline" : ""}${selectedRowId === row.id ? " is-selected" : ""}${pagePlacement !== null ? " is-drop-target" : ""}${dragState?.kind === "row" && dragState.rowId === row.id ? " is-drag-source" : ""}`}
                    data-row-id={row.id}
                    onDragOver={(event) => {
                      if (dragState?.kind === "row") {
                        const rect = event.currentTarget.getBoundingClientRect();
                        const placement = event.clientY < rect.top + rect.height / 2 ? "before" : "after";
                        if (!canDropIntoGap(row, placement)) {
                          setDropTargetId(null);
                          return;
                        }
                        event.preventDefault();
                        setDropTargetId(`gap:${row.id}:${placement}`);
                      } else if (
                        dragState?.kind === "page"
                      ) {
                        const placement = pagePlacementForRow(event.currentTarget, event.clientX);
                        if (canMergePageInto(dragState.group, row, placement)) {
                          event.preventDefault();
                          setDropTargetId(`page:${row.id}:${placement}`);
                        } else {
                          setDropTargetId(null);
                        }
                      }
                    }}
                    onDrop={(event) => dropOnRow(event, row)}
                    onMouseEnter={() => {
                      if (pointerDragRef.current === null) selectEditorRow(row.id);
                    }}
                    ref={(node) => {
                      if (node) rowRefs.current.set(row.id, node);
                      else rowRefs.current.delete(row.id);
                    }}
                  >
                    {displayPaged ? <span className="fs-row-badge">翻页行 · 2 页</span> : null}
                    <button
                      aria-label={`拖动整行：${rowTitle(row)}`}
                      className="fs-row-handle"
                      draggable={false}
                      onPointerCancel={cancelPointerDrag}
                      onPointerDown={(event) => beginPointerDrag(
                        event,
                        { kind: "row", groups: row.groups, rowId: row.id },
                      )}
                      onPointerMove={movePointerDrag}
                      onPointerUp={endPointerDrag}
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
                      {pageItems.map((item, groupIndex) => {
                        const { group } = item;
                        const isInline = inline && !row.layoutRow.groups.includes(group);
                        const canPage = FLOATING_PAGE_CAPABLE_GROUPS.includes(group) && !isInline;
                        const isDefault = displayPaged && groupIndex === 0;
                        if (item.placeholder) {
                          return (
                            <span
                              aria-label={`${title(group)}可放置位置`}
                              className={`fs-chip fs-chip--placeholder${isDefault ? " is-default" : ""}`}
                              key={`placeholder:${row.id}:${group}`}
                            >
                              {isDefault ? <span aria-hidden="true">★</span> : null}
                              <strong>{title(group)}</strong>
                              {isDefault ? <em>默认页</em> : null}
                            </span>
                          );
                        }
                        return (
                          <button
                            className={`fs-chip${isDefault ? " is-default" : ""}${isInline ? " is-inline" : ""}${canPage ? " is-draggable" : ""}`}
                            draggable={false}
                            key={`${row.id}:${group}`}
                            onPointerCancel={canPage ? cancelPointerDrag : undefined}
                            onPointerDown={canPage ? (event) => beginPointerDrag(
                              event,
                              { kind: "page", group },
                            ) : undefined}
                            onPointerMove={canPage ? movePointerDrag : undefined}
                            onPointerUp={canPage ? endPointerDrag : undefined}
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
                    {displayPaged ? <span aria-label="悬浮窗内可左右翻页" className="fs-page-mark">‹ ›</span> : null}
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
              >
                {dropTargetId === `gap:${rows[rows.length - 1].id}:after` ? (
                  <span className="fs-row-placeholder">{draggedItemLabel(dragState)}</span>
                ) : null}
              </div>
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
            ref={hiddenZoneRef}
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

        {showPreview ? (
          <FloatingStructurePreview
            crowdRadarSnapshot={crowdRadarSnapshot}
            onSelectedRowIdChange={selectPreviewRow}
            priceModel={priceModel}
            radarSnapshot={radarSnapshot}
            runningThreads={runningThreads}
            selectedRowId={selectedRowId}
            settings={settings}
            snapshot={snapshot}
            visibility={visibility}
          />
        ) : null}
      </div>

      <footer className="floating-structure-footer">
        <span>费用口径：真实模型与缓存价格；未知模型使用回退模型，Spark 为独立额度。</span>
      </footer>

      {undoState ? (
        <div aria-live="polite" className="fs-undo-bar">
          <span>{undoState.message}</span>
          <button onClick={() => {
            setDraftVisibility(undoState.previous);
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

interface FloatingStructurePreviewProps {
  settings: FloatingWindowSettings;
  snapshot: FloatingPanelSnapshot;
  runningThreads: RunningThreadSummary;
  visibility: FloatingContentVisibility;
  selectedRowId: string | null;
  onSelectedRowIdChange: (rowId: string) => void;
  radarSnapshot?: CodexRadarSnapshot | null;
  crowdRadarSnapshot?: CodexCrowdRadarSnapshot | null;
  priceModel?: OfficialAPIPriceModel;
}

export function FloatingStructurePreview({
  settings,
  snapshot,
  runningThreads,
  visibility,
  selectedRowId,
  onSelectedRowIdChange,
  radarSnapshot,
  crowdRadarSnapshot,
  priceModel,
}: FloatingStructurePreviewProps) {
  return (
    <section aria-label="悬浮窗实时预览" className="floating-structure-preview">
      <div className="floating-structure-preview__label">
        <strong>实时预览</strong>
        <span>点击预览中的行可定位左侧结构</span>
      </div>
      <div className="floating-structure-preview__stage">
        <FloatingPanelSurface
          crowdRadarSnapshot={crowdRadarSnapshot}
          previewMode
          onPreviewRowSelect={onSelectedRowIdChange}
          priceModel={priceModel}
          radarSnapshot={radarSnapshot}
          runningThreads={runningThreads}
          selectedPreviewRowId={selectedRowId}
          settings={{ ...settings, contentVisibility: visibility }}
          snapshot={snapshot}
          unreadEffect="off"
        />
      </div>
    </section>
  );
}

function pagePlacementForRow(row: HTMLDivElement, clientX: number): FloatingContentRowPlacement {
  const pages = row.querySelector<HTMLElement>(".fs-row-pages");
  const rect = (pages ?? row).getBoundingClientRect();
  return pagePlacementForRect(rect, clientX);
}

function pagePlacementForRect(rect: ClientRectSnapshot, clientX: number): FloatingContentRowPlacement {
  return clientX < rect.left + rect.width / 2 ? "before" : "after";
}

function snapshotClientRect(rect: DOMRect | undefined | null): ClientRectSnapshot | null {
  if (!rect) return null;
  return {
    bottom: rect.bottom,
    height: rect.height,
    left: rect.left,
    right: rect.right,
    top: rect.top,
    width: rect.width,
  };
}

function pointInsideRect(clientX: number, clientY: number, rect: ClientRectSnapshot): boolean {
  return clientX >= rect.left
    && clientX <= rect.right
    && clientY >= rect.top
    && clientY <= rect.bottom;
}

function pointInsideHorizontalRect(clientX: number, rect: ClientRectSnapshot): boolean {
  return clientX >= rect.left && clientX <= rect.right;
}

function clampDragGhostPosition(position: number, itemSize: number, viewportSize: number): number {
  const margin = 8;
  return Math.min(Math.max(margin, viewportSize - itemSize - margin), Math.max(margin, position));
}

function draggedItemLabel(dragState: EditorDragState | null): string {
  if (dragState?.kind === "page") return title(dragState.group);
  if (dragState?.kind === "row") return dragState.groups.map(title).join(" · ");
  return "放到这里";
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

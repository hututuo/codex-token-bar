export type SidebarMode = "rest" | "hover" | "detail";
export type SidebarSection = "top" | "usage" | "five" | "seven" | "models" | "credits" | "ranking";
export interface SidebarState { section?: SidebarSection; focusRevision?: number; mode: SidebarMode; tab: "quota" | "running" | "radar" | "credits"; pinned: boolean }
export type SidebarAction = { type: "enter" } | { type: "leave" } | { type: "open"; tab: SidebarState["tab"]; section?: SidebarSection } | { type: "pin" } | { type: "close" } | { type: "disable" } | { type: "drag" };
export const initialSidebarState: SidebarState = { mode: "rest", tab: "quota", pinned: false };
export function sidebarReducer(state: SidebarState, action: SidebarAction): SidebarState {
  switch (action.type) {
    case "enter": return state.mode === "rest" ? { ...state, mode: "hover" } : state;
    case "leave": return state.pinned ? state : initialSidebarState;
    case "open": {
      const { section: _section, focusRevision: _revision, ...rest } = state;
      return { ...rest, mode: "detail", tab: action.tab, ...(action.section ? { section: action.section, focusRevision: (state.focusRevision ?? 0) + 1 } : {}) };
    }
    case "pin": return state.mode !== "rest" ? { ...state, pinned: !state.pinned } : state;
    case "close": return { ...state, mode: "hover", pinned: false };
    case "drag": return { ...state, mode: state.mode === "detail" ? "hover" : state.mode, pinned: false };
    case "disable": return initialSidebarState;
    default: return state;
  }
}
export function quotaPercent(availability: string, value: number | null): number | null {
  return availability === "measured" && value !== null && Number.isFinite(value) ? Math.min(100, Math.max(0, value * 100)) : null;
}
export function quotaText(value: number | null): string { return value === null ? "未知" : `${Math.round(value)}%`; }

export function isSidebarAction(value: unknown): value is SidebarAction {
  if (!value || typeof value !== "object" || !("type" in value)) return false;
  const action = value as Record<string, unknown>;
  return action.type === "open" ? (action.tab === "quota" || action.tab === "running" || action.tab === "radar" || action.tab === "credits") && (action.section === undefined || ["top", "usage", "five", "seven", "models", "credits", "ranking"].includes(String(action.section)))
    : ["enter", "leave", "pin", "close", "disable", "drag"].includes(String(action.type));
}

/** A measured zero is present; missing, unavailable and nonfinite 5h are absent. */
export function hasFiveHourQuota(availability: string, percent: number | null): boolean {
  return quotaPercent(availability, percent) !== null;
}

/** Rail mode classes must never inherit the standalone detail card's padding/animation. */
export function sidebarRailClassName(side: "left" | "right", mode: SidebarMode): string {
  return `qs-rail qs-${side} qs-mode-${mode}`;
}

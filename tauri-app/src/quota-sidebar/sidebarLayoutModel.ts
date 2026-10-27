export interface SidebarLayoutConfig {
  version: 1;
  order: readonly string[];
  hidden: readonly string[];
  hiddenCompact?: readonly string[];
  hiddenExpanded?: readonly string[];
}

export interface SidebarLayout extends SidebarLayoutConfig {
  order: string[];
  hidden: string[];
  hiddenCompact: string[];
  hiddenExpanded: string[];
}

export type SidebarVisibilityLevel = "compact" | "expanded";

export const DEFAULT_SIDEBAR_LAYOUT = Object.freeze({
  version: 1 as const,
  order: Object.freeze([
    "modeltrace",
    "speed",
    "tps",
    "quota:codex",
    "quota:claudeCode",
    "models",
    "tasks",
    "radar",
    "credits",
    "clientUsage",
  ]),
  hidden: Object.freeze(["clientUsage"]),
  hiddenCompact: Object.freeze([]),
  hiddenExpanded: Object.freeze([]),
});

const LEGACY_MODULE_ORDER = ["modeltrace", "speeds", "overview", "tasks", "radar", "credits"] as const;
const FIXED_ITEM_IDS = new Set(DEFAULT_SIDEBAR_LAYOUT.order.filter(id => !id.startsWith("quota:")));
const MAX_QUOTA_CLIENT_ID_LENGTH = 64;
const MAX_LAYOUT_ITEMS = 128;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isSidebarLayoutItemId(value: unknown): value is string {
  if (typeof value !== "string") return false;
  if (FIXED_ITEM_IDS.has(value)) return true;
  if (!value.startsWith("quota:")) return false;
  const client = value.slice("quota:".length);
  return client.length > 0
    && client.length <= MAX_QUOTA_CLIENT_ID_LENGTH
    && /^[A-Za-z0-9_-]+$/.test(client);
}

function uniqueValidIds(value: unknown, fallback: readonly string[] = [], limit = MAX_LAYOUT_ITEMS): string[] {
  const source = Array.isArray(value) ? value : fallback;
  const result: string[] = [];
  for (const candidate of source) {
    if (isSidebarLayoutItemId(candidate) && !result.includes(candidate)) result.push(candidate);
    if (result.length >= limit) break;
  }
  return result;
}

export function normalizeSidebarLayout(value: unknown): SidebarLayout {
  if (!isRecord(value) || value.version !== 1) return {
    version: 1,
    order: [...DEFAULT_SIDEBAR_LAYOUT.order],
    hidden: [...DEFAULT_SIDEBAR_LAYOUT.hidden],
    hiddenCompact: [],
    hiddenExpanded: [],
  };

  const order = uniqueValidIds(value.order, [], MAX_LAYOUT_ITEMS - DEFAULT_SIDEBAR_LAYOUT.order.length);
  for (const item of DEFAULT_SIDEBAR_LAYOUT.order) {
    if (!order.includes(item)) order.push(item);
  }
  return {
    version: 1,
    order,
    // Missing hidden state gets the new-item default. An explicit empty list means
    // the user chose to show every item.
    hidden: uniqueValidIds(value.hidden, DEFAULT_SIDEBAR_LAYOUT.hidden),
    hiddenCompact: uniqueValidIds(value.hiddenCompact),
    hiddenExpanded: uniqueValidIds(value.hiddenExpanded),
  };
}

function normalizedLegacyModuleOrder(value: unknown): string[] {
  const result: string[] = [];
  if (Array.isArray(value)) {
    for (const candidate of value) {
      if (typeof candidate === "string" && LEGACY_MODULE_ORDER.includes(candidate as typeof LEGACY_MODULE_ORDER[number]) && !result.includes(candidate)) {
        result.push(candidate);
      }
    }
  }
  for (const module of LEGACY_MODULE_ORDER) if (!result.includes(module)) result.push(module);
  return result;
}

function quotaClientsFromWindowOrder(value: unknown): string[] {
  const clients: string[] = [];
  if (Array.isArray(value)) {
    for (const entry of value) {
      if (typeof entry !== "string") continue;
      const separator = entry.indexOf(":");
      if (separator <= 0) continue;
      const client = entry.slice(0, separator);
      if (isSidebarLayoutItemId(`quota:${client}`) && !clients.includes(client)) clients.push(client);
    }
  }
  for (const fallback of ["codex", "claudeCode"]) if (!clients.includes(fallback)) clients.push(fallback);
  return clients;
}

function legacyHiddenModules(value: unknown): Set<string> {
  const hidden = new Set<string>();
  if (Array.isArray(value)) {
    for (const item of value) if (typeof item === "string") hidden.add(item);
  } else if (isRecord(value)) {
    // The legacy Rust/React shape stores visibility booleans, where false means hidden.
    for (const module of LEGACY_MODULE_ORDER) if (value[module] === false) hidden.add(module);
  }
  return hidden;
}

export function migrateSidebarLayout(
  legacyModuleOrder: unknown,
  hiddenModules: unknown,
  quotaWindowOrder: unknown,
): SidebarLayout {
  const quotaClients = quotaClientsFromWindowOrder(quotaWindowOrder);
  const order: string[] = [];
  const hidden = new Set<string>(DEFAULT_SIDEBAR_LAYOUT.hidden);
  const oldHidden = legacyHiddenModules(hiddenModules);

  for (const module of normalizedLegacyModuleOrder(legacyModuleOrder)) {
    switch (module) {
      case "modeltrace":
        order.push("modeltrace");
        if (oldHidden.has(module)) hidden.add("modeltrace");
        break;
      case "speeds":
        order.push("speed", "tps");
        if (oldHidden.has(module)) { hidden.add("speed"); hidden.add("tps"); }
        break;
      case "overview":
        order.push(...quotaClients.map(client => `quota:${client}`), "models");
        if (oldHidden.has(module)) {
          for (const client of quotaClients) hidden.add(`quota:${client}`);
          hidden.add("models");
        }
        break;
      case "tasks":
      case "radar":
      case "credits":
        order.push(module);
        if (oldHidden.has(module)) hidden.add(module);
        break;
    }
  }

  // Preserve any already-migrated custom quota visibility passed as a hidden ID.
  if (Array.isArray(hiddenModules)) {
    for (const item of hiddenModules) if (isSidebarLayoutItemId(item)) hidden.add(item);
  }
  return normalizeSidebarLayout({ version: 1, order, hidden: [...hidden] });
}

/**
 * Returns the saved order, including unavailable quota groups, and inserts any newly
 * available quota clients after the final saved quota group without disturbing existing IDs.
 */
export function arrangedSidebarItems(
  config: SidebarLayoutConfig,
  availableQuotaClients: readonly string[],
): string[] {
  const order = [...normalizeSidebarLayout(config).order];
  const additions: string[] = [];
  for (const client of availableQuotaClients) {
    const id = `quota:${client}`;
    if (isSidebarLayoutItemId(id) && !order.includes(id) && !additions.includes(id)) additions.push(id);
  }
  if (!additions.length) return order;

  let insertion = -1;
  for (let index = 0; index < order.length; index++) if (order[index].startsWith("quota:")) insertion = index + 1;
  if (insertion < 0) insertion = order.indexOf("models");
  if (insertion < 0) insertion = order.length;
  order.splice(insertion, 0, ...additions);
  return order;
}

export function isSidebarItemVisible(
  config: SidebarLayoutConfig,
  id: string,
  level?: SidebarVisibilityLevel,
): boolean {
  if (!isSidebarLayoutItemId(id)) return false;
  const normalized = normalizeSidebarLayout(config);
  if (normalized.hidden.includes(id)) return false;
  if (level === "compact") return !normalized.hiddenCompact.includes(id);
  if (level === "expanded") return !normalized.hiddenExpanded.includes(id);
  return true;
}

export function setSidebarItemLevelVisible(
  config: SidebarLayoutConfig,
  id: string,
  level: SidebarVisibilityLevel,
  visible: boolean,
): SidebarLayout {
  const next = normalizeSidebarLayout(config);
  if (!isSidebarLayoutItemId(id)) return next;

  const wasMasterHidden = next.hidden.includes(id);
  next.hidden = next.hidden.filter(item => item !== id);
  if (wasMasterHidden) {
    if (!next.hiddenCompact.includes(id)) next.hiddenCompact.push(id);
    if (!next.hiddenExpanded.includes(id)) next.hiddenExpanded.push(id);
  }

  const hiddenAtLevel = level === "compact" ? next.hiddenCompact : next.hiddenExpanded;
  if (visible) {
    next[level === "compact" ? "hiddenCompact" : "hiddenExpanded"] = hiddenAtLevel.filter(item => item !== id);
  } else if (!hiddenAtLevel.includes(id)) {
    hiddenAtLevel.push(id);
  }
  return next;
}

export function moveSidebarItem(
  config: SidebarLayoutConfig,
  id: string,
  target: string,
  after: boolean,
): SidebarLayout {
  const next = normalizeSidebarLayout(config);
  if (!isSidebarLayoutItemId(id) || !isSidebarLayoutItemId(target) || id === target) return next;
  if (!next.order.includes(target)) next.order.push(target);
  const from = next.order.indexOf(id);
  if (from >= 0) next.order.splice(from, 1);
  const adjustedTarget = next.order.indexOf(target);
  next.order.splice(adjustedTarget + (after ? 1 : 0), 0, id);
  return next;
}

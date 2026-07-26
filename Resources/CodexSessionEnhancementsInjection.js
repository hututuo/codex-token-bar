/*
 * Codex Token Bar session enhancements.
 *
 * Portions of the behavior and implementation are adapted from
 * BigPizzaV3/CodexPlusPlus v1.2.41 (renderer-inject.js), commit
 * 3dafffcafb2566a1e8bce4b35671656d6adb3eda, licensed under GNU AGPL-3.0.
 * This modified file remains available under GNU AGPL-3.0.
 */
(() => {
  const settings = window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ || {};
  const stateKey = "__codexTokenBarSessionEnhancementsState";
  const runtimeVersion = 4;
  const styleId = "codex-token-bar-session-enhancements-style";
  const overlayId = "codex-token-bar-session-enhancements-overlay";
  const moreAttribute = "data-codex-token-bar-session-more";
  const moreThreadAttribute = "data-codex-token-bar-session-more-thread-id";
  const badgeAttribute = "data-codex-token-bar-thread-id-badge";
  const menuClass = "codex-token-bar-session-menu";
  const moveOverlayClass = "codex-token-bar-project-move-overlay";
  const toastClass = "codex-token-bar-session-toast";
  const scrollStorageKey = "codexTokenBar.threadScrollPositions.v1";
  const previousRuntimeVersion = Number(window[stateKey]?.runtimeVersion) || 0;

  const normalizedSettings = {
    sessionDelete: settings.sessionDelete !== false,
    markdownExport: settings.markdownExport === true,
    pasteFix: settings.pasteFix === true,
    projectMove: settings.projectMove === true,
    threadIDBadge: settings.threadIDBadge === true,
    conversationView: settings.conversationView === true,
    conversationViewMaxWidth: Math.max(320, Math.min(4000, Number(settings.conversationViewMaxWidth) || 900)),
    threadScrollRestore: settings.threadScrollRestore === true,
  };

  const state = window[stateKey] || {
    runtimeVersion,
    settings: normalizedSettings,
    observer: null,
    scanQueued: false,
    overlay: null,
    moreButtonsByReference: new Map(),
    hoveredReference: null,
    pointerMoveListener: null,
    pointerLeaveListener: null,
    scrollLayoutListener: null,
    resizeListener: null,
    pasteListener: null,
    routePointerListener: null,
    menuDismissPointerListener: null,
    menuDismissFocusListener: null,
    menuDismissKeyListener: null,
    menuDismissScrollListener: null,
    menuDismissResizeListener: null,
    menuDismissBlurListener: null,
    openMenuTrigger: null,
    conversationObserver: null,
    conversationResizeObserver: null,
    conversationPoll: null,
    conversationElements: new Map(),
    scroll: {
      activeThreadId: "",
      scroller: null,
      listener: null,
      restoreTimers: [],
      cancelledThreadId: "",
    },
  };
  state.runtimeVersion = runtimeVersion;
  state.settings = normalizedSettings;
  state.moreButtonsByReference ||= new Map();
  state.conversationElements ||= new Map();
  state.scroll ||= {
    activeThreadId: "",
    scroller: null,
    listener: null,
    restoreTimers: [],
    cancelledThreadId: "",
  };
  if (previousRuntimeVersion > 0 && previousRuntimeVersion !== runtimeVersion) {
    document.querySelectorAll(`.${menuClass}`).forEach((node) => node.remove());
    state.moreButtonsByReference.forEach((button) => button.remove());
    state.moreButtonsByReference = new Map();
    state.openMenuTrigger = null;
  }
  window[stateKey] = state;
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS_RUNTIME_VERSION__ = runtimeVersion;

  function canonicalThreadId(value) {
    const match = /^(?:local:)?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i.exec(String(value || "").trim());
    return match?.[1] || "";
  }

  function sidebarRows() {
    return [...document.querySelectorAll("[data-app-action-sidebar-thread-id]")];
  }

  function rowReference(row) {
    return String(row?.getAttribute("data-app-action-sidebar-thread-id") || "").trim();
  }

  function rowForReference(reference) {
    return sidebarRows().find((row) => rowReference(row) === reference) || null;
  }

  function rowTitle(row) {
    const title = row?.querySelector('[data-testid="thread-title"], [data-thread-title], .truncate.select-none, .truncate.text-base, .truncate');
    return String(title?.textContent || row?.textContent || "未命名会话")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 160);
  }

  function stopNavigation(event) {
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation?.();
  }

  function showToast(message) {
    document.querySelectorAll(`.${toastClass}`).forEach((node) => node.remove());
    const toast = document.createElement("div");
    toast.className = toastClass;
    toast.setAttribute("role", "status");
    toast.textContent = String(message || "");
    (document.body || document.documentElement)?.appendChild(toast);
    window.setTimeout(() => toast.remove(), 5000);
  }

  function escapeHTML(value) {
    return String(value || "").replace(/[&<>"']/g, (character) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    })[character]);
  }

  function ensureStyle() {
    if (document.getElementById(styleId)) return;
    const host = document.head || document.documentElement;
    if (!host) return;
    const style = document.createElement("style");
    style.id = styleId;
    style.textContent = `
      #${overlayId} { height: 0; inset: 0; overflow: visible; pointer-events: none; position: fixed; width: 0; z-index: 2147482999; }
      #${overlayId} [${moreAttribute}="true"] {
        align-items: center; background: color-mix(in srgb, Canvas 88%, transparent);
        border: 1px solid color-mix(in srgb, currentColor 18%, transparent); border-radius: 5px;
        color: color-mix(in srgb, currentColor 68%, transparent); cursor: pointer; display: inline-flex;
        font: 700 15px/1 system-ui, sans-serif; height: 24px; justify-content: center; opacity: 0;
        padding: 0 0 5px; pointer-events: none; position: fixed; transition: opacity 120ms ease, color 120ms ease, background 120ms ease;
        width: 24px; z-index: 1;
      }
      #${overlayId} [${moreAttribute}="true"][data-visible="true"],
      #${overlayId} [${moreAttribute}="true"]:focus-visible { opacity: 1; pointer-events: auto; }
      #${overlayId} [${moreAttribute}="true"]:hover { background: color-mix(in srgb, #2563eb 12%, Canvas); color: #2563eb; }
      .${menuClass} {
        background: color-mix(in srgb, Canvas 96%, transparent); border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
        border-radius: 8px; box-shadow: 0 12px 30px rgba(0,0,0,.2); display: grid; gap: 3px; min-width: 124px;
        padding: 5px; position: fixed; z-index: 2147483646;
      }
      .${menuClass}[hidden] { display: none; }
      .${menuClass} button { background: transparent; border: 0; border-radius: 6px; color: CanvasText; cursor: pointer; font: 500 13px/1.2 system-ui,sans-serif; padding: 8px 10px; text-align: left; }
      .${menuClass} button:hover, .${menuClass} button:focus-visible { background: color-mix(in srgb, currentColor 10%, transparent); outline: none; }
      .${toastClass} { background: color-mix(in srgb, Canvas 94%, transparent); border: 1px solid color-mix(in srgb, currentColor 18%, transparent); border-radius: 6px; bottom: 22px; color: CanvasText; font: 500 13px/1.4 system-ui,sans-serif; left: 50%; max-width: min(480px, calc(100vw - 32px)); padding: 9px 12px; position: fixed; transform: translateX(-50%); z-index: 2147483647; }
      [${badgeAttribute}="true"] { color: color-mix(in srgb, currentColor 56%, transparent); flex: 0 0 auto; font: 500 9px/1.2 ui-monospace,SFMono-Regular,monospace; margin-right: 5px; white-space: nowrap; }
      [data-codex-token-bar-thread-badge-wrap="true"] { align-items: center; display: inline-flex; min-width: 0; overflow: hidden; }
      .${moveOverlayClass} { background: rgba(0,0,0,.18); inset: 0; position: fixed; z-index: 2147483645; }
      .${moveOverlayClass} .ctb-project-panel { background: Canvas; border: 1px solid color-mix(in srgb, currentColor 18%, transparent); border-radius: 10px; box-shadow: 0 16px 36px rgba(0,0,0,.25); max-height: min(460px, calc(100vh - 32px)); overflow: auto; padding: 8px; position: fixed; width: min(360px, calc(100vw - 32px)); }
      .${moveOverlayClass} .ctb-project-title { font: 650 13px/1.3 system-ui,sans-serif; padding: 7px 8px 9px; }
      .${moveOverlayClass} button { background: transparent; border: 0; border-radius: 7px; color: CanvasText; cursor: pointer; display: block; padding: 8px; text-align: left; width: 100%; }
      .${moveOverlayClass} button:hover, .${moveOverlayClass} button:focus-visible { background: color-mix(in srgb, currentColor 10%, transparent); outline: none; }
      .${moveOverlayClass} .ctb-project-name { font: 600 12px/1.3 system-ui,sans-serif; }
      .${moveOverlayClass} .ctb-project-path { color: color-mix(in srgb, currentColor 58%, transparent); font: 500 10px/1.3 system-ui,sans-serif; margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    `;
    host.appendChild(style);
  }

  function ensureOverlay() {
    if (state.overlay?.isConnected) return state.overlay;
    const host = document.body || document.documentElement;
    if (!host) return null;
    state.overlay = document.getElementById(overlayId) || document.createElement("div");
    state.overlay.id = overlayId;
    if (!state.overlay.isConnected) host.appendChild(state.overlay);
    state.moreButtonsByReference = new Map(
      [...state.overlay.querySelectorAll(`[${moreAttribute}="true"]`)]
        .map((button) => [button.getAttribute(moreThreadAttribute) || "", button])
        .filter(([reference]) => reference),
    );
    return state.overlay;
  }

  function positionMoreButton(button, row) {
    const rect = row.getBoundingClientRect();
    const visible = rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.top < window.innerHeight;
    button.style.visibility = visible ? "visible" : "hidden";
    if (!visible) return;
    const offset = state.settings.sessionDelete ? 82 : 54;
    button.style.left = `${Math.round(rect.right - offset)}px`;
    button.style.top = `${Math.round(rect.top + (rect.height - 24) / 2)}px`;
  }

  function updateMoreVisibility() {
    for (const [reference, button] of state.moreButtonsByReference) {
      button.dataset.visible = String(reference === state.hoveredReference || button === document.activeElement);
    }
  }

  function closeMenus({ restoreFocus = false } = {}) {
    const trigger = state.openMenuTrigger;
    document.querySelectorAll(`.${menuClass}`).forEach((node) => node.remove());
    if (trigger?.isConnected) {
      trigger.setAttribute("aria-expanded", "false");
      if (restoreFocus) trigger.focus();
    }
    state.openMenuTrigger = null;
  }

  function isInsideOpenMenu(target) {
    return Boolean(target?.closest?.(`.${menuClass}, [${moreAttribute}="true"]`));
  }

  async function invoke(payload) {
    if (typeof window.__codexTokenBarSessionEnhancementInvoke !== "function") {
      throw new Error("会话增强桥接暂不可用");
    }
    return await window.__codexTokenBarSessionEnhancementInvoke(payload);
  }

  function markdownParts(value) {
    if (typeof value === "string") return [value];
    if (Array.isArray(value) && value.every((part) => typeof part === "string")) {
      return value;
    }
    return null;
  }

  function downloadMarkdownFallback(filename, parts) {
    const blob = new Blob(parts, { type: "text/markdown;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = filename;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function saveMarkdown(filename, parts) {
    if (typeof window.showSaveFilePicker !== "function") {
      downloadMarkdownFallback(filename, parts);
      return "saved";
    }
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: filename,
        types: [{ description: "Markdown", accept: { "text/markdown": [".md", ".markdown"] } }],
      });
      const writable = await handle.createWritable();
      for (const part of parts) {
        await writable.write(part);
      }
      await writable.close();
      return "saved";
    } catch (error) {
      if (error?.name === "AbortError") return "cancelled";
      throw error;
    }
  }

  async function exportMarkdown(row, reference) {
    const threadId = canonicalThreadId(reference);
    const result = await invoke({
      action: "exportMarkdown",
      threadId,
      title: rowTitle(row),
    });
    const parts = markdownParts(result?.markdownChunks ?? result?.markdown);
    if (result?.status !== "exported" || !parts || !result.filename) {
      throw new Error(result?.message || "导出失败");
    }
    const saveStatus = await saveMarkdown(result.filename, parts);
    showToast(saveStatus === "cancelled" ? "导出已取消" : (result.message || "导出成功"));
  }

  function projectTargets() {
    const seen = new Set();
    const targets = [{ kind: "projectless", label: "普通对话", path: "", description: "不属于任何项目" }];
    document.querySelectorAll("[data-app-action-sidebar-project-row]").forEach((row) => {
      const path = String(row.getAttribute("data-app-action-sidebar-project-id") || "").trim();
      if (!path || seen.has(path)) return;
      seen.add(path);
      const label = String(
        row.getAttribute("data-app-action-sidebar-project-label")
        || row.getAttribute("aria-label")
        || path.split(/[\\/]+/).filter(Boolean).pop()
        || path,
      ).trim();
      targets.push({ kind: "project", label, path, description: path });
    });
    return targets;
  }

  const modulePromises = new Map();

  function codexAssetURL(namePart) {
    const urls = [
      ...[...document.scripts].map((script) => script.src),
      ...[...document.querySelectorAll("link[href]")].map((link) => link.href),
      ...performance.getEntriesByType("resource").map((entry) => entry.name),
    ].filter(Boolean);
    return urls.find((url) => url.includes("/assets/") && url.includes(namePart) && url.split("?")[0].endsWith(".js")) || "";
  }

  async function codexAssetURLFromScript(namePart) {
    for (const source of [...document.scripts].map((script) => script.src).filter(Boolean)) {
      if (!source.includes("/assets/") || !source.split("?")[0].endsWith(".js")) continue;
      try {
        const text = await fetch(source).then((response) => response.ok ? response.text() : "");
        const escaped = namePart.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const match = text.match(new RegExp(`["'](\\./assets/${escaped}[^"']+\\.js)["']`));
        if (match) return new URL(match[1], source).href;
      } catch (_) {}
    }
    return "";
  }

  async function loadCodexModule(namePart) {
    if (!modulePromises.has(namePart)) {
      modulePromises.set(namePart, Promise.resolve().then(async () => {
        const url = codexAssetURL(namePart) || await codexAssetURLFromScript(namePart);
        if (!url) throw new Error(`未找到 Codex App asset: ${namePart}`);
        return await import(url);
      }).catch((error) => {
        modulePromises.delete(namePart);
        throw error;
      }));
    }
    return await modulePromises.get(namePart);
  }

  let codexStateAPI;
  async function stateCall(method, params) {
    if (!codexStateAPI) {
      const module = await loadCodexModule("vscode-api-");
      if (typeof module.n !== "function") throw new Error("Codex 状态 API 不可用");
      codexStateAPI = module.n;
    }
    return await codexStateAPI(method, params);
  }

  async function getGlobalState(key) {
    const result = await stateCall("get-global-state", { params: { key } });
    return result && Object.prototype.hasOwnProperty.call(result, "value") ? result.value : result;
  }

  async function setGlobalState(key, value) {
    return await stateCall("set-global-state", { params: { key, value } });
  }

  function idVariants(reference) {
    const bare = canonicalThreadId(reference);
    return bare ? [bare, `local:${bare}`] : [];
  }

  async function updateProjectlessState(reference, projectless) {
    const variants = idVariants(reference);
    const existing = await getGlobalState("projectless-thread-ids").catch(() => []);
    const ids = Array.isArray(existing) ? existing : [];
    const variantSet = new Set(variants);
    const next = projectless
      ? [...new Set([...ids, ...variants])]
      : ids.filter((id) => !variantSet.has(id));
    if (JSON.stringify(next) !== JSON.stringify(ids)) {
      await setGlobalState("projectless-thread-ids", next);
    }
    for (const key of ["thread-workspace-root-hints", "thread-writable-roots", "thread-projectless-output-directories"]) {
      const value = await getGlobalState(key).catch(() => ({}));
      if (!value || typeof value !== "object" || Array.isArray(value)) continue;
      let changed = false;
      for (const id of variants) {
        if (Object.prototype.hasOwnProperty.call(value, id)) {
          delete value[id];
          changed = true;
        }
      }
      if (changed) await setGlobalState(key, value);
    }
  }

  async function moveThread(row, reference, target) {
    const threadId = canonicalThreadId(reference);
    if (target.kind === "projectless") {
      await updateProjectlessState(reference, true);
      showToast(`已移动到普通对话：“${rowTitle(row)}”`);
    } else {
      const result = await invoke({
        action: "moveThreadWorkspace",
        threadId,
        title: rowTitle(row),
        targetCwd: target.path,
      });
      if (result?.status !== "moved") throw new Error(result?.message || "移动失败");
      await updateProjectlessState(reference, false).catch(() => {});
      showToast(`已移动到“${target.label}”：“${rowTitle(row)}”`);
    }
    window.setTimeout(() => window.location.reload(), 300);
  }

  function openProjectMove(row, reference, anchor) {
    document.querySelectorAll(`.${moveOverlayClass}`).forEach((node) => node.remove());
    const overlay = document.createElement("div");
    overlay.className = moveOverlayClass;
    overlay.innerHTML = `<div class="ctb-project-panel" role="dialog" aria-modal="true" aria-label="移动对话"><div class="ctb-project-title">移动“${escapeHTML(rowTitle(row))}”</div><div class="ctb-project-list"></div></div>`;
    const panel = overlay.querySelector(".ctb-project-panel");
    const rect = anchor.getBoundingClientRect();
    panel.style.left = `${Math.max(16, Math.min(window.innerWidth - 376, rect.right - 360))}px`;
    panel.style.top = `${Math.max(16, Math.min(window.innerHeight - 260, rect.bottom + 6))}px`;
    const close = () => overlay.remove();
    overlay.addEventListener("click", (event) => { if (event.target === overlay) close(); }, true);
    overlay.addEventListener("keydown", (event) => { if (event.key === "Escape") close(); }, true);
    const list = overlay.querySelector(".ctb-project-list");
    projectTargets().forEach((target) => {
      const item = document.createElement("button");
      item.type = "button";
      item.innerHTML = `<div class="ctb-project-name">${escapeHTML(target.label)}</div><div class="ctb-project-path">${escapeHTML(target.description)}</div>`;
      item.addEventListener("click", async (event) => {
        stopNavigation(event);
        close();
        try {
          await moveThread(row, reference, target);
        } catch (error) {
          showToast(`移动失败：${error?.message || error}`);
        }
      }, true);
      list.appendChild(item);
    });
    (document.body || document.documentElement).appendChild(overlay);
    list.querySelector("button")?.focus();
  }

  function openMoreMenu(row, reference, button, event) {
    stopNavigation(event);
    const isTogglingClosed = state.openMenuTrigger === button
      && Boolean(document.querySelector(`.${menuClass}`));
    closeMenus();
    if (isTogglingClosed) return;
    const menu = document.createElement("div");
    menu.className = menuClass;
    menu.setAttribute("role", "menu");
    if (state.settings.markdownExport) {
      const item = document.createElement("button");
      item.type = "button";
      item.textContent = "导出 Markdown";
      item.addEventListener("click", async (clickEvent) => {
        stopNavigation(clickEvent);
        closeMenus();
        try { await exportMarkdown(row, reference); }
        catch (error) { showToast(`导出失败：${error?.message || error}`); }
      }, true);
      menu.appendChild(item);
    }
    if (state.settings.projectMove) {
      const item = document.createElement("button");
      item.type = "button";
      item.textContent = "移动到项目";
      item.addEventListener("click", (clickEvent) => {
        stopNavigation(clickEvent);
        closeMenus();
        openProjectMove(row, reference, button);
      }, true);
      menu.appendChild(item);
    }
    (document.body || document.documentElement).appendChild(menu);
    state.openMenuTrigger = button;
    button.setAttribute("aria-expanded", "true");
    const rect = button.getBoundingClientRect();
    const menuRect = menu.getBoundingClientRect();
    menu.style.left = `${Math.max(8, Math.min(window.innerWidth - menuRect.width - 8, rect.right - menuRect.width))}px`;
    menu.style.top = `${Math.max(8, Math.min(window.innerHeight - menuRect.height - 8, rect.bottom + 5))}px`;
    menu.querySelector("button")?.focus();
  }

  function createMoreButton(reference) {
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute(moreAttribute, "true");
    button.setAttribute(moreThreadAttribute, reference);
    button.setAttribute("aria-label", "更多会话操作");
    button.setAttribute("aria-haspopup", "menu");
    button.setAttribute("aria-expanded", "false");
    button.textContent = "…";
    for (const eventName of ["pointerdown", "mousedown", "mouseup", "touchstart"]) {
      button.addEventListener(eventName, stopNavigation, true);
    }
    button.addEventListener("click", (event) => {
      const row = rowForReference(reference);
      if (row) openMoreMenu(row, reference, button, event);
    }, true);
    button.addEventListener("focus", updateMoreVisibility, true);
    button.addEventListener("blur", updateMoreVisibility, true);
    return button;
  }

  function refreshMoreButtons(rows) {
    const enabled = state.settings.markdownExport || state.settings.projectMove;
    const overlay = ensureOverlay();
    const live = new Set();
    if (enabled && overlay) {
      for (const row of rows) {
        const reference = rowReference(row);
        if (!canonicalThreadId(reference)) continue;
        live.add(reference);
        let button = state.moreButtonsByReference.get(reference);
        if (!button?.isConnected) {
          button = createMoreButton(reference);
          overlay.appendChild(button);
          state.moreButtonsByReference.set(reference, button);
        }
        button.setAttribute("aria-label", `更多会话操作：${rowTitle(row)}`);
        positionMoreButton(button, row);
      }
    }
    for (const [reference, button] of state.moreButtonsByReference) {
      if (live.has(reference) && button.isConnected) continue;
      button.remove();
      state.moreButtonsByReference.delete(reference);
    }
    updateMoreVisibility();
  }

  function uuidV7Date(threadId) {
    const compact = canonicalThreadId(threadId).replaceAll("-", "");
    if (!/^[0-9a-f]{12}/i.test(compact)) return null;
    const milliseconds = Number.parseInt(compact.slice(0, 12), 16);
    if (!Number.isFinite(milliseconds) || milliseconds < Date.UTC(2020, 0, 1) || milliseconds > Date.now() + 31_536_000_000) return null;
    return new Date(milliseconds);
  }

  function badgeLabel(threadId) {
    const id = canonicalThreadId(threadId);
    const shortId = id.replaceAll("-", "").slice(0, 8);
    const date = uuidV7Date(id);
    const two = (value) => String(value).padStart(2, "0");
    const created = date ? `${two(date.getMonth() + 1)}-${two(date.getDate())} ${two(date.getHours())}:${two(date.getMinutes())}` : "";
    return shortId ? `[${shortId}${created ? ` ${created}` : ""}]` : "";
  }

  function removeBadges(root = document) {
    root.querySelectorAll?.(`[${badgeAttribute}="true"]`).forEach((node) => node.remove());
    root.querySelectorAll?.('[data-codex-token-bar-thread-badge-wrap="true"]').forEach((wrapper) => {
      const parent = wrapper.parentElement;
      if (!parent) return;
      while (wrapper.firstChild) parent.insertBefore(wrapper.firstChild, wrapper);
      wrapper.remove();
    });
  }

  function refreshBadges(rows) {
    if (!state.settings.threadIDBadge) {
      removeBadges();
      return;
    }
    for (const row of rows) {
      const reference = rowReference(row);
      const id = canonicalThreadId(reference);
      const title = row.querySelector('[data-testid="thread-title"], [data-thread-title], .truncate.select-none, .truncate.text-base, .truncate');
      const label = badgeLabel(id);
      if (!id || !title || !label) continue;
      let wrapper = title.parentElement?.dataset?.codexTokenBarThreadBadgeWrap === "true"
        ? title.parentElement
        : null;
      if (!wrapper && title.parentElement) {
        wrapper = document.createElement("span");
        wrapper.dataset.codexTokenBarThreadBadgeWrap = "true";
        title.parentElement.insertBefore(wrapper, title);
        wrapper.appendChild(title);
      }
      if (!wrapper) continue;
      let badge = wrapper.querySelector(`[${badgeAttribute}="true"]`);
      if (!badge) {
        badge = document.createElement("span");
        badge.setAttribute(badgeAttribute, "true");
        wrapper.insertBefore(badge, title);
      }
      badge.textContent = label;
      const date = uuidV7Date(id);
      badge.title = date ? `Session ID: ${id}\nCreated: ${date.toLocaleString()}` : `Session ID: ${id}`;
    }
  }

  function configurePasteFix() {
    if (state.settings.pasteFix && !state.pasteListener) {
      state.pasteListener = (event) => {
        const target = event.target;
        const editable = target?.closest?.('textarea, input, [contenteditable="true"], [role="textbox"]');
        if (!editable) return;
        const text = event.clipboardData?.getData("text/plain");
        if (typeof text !== "string" || text.length === 0) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        let inserted = false;
        try { inserted = document.execCommand("insertText", false, text); } catch (_) {}
        if (!inserted && "value" in editable) {
          const start = editable.selectionStart ?? editable.value.length;
          const end = editable.selectionEnd ?? start;
          editable.value = `${editable.value.slice(0, start)}${text}${editable.value.slice(end)}`;
          editable.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
        }
      };
      document.addEventListener("paste", state.pasteListener, true);
    } else if (!state.settings.pasteFix && state.pasteListener) {
      document.removeEventListener("paste", state.pasteListener, true);
      state.pasteListener = null;
    }
  }

  const contentClasses = ["mx-auto", "w-full", "max-w-(--thread-content-max-width)", "px-toolbar", "relative", "flex", "shrink-0", "flex-col", "pb-8"];
  const composerClasses = ["relative", "z-10", "flex", "flex-col", "mx-auto", "w-full", "max-w-(--thread-content-max-width)", "px-toolbar"];

  function hasClasses(element, classes) {
    const tokens = new Set(String(element?.className || "").split(/\s+/).filter(Boolean));
    return classes.every((name) => tokens.has(name));
  }

  function conversationTargets() {
    const divs = [...document.querySelectorAll("div")];
    return [
      divs.find((element) => hasClasses(element, contentClasses)) || null,
      divs.find((element) => hasClasses(element, composerClasses)) || null,
    ].filter(Boolean);
  }

  function rememberConversationStyle(element) {
    if (state.conversationElements.has(element)) return;
    state.conversationElements.set(element, {
      width: element.style.width,
      maxWidth: element.style.maxWidth,
      marginLeft: element.style.marginLeft,
      marginRight: element.style.marginRight,
      boxSizing: element.style.boxSizing,
    });
  }

  function applyConversationView() {
    if (!state.settings.conversationView) {
      for (const [element, original] of state.conversationElements) {
        if (!element?.style) continue;
        Object.assign(element.style, original);
      }
      state.conversationElements.clear();
      if (state.conversationPoll) window.clearInterval(state.conversationPoll);
      state.conversationPoll = null;
      state.conversationObserver?.disconnect?.();
      state.conversationObserver = null;
      state.conversationResizeObserver?.disconnect?.();
      state.conversationResizeObserver = null;
      return;
    }
    for (const element of conversationTargets()) {
      rememberConversationStyle(element);
      element.style.boxSizing = "border-box";
      element.style.width = "100%";
      element.style.maxWidth = `${state.settings.conversationViewMaxWidth}px`;
      element.style.marginLeft = "auto";
      element.style.marginRight = "auto";
      state.conversationResizeObserver?.observe?.(element);
    }
    if (!state.conversationObserver && document.body) {
      state.conversationObserver = new MutationObserver(queueScan);
      state.conversationObserver.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["class"] });
    }
    if (!state.conversationResizeObserver && typeof ResizeObserver === "function") {
      state.conversationResizeObserver = new ResizeObserver(queueScan);
    }
    if (!state.conversationPoll) state.conversationPoll = window.setInterval(queueScan, 500);
  }

  function currentThreadId() {
    const active = sidebarRows().find((row) => row.getAttribute("aria-current") === "page" || row.getAttribute("aria-current") === "true");
    const activeId = canonicalThreadId(rowReference(active));
    if (activeId) return activeId;
    const source = `${location.pathname}${location.search}${location.hash}`;
    const match = source.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i);
    return match?.[1] || "";
  }

  function threadScroller() {
    const explicit = document.querySelector(".thread-scroll-container");
    if (explicit) return explicit;
    const root = document.querySelector("main, [role='main']");
    for (let element = root; element; element = element.parentElement) {
      const style = getComputedStyle(element);
      if (/(auto|scroll)/.test(style.overflowY) && element.scrollHeight > element.clientHeight) return element;
    }
    return document.scrollingElement || document.documentElement;
  }

  function readScrollEntries() {
    try {
      const value = JSON.parse(localStorage.getItem(scrollStorageKey) || "{}");
      return value && typeof value === "object" && !Array.isArray(value) ? value : {};
    } catch (_) { return {}; }
  }

  function writeScrollEntry(threadId, scroller) {
    if (!threadId || !scroller) return;
    const entries = readScrollEntries();
    entries[threadId] = { top: Number(scroller.scrollTop) || 0, at: Date.now() };
    const pruned = Object.fromEntries(Object.entries(entries).sort((left, right) => (right[1]?.at || 0) - (left[1]?.at || 0)).slice(0, 200));
    localStorage.setItem(scrollStorageKey, JSON.stringify(pruned));
  }

  function clearRestoreTimers() {
    for (const timer of state.scroll.restoreTimers || []) window.clearTimeout(timer);
    state.scroll.restoreTimers = [];
  }

  function restoreScroll(threadId, scroller) {
    clearRestoreTimers();
    const entry = readScrollEntries()[threadId];
    if (!entry || state.scroll.cancelledThreadId === threadId) return;
    for (const delay of [0, 60, 180, 420, 800]) {
      state.scroll.restoreTimers.push(window.setTimeout(() => {
        if (!state.settings.threadScrollRestore || currentThreadId() !== threadId || state.scroll.cancelledThreadId === threadId) return;
        scroller.scrollTop = Number(entry.top) || 0;
      }, delay));
    }
  }

  function configureScrollRestore() {
    if (!state.settings.threadScrollRestore) {
      if (state.scroll.listener && state.scroll.scroller) state.scroll.scroller.removeEventListener("scroll", state.scroll.listener);
      state.scroll.listener = null;
      state.scroll.scroller = null;
      state.scroll.activeThreadId = "";
      clearRestoreTimers();
      return;
    }
    const nextId = currentThreadId();
    const nextScroller = threadScroller();
    if (!nextId || !nextScroller) return;
    if (state.scroll.activeThreadId === nextId && state.scroll.scroller === nextScroller) return;
    if (state.scroll.activeThreadId && state.scroll.scroller) writeScrollEntry(state.scroll.activeThreadId, state.scroll.scroller);
    if (state.scroll.listener && state.scroll.scroller) state.scroll.scroller.removeEventListener("scroll", state.scroll.listener);
    state.scroll.activeThreadId = nextId;
    state.scroll.scroller = nextScroller;
    state.scroll.cancelledThreadId = "";
    state.scroll.listener = () => writeScrollEntry(nextId, nextScroller);
    nextScroller.addEventListener("scroll", state.scroll.listener, { passive: true });
    restoreScroll(nextId, nextScroller);
  }

  function ensureRuntimeListeners() {
    if (!state.menuDismissPointerListener) {
      state.menuDismissPointerListener = (event) => {
        if (!isInsideOpenMenu(event.target)) closeMenus();
      };
      document.addEventListener("pointerdown", state.menuDismissPointerListener, true);
    }
    if (!state.menuDismissFocusListener) {
      state.menuDismissFocusListener = (event) => {
        if (!isInsideOpenMenu(event.target)) closeMenus();
      };
      document.addEventListener("focusin", state.menuDismissFocusListener, true);
    }
    if (!state.menuDismissKeyListener) {
      state.menuDismissKeyListener = (event) => {
        if (event.key !== "Escape" || !document.querySelector(`.${menuClass}`)) return;
        event.preventDefault();
        event.stopPropagation();
        closeMenus({ restoreFocus: true });
      };
      document.addEventListener("keydown", state.menuDismissKeyListener, true);
    }
    if (!state.menuDismissScrollListener) {
      state.menuDismissScrollListener = closeMenus;
      document.addEventListener("scroll", state.menuDismissScrollListener, true);
    }
    if (!state.menuDismissResizeListener) {
      state.menuDismissResizeListener = closeMenus;
      window.addEventListener("resize", state.menuDismissResizeListener);
    }
    if (!state.menuDismissBlurListener) {
      state.menuDismissBlurListener = closeMenus;
      window.addEventListener("blur", state.menuDismissBlurListener);
    }
    if (!state.pointerMoveListener) {
      state.pointerMoveListener = (event) => {
        const button = event.target?.closest?.(`[${moreAttribute}="true"]`);
        const row = event.target?.closest?.("[data-app-action-sidebar-thread-id]");
        const reference = String(button?.getAttribute(moreThreadAttribute) || rowReference(row)).trim();
        state.hoveredReference = canonicalThreadId(reference) ? reference : null;
        updateMoreVisibility();
      };
      document.addEventListener("pointermove", state.pointerMoveListener, true);
    }
    if (!state.pointerLeaveListener) {
      state.pointerLeaveListener = () => { state.hoveredReference = null; updateMoreVisibility(); };
      document.addEventListener("pointerleave", state.pointerLeaveListener, true);
    }
    if (!state.scrollLayoutListener) {
      state.scrollLayoutListener = queueScan;
      document.addEventListener("scroll", state.scrollLayoutListener, true);
    }
    if (!state.resizeListener) {
      state.resizeListener = queueScan;
      window.addEventListener("resize", state.resizeListener);
    }
    if (!state.routePointerListener) {
      state.routePointerListener = (event) => {
        const row = event.target?.closest?.("[data-app-action-sidebar-thread-id]");
        if (!row || !state.settings.threadScrollRestore) return;
        if (state.scroll.activeThreadId && state.scroll.scroller) writeScrollEntry(state.scroll.activeThreadId, state.scroll.scroller);
        state.scroll.cancelledThreadId = "";
        window.setTimeout(queueScan, 0);
      };
      document.addEventListener("pointerdown", state.routePointerListener, true);
      for (const eventName of ["wheel", "touchstart"]) {
        document.addEventListener(eventName, () => {
          if (state.scroll.activeThreadId) state.scroll.cancelledThreadId = state.scroll.activeThreadId;
          clearRestoreTimers();
        }, { capture: true, passive: true });
      }
    }
  }

  function scan() {
    state.scanQueued = false;
    if (!document.documentElement) return;
    ensureStyle();
    ensureOverlay();
    ensureRuntimeListeners();
    const rows = sidebarRows();
    refreshMoreButtons(rows);
    refreshBadges(rows);
    configurePasteFix();
    applyConversationView();
    configureScrollRestore();
  }

  function queueScan() {
    if (state.scanQueued) return;
    state.scanQueued = true;
    (window.requestAnimationFrame || window.setTimeout)(scan);
  }

  if (!state.observer && document.documentElement) {
    state.observer = new MutationObserver(queueScan);
    state.observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-app-action-sidebar-thread-id", "aria-current"],
      childList: true,
      subtree: true,
    });
  }

  window.__codexTokenBarSessionEnhancementsHealth = () => {
    scan();
    const rows = sidebarRows().filter((row) => canonicalThreadId(rowReference(row)));
    return {
      runtimeVersion,
      settings: { ...state.settings },
      eligibleRowCount: rows.length,
      moreButtonCount: document.querySelectorAll(`[${moreAttribute}="true"]`).length,
      badgeCount: document.querySelectorAll(`[${badgeAttribute}="true"]`).length,
      pasteFixInstalled: Boolean(state.pasteListener),
      conversationElementCount: state.conversationElements.size,
      scrollRestoreInstalled: Boolean(state.scroll.listener),
    };
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", scan, { once: true });
  }
  scan();
  queueScan();
})();

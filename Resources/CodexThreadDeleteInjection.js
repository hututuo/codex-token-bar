(() => {
  const owner = __CTB_OWNER_JSON__;
  const bindingName = __CTB_BINDING_JSON__;
  const stateKey = "__codexTokenBarThreadDeleteState";
  const styleId = "codex-token-bar-thread-delete-style";
  const overlayId = "codex-token-bar-thread-delete-overlay";
  const buttonAttribute = "data-codex-token-bar-thread-delete";
  const buttonThreadAttribute = "data-codex-token-bar-thread-delete-thread-id";
  const runtimeVersion = 3;
  const bridgeTimeoutMs = Number(window.__CODEX_TOKEN_BAR_DELETE_BRIDGE_TIMEOUT_MS__) || 25000;
  const requestedSettings = window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ || {};

  const state = window[stateKey] || {
    version: 2,
    runtimeVersion,
    bridges: new Map(),
    observer: null,
    documentReadyListener: null,
    scanQueued: false,
    sequence: 0,
    overlay: null,
    buttonsByReference: new Map(),
    hoveredThreadReference: null,
    pointerMoveListener: null,
    pointerLeaveListener: null,
    scrollListener: null,
    resizeListener: null,
  };
  if (state.runtimeVersion !== runtimeVersion) {
    state.observer?.disconnect?.();
    if (state.pointerMoveListener) {
      document.removeEventListener("pointermove", state.pointerMoveListener, true);
    }
    if (state.pointerLeaveListener) {
      document.removeEventListener("pointerleave", state.pointerLeaveListener, true);
    }
    if (state.scrollListener) {
      document.removeEventListener("scroll", state.scrollListener, true);
    }
    if (state.resizeListener) {
      window.removeEventListener("resize", state.resizeListener);
    }
    document.querySelectorAll(`[${buttonAttribute}="true"]`).forEach((button) => button.remove());
    document.getElementById(overlayId)?.remove();
    document.getElementById(styleId)?.remove();
    state.observer = null;
    state.scanQueued = false;
    state.overlay = null;
    state.buttonsByReference = new Map();
    state.hoveredThreadReference = null;
    state.pointerMoveListener = null;
    state.pointerLeaveListener = null;
    state.scrollListener = null;
    state.resizeListener = null;
  }
  state.version = 2;
  state.runtimeVersion = runtimeVersion;
  state.enhancementSettings = {
    sessionDelete: requestedSettings.sessionDelete !== false,
    markdownExport: requestedSettings.markdownExport === true,
    pasteFix: requestedSettings.pasteFix === true,
    projectMove: requestedSettings.projectMove === true,
    threadIDBadge: requestedSettings.threadIDBadge === true,
    conversationView: requestedSettings.conversationView === true,
    conversationViewMaxWidth: Math.max(320, Math.min(4000, Number(requestedSettings.conversationViewMaxWidth) || 900)),
    threadScrollRestore: requestedSettings.threadScrollRestore === true,
  };
  state.documentReadyListener ||= null;
  state.buttonsByReference ||= new Map();
  state.hoveredThreadReference ||= null;
  window[stateKey] = state;

  const previousBridge = state.bridges.get(owner);
  const callbacks = previousBridge?.callbacks || new Map();
  const bridge = {
    owner,
    bindingName,
    callbacks,
    rank: ++state.sequence,
    invoke(payload) {
      return new Promise((resolve, reject) => {
        const nativeBinding = window[bindingName];
        if (typeof nativeBinding !== "function") {
          reject(new Error("删除桥接暂不可用"));
          return;
        }
        const requestId = `${owner}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
        const timer = window.setTimeout(() => {
          callbacks.delete(requestId);
          reject(new Error("删除请求超时"));
        }, bridgeTimeoutMs);
        callbacks.set(requestId, {
          resolve(result) {
            window.clearTimeout(timer);
            callbacks.delete(requestId);
            resolve(result);
          },
        });
        try {
          nativeBinding(JSON.stringify({
            id: requestId,
            owner,
            action: payload.action || "delete",
            ...payload,
          }));
        } catch (error) {
          window.clearTimeout(timer);
          callbacks.delete(requestId);
          reject(error);
        }
      });
    },
  };
  state.bridges.set(owner, bridge);

  window.__codexTokenBarThreadDeleteResolve = (targetOwner, requestId, result) => {
    const target = state.bridges.get(targetOwner);
    target?.callbacks.get(requestId)?.resolve(result);
  };

  state.callDelete = async (payload) => {
    const bridges = [...state.bridges.values()]
      .sort((left, right) => right.rank - left.rank);
    let lastError = new Error("没有可用的删除桥接");
    for (const candidate of bridges) {
      try {
        return await candidate.invoke(payload);
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(String(error));
      }
    }
    throw lastError;
  };
  window.__codexTokenBarSessionEnhancementInvoke = (payload) => state.callDelete(payload);

  function ensureStyle() {
    const existing = document.getElementById(styleId);
    if (existing?.dataset.codexTokenBarRuntimeVersion === String(runtimeVersion)) return true;
    existing?.remove();
    const host = document.head || document.documentElement;
    if (!host) return false;
    const style = document.createElement("style");
    style.id = styleId;
    style.dataset.codexTokenBarRuntimeVersion = String(runtimeVersion);
    style.textContent = `
      #${overlayId} {
        height: 0;
        inset: 0;
        overflow: visible;
        pointer-events: none;
        position: fixed;
        width: 0;
        z-index: 2147483000;
      }
      #${overlayId} [${buttonAttribute}="true"] {
        align-items: center;
        background: color-mix(in srgb, Canvas 88%, transparent);
        border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
        border-radius: 5px;
        color: color-mix(in srgb, currentColor 68%, transparent);
        cursor: pointer;
        display: inline-flex;
        height: 24px;
        justify-content: center;
        opacity: 0;
        padding: 0;
        pointer-events: none;
        position: fixed;
        transition: opacity 120ms ease, color 120ms ease, background 120ms ease;
        width: 24px;
        z-index: 1;
      }
      #${overlayId} [${buttonAttribute}="true"][data-visible="true"],
      #${overlayId} [${buttonAttribute}="true"]:focus-visible {
        opacity: 1;
        pointer-events: auto;
      }
      #${overlayId} [${buttonAttribute}="true"]:hover {
        background: color-mix(in srgb, #dc2626 13%, Canvas);
        color: #dc2626;
      }
      #${overlayId} [${buttonAttribute}="true"]:disabled {
        cursor: wait;
        opacity: .55;
        pointer-events: auto;
      }
      .codex-token-bar-delete-toast {
        background: color-mix(in srgb, Canvas 94%, transparent);
        border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
        border-radius: 6px;
        bottom: 22px;
        color: CanvasText;
        font: 500 13px/1.4 system-ui, sans-serif;
        left: 50%;
        max-width: min(420px, calc(100vw - 32px));
        padding: 9px 12px;
        position: fixed;
        transform: translateX(-50%);
        z-index: 2147483647;
      }
    `;
    host.appendChild(style);
    return true;
  }

  function showToast(message) {
    document.querySelectorAll(".codex-token-bar-delete-toast").forEach((node) => node.remove());
    const toast = document.createElement("div");
    toast.className = "codex-token-bar-delete-toast";
    toast.setAttribute("role", "status");
    toast.textContent = message;
    document.body.appendChild(toast);
    window.setTimeout(() => toast.remove(), 5000);
  }

  function rowTitle(row) {
    const title = row.querySelector('[data-testid="thread-title"], [data-thread-title], .truncate');
    return (title?.textContent || row.textContent || "未命名会话").trim().slice(0, 160);
  }

  function stopRowNavigation(event) {
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation?.();
  }

  function canonicalThreadId(value) {
    const match = /^(?:local:)?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i.exec(value);
    return match?.[1] || null;
  }

  function ensureOverlay() {
    if (state.overlay?.isConnected) return state.overlay;
    const host = document.body || document.documentElement;
    if (!host) {
      ensureDocumentReadyRetry();
      return null;
    }
    let overlay = document.getElementById(overlayId);
    if (!overlay) {
      overlay = document.createElement("div");
      overlay.id = overlayId;
      overlay.setAttribute("aria-hidden", "false");
      host.appendChild(overlay);
    }
    state.overlay = overlay;
    state.buttonsByReference = new Map(
      [...overlay.querySelectorAll(`[${buttonAttribute}="true"]`)]
        .map((button) => [button.getAttribute(buttonThreadAttribute) || "", button])
        .filter(([reference]) => reference),
    );
    return overlay;
  }

  function rowForReference(threadReference) {
    return [...document.querySelectorAll("[data-app-action-sidebar-thread-id]")]
      .find((row) => (
        row.getAttribute("data-app-action-sidebar-thread-id") || ""
      ).trim() === threadReference) || null;
  }

  function positionButton(button, row) {
    const rect = row.getBoundingClientRect();
    const visible = rect.width > 0 && rect.height > 0
      && rect.bottom > 0 && rect.top < window.innerHeight
      && rect.right > 0 && rect.left < window.innerWidth;
    button.style.visibility = visible ? "visible" : "hidden";
    if (!visible) return;
    button.style.left = `${Math.round(rect.right - 54)}px`;
    button.style.top = `${Math.round(rect.top + (rect.height - 24) / 2)}px`;
  }

  function updateButtonVisibility() {
    for (const [threadReference, button] of state.buttonsByReference) {
      button.dataset.visible = String(
        threadReference === state.hoveredThreadReference || button === document.activeElement,
      );
    }
  }

  async function deleteFromButton(button, event) {
    stopRowNavigation(event);
    const threadReference = (button.getAttribute(buttonThreadAttribute) || "").trim();
    const row = rowForReference(threadReference);
    const currentThreadId = canonicalThreadId(threadReference);
    if (!row || !currentThreadId) {
      showToast("删除失败：当前会话 ID 不可用，请刷新侧栏后重试");
      return;
    }
    const title = rowTitle(row);
    if (!window.confirm(`永久删除“${title}”？\n\n该会话及其派生会话将被删除，无法撤销。`)) return;
    button.disabled = true;
    try {
      const result = await state.callDelete({ threadId: currentThreadId, title });
      if (result?.status !== "deleted") {
        throw new Error(result?.message || "删除失败");
      }
      const current = row.getAttribute("aria-current") === "page"
        || row.getAttribute("aria-current") === "true"
        || window.location.href.includes(currentThreadId);
      row.remove();
      button.remove();
      state.buttonsByReference.delete(threadReference);
      showToast(result.message || "会话已永久删除");
      if (current) window.setTimeout(() => window.location.reload(), 120);
    } catch (error) {
      button.disabled = false;
      showToast(`删除失败：${error?.message || error}`);
    }
  }

  function createButton(threadReference) {
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute(buttonAttribute, "true");
    button.setAttribute(buttonThreadAttribute, threadReference);
    button.innerHTML = '<svg aria-hidden="true" fill="none" height="14" viewBox="0 0 24 24" width="14"><path d="M3 6h18M8 6V4h8v2m3 0-1 14H6L5 6m5 5v5m4-5v5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2"/></svg>';
    for (const eventName of ["pointerdown", "mousedown", "mouseup", "touchstart"]) {
      button.addEventListener(eventName, stopRowNavigation, true);
    }
    button.addEventListener("click", (event) => deleteFromButton(button, event), true);
    button.addEventListener("focus", updateButtonVisibility, true);
    button.addEventListener("blur", updateButtonVisibility, true);
    return button;
  }

  function attachButton(row, liveReferences) {
    const threadReference = (
      row.getAttribute("data-app-action-sidebar-thread-id") || ""
    ).trim();
    if (!canonicalThreadId(threadReference)) return;
    liveReferences.add(threadReference);
    const overlay = ensureOverlay();
    if (!overlay) return;
    let button = state.buttonsByReference.get(threadReference);
    if (!button?.isConnected || button.parentElement !== overlay) {
      button = createButton(threadReference);
      overlay.appendChild(button);
      state.buttonsByReference.set(threadReference, button);
    }
    button.setAttribute("aria-label", `永久删除会话：${rowTitle(row)}`);
    positionButton(button, row);
  }

  function scan() {
    state.scanQueued = false;
    ensureObserver();
    if (!document.documentElement) return;
    ensureStyle();
    ensureRuntimeListeners();
    ensureOverlay();
    const rows = [...document.querySelectorAll("[data-app-action-sidebar-thread-id]")];
    const liveReferences = new Set();
    if (state.enhancementSettings.sessionDelete) {
      rows.forEach((row) => attachButton(row, liveReferences));
    }
    for (const [threadReference, button] of state.buttonsByReference) {
      if (liveReferences.has(threadReference) && button.isConnected) continue;
      button.remove();
      state.buttonsByReference.delete(threadReference);
    }
    if (!liveReferences.has(state.hoveredThreadReference)) {
      const hoveredRow = rows.find((row) => row.matches?.(":hover"));
      const hoveredReference = (
        hoveredRow?.getAttribute("data-app-action-sidebar-thread-id") || ""
      ).trim();
      state.hoveredThreadReference = canonicalThreadId(hoveredReference)
        ? hoveredReference
        : null;
    }
    updateButtonVisibility();
  }

  function queueScan() {
    if (state.scanQueued) return;
    state.scanQueued = true;
    window.requestAnimationFrame ? window.requestAnimationFrame(scan) : window.setTimeout(scan, 0);
  }

  function ensureObserver() {
    if (state.observer) return true;
    if (!document.documentElement) {
      ensureDocumentReadyRetry();
      return false;
    }
    state.observer = new MutationObserver((mutations) => {
      const overlay = state.overlay;
      const outsideOverlay = mutations.some((mutation) => (
        !overlay || (mutation.target !== overlay && !overlay.contains(mutation.target))
      ));
      if (outsideOverlay) queueScan();
    });
    state.observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-app-action-sidebar-thread-id"],
      childList: true,
      subtree: true,
    });
    return true;
  }

  function ensureRuntimeListeners() {
    if (!state.pointerMoveListener) {
      state.pointerMoveListener = (event) => {
        const target = event.target;
        const button = target?.closest?.(`[${buttonAttribute}="true"]`);
        const row = target?.closest?.("[data-app-action-sidebar-thread-id]");
        const threadReference = (
          button?.getAttribute(buttonThreadAttribute)
          || row?.getAttribute("data-app-action-sidebar-thread-id")
          || ""
        ).trim();
        state.hoveredThreadReference = canonicalThreadId(threadReference)
          ? threadReference
          : null;
        updateButtonVisibility();
      };
      document.addEventListener("pointermove", state.pointerMoveListener, true);
    }
    if (!state.pointerLeaveListener) {
      state.pointerLeaveListener = () => {
        state.hoveredThreadReference = null;
        updateButtonVisibility();
      };
      document.addEventListener("pointerleave", state.pointerLeaveListener, true);
    }
    if (!state.scrollListener) {
      state.scrollListener = () => {
        state.hoveredThreadReference = null;
        updateButtonVisibility();
        queueScan();
      };
      document.addEventListener("scroll", state.scrollListener, true);
    }
    if (!state.resizeListener) {
      state.resizeListener = queueScan;
      window.addEventListener("resize", state.resizeListener);
    }
  }

  function ensureDocumentReadyRetry() {
    if (state.documentReadyListener) return;
    const listener = () => {
      if (!document.documentElement) return;
      document.removeEventListener("DOMContentLoaded", listener);
      document.removeEventListener("readystatechange", listener);
      state.documentReadyListener = null;
      scan();
    };
    state.documentReadyListener = listener;
    document.addEventListener("DOMContentLoaded", listener);
    document.addEventListener("readystatechange", listener);
    window.setTimeout(listener, 0);
  }

  window.__codexTokenBarThreadDeleteHealth = (targetOwner, expectedBindingName) => {
    let scanError = null;
    try {
      scan();
    } catch (error) {
      scanError = error?.message || String(error);
    }
    const targetBridge = state.bridges.get(targetOwner);
    const candidateRows = document.documentElement
      ? [...document.querySelectorAll("[data-app-action-sidebar-thread-id]")]
      : [];
    const eligibleRows = candidateRows.filter((row) => canonicalThreadId((
      row.getAttribute("data-app-action-sidebar-thread-id") || ""
    ).trim()) !== null);
    const eligibleReferences = eligibleRows.map((row) => (
      row.getAttribute("data-app-action-sidebar-thread-id") || ""
    ).trim());
    const eligibleReferenceSet = new Set(eligibleReferences);
    const buttons = document.documentElement
      ? [...document.querySelectorAll(`[${buttonAttribute}="true"]`)]
      : [];
    const buttonReference = (button) => (
      button.getAttribute(buttonThreadAttribute)
      || button.closest?.("[data-app-action-sidebar-thread-id]")
        ?.getAttribute("data-app-action-sidebar-thread-id")
      || ""
    ).trim();
    const rowButtonCounts = eligibleReferences.map((reference) => (
      buttons.filter((button) => buttonReference(button) === reference).length
    ));
    const buttonCount = buttons.length;
    const attachedRowCount = rowButtonCounts.filter((count) => count > 0).length;
    const missingButtonCount = rowButtonCounts.filter((count) => count === 0).length;
    const duplicateButtonCount = rowButtonCounts.reduce(
      (total, count) => total + Math.max(0, count - 1),
      0,
    );
    const orphanButtonCount = buttons.filter((button) => (
      !eligibleReferenceSet.has(buttonReference(button))
    )).length;
    const bridgeRegistered = Boolean(targetBridge);
    const bindingMatches = targetBridge?.bindingName === expectedBindingName;
    const bindingAvailable = typeof window[expectedBindingName] === "function";
    const installedStyle = document.getElementById(styleId);
    const styleInstalled = Boolean(
      installedStyle?.dataset.codexTokenBarRuntimeVersion === String(runtimeVersion)
      && state.overlay?.isConnected,
    );
    const observerInstalled = Boolean(state.observer);
    const deleteEnabled = state.enhancementSettings.sessionDelete;
    let sessionEnhancementsInstalled = false;
    let sessionEnhancementError = null;
    try {
      const sessionHealth = window.__codexTokenBarSessionEnhancementsHealth?.();
      sessionEnhancementsInstalled = sessionHealth?.runtimeVersion === 1;
    } catch (error) {
      sessionEnhancementError = error?.message || String(error);
    }
    let readiness = "failed";
    if (!scanError && bridgeRegistered && bindingMatches && bindingAvailable
      && styleInstalled && observerInstalled) {
      if (candidateRows.length === 0 && eligibleRows.length === 0 && buttonCount === 0) {
        readiness = "waitingForRows";
      } else if (!deleteEnabled
        && candidateRows.length === eligibleRows.length
        && buttonCount === 0) {
        readiness = "ready";
      } else if (deleteEnabled
        && candidateRows.length === eligibleRows.length
        && eligibleRows.length > 0
        && missingButtonCount === 0
        && duplicateButtonCount === 0
        && orphanButtonCount === 0
        && buttonCount === eligibleRows.length) {
        readiness = "ready";
      }
    }
    return {
      schemaVersion: state.version,
      owner: targetOwner,
      bridgeRegistered,
      bindingMatches,
      bindingAvailable,
      deleteEnabled,
      sessionEnhancementsInstalled,
      sessionEnhancementError,
      candidateRowCount: candidateRows.length,
      eligibleRowCount: eligibleRows.length,
      attachedRowCount,
      buttonCount,
      missingButtonCount,
      duplicateButtonCount,
      orphanButtonCount,
      styleInstalled,
      observerInstalled,
      scanError,
      readiness,
    };
  };

  ensureObserver();
  scan();
  queueScan();
})();

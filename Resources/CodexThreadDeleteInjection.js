(() => {
  const owner = __CTB_OWNER_JSON__;
  const bindingName = __CTB_BINDING_JSON__;
  const stateKey = "__codexTokenBarThreadDeleteState";
  const styleId = "codex-token-bar-thread-delete-style";
  const buttonAttribute = "data-codex-token-bar-thread-delete";
  const buttonThreadAttribute = "data-codex-token-bar-thread-delete-thread-id";
  const rowAttribute = "data-codex-token-bar-thread-delete-row";
  const bridgeTimeoutMs = Number(window.__CODEX_TOKEN_BAR_DELETE_BRIDGE_TIMEOUT_MS__) || 25000;

  const state = window[stateKey] || {
    version: 2,
    bridges: new Map(),
    observer: null,
    documentReadyListener: null,
    scanQueued: false,
    sequence: 0,
  };
  state.version = 2;
  state.documentReadyListener ||= null;
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
            threadId: payload.threadId,
            title: payload.title,
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

  function ensureStyle() {
    if (document.getElementById(styleId)) return true;
    const host = document.head || document.documentElement;
    if (!host) return false;
    const style = document.createElement("style");
    style.id = styleId;
    style.textContent = `
      [${rowAttribute}="true"] { position: relative !important; }
      [${buttonAttribute}="true"] {
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
        position: absolute;
        right: 30px;
        top: 50%;
        transform: translateY(-50%);
        transition: opacity 120ms ease, color 120ms ease, background 120ms ease;
        width: 24px;
        z-index: 5;
      }
      [${rowAttribute}="true"]:hover [${buttonAttribute}="true"],
      [${buttonAttribute}="true"]:focus-visible {
        opacity: 1;
      }
      [${buttonAttribute}="true"]:hover {
        background: color-mix(in srgb, #dc2626 13%, Canvas);
        color: #dc2626;
      }
      [${buttonAttribute}="true"]:disabled { cursor: wait; opacity: .55; }
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

  function isTrustedThreadId(value) {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
  }

  function attachButton(row) {
    const threadId = (row.getAttribute("data-app-action-sidebar-thread-id") || "").trim();
    const existingButton = row.querySelector(`[${buttonAttribute}="true"]`);
    if (!isTrustedThreadId(threadId)) {
      existingButton?.remove();
      row.removeAttribute(rowAttribute);
      return;
    }
    if (existingButton?.getAttribute(buttonThreadAttribute) === threadId) return;
    existingButton?.remove();
    row.setAttribute(rowAttribute, "true");
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute(buttonAttribute, "true");
    button.setAttribute(buttonThreadAttribute, threadId);
    button.setAttribute("aria-label", `永久删除会话：${rowTitle(row)}`);
    button.innerHTML = '<svg aria-hidden="true" fill="none" height="14" viewBox="0 0 24 24" width="14"><path d="M3 6h18M8 6V4h8v2m3 0-1 14H6L5 6m5 5v5m4-5v5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2"/></svg>';
    for (const eventName of ["pointerdown", "mousedown", "mouseup", "touchstart"]) {
      button.addEventListener(eventName, stopRowNavigation, true);
    }
    button.addEventListener("click", async (event) => {
      stopRowNavigation(event);
      const currentThreadId = (
        row.getAttribute("data-app-action-sidebar-thread-id") || ""
      ).trim();
      if (!isTrustedThreadId(currentThreadId)) {
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
        showToast(result.message || "会话已永久删除");
        if (current) window.setTimeout(() => window.location.reload(), 120);
      } catch (error) {
        button.disabled = false;
        showToast(`删除失败：${error?.message || error}`);
      }
    }, true);
    row.appendChild(button);
  }

  function scan() {
    state.scanQueued = false;
    ensureObserver();
    if (!document.documentElement) return;
    ensureStyle();
    document.querySelectorAll("[data-app-action-sidebar-thread-id]").forEach(attachButton);
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
    state.observer = new MutationObserver(queueScan);
    state.observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-app-action-sidebar-thread-id"],
      childList: true,
      subtree: true,
    });
    return true;
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
    const eligibleRows = candidateRows.filter((row) => isTrustedThreadId((
      row.getAttribute("data-app-action-sidebar-thread-id") || ""
    ).trim()));
    const rowButtonCounts = eligibleRows.map((row) => (
      row.querySelectorAll(`[${buttonAttribute}="true"]`).length
    ));
    const buttonCount = document.documentElement
      ? document.querySelectorAll(`[${buttonAttribute}="true"]`).length
      : 0;
    const attachedRowCount = rowButtonCounts.filter((count) => count > 0).length;
    const missingButtonCount = rowButtonCounts.filter((count) => count === 0).length;
    const duplicateButtonCount = rowButtonCounts.reduce(
      (total, count) => total + Math.max(0, count - 1),
      0,
    );
    const buttonsInsideEligibleRows = rowButtonCounts.reduce((total, count) => total + count, 0);
    const orphanButtonCount = Math.max(0, buttonCount - buttonsInsideEligibleRows);
    const bridgeRegistered = Boolean(targetBridge);
    const bindingMatches = targetBridge?.bindingName === expectedBindingName;
    const bindingAvailable = typeof window[expectedBindingName] === "function";
    const styleInstalled = Boolean(document.getElementById(styleId));
    const observerInstalled = Boolean(state.observer);
    let readiness = "failed";
    if (!scanError && bridgeRegistered && bindingMatches && bindingAvailable
      && styleInstalled && observerInstalled) {
      if (candidateRows.length === 0 && eligibleRows.length === 0 && buttonCount === 0) {
        readiness = "waitingForRows";
      } else if (candidateRows.length === eligibleRows.length
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

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { Window } from "happy-dom";

const here = path.dirname(fileURLToPath(import.meta.url));
const deleteTemplate = fs.readFileSync(
  path.resolve(here, "../../../Resources/CodexThreadDeleteInjection.js"),
  "utf8",
);
const enhancementTemplate = fs.readFileSync(
  path.resolve(here, "../../../Resources/CodexSessionEnhancementsInjection.js"),
  "utf8",
);

const defaultSettings = {
  sessionDelete: true,
  markdownExport: true,
  pasteFix: false,
  projectMove: true,
  threadIDBadge: false,
  conversationView: false,
  conversationViewMaxWidth: 900,
  threadScrollRestore: true,
};

function renderedScript(settings = {}, owner = "swift", binding = "codexTokenBarDeleteSwift") {
  const configuration = { ...defaultSettings, ...settings };
  const deleteScript = deleteTemplate
    .replaceAll("__CTB_OWNER_JSON__", JSON.stringify(owner))
    .replaceAll("__CTB_BINDING_JSON__", JSON.stringify(binding));
  return `window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = ${JSON.stringify(configuration)};\n${deleteScript}\n${enhancementTemplate}`;
}

function sidebarRow(document, reference, title, active = false) {
  const row = document.createElement("a");
  row.setAttribute("data-app-action-sidebar-thread-id", reference);
  if (active) row.setAttribute("aria-current", "page");
  const label = document.createElement("span");
  label.className = "truncate";
  label.textContent = title;
  row.appendChild(label);
  document.body.appendChild(row);
  return row;
}

function projectRow(document, projectPath, label) {
  const row = document.createElement("div");
  row.setAttribute("data-app-action-sidebar-project-row", "true");
  row.setAttribute("data-app-action-sidebar-project-id", projectPath);
  row.setAttribute("data-app-action-sidebar-project-label", label);
  document.body.appendChild(row);
  return row;
}

async function flush(window, milliseconds = 20) {
  await new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

async function cleanupWindow(window) {
  const state = window.__codexTokenBarSessionEnhancementsState;
  if (state?.conversationPoll) window.clearInterval(state.conversationPoll);
  for (const timer of state?.scroll?.restoreTimers || []) window.clearTimeout(timer);
  state?.observer?.disconnect?.();
  state?.conversationObserver?.disconnect?.();
  state?.conversationResizeObserver?.disconnect?.();
  await window.happyDOM.abort();
  window.close();
}

test("session more menu exports real Markdown through the native bridge", async () => {
  const window = new Window({ url: "app://codex/" });
  const threadId = "019f5a7c-1234-7abc-8def-0123456789ab";
  sidebarRow(window.document, `local:${threadId}`, "导出会话");
  const calls = [];
  let written = "";
  window.showSaveFilePicker = async () => ({
    createWritable: async () => ({
      write: async (value) => { written = value; },
      close: async () => {},
    }),
  });
  window.codexTokenBarDeleteSwift = (payloadText) => {
    const payload = JSON.parse(payloadText);
    calls.push(payload);
    window.__codexTokenBarThreadDeleteResolve(payload.owner, payload.id, {
      status: "exported",
      message: "已生成 Markdown",
      filename: "导出会话.md",
      markdown: "# 导出会话\n",
    });
  };

  window.eval(renderedScript({ sessionDelete: false, projectMove: false }));
  const more = window.document.querySelector('[data-codex-token-bar-session-more="true"]');
  assert.ok(more);
  assert.equal(
    window.__codexTokenBarThreadDeleteHealth("swift", "codexTokenBarDeleteSwift")
      .sessionEnhancementsInstalled,
    true,
  );
  more.click();
  const exportItem = [...window.document.querySelectorAll(".codex-token-bar-session-menu button")]
    .find((button) => button.textContent.includes("导出"));
  assert.ok(exportItem);
  exportItem.click();
  await flush(window);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].action, "exportMarkdown");
  assert.equal(calls[0].threadId, threadId);
  assert.equal(written, "# 导出会话\n");
  await cleanupWindow(window);
});

test("session more menu dismisses outside, on Escape, scroll, resize and focus loss", async () => {
  const window = new Window({ url: "app://codex/" });
  sidebarRow(window.document, "019f5a7c-1334-7abc-8def-0123456789ab", "菜单收口");
  const outside = window.document.createElement("button");
  outside.textContent = "页面其他区域";
  window.document.body.appendChild(outside);
  window.codexTokenBarDeleteSwift = () => {};

  window.eval(renderedScript({ sessionDelete: false, projectMove: false }));
  const more = window.document.querySelector('[data-codex-token-bar-session-more="true"]');
  assert.ok(more);

  more.click();
  let menu = window.document.querySelector(".codex-token-bar-session-menu");
  assert.ok(menu);
  assert.equal(more.getAttribute("aria-expanded"), "true");
  menu.dispatchEvent(new window.Event("pointerdown", { bubbles: true }));
  assert.ok(window.document.querySelector(".codex-token-bar-session-menu"));

  outside.dispatchEvent(new window.Event("pointerdown", { bubbles: true }));
  assert.equal(window.document.querySelector(".codex-token-bar-session-menu"), null);
  assert.equal(more.getAttribute("aria-expanded"), "false");

  more.click();
  window.document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  assert.equal(window.document.querySelector(".codex-token-bar-session-menu"), null);
  assert.equal(window.document.activeElement, more);

  more.click();
  window.document.dispatchEvent(new window.Event("scroll"));
  assert.equal(window.document.querySelector(".codex-token-bar-session-menu"), null);

  more.click();
  window.dispatchEvent(new window.Event("resize"));
  assert.equal(window.document.querySelector(".codex-token-bar-session-menu"), null);

  more.click();
  outside.dispatchEvent(new window.FocusEvent("focusin", { bubbles: true }));
  assert.equal(window.document.querySelector(".codex-token-bar-session-menu"), null);
  await cleanupWindow(window);
});

test("a runtime upgrade replaces more buttons that still hold old injected handlers", async () => {
  const window = new Window({ url: "app://codex/" });
  sidebarRow(window.document, "019f5a7c-1434-7abc-8def-0123456789ab", "热升级会话");
  window.codexTokenBarDeleteSwift = () => {};

  const legacyScript = renderedScript({ sessionDelete: false, projectMove: false })
    .replaceAll("const runtimeVersion = 3;", "const runtimeVersion = 2;");
  window.eval(legacyScript);
  const legacyMore = window.document.querySelector('[data-codex-token-bar-session-more="true"]');
  assert.ok(legacyMore);

  window.eval(renderedScript({ sessionDelete: false, projectMove: false }));
  const upgradedMore = window.document.querySelector('[data-codex-token-bar-session-more="true"]');
  assert.ok(upgradedMore);
  assert.notEqual(upgradedMore, legacyMore);
  assert.equal(legacyMore.isConnected, false);
  assert.equal(upgradedMore.getAttribute("aria-haspopup"), "menu");
  assert.equal(window.__codexTokenBarSessionEnhancementsState.runtimeVersion, 3);
  await cleanupWindow(window);
});

test("project move menu sends the selected native project path", async () => {
  const window = new Window({ url: "app://codex/" });
  const threadId = "019f5a7c-2234-7abc-8def-0123456789ab";
  sidebarRow(window.document, threadId, "待移动会话");
  projectRow(window.document, "/tmp/project-alpha", "Project Alpha");
  const calls = [];
  window.codexTokenBarDeleteSwift = (payloadText) => {
    const payload = JSON.parse(payloadText);
    calls.push(payload);
    window.__codexTokenBarThreadDeleteResolve(payload.owner, payload.id, {
      status: "moved",
      message: "已移动对话",
      targetCwd: payload.targetCwd,
    });
  };

  window.eval(renderedScript({ sessionDelete: false, markdownExport: false }));
  window.document.querySelector('[data-codex-token-bar-session-more="true"]').click();
  const moveItem = [...window.document.querySelectorAll(".codex-token-bar-session-menu button")]
    .find((button) => button.textContent.includes("移动"));
  moveItem.click();
  const target = [...window.document.querySelectorAll(".ctb-project-list button")]
    .find((button) => button.textContent.includes("Project Alpha"));
  assert.ok(target);
  target.click();
  await flush(window, 40);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].action, "moveThreadWorkspace");
  assert.equal(calls[0].targetCwd, "/tmp/project-alpha");
  await cleanupWindow(window);
});

test("badges, paste fix, centered width and scroll persistence can run together", async () => {
  const window = new Window({ url: "app://codex/thread/019f5a7c-3234-7abc-8def-0123456789ab" });
  const threadId = "019f5a7c-3234-7abc-8def-0123456789ab";
  sidebarRow(window.document, threadId, "增强会话", true);
  window.codexTokenBarDeleteSwift = () => {};

  const content = window.document.createElement("div");
  content.className = "mx-auto w-full max-w-(--thread-content-max-width) px-toolbar relative flex shrink-0 flex-col pb-8";
  window.document.body.appendChild(content);
  const composer = window.document.createElement("div");
  composer.className = "relative z-10 flex flex-col mx-auto w-full max-w-(--thread-content-max-width) px-toolbar";
  window.document.body.appendChild(composer);
  const editable = window.document.createElement("div");
  editable.setAttribute("contenteditable", "true");
  window.document.body.appendChild(editable);
  const scroller = window.document.createElement("div");
  scroller.className = "thread-scroll-container";
  scroller.scrollTop = 42;
  window.document.body.appendChild(scroller);

  window.eval(renderedScript({
    sessionDelete: false,
    markdownExport: false,
    projectMove: false,
    threadIDBadge: true,
    pasteFix: true,
    conversationView: true,
    conversationViewMaxWidth: 1040,
    threadScrollRestore: true,
  }));
  await flush(window);

  const health = window.__codexTokenBarSessionEnhancementsHealth();
  assert.equal(health.badgeCount, 1);
  assert.equal(health.pasteFixInstalled, true);
  assert.equal(health.conversationElementCount, 2);
  assert.equal(health.scrollRestoreInstalled, true);
  assert.equal(content.style.maxWidth, "1040px");
  assert.equal(composer.style.maxWidth, "1040px");

  const paste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", { value: { getData: () => "纯文本" } });
  editable.dispatchEvent(paste);
  assert.equal(paste.defaultPrevented, true);

  scroller.scrollTop = 128;
  scroller.dispatchEvent(new window.Event("scroll"));
  const positions = JSON.parse(window.localStorage.getItem("codexTokenBar.threadScrollPositions.v1"));
  assert.equal(positions[threadId].top, 128);
  await cleanupWindow(window);
});

test("turning every feature off leaves the bridge healthy and removes page controls", async () => {
  const window = new Window({ url: "app://codex/" });
  sidebarRow(window.document, "019f5a7c-4234-7abc-8def-0123456789ab", "原生模式");
  window.codexTokenBarDeleteSwift = () => {};

  window.eval(renderedScript({
    sessionDelete: false,
    markdownExport: false,
    pasteFix: false,
    projectMove: false,
    threadIDBadge: false,
    conversationView: false,
    threadScrollRestore: false,
  }));

  const deleteHealth = window.__codexTokenBarThreadDeleteHealth("swift", "codexTokenBarDeleteSwift");
  const enhancementHealth = window.__codexTokenBarSessionEnhancementsHealth();
  assert.equal(deleteHealth.readiness, "ready");
  assert.equal(deleteHealth.deleteEnabled, false);
  assert.equal(deleteHealth.buttonCount, 0);
  assert.equal(enhancementHealth.moreButtonCount, 0);
  assert.equal(enhancementHealth.badgeCount, 0);
  assert.equal(enhancementHealth.pasteFixInstalled, false);
  await cleanupWindow(window);
});

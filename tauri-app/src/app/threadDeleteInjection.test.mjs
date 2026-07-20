import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { Window } from "happy-dom";

const here = path.dirname(fileURLToPath(import.meta.url));
const template = fs.readFileSync(
  path.resolve(here, "../../../Resources/CodexThreadDeleteInjection.js"),
  "utf8",
);

function renderedScript(owner = "tauri", binding = "codexTokenBarDeleteTauri") {
  return template
    .replaceAll("__CTB_OWNER_JSON__", JSON.stringify(owner))
    .replaceAll("__CTB_BINDING_JSON__", JSON.stringify(binding));
}

function sidebarRow(document, id, title) {
  const row = document.createElement("a");
  row.setAttribute("data-app-action-sidebar-thread-id", id);
  const label = document.createElement("span");
  label.className = "truncate";
  label.textContent = title;
  row.appendChild(label);
  document.body.appendChild(row);
  return row;
}

async function flush(window) {
  await new Promise((resolve) => window.setTimeout(resolve, 10));
}

test("injected delete control calls the native bridge and removes the row after success", async () => {
  const window = new Window({ url: "app://codex/" });
  const id = "019f5a7c-1234-7abc-8def-0123456789ab";
  const row = sidebarRow(window.document, id, "需要删除的会话");
  const calls = [];
  window.confirm = () => true;
  window.codexTokenBarDeleteTauri = (payloadText) => {
    const payload = JSON.parse(payloadText);
    calls.push(payload);
    window.__codexTokenBarThreadDeleteResolve(payload.owner, payload.id, {
      status: "deleted",
      message: "会话已永久删除",
    });
  };

  window.eval(renderedScript());
  await flush(window);
  const button = row.querySelector('[data-codex-token-bar-thread-delete="true"]');
  assert.ok(button);
  assert.equal(button.getAttribute("aria-label"), "永久删除会话：需要删除的会话");
  button.click();
  await flush(window);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].threadId, id);
  assert.equal(row.isConnected, false);
  assert.match(window.document.body.textContent, /会话已永久删除/);
});

test("repeated Swift and Tauri injection keeps one button and can fall through to a live bridge", async () => {
  const window = new Window({ url: "app://codex/" });
  const id = "019f5a7c-2234-7abc-8def-0123456789ab";
  const row = sidebarRow(window.document, id, "双端共存");
  window.confirm = () => true;
  window.__CODEX_TOKEN_BAR_DELETE_BRIDGE_TIMEOUT_MS__ = 20;
  window.codexTokenBarDeleteSwift = () => {};
  window.codexTokenBarDeleteTauri = (payloadText) => {
    const payload = JSON.parse(payloadText);
    window.__codexTokenBarThreadDeleteResolve(payload.owner, payload.id, { status: "deleted" });
  };

  window.eval(renderedScript("tauri", "codexTokenBarDeleteTauri"));
  window.eval(renderedScript("swift", "codexTokenBarDeleteSwift"));
  await flush(window);

  assert.equal(row.querySelectorAll('[data-codex-token-bar-thread-delete="true"]').length, 1);
  row.querySelector('[data-codex-token-bar-thread-delete="true"]').click();
  await new Promise((resolve) => window.setTimeout(resolve, 60));
  assert.equal(row.isConnected, false);
});

test("rows without a trusted thread id are not modified", async () => {
  const window = new Window({ url: "app://codex/" });
  const row = window.document.createElement("a");
  row.textContent = "没有 thread id";
  window.document.body.appendChild(row);
  window.codexTokenBarDeleteTauri = () => {};

  window.eval(renderedScript());
  await flush(window);

  assert.equal(row.querySelector('[data-codex-token-bar-thread-delete="true"]'), null);
});

test("health is JSON serializable and reports an empty sidebar as waiting", () => {
  const window = new Window({ url: "app://codex/" });
  window.codexTokenBarDeleteTauri = () => {};

  window.eval(renderedScript());
  const health = window.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  );
  const copy = JSON.parse(JSON.stringify(health));

  assert.deepEqual(Object.keys(copy).sort(), [
    "attachedRowCount",
    "bindingAvailable",
    "bindingMatches",
    "bridgeRegistered",
    "buttonCount",
    "candidateRowCount",
    "duplicateButtonCount",
    "eligibleRowCount",
    "missingButtonCount",
    "observerInstalled",
    "orphanButtonCount",
    "owner",
    "readiness",
    "scanError",
    "schemaVersion",
    "styleInstalled",
  ]);
  assert.equal(copy.readiness, "waitingForRows");
  assert.equal(copy.candidateRowCount, 0);
  assert.equal(copy.eligibleRowCount, 0);
  assert.equal(copy.buttonCount, 0);
  assert.equal(copy.bridgeRegistered, true);
  assert.equal(copy.bindingMatches, true);
  assert.equal(copy.bindingAvailable, true);
});

test("health synchronously scans rows and verifies one button per eligible row", () => {
  const window = new Window({ url: "app://codex/" });
  window.codexTokenBarDeleteTauri = () => {};
  sidebarRow(window.document, "019f5a7c-3234-7abc-8def-0123456789ab", "立即验收");

  window.eval(renderedScript());
  const health = window.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  );

  assert.equal(health.readiness, "ready");
  assert.equal(health.eligibleRowCount, 1);
  assert.equal(health.attachedRowCount, 1);
  assert.equal(health.buttonCount, 1);
  assert.equal(health.missingButtonCount, 0);
});

test("Swift and Tauri health remain independently addressable after repeated injection", () => {
  const window = new Window({ url: "app://codex/" });
  window.codexTokenBarDeleteTauri = () => {};
  window.codexTokenBarDeleteSwift = () => {};
  sidebarRow(window.document, "019f5a7c-4234-7abc-8def-0123456789ab", "双端健康检查");

  window.eval(renderedScript("tauri", "codexTokenBarDeleteTauri"));
  window.eval(renderedScript("swift", "codexTokenBarDeleteSwift"));

  assert.equal(window.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  ).readiness, "ready");
  assert.equal(window.__codexTokenBarThreadDeleteHealth(
    "swift",
    "codexTokenBarDeleteSwift",
  ).readiness, "ready");
  const wrongBinding = window.__codexTokenBarThreadDeleteHealth(
    "swift",
    "codexTokenBarDeleteTauri",
  );
  assert.equal(wrongBinding.bindingMatches, false);
  assert.equal(wrongBinding.readiness, "failed");
});

test("blank thread ids, duplicate buttons, and orphan buttons fail health verification", () => {
  const blankWindow = new Window({ url: "app://codex/" });
  blankWindow.codexTokenBarDeleteTauri = () => {};
  const blank = blankWindow.document.createElement("a");
  blank.setAttribute("data-app-action-sidebar-thread-id", "");
  blankWindow.document.body.appendChild(blank);
  blankWindow.eval(renderedScript());
  const blankHealth = blankWindow.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  );
  assert.equal(blankHealth.candidateRowCount, 1);
  assert.equal(blankHealth.eligibleRowCount, 0);
  assert.equal(blankHealth.readiness, "failed");

  const malformed = blankWindow.document.createElement("a");
  malformed.setAttribute("data-app-action-sidebar-thread-id", "thread_placeholder");
  blankWindow.document.body.appendChild(malformed);
  const malformedHealth = blankWindow.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  );
  assert.equal(malformedHealth.candidateRowCount, 2);
  assert.equal(malformedHealth.eligibleRowCount, 0);
  assert.equal(malformedHealth.readiness, "failed");
  assert.equal(malformed.querySelector('[data-codex-token-bar-thread-delete="true"]'), null);

  const duplicateWindow = new Window({ url: "app://codex/" });
  duplicateWindow.codexTokenBarDeleteTauri = () => {};
  const row = sidebarRow(
    duplicateWindow.document,
    "019f5a7c-5234-7abc-8def-0123456789ab",
    "重复按钮",
  );
  duplicateWindow.eval(renderedScript());
  const duplicate = duplicateWindow.document.createElement("button");
  duplicate.setAttribute("data-codex-token-bar-thread-delete", "true");
  row.appendChild(duplicate);
  const duplicateHealth = duplicateWindow.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  );
  assert.equal(duplicateHealth.duplicateButtonCount, 1);
  assert.equal(duplicateHealth.readiness, "failed");

  const orphan = duplicateWindow.document.createElement("button");
  orphan.setAttribute("data-codex-token-bar-thread-delete", "true");
  duplicateWindow.document.body.appendChild(orphan);
  const orphanHealth = duplicateWindow.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  );
  assert.equal(orphanHealth.orphanButtonCount, 1);
  assert.equal(orphanHealth.readiness, "failed");
});

test("a valid and malformed thread id mix never reports ready", () => {
  const window = new Window({ url: "app://codex/" });
  window.codexTokenBarDeleteTauri = () => {};
  sidebarRow(window.document, "019f5a7c-a234-7abc-8def-0123456789ab", "有效会话");
  sidebarRow(window.document, "thread_placeholder", "异常会话");

  window.eval(renderedScript());
  const health = window.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  );

  assert.equal(health.candidateRowCount, 2);
  assert.equal(health.eligibleRowCount, 1);
  assert.equal(health.buttonCount, 1);
  assert.equal(health.readiness, "failed");
});

test("observer adds a button when a sidebar row appears after injection", async () => {
  const window = new Window({ url: "app://codex/" });
  window.codexTokenBarDeleteTauri = () => {};
  window.eval(renderedScript());
  assert.equal(window.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  ).readiness, "waitingForRows");

  sidebarRow(window.document, "019f5a7c-6234-7abc-8def-0123456789ab", "稍后出现");
  await flush(window);

  assert.equal(window.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  ).readiness, "ready");
});

test("a reused sidebar row always deletes its current thread id", async () => {
  const window = new Window({ url: "app://codex/" });
  const oldID = "019f5a7c-7234-7abc-8def-0123456789ab";
  const newID = "019f5a7c-8234-7abc-8def-0123456789ab";
  const row = sidebarRow(window.document, oldID, "被复用的行");
  const calls = [];
  window.confirm = () => true;
  window.codexTokenBarDeleteTauri = (payloadText) => {
    const payload = JSON.parse(payloadText);
    calls.push(payload);
    window.__codexTokenBarThreadDeleteResolve(payload.owner, payload.id, {
      status: "deleted",
      message: "会话已永久删除",
    });
  };

  window.eval(renderedScript());
  row.setAttribute("data-app-action-sidebar-thread-id", newID);
  await flush(window);
  const button = row.querySelector('[data-codex-token-bar-thread-delete="true"]');
  assert.equal(
    button.getAttribute("data-codex-token-bar-thread-delete-thread-id"),
    newID,
  );
  assert.equal(window.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  ).readiness, "ready");

  button.click();
  await flush(window);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].threadId, newID);
});

test("an early-document injection installs its observer when the root appears", async () => {
  const window = new Window({ url: "app://codex/" });
  window.document.documentElement.remove();
  window.codexTokenBarDeleteTauri = () => {};

  window.eval(renderedScript());
  const html = window.document.createElement("html");
  const head = window.document.createElement("head");
  const body = window.document.createElement("body");
  html.append(head, body);
  window.document.appendChild(html);
  window.document.dispatchEvent(new window.Event("DOMContentLoaded"));
  sidebarRow(window.document, "019f5a7c-9234-7abc-8def-0123456789ab", "早期文档");
  await flush(window);

  const health = window.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  );
  assert.equal(health.observerInstalled, true);
  assert.equal(health.styleInstalled, true);
  assert.equal(health.readiness, "ready");
});

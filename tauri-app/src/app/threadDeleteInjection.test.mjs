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

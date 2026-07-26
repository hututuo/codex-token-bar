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
  const button = window.document.querySelector('[data-codex-token-bar-thread-delete="true"]');
  assert.ok(button);
  assert.equal(button.getAttribute("aria-label"), "永久删除会话：需要删除的会话");
  button.click();
  await flush(window);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].threadId, id);
  assert.equal(row.isConnected, false);
  assert.match(window.document.body.textContent, /会话已永久删除/);
});

test("current local namespace is accepted but the native bridge receives a bare UUID", async () => {
  const window = new Window({ url: "app://codex/" });
  const id = "019f5a7c-1334-7abc-8def-0123456789ab";
  const reference = `local:${id}`;
  const row = sidebarRow(window.document, reference, "当前格式的会话");
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
  const health = window.__codexTokenBarThreadDeleteHealth(
    "tauri",
    "codexTokenBarDeleteTauri",
  );
  assert.equal(health.readiness, "ready");
  const button = window.document.querySelector('[data-codex-token-bar-thread-delete="true"]');
  assert.ok(button);
  assert.equal(
    button.getAttribute("data-codex-token-bar-thread-delete-thread-id"),
    reference,
  );

  button.click();
  await flush(window);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].threadId, id);
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

  assert.equal(window.document.querySelectorAll('[data-codex-token-bar-thread-delete="true"]').length, 1);
  window.document.querySelector('[data-codex-token-bar-thread-delete="true"]').click();
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

  assert.equal(window.document.querySelector('[data-codex-token-bar-thread-delete="true"]'), null);
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
    "deleteEnabled",
    "duplicateButtonCount",
    "eligibleRowCount",
    "missingButtonCount",
    "observerInstalled",
    "orphanButtonCount",
    "owner",
    "readiness",
    "scanError",
    "schemaVersion",
    "sessionEnhancementError",
    "sessionEnhancementsInstalled",
    "styleInstalled",
  ]);
  assert.equal(copy.readiness, "waitingForRows");
  assert.equal(copy.candidateRowCount, 0);
  assert.equal(copy.eligibleRowCount, 0);
  assert.equal(copy.buttonCount, 0);
  assert.equal(copy.bridgeRegistered, true);
  assert.equal(copy.bindingMatches, true);
  assert.equal(copy.bindingAvailable, true);
  assert.equal(copy.deleteEnabled, true);
  assert.equal(copy.sessionEnhancementsInstalled, false);
  assert.equal(copy.sessionEnhancementError, null);
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
  assert.equal(blankWindow.document.querySelector('[data-codex-token-bar-thread-delete="true"]'), null);

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

test("React-style row reconciliation cannot remove the portal delete button", async () => {
  const window = new Window({ url: "app://codex/" });
  window.codexTokenBarDeleteTauri = () => {};
  const id = "019f5a7c-6334-7abc-8def-0123456789ab";
  const row = sidebarRow(window.document, `local:${id}`, "会被重绘的行");

  window.eval(renderedScript());
  const originalButton = window.document.querySelector(
    '[data-codex-token-bar-thread-delete="true"]',
  );
  assert.ok(originalButton);
  assert.equal(originalButton.parentElement?.id, "codex-token-bar-thread-delete-overlay");
  assert.equal(row.contains(originalButton), false);

  const replacementLabel = window.document.createElement("span");
  replacementLabel.className = "truncate";
  replacementLabel.textContent = "React 重绘后的行";
  row.replaceChildren(replacementLabel);
  await flush(window);

  assert.equal(originalButton.isConnected, true);
  assert.equal(
    window.document.querySelectorAll('[data-codex-token-bar-thread-delete="true"]').length,
    1,
  );
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
  const button = window.document.querySelector('[data-codex-token-bar-thread-delete="true"]');
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

function recordingSink() {
  return {
    started: false,
    written: "",
    aborted: false,
    async write(value) { this.written += value; },
    async abort() { this.aborted = true; },
  };
}

const exportPayload = (threadId) => ({
  action: "exportMarkdown",
  threadId,
  title: "流式导出",
});

test("a streaming export fails closed when native resolves old-protocol inline markdown", async () => {
  const window = new Window({ url: "app://codex/" });
  const id = "019f5a7c-5234-7abc-8def-0123456789ab";
  sidebarRow(window.document, id, "旧协议导出");
  window.codexTokenBarDeleteTauri = (payloadText) => {
    const payload = JSON.parse(payloadText);
    window.__codexTokenBarThreadDeleteResolve(payload.owner, payload.id, {
      status: "exported",
      message: "已生成 Markdown",
      filename: "旧协议.md",
      markdown: "# 全文内联\n",
    });
  };
  window.eval(renderedScript());
  const sink = recordingSink();
  const result = await window.__codexTokenBarSessionEnhancementInvoke(
    exportPayload(id),
    sink,
  );
  assert.equal(result.status, "failed");
  assert.match(result.message, /未按 Markdown 流式协议/);
  assert.equal(sink.written, "");
});

test("an out-of-order chunk rejects native and resolves the page request as failed", async () => {
  const window = new Window({ url: "app://codex/" });
  const id = "019f5a7c-5334-7abc-8def-0123456789ab";
  sidebarRow(window.document, id, "乱序导出");
  let chunkError = null;
  const acks = [];
  window.codexTokenBarDeleteTauri = (payloadText) => {
    const payload = JSON.parse(payloadText);
    void (async () => {
      acks.push(await window.__codexTokenBarThreadDeleteMarkdownChunk(
        payload.owner, payload.id, 0, "第一块",
      ));
      try {
        await window.__codexTokenBarThreadDeleteMarkdownChunk(
          payload.owner, payload.id, 2, "跳号块",
        );
        acks.push("no-throw");
      } catch (error) {
        chunkError = error;
      }
    })();
  };
  window.eval(renderedScript());
  const sink = recordingSink();
  const result = await window.__codexTokenBarSessionEnhancementInvoke(
    exportPayload(id),
    sink,
  );
  await flush(window);
  assert.equal(result.status, "failed");
  assert.match(result.message, /分块顺序不一致/);
  assert.deepEqual(acks, [true]);
  assert.match(String(chunkError), /分块顺序不一致/);
  assert.equal(sink.written, "第一块");
});

test("a duplicated chunk sequence is rejected the same way as a gap", async () => {
  const window = new Window({ url: "app://codex/" });
  const id = "019f5a7c-5434-7abc-8def-0123456789ab";
  sidebarRow(window.document, id, "重复分块");
  let chunkError = null;
  window.codexTokenBarDeleteTauri = (payloadText) => {
    const payload = JSON.parse(payloadText);
    void (async () => {
      await window.__codexTokenBarThreadDeleteMarkdownChunk(
        payload.owner, payload.id, 0, "第一块",
      );
      try {
        await window.__codexTokenBarThreadDeleteMarkdownChunk(
          payload.owner, payload.id, 0, "重复块",
        );
      } catch (error) {
        chunkError = error;
      }
    })();
  };
  window.eval(renderedScript());
  const sink = recordingSink();
  const result = await window.__codexTokenBarSessionEnhancementInvoke(
    exportPayload(id),
    sink,
  );
  await flush(window);
  assert.equal(result.status, "failed");
  assert.match(result.message, /分块顺序不一致/);
  assert.match(String(chunkError), /分块顺序不一致/);
  assert.equal(sink.written, "第一块");
});

test("a mismatched, negative or non-numeric chunk count fails the transfer", async () => {
  for (const badCount of [2, -1, "1"]) {
    const window = new Window({ url: "app://codex/" });
    const id = "019f5a7c-5534-7abc-8def-0123456789ab";
    sidebarRow(window.document, id, "坏分块数");
    window.codexTokenBarDeleteTauri = (payloadText) => {
      const payload = JSON.parse(payloadText);
      void (async () => {
        await window.__codexTokenBarThreadDeleteMarkdownChunk(
          payload.owner, payload.id, 0, "唯一一块",
        );
        window.__codexTokenBarThreadDeleteResolve(payload.owner, payload.id, {
          status: "exported",
          message: "ok",
          filename: "坏分块数.md",
          markdownTransfer: true,
          markdownChunkCount: badCount,
        });
      })();
    };
    window.eval(renderedScript());
    const sink = recordingSink();
    const result = await window.__codexTokenBarSessionEnhancementInvoke(
      exportPayload(id),
      sink,
    );
    assert.equal(result.status, "failed", `count=${badCount}`);
    assert.match(result.message, /分块传输不完整/);
  }
});

test("unowned, malformed or late chunks return false without touching the sink", async () => {
  const window = new Window({ url: "app://codex/" });
  const id = "019f5a7c-5634-7abc-8def-0123456789ab";
  sidebarRow(window.document, id, "无主分块");
  let captured = null;
  window.codexTokenBarDeleteTauri = (payloadText) => {
    captured = JSON.parse(payloadText);
  };
  window.eval(renderedScript());
  const sink = recordingSink();
  const pending = window.__codexTokenBarSessionEnhancementInvoke(
    exportPayload(id),
    sink,
  );
  await flush(window);
  assert.ok(captured);
  const chunk = window.__codexTokenBarThreadDeleteMarkdownChunk;
  assert.equal(await chunk(captured.owner, "not-the-request", 0, "x"), false);
  assert.equal(await chunk("nobody", captured.id, 0, "x"), false);
  assert.equal(await chunk(captured.owner, captured.id, 0, 42), false);
  assert.equal(await chunk(captured.owner, captured.id, 1.5, "x"), false);
  assert.equal(await chunk(captured.owner, captured.id, -1, "x"), false);
  assert.equal(await chunk(captured.owner, captured.id, 0, "真实块"), true);
  window.__codexTokenBarThreadDeleteResolve(captured.owner, captured.id, {
    status: "exported",
    message: "ok",
    filename: "无主分块.md",
    markdownTransfer: true,
    markdownChunkCount: 1,
  });
  const result = await pending;
  assert.equal(result.status, "exported");
  assert.equal(await chunk(captured.owner, captured.id, 1, "迟到块"), false);
  assert.equal(sink.written, "真实块");
});

test("a crashed newer bridge never falls back once the sink started writing", async () => {
  const window = new Window({ url: "app://codex/" });
  const id = "019f5a7c-5734-7abc-8def-0123456789ab";
  sidebarRow(window.document, id, "双桥导出");
  let swiftCalls = 0;
  window.codexTokenBarDeleteSwift = () => {
    swiftCalls += 1;
  };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    const payload = JSON.parse(payloadText);
    // 同步发出首块（置 started）后崩溃：绝不允许回退到另一条桥重写同一文件。
    void window.__codexTokenBarThreadDeleteMarkdownChunk(
      payload.owner, payload.id, 0, "部分内容",
    );
    throw new Error("tauri 桥崩溃");
  };
  window.eval(renderedScript("swift", "codexTokenBarDeleteSwift"));
  window.eval(renderedScript("tauri", "codexTokenBarDeleteTauri"));
  const sink = recordingSink();
  await assert.rejects(
    window.__codexTokenBarSessionEnhancementInvoke(exportPayload(id), sink),
    /tauri 桥崩溃/,
  );
  assert.equal(swiftCalls, 0);
  assert.equal(sink.started, true);
});

test("a runtime upgrade during an active transfer aborts the sink and fails the request", async () => {
  const window = new Window({ url: "app://codex/" });
  const id = "019f5a7c-5834-7abc-8def-0123456789ab";
  sidebarRow(window.document, id, "升级中断");
  let captured = null;
  window.codexTokenBarDeleteTauri = (payloadText) => {
    captured = JSON.parse(payloadText);
  };
  window.eval(renderedScript());
  const sink = recordingSink();
  const pending = window.__codexTokenBarSessionEnhancementInvoke(
    exportPayload(id),
    sink,
  );
  await flush(window);
  assert.ok(captured);
  assert.equal(
    await window.__codexTokenBarThreadDeleteMarkdownChunk(
      captured.owner, captured.id, 0, "升级前的块",
    ),
    true,
  );

  const currentRuntimeVersion = Number(
    template.match(/const runtimeVersion = (\d+);/)[1],
  );
  const upgraded = renderedScript().replaceAll(
    `const runtimeVersion = ${currentRuntimeVersion};`,
    `const runtimeVersion = ${currentRuntimeVersion + 1};`,
  );
  assert.notEqual(upgraded, renderedScript());
  window.eval(upgraded);

  const result = await pending;
  assert.equal(result.status, "failed");
  assert.match(result.message, /注入已升级/);
  assert.equal(sink.aborted, true);
  assert.equal(
    await window.__codexTokenBarThreadDeleteMarkdownChunk(
      captured.owner, captured.id, 1, "升级后的块",
    ),
    false,
  );
});

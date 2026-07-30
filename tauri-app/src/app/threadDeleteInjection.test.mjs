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

const deleteSelector = '[data-codex-token-bar-thread-delete="true"]';

function deleteHealth(window, owner = "tauri", binding = "codexTokenBarDeleteTauri") {
  return window.__codexTokenBarThreadDeleteHealth(owner, binding);
}

function assertLegacyDeleteRetired(window, calls) {
  assert.equal(window.__codexTokenBarThreadDeleteState.enhancementSettings.sessionDelete, false);
  assert.equal(window.document.querySelectorAll(deleteSelector).length, 0);
  assert.equal(calls.length, 0);
}

test("persisted sessionDelete=true is normalized to a retired, fail-closed sidebar", async () => {
  const window = new Window({ url: "app://codex/" });
  const row = sidebarRow(
    window.document,
    "019f5a7c-1234-7abc-8def-0123456789ab",
    "旧设置仍启用删除",
  );
  const calls = [];
  let confirmations = 0;
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = {
    sessionDelete: true,
    markdownExport: true,
  };
  window.confirm = () => {
    confirmations += 1;
    return true;
  };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    calls.push(JSON.parse(payloadText));
  };

  window.eval(renderedScript());
  await flush(window);
  window.document.body.click();
  await flush(window);

  assertLegacyDeleteRetired(window, calls);
  assert.equal(confirmations, 0);
  assert.equal(row.isConnected, true);
  assert.deepEqual(window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__, {
    sessionDelete: true,
    markdownExport: true,
  });
  const health = deleteHealth(window);
  assert.equal(health.readiness, "ready");
  assert.equal(health.deleteEnabled, false);
  assert.equal(health.candidateRowCount, 1);
  assert.equal(health.eligibleRowCount, 1);
  assert.equal(health.attachedRowCount, 0);
  assert.equal(health.missingButtonCount, 1);
});

test("bare and local UUID rows remain diagnosable but never receive direct-delete controls", async () => {
  const window = new Window({ url: "app://codex/" });
  sidebarRow(
    window.document,
    "019f5a7c-1334-7abc-8def-0123456789ab",
    "裸 UUID",
  );
  sidebarRow(
    window.document,
    "local:019f5a7c-1434-7abc-8def-0123456789ab",
    "本地命名空间 UUID",
  );
  const calls = [];
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = { sessionDelete: true };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    calls.push(JSON.parse(payloadText));
  };

  window.eval(renderedScript());
  await flush(window);

  assertLegacyDeleteRetired(window, calls);
  const health = deleteHealth(window);
  assert.equal(health.readiness, "ready");
  assert.equal(health.candidateRowCount, 2);
  assert.equal(health.eligibleRowCount, 2);
  assert.equal(health.buttonCount, 0);
  assert.equal(health.missingButtonCount, 2);
});

test("blank, malformed and absent thread ids cannot recreate the retired control", async () => {
  const window = new Window({ url: "app://codex/" });
  const blank = sidebarRow(window.document, "", "空 ID");
  const malformed = sidebarRow(window.document, "thread_placeholder", "伪造 ID");
  const absent = window.document.createElement("a");
  absent.textContent = "没有 thread id";
  window.document.body.appendChild(absent);
  const calls = [];
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = { sessionDelete: true };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    calls.push(JSON.parse(payloadText));
  };

  window.eval(renderedScript());
  blank.setAttribute("data-app-action-sidebar-thread-id", "still-not-a-uuid");
  malformed.replaceChildren(window.document.createTextNode("React 重绘后的伪造 ID"));
  await flush(window);
  absent.click();

  assertLegacyDeleteRetired(window, calls);
  const health = deleteHealth(window);
  assert.equal(health.candidateRowCount, 2);
  assert.equal(health.eligibleRowCount, 0);
  assert.equal(health.readiness, "failed");
});

test("repeated Swift and Tauri injections cannot revive direct delete or fall through bridges", async () => {
  const window = new Window({ url: "app://codex/" });
  const row = sidebarRow(
    window.document,
    "019f5a7c-2234-7abc-8def-0123456789ab",
    "双端重复注入",
  );
  const tauriCalls = [];
  const swiftCalls = [];
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = { sessionDelete: true };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    tauriCalls.push(JSON.parse(payloadText));
  };
  window.codexTokenBarDeleteSwift = (payloadText) => {
    swiftCalls.push(JSON.parse(payloadText));
  };

  window.eval(renderedScript("tauri", "codexTokenBarDeleteTauri"));
  window.eval(renderedScript("swift", "codexTokenBarDeleteSwift"));
  window.eval(renderedScript("tauri", "codexTokenBarDeleteTauri"));
  row.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true }));
  row.click();
  await flush(window);

  assertLegacyDeleteRetired(window, tauriCalls);
  assert.equal(swiftCalls.length, 0);
  for (const [owner, binding] of [
    ["tauri", "codexTokenBarDeleteTauri"],
    ["swift", "codexTokenBarDeleteSwift"],
  ]) {
    const health = deleteHealth(window, owner, binding);
    assert.equal(health.readiness, "ready");
    assert.equal(health.deleteEnabled, false);
    assert.equal(health.buttonCount, 0);
  }
  const wrongBinding = deleteHealth(window, "swift", "codexTokenBarDeleteTauri");
  assert.equal(wrongBinding.bindingMatches, false);
  assert.equal(wrongBinding.readiness, "failed");
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
  assert.equal(copy.deleteEnabled, false);
  assert.equal(copy.sessionEnhancementsInstalled, false);
  assert.equal(copy.sessionEnhancementError, null);
});

test("health synchronously recognizes eligible rows without requiring retired buttons", () => {
  const window = new Window({ url: "app://codex/" });
  const calls = [];
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = { sessionDelete: true };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    calls.push(JSON.parse(payloadText));
  };
  sidebarRow(window.document, "019f5a7c-3234-7abc-8def-0123456789ab", "立即验收");

  window.eval(renderedScript());
  const health = deleteHealth(window);

  assertLegacyDeleteRetired(window, calls);
  assert.equal(health.readiness, "ready");
  assert.equal(health.eligibleRowCount, 1);
  assert.equal(health.attachedRowCount, 0);
  assert.equal(health.buttonCount, 0);
  assert.equal(health.missingButtonCount, 1);
});

test("health rejects externally inserted legacy duplicate and orphan controls", () => {
  const window = new Window({ url: "app://codex/" });
  const calls = [];
  window.codexTokenBarDeleteTauri = (payloadText) => {
    calls.push(JSON.parse(payloadText));
  };
  const row = sidebarRow(
    window.document,
    "019f5a7c-5234-7abc-8def-0123456789ab",
    "外部旧按钮",
  );
  window.eval(renderedScript());

  const duplicate = window.document.createElement("button");
  duplicate.setAttribute("data-codex-token-bar-thread-delete", "true");
  duplicate.setAttribute(
    "data-codex-token-bar-thread-delete-thread-id",
    "019f5a7c-5234-7abc-8def-0123456789ab",
  );
  row.appendChild(duplicate);
  const orphan = window.document.createElement("button");
  orphan.setAttribute("data-codex-token-bar-thread-delete", "true");
  orphan.setAttribute(
    "data-codex-token-bar-thread-delete-thread-id",
    "019f5a7c-9999-7abc-8def-0123456789ab",
  );
  window.document.body.appendChild(orphan);
  duplicate.click();
  orphan.click();
  const health = deleteHealth(window);

  assert.equal(calls.length, 0);
  assert.equal(health.deleteEnabled, false);
  assert.equal(health.buttonCount, 2);
  assert.equal(health.attachedRowCount, 1);
  assert.equal(health.orphanButtonCount, 1);
  assert.equal(health.readiness, "failed");
});

test("observer recognizes a late row without creating a retired button", async () => {
  const window = new Window({ url: "app://codex/" });
  const calls = [];
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = { sessionDelete: true };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    calls.push(JSON.parse(payloadText));
  };
  window.eval(renderedScript());
  assert.equal(deleteHealth(window).readiness, "waitingForRows");

  const row = sidebarRow(
    window.document,
    "019f5a7c-6234-7abc-8def-0123456789ab",
    "稍后出现",
  );
  await flush(window);
  row.click();

  assertLegacyDeleteRetired(window, calls);
  assert.equal(deleteHealth(window).readiness, "ready");
});

test("React-style reconciliation cannot recreate the retired portal button", async () => {
  const window = new Window({ url: "app://codex/" });
  const calls = [];
  const id = "019f5a7c-6334-7abc-8def-0123456789ab";
  const row = sidebarRow(window.document, `local:${id}`, "会被重绘的行");
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = { sessionDelete: true };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    calls.push(JSON.parse(payloadText));
  };

  window.eval(renderedScript());
  const replacementLabel = window.document.createElement("span");
  replacementLabel.className = "truncate";
  replacementLabel.textContent = "React 重绘后的行";
  row.replaceChildren(replacementLabel);
  row.remove();
  window.document.body.appendChild(row);
  await flush(window);
  row.click();

  assertLegacyDeleteRetired(window, calls);
  assert.equal(deleteHealth(window).readiness, "ready");
});

test("a reused sidebar row cannot carry a delete affordance to a new thread id", async () => {
  const window = new Window({ url: "app://codex/" });
  const oldID = "019f5a7c-7234-7abc-8def-0123456789ab";
  const newID = "019f5a7c-8234-7abc-8def-0123456789ab";
  const row = sidebarRow(window.document, oldID, "被复用的行");
  const calls = [];
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = { sessionDelete: true };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    calls.push(JSON.parse(payloadText));
  };

  window.eval(renderedScript());
  row.setAttribute("data-app-action-sidebar-thread-id", newID);
  await flush(window);
  row.click();
  assertLegacyDeleteRetired(window, calls);
  assert.equal(deleteHealth(window).readiness, "ready");

  row.setAttribute("data-app-action-sidebar-thread-id", "recycled-placeholder");
  await flush(window);
  row.click();
  assertLegacyDeleteRetired(window, calls);
  assert.equal(deleteHealth(window).readiness, "failed");

  row.setAttribute("data-app-action-sidebar-thread-id", oldID);
  await flush(window);
  assertLegacyDeleteRetired(window, calls);
  assert.equal(deleteHealth(window).readiness, "ready");
});

test("an early-document injection installs its observer when the root appears", async () => {
  const window = new Window({ url: "app://codex/" });
  window.document.documentElement.remove();
  const calls = [];
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = { sessionDelete: true };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    calls.push(JSON.parse(payloadText));
  };

  window.eval(renderedScript());
  const html = window.document.createElement("html");
  const head = window.document.createElement("head");
  const body = window.document.createElement("body");
  html.append(head, body);
  window.document.appendChild(html);
  window.document.dispatchEvent(new window.Event("DOMContentLoaded"));
  const row = sidebarRow(
    window.document,
    "019f5a7c-9234-7abc-8def-0123456789ab",
    "早期文档",
  );
  await flush(window);
  row.click();

  assertLegacyDeleteRetired(window, calls);
  const health = deleteHealth(window);
  assert.equal(health.observerInstalled, true);
  assert.equal(health.styleInstalled, true);
  assert.equal(health.readiness, "ready");
});

test("upgrading a legacy injected runtime removes its stale direct-delete DOM", async () => {
  const window = new Window({ url: "app://codex/" });
  const currentRuntimeVersion = Number(template.match(/const runtimeVersion = (\d+);/)[1]);
  const row = sidebarRow(
    window.document,
    "019f5a7c-a234-7abc-8def-0123456789ab",
    "旧运行时残留",
  );
  const legacyOverlay = window.document.createElement("div");
  legacyOverlay.id = "codex-token-bar-thread-delete-overlay";
  const legacyButton = window.document.createElement("button");
  legacyButton.setAttribute("data-codex-token-bar-thread-delete", "true");
  legacyButton.setAttribute(
    "data-codex-token-bar-thread-delete-thread-id",
    row.getAttribute("data-app-action-sidebar-thread-id"),
  );
  legacyOverlay.appendChild(legacyButton);
  window.document.body.appendChild(legacyOverlay);
  const legacyStyle = window.document.createElement("style");
  legacyStyle.id = "codex-token-bar-thread-delete-style";
  window.document.head.appendChild(legacyStyle);
  let disconnected = 0;
  window.__codexTokenBarThreadDeleteState = {
    version: 2,
    runtimeVersion: currentRuntimeVersion - 1,
    bridges: new Map(),
    markdownTransfers: new Map(),
    observer: { disconnect: () => { disconnected += 1; } },
    documentReadyListener: null,
    scanQueued: false,
    sequence: 0,
    overlay: legacyOverlay,
    buttonsByReference: new Map([
      [row.getAttribute("data-app-action-sidebar-thread-id"), legacyButton],
    ]),
    hoveredThreadReference: null,
    pointerMoveListener: null,
    pointerLeaveListener: null,
    scrollListener: null,
    resizeListener: null,
    enhancementSettings: { sessionDelete: true },
  };
  const calls = [];
  window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = { sessionDelete: true };
  window.codexTokenBarDeleteTauri = (payloadText) => {
    calls.push(JSON.parse(payloadText));
  };

  window.eval(renderedScript());
  await flush(window);
  row.click();

  assert.equal(disconnected, 1);
  assert.equal(legacyButton.isConnected, false);
  assert.equal(legacyOverlay.isConnected, false);
  assertLegacyDeleteRetired(window, calls);
  assert.equal(deleteHealth(window).readiness, "ready");
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

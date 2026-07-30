import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

const SOURCE_TOKEN = {
  canonicalHomeKey: "/fixture/codex",
  physicalHomeKey: "unix:1:2",
  transitionGeneration: 7,
};

test("session management progressively discloses real catalog data and keeps dangerous states blocked", async () => {
  await withMountedWorkspace(async ({ act, calls, container, window }) => {
    await flushPromises(act);
    assert.match(container.textContent, /206 个会话/);
    assert.match(container.textContent, /当前显示 100 \/ 205/);
    assert.equal(container.querySelectorAll(".session-management-thread-row").length, 100);

    await click(act, buttonWithText(container, "继续显示 100 个"), window);
    assert.match(container.textContent, /当前显示 200 \/ 205/);

    const search = container.querySelector('input[aria-label="搜索全部会话元数据"]');
    assert.ok(search);
    await setInput(act, search, "Far away 180", window);
    assert.equal(container.querySelectorAll(".session-management-thread-row").length, 1);
    assert.match(container.textContent, /Far away 180/);

    await setInput(act, search, "", window);
    const activeRow = rowContaining(container, "Active protected");
    assert.equal(activeRow.querySelector('input[type="checkbox"]').disabled, false);

    const safeRow = rowContaining(container, "Safe thread");
    assert.match(safeRow.textContent, /未加载/);
    await click(act, safeRow, window);
    assert.match(container.querySelector(".session-management-detail")?.textContent, /safe-thread/);
    assert.equal(buttonWithText(container, "从恢复包还原").disabled, true);
    assert.match(buttonWithText(container, "从恢复包还原").title, /全部 Codex writer 退出/);

    await click(act, buttonWithText(container, "上下文"), window);
    await flushPromises(act);
    assert.match(container.textContent, /最新一页内容/);
    assert.equal(calls.context.length, 1);
    await click(act, buttonWithText(container, "加载更早上下文"), window);
    await flushPromises(act);
    assert.match(container.textContent, /更早内容/);
    assert.match(container.textContent, /最新一页内容/);
    assert.equal(calls.context.length, 2);

    await click(act, safeRow.querySelector('input[type="checkbox"]'), window);
    assert.equal(buttonWithText(container, "创建深度压缩恢复包").disabled, false);
    const archive = buttonWithText(container, "官方归档");
    assert.equal(archive.disabled, false);
    await click(act, archive, window);
    await flushPromises(act);
    assert.deepEqual(calls.archive, [["safe-thread"]]);
    assert.match(container.textContent, /操作完成：成功 1，失败 0/);
  });
});

test("project, session and detail form a drill-down path with explicit back navigation", async () => {
  await withMountedWorkspace(async ({ act, container, window }) => {
    await flushPromises(act);
    const layout = container.querySelector(".session-management-layout");
    assert.equal(layout?.dataset.navigationStage, "projects");
    assert.match(container.querySelector(".session-management-hierarchy")?.textContent, /项目：全部会话.*会话：205.*详情：未选择/);

    await click(act, collectionButton(container, "全部会话"), window);
    assert.equal(layout?.dataset.navigationStage, "sessions");

    await click(act, rowContaining(container, "Safe thread"), window);
    assert.equal(layout?.dataset.navigationStage, "detail");
    assert.match(container.querySelector(".session-management-hierarchy")?.textContent, /详情：Safe thread/);

    await click(act, buttonWithText(container, "← 返回会话"), window);
    assert.equal(layout?.dataset.navigationStage, "sessions");
    await click(act, buttonWithText(container, "← 返回项目"), window);
    assert.equal(layout?.dataset.navigationStage, "projects");
  });
});

test("selection stays clickable and isolated from row focus while actions fail closed independently", async () => {
  await withMountedWorkspace(async ({ act, container, window }) => {
    await flushPromises(act);
    await click(act, collectionButton(container, "全部会话"), window);
    const layout = container.querySelector(".session-management-layout");
    const activeRow = rowContaining(container, "Active protected");
    const activeCheckbox = activeRow.querySelector('input[type="checkbox"]');
    assert.equal(activeCheckbox.disabled, false);

    await click(act, activeCheckbox, window);
    assert.equal(activeCheckbox.checked, true);
    assert.equal(activeRow.getAttribute("aria-selected"), "false");
    assert.equal(layout?.dataset.navigationStage, "sessions");
    assert.match(container.querySelector(".session-management-detail")?.textContent, /选择一个会话/);
    const archive = buttonWithText(container, "官方归档");
    assert.equal(archive.disabled, true);
    assert.match(archive.title, /已保留全部选择.*仍在运行、加载或受保护/);

    await keyDown(act, activeCheckbox, " ", window);
    assert.equal(activeRow.getAttribute("aria-selected"), "false");
    assert.equal(layout?.dataset.navigationStage, "sessions");

    await click(act, activeCheckbox, window);
    const selectAll = container.querySelector('input[aria-label="选择当前显示的全部会话"]');
    await click(act, selectAll, window);
    assert.equal(activeCheckbox.checked, true);
    assert.match(container.textContent, /已选 100/);
    assert.equal(archive.disabled, true);
    assert.match(archive.title, /已保留全部选择/);
  });
});

test("delete confirmation requires a verified full-scope recovery package with no bypass", async () => {
  await withMountedWorkspace(async ({ act, calls, container, window }) => {
    await flushPromises(act);
    const safeRow = rowContaining(container, "Safe thread");
    await click(act, safeRow.querySelector('input[type="checkbox"]'), window);
    await click(act, buttonWithText(container, "恢复包后删除"), window);
    await flushPromises(act);

    const dialog = container.querySelector('[role="alertdialog"]');
    assert.ok(dialog);
    assert.match(dialog.textContent, /创建完整恢复包后永久删除 2 个会话/);
    assert.match(dialog.textContent, /另含 1 个 spawned 后代/);
    assert.match(dialog.textContent, /外部 Fork 引用0 个/);
    assert.equal(dialog.querySelectorAll('input[type="radio"]').length, 0);
    assert.doesNotMatch(dialog.textContent, /不创建恢复包/);
    assert.equal(buttonWithText(dialog, "确认删除").disabled, true);
    assert.match(dialog.textContent, /完整恢复包是永久删除的强制前置条件/);

    // The exact root/descendant scope shown in this dialog is immutable. Even
    // if background catalog/selection state changes before the click returns,
    // the native command must receive the scope the user actually reviewed.
    const unrelatedRow = rowContaining(container, "Ordinary 0");
    await click(act, unrelatedRow.querySelector('input[type="checkbox"]'), window);

    const acknowledgement = dialog.querySelector('input[type="checkbox"]');
    await click(act, acknowledgement, window);
    assert.equal(buttonWithText(dialog, "确认删除").disabled, false);
    await click(act, buttonWithText(dialog, "确认删除"), window);
    await flushPromises(act);
    assert.deepEqual(calls.prepareDelete, [["safe-thread"]]);
    assert.deepEqual(calls.delete, [{
      confirmation: deleteConfirmationFixture(),
      threadIds: ["safe-thread"],
    }]);
  });
});

test("backend archive and unarchive failures stay failed when the refreshed catalog looks complete", async () => {
  await withMountedWorkspace(async ({ act, calls, container, window }) => {
    await flushPromises(act);
    const safeRow = rowContaining(container, "Safe thread");
    await click(act, safeRow.querySelector('input[type="checkbox"]'), window);

    await click(act, buttonWithText(container, "官方归档"), window);
    await flushPromises(act);
    assert.deepEqual(calls.archive, [["safe-thread"]]);
    assert.match(container.textContent, /操作完成：成功 0，失败 1/);
    assert.match(container.textContent, /归档后端失败/);
    assert.match(container.textContent, /后端失败或不确定回执保持不变/);

    await click(act, buttonWithText(container, "恢复到 Codex"), window);
    await flushPromises(act);
    assert.deepEqual(calls.unarchive, [["safe-thread"]]);
    assert.match(container.textContent, /操作完成：成功 0，失败 1/);
    assert.match(container.textContent, /恢复后端失败/);
    assert.match(container.textContent, /后端失败或不确定回执保持不变/);
  }, {
    clientFactory: (calls) => {
      const catalog = catalogFixture();
      return {
        ...clientFixture(calls, catalog),
        archive: async (threadIds) => {
          calls.archive.push(threadIds);
          setArchivedState(catalog, threadIds, true);
          return failedMutation(threadIds, "归档后端失败");
        },
        unarchive: async (threadIds) => {
          calls.unarchive.push(threadIds);
          setArchivedState(catalog, threadIds, false);
          return failedMutation(threadIds, "恢复后端失败");
        },
      };
    },
  });
});

test("backend delete failure stays failed when the root disappears but an affected child remains", async () => {
  await withMountedWorkspace(async ({ act, calls, container, window }) => {
    await flushPromises(act);
    await performConfirmedDelete({ act, container, window });
    await flushPromises(act);

    assert.equal(calls.delete.length, 1);
    assert.match(container.textContent, /操作完成：成功 0，失败 1/);
    assert.match(container.textContent, /删除后端失败/);
    assert.match(container.textContent, /仍显示删除影响范围中的 1 个会话/);
    assert.match(container.textContent, /subagent-thread/);
  }, {
    clientFactory: (calls) => {
      const catalog = catalogFixture();
      return {
        ...clientFixture(calls, catalog),
        delete: async (threadIds, confirmation) => {
          calls.delete.push({ confirmation, threadIds });
          catalog.threads = catalog.threads.filter((thread) => thread.id !== "safe-thread");
          return failedMutation(threadIds, "删除后端失败");
        },
      };
    },
  });
});

test("backend delete failure stays failed when a degraded catalog omits the full affected scope", async () => {
  await withMountedWorkspace(async ({ act, container, window }) => {
    await flushPromises(act);
    await performConfirmedDelete({ act, container, window });
    await flushPromises(act);

    assert.match(container.textContent, /操作完成：成功 0，失败 1/);
    assert.match(container.textContent, /删除回执不确定/);
    assert.match(container.textContent, /目录可能来自降级数据/);
    assert.match(container.textContent, /后端失败或不确定回执保持不变/);
  }, {
    clientFactory: (calls) => {
      const catalog = catalogFixture();
      return {
        ...clientFixture(calls, catalog),
        delete: async (threadIds, confirmation) => {
          calls.delete.push({ confirmation, threadIds });
          catalog.threads = catalog.threads.filter((thread) => (
            thread.id !== "safe-thread" && thread.id !== "subagent-thread"
          ));
          catalog.warnings = ["官方目录读取失败，当前目录来自降级扫描。"];
          return failedMutation(threadIds, "删除回执不确定");
        },
      };
    },
  });
});

test("stale delete preparation cannot open after selection, catalog refresh, or close changes", async () => {
  const preparations = [deferred(), deferred(), deferred()];
  let preparationIndex = 0;
  let closeCalls = 0;
  await withMountedWorkspace(async ({ act, container, window }) => {
    await flushPromises(act);
    const safeCheckbox = rowContaining(container, "Safe thread")
      .querySelector('input[type="checkbox"]');
    const unrelatedCheckbox = rowContaining(container, "Ordinary 0")
      .querySelector('input[type="checkbox"]');
    await click(act, safeCheckbox, window);

    await click(act, buttonWithText(container, "恢复包后删除"), window);
    assert.match(container.textContent, /正在冻结确认/);
    await click(act, unrelatedCheckbox, window);
    preparations[0].resolve(deleteConfirmationFixture());
    await flushPromises(act);
    assert.equal(container.querySelector('[role="alertdialog"]'), null);

    await click(act, unrelatedCheckbox, window);
    await click(act, buttonWithText(container, "恢复包后删除"), window);
    await click(act, buttonWithText(container, "刷新"), window);
    preparations[1].resolve(deleteConfirmationFixture());
    await flushPromises(act);
    assert.equal(container.querySelector('[role="alertdialog"]'), null);

    await click(act, buttonWithText(container, "恢复包后删除"), window);
    await click(act, buttonWithText(container, "关闭"), window);
    preparations[2].resolve(deleteConfirmationFixture());
    await flushPromises(act);
    assert.equal(closeCalls, 1);
    assert.equal(container.querySelector('[role="alertdialog"]'), null);
  }, {
    clientFactory: (calls) => ({
      ...clientFixture(calls),
      prepareDeleteConfirmation: async (threadIds) => {
        calls.prepareDelete.push(threadIds);
        const pending = preparations[preparationIndex];
        preparationIndex += 1;
        return pending.promise;
      },
    }),
    onClose: () => {
      closeCalls += 1;
    },
  });
});

async function withMountedWorkspace(run, {
  clientFactory = null,
  onClose = () => {},
} = {}) {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { SessionManagementWorkspace } = await load("/src/pages/SessionManagementWorkspace.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const calls = {
        archive: [],
        context: [],
        delete: [],
        prepareDelete: [],
        unarchive: [],
      };
      const client = clientFactory ? clientFactory(calls) : clientFixture(calls);
      const root = createRoot(container);
      try {
        await React.act(async () => root.render(React.createElement(SessionManagementWorkspace, {
          client,
          onClose,
          open: true,
          sourceToken: SOURCE_TOKEN,
        })));
        await run({ act: React.act, calls, container, window });
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
}

function clientFixture(calls, catalog = catalogFixture()) {
  return {
    listCatalog: async () => catalog,
    readContextPage: async (threadId, beforeOffset, pageSize) => {
      calls.context.push({ beforeOffset, pageSize, threadId });
      if (beforeOffset === 100) {
        return {
          threadId,
          messages: [contextMessage("older", "更早内容", 10)],
          nextBeforeOffset: null,
          hasMoreBefore: false,
          fileIdentity: "fixture:1",
          warnings: [],
        };
      }
      return {
        threadId,
        messages: [contextMessage("latest", "最新一页内容", 200)],
        nextBeforeOffset: 100,
        hasMoreBefore: true,
        fileIdentity: "fixture:1",
        warnings: [],
      };
    },
    archive: async (threadIds) => {
      calls.archive.push(threadIds);
      for (const threadId of threadIds) {
        const current = catalog.threads.find((thread) => thread.id === threadId);
        if (current) {
          current.archived = true;
          current.canArchive = false;
          current.canUnarchive = true;
        }
      }
      return {
        results: threadIds.map((threadId) => ({ threadId, ok: true })),
        warnings: [],
      };
    },
    unarchive: async (threadIds) => {
      calls.unarchive.push(threadIds);
      return {
        results: threadIds.map((threadId) => ({ threadId, ok: true })),
        warnings: [],
      };
    },
    prepareDeleteConfirmation: async (threadIds) => {
      calls.prepareDelete.push(threadIds);
      return deleteConfirmationFixture();
    },
    delete: async (threadIds, confirmation) => {
      calls.delete.push({ confirmation, threadIds });
      return {
        results: threadIds.map((threadId) => ({ threadId, ok: true })),
        warnings: [],
      };
    },
    createRecoveryArchives: async (threadIds) => ({
      results: threadIds.map((threadId) => ({ threadId, ok: true })),
      warnings: [],
    }),
  };
}

async function performConfirmedDelete({ act, container, window }) {
  const safeRow = rowContaining(container, "Safe thread");
  await click(act, safeRow.querySelector('input[type="checkbox"]'), window);
  await click(act, buttonWithText(container, "恢复包后删除"), window);
  await flushPromises(act);
  const dialog = container.querySelector('[role="alertdialog"]');
  assert.ok(dialog);
  await click(act, dialog.querySelector('input[type="checkbox"]'), window);
  await click(act, buttonWithText(dialog, "确认删除"), window);
}

function setArchivedState(catalog, threadIds, archived) {
  for (const threadId of threadIds) {
    const current = catalog.threads.find((thread) => thread.id === threadId);
    if (!current) continue;
    current.archived = archived;
    current.canArchive = !archived;
    current.canUnarchive = archived;
  }
}

function failedMutation(threadIds, message) {
  return {
    results: threadIds.map((threadId) => ({ threadId, ok: false, message })),
    warnings: [],
  };
}

function deleteConfirmationFixture() {
  return {
    schemaVersion: 1,
    preparedAt: 2_000_000_000,
    physicalHomeKey: SOURCE_TOKEN.physicalHomeKey,
    requestedIds: ["safe-thread"],
    effectiveRootIds: ["safe-thread"],
    affectedIds: ["safe-thread", "subagent-thread"],
    rollouts: [
      rolloutSnapshot("safe-thread", "sessions/safe-thread.jsonl", "unix:1:10"),
      rolloutSnapshot("subagent-thread", "sessions/subagent-thread.jsonl", "unix:1:11"),
    ],
  };
}

function rolloutSnapshot(threadId, canonicalRelativePath, physicalIdentity) {
  return {
    threadId,
    canonicalRelativePath,
    physicalIdentity,
    sizeBytes: "123",
    modifiedNanos: "2000000000000000000",
    sha256: "a".repeat(64),
  };
}

function catalogFixture() {
  const threads = [
    thread({ id: "safe-thread", title: "Safe thread", recencyAt: 2_000_000_000 }),
    thread({ id: "active-thread", title: "Active protected", status: "active", recencyAt: 1_999_999_999 }),
  ];
  for (let index = 0; index < 203; index += 1) {
    threads.push(thread({
      id: `thread-${index}`,
      title: index === 180 ? "Far away 180" : `Ordinary ${index}`,
      recencyAt: 1_900_000_000 - index,
    }));
  }
  threads.push(thread({
    id: "subagent-thread",
    title: "Subagent child",
    isSubagent: true,
    parentThreadId: "safe-thread",
    recencyAt: 2_000_000_001,
  }));
  return {
    threads,
    generatedAt: 2_000_000_000,
    codexHome: "/Users/test/.codex",
    totalBytes: null,
    warnings: [],
    capabilities: {
      officialArchive: { available: true },
      officialUnarchive: { available: true },
      officialDelete: { available: true },
      recoveryArchive: { available: true },
      recoveryRestore: { available: false, reason: "需要全部 Codex writer 退出后才能安全恢复。" },
      recoveryReclaim: { available: false, reason: "本轮不会自动删除恢复包对应的原会话。" },
    },
  };
}

function thread(overrides = {}) {
  return {
    id: "thread",
    title: "Thread",
    preview: "真实本地会话预览",
    cwd: "/work/project",
    createdAt: 1_700_000_000,
    updatedAt: 1_900_000_000,
    recencyAt: 1_900_000_000,
    archived: false,
    archivedAt: null,
    tokensUsed: null,
    fileBytes: null,
    fileModifiedAt: null,
    status: "notLoaded",
    source: null,
    model: null,
    sessionId: null,
    forkedFromId: null,
    parentThreadId: null,
    isSubagent: false,
    spawnChildCount: 0,
    forkChildCount: 0,
    similarityGroupId: null,
    similarityReason: null,
    protectionReasons: [],
    canArchive: true,
    canUnarchive: false,
    canDelete: true,
    ...overrides,
  };
}

function contextMessage(id, content, offset) {
  return {
    id,
    role: "assistant",
    content,
    timestamp: "2026-07-30T08:00:00.000Z",
    offset,
    kind: "message",
  };
}

function installDomGlobals(window) {
  const values = {
    document: window.document,
    window,
    navigator: window.navigator,
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    HTMLButtonElement: window.HTMLButtonElement,
    HTMLInputElement: window.HTMLInputElement,
    Event: window.Event,
    FocusEvent: window.FocusEvent,
    KeyboardEvent: window.KeyboardEvent,
    MouseEvent: window.MouseEvent,
    PointerEvent: window.PointerEvent,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
  };
  const previous = new Map();
  for (const [name, value] of Object.entries(values)) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, value, writable: true });
  }
  return () => {
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  };
}

async function flushPromises(act) {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

async function click(act, target, window) {
  assert.ok(target);
  await act(async () => target.dispatchEvent(
    new window.MouseEvent("click", { bubbles: true, cancelable: true }),
  ));
}

async function keyDown(act, target, key, window) {
  assert.ok(target);
  await act(async () => target.dispatchEvent(
    new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key }),
  ));
}

async function setInput(act, input, value, window) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")?.set;
  assert.ok(setter);
  setter.call(input, value);
  await act(async () => input.dispatchEvent(
    new window.Event("input", { bubbles: true, cancelable: true }),
  ));
}

function buttonWithText(container, text) {
  const matches = [...container.querySelectorAll("button")]
    .filter((button) => button.textContent?.trim() === text);
  assert.equal(matches.length, 1, `expected one button named ${text}`);
  return matches[0];
}

function collectionButton(container, text) {
  const matches = [...container.querySelectorAll(".session-management-sidebar button")]
    .filter((button) => button.querySelector("strong")?.textContent?.trim() === text);
  assert.equal(matches.length, 1, `expected one collection button named ${text}`);
  return matches[0];
}

function rowContaining(container, text) {
  const row = [...container.querySelectorAll(".session-management-thread-row")]
    .find((candidate) => candidate.textContent?.includes(text));
  assert.ok(row, `expected a row containing ${text}`);
  return row;
}

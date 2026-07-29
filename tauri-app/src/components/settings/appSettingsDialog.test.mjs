import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

const SETTINGS_CATEGORIES = [
  "常规",
  "会话增强",
  "Codex 实例",
  "自动续跑",
  "显示面",
  "监控与额度",
  "悬浮窗",
  "内容与排序",
  "提醒与更新",
  "数据与维护",
];

test("global settings exposes ten categorized tabs and defaults to general", async () => {
  await withSsrModules(async (load) => {
    const { AppSettingsDialog } = await load("/src/components/settings/AppSettingsDialog.tsx");
    const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
    const html = renderToStaticMarkup(React.createElement(
      AppSettingsDialog,
      settingsProps(DEFAULT_FLOATING_SETTINGS),
    ));

    assert.match(html, /role="dialog"/);
    assert.match(html, /总体设置/);
    assert.match(html, /role="tablist"/);
    assert.equal(html.match(/role="tab"/g)?.length, SETTINGS_CATEGORIES.length);
    for (const category of SETTINGS_CATEGORIES) {
      assert.match(html, new RegExp(category));
    }
    assert.match(html, /aria-selected="true"/);
    assert.match(html, /role="tabpanel"/);
    assert.match(html, /开机自启/);
    assert.doesNotMatch(html, /删除本地数据/);
  });
});

test("global settings stays unmounted while closed", async () => {
  await withSsrModules(async (load) => {
    const { AppSettingsDialog } = await load("/src/components/settings/AppSettingsDialog.tsx");
    const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
    const html = renderToStaticMarkup(React.createElement(AppSettingsDialog, {
      ...settingsProps(DEFAULT_FLOATING_SETTINGS),
      open: false,
    }));
    assert.equal(html, "");
  });
});

test("header shortcuts can open session enhancements and auto resume directly", async () => {
  await withMountedSettings(async ({ container, render }) => {
    assert.equal(tabName(selectedTab(container)), "会话增强");
    assert.match(activePanel(container).textContent, /Markdown 导出/);

    await render({ initialCategory: "automation" });
    assert.equal(tabName(selectedTab(container)), "自动续跑");
    assert.match(activePanel(container).textContent, /创建监控任务/);
  }, { initialCategory: "session" });
});

test("settings tabs switch by click and support ArrowUp, ArrowDown, Home, and End", async () => {
  await withMountedSettings(async ({ act, container, document, window }) => {
    assert.deepEqual(settingTabs(container).map(tabName), SETTINGS_CATEGORIES);
    assert.equal(tabName(selectedTab(container)), "常规");
    assert.match(activePanel(container).textContent, /开机自启/);

    const generalTab = tabByName(container, "常规");
    generalTab.focus();
    await pressKey(act, generalTab, "ArrowDown", window);
    await flushAnimationFrame(act, window);
    assert.equal(tabName(selectedTab(container)), "会话增强");
    assert.equal(document.activeElement, tabByName(container, "会话增强"));

    await pressKey(act, document.activeElement, "ArrowUp", window);
    await flushAnimationFrame(act, window);
    assert.equal(tabName(selectedTab(container)), "常规");
    assert.equal(document.activeElement, generalTab);

    await pressKey(act, generalTab, "End", window);
    await flushAnimationFrame(act, window);
    assert.equal(tabName(selectedTab(container)), "数据与维护");
    assert.equal(document.activeElement, tabByName(container, "数据与维护"));

    await pressKey(act, document.activeElement, "Home", window);
    await flushAnimationFrame(act, window);
    assert.equal(tabName(selectedTab(container)), "常规");
    assert.equal(document.activeElement, generalTab);

    await click(act, tabByName(container, "内容与排序"), window);
    assert.equal(tabName(selectedTab(container)), "内容与排序");
    assert.match(activePanel(container).textContent, /速率|额度|雷达/);
    assert.match(activePanel(container).textContent, /运行线程/);
  });
});

test("session enhancements expose real feature toggles, connection flow and attribution", async () => {
  await withMountedSettings(async ({ act, calls, container, window }) => {
    await click(act, tabByName(container, "会话增强"), window);
    const panel = activePanel(container);
    for (const label of [
      "会话删除",
      "Markdown 导出",
      "会话项目移动",
      "会话 ID 标识",
      "粘贴修复",
      "对话居中宽度",
      "切换对话保留位置",
    ]) {
      assert.match(panel.textContent, new RegExp(label));
    }
    assert.match(panel.textContent, /Codex\+\+ · AGPL-3\.0/);
    assert.match(panel.querySelector('a[href*="BigPizzaV3/CodexPlusPlus"]')?.textContent, /上游源码/);

    await click(act, panel.querySelector('button[aria-label^="粘贴修复："]'), window);
    await flushPromises(act);
    assert.equal(calls.sessionEnhancementSaves.length, 1);
    assert.equal(calls.sessionEnhancementSaves[0].pasteFix, true);
    assert.equal(calls.sessionEnhancementSaves[0].markdownExport, true);

    await click(act, buttonWithText(panel, "重新连接"), window);
    assert.equal(calls.threadDeleteReconnect, 1);
  });
});

test("monitoring settings own the token-rate full scale control", async () => {
  await withMountedSettings(async ({ act, calls, container, window }) => {
    await click(act, tabByName(container, "监控与额度"), window);
    const panel = activePanel(container);
    assert.match(panel.textContent, /实时速率/);
    assert.match(panel.textContent, /额度刷新/);

    const fullScale = panel.querySelector('input[type="range"][aria-label*="速率"]');
    assert.ok(fullScale, "monitoring page should expose the token-rate full-scale range");
    assert.equal(fullScale.value, "200");
    await setRangeValue(act, fullScale, 260, window);
    assert.deepEqual(calls.tokenRateFullScale, [260]);
  });
});

test("auto resume settings preserve same-directory threads and save the selected exact thread id", async () => {
  const sharedCwd = "/Users/test/project";
  await withMountedSettings(async ({ act, calls, container, window }) => {
    await click(act, tabByName(container, "自动续跑"), window);
    const panel = activePanel(container);
    assert.match(panel.textContent, /一条任务保护一个 Codex 会话/);
    assert.match(panel.textContent, /任务被中断.*可能包含主动停止/);

    const threadButtons = [...panel.querySelectorAll('.auto-resume-thread-list > button[role="option"]')];
    assert.equal(threadButtons.length, 2, "same-directory threads must not be deduplicated");
    assert.match(panel.textContent, new RegExp(`${sharedCwd} · 共 2 个会话`));

    const search = panel.querySelector('input[aria-label="搜索自动续跑会话"]');
    assert.ok(search);
    await setInputValue(act, search, "Beta", window);
    assert.equal(panel.querySelectorAll('.auto-resume-thread-list > button[role="option"]').length, 1);
    const refreshesBeforeSubmit = calls.autoResumeRefreshes;
    await submitForm(act, search.closest("form"), window);
    await flushPromises(act);
    assert.equal(calls.autoResumeRefreshes, refreshesBeforeSubmit + 1, "submitting search with Enter refreshes threads");
    const submitArrow = panel.querySelector('button[aria-label="应用搜索并刷新会话"]');
    assert.ok(submitArrow);
    await click(act, submitArrow, window);
    await flushPromises(act);
    assert.equal(calls.autoResumeRefreshes, refreshesBeforeSubmit + 2, "explicit arrow submits search");
    await setInputValue(act, search, "", window);

    const beta = [...panel.querySelectorAll('.auto-resume-thread-list > button[role="option"]')]
      .find((button) => button.textContent.includes("Beta thread"));
    assert.ok(beta);
    await click(act, beta, window);
    await click(act, buttonWithText(panel, "创建任务"), window);
    await flushPromises(act);

    assert.equal(calls.autoResumeSaves.length, 1);
    const created = calls.autoResumeSaves[0].tasks[0];
    assert.equal(created.threadId, "thread-beta");
    assert.equal(created.threadTitle, "Beta thread");
    assert.equal(created.threadCwd, sharedCwd);
    assert.equal(created.enabled, false, "new tasks must start paused");
    assert.equal(created.quotaResumeEnabled, true);

    const protectionToggle = panel.querySelector('button[aria-label="Beta thread保护：关"]');
    assert.ok(protectionToggle);
    await click(act, protectionToggle, window);
    await flushPromises(act);
    assert.equal(calls.autoResumeSaves.length, 2);
    assert.equal(calls.autoResumeSaves[1].tasks[0].enabled, true);
  }, {
    autoResumeThreads: [
      { id: "thread-alpha", title: "Alpha thread", cwd: sharedCwd, updatedAt: 1_784_000_000, status: "idle", source: "state-db" },
      { id: "thread-beta", title: "Beta thread", cwd: sharedCwd, updatedAt: 1_784_100_000, status: "active", source: "state-db" },
    ],
  });
});

test("deleting the final auto resume task persists an explicit empty collection", async () => {
  await withMountedSettings(async ({ act, calls, container, window }) => {
    await click(act, tabByName(container, "自动续跑"), window);
    const panel = activePanel(container);
    await click(act, buttonWithText(panel, "删除任务"), window);
    await click(act, buttonWithText(panel, "确认删除"), window);
    await flushPromises(act);

    assert.equal(calls.autoResumeSaves.length, 1);
    const saved = calls.autoResumeSaves[0];
    assert.equal(saved.taskCollectionVersion, 2);
    assert.deepEqual(saved.tasks, []);
    assert.equal(saved.selectedTaskId, "");
    assert.equal(saved.threadId, "");
    assert.equal(saved.enabled, false);
  }, {
    autoResumeSettings: settingsWithTask(),
  });
});

test("auto resume progressively reveals project history beyond the first hundred rows", async () => {
  const mainCwd = "/Users/test/main-project";
  const otherCwd = "/Users/test/other-project";
  const mainThreads = Array.from({ length: 230 }, (_, index) => ({
    id: `main-${index}`,
    title: `完整会话标题 ${index}：这是用于确认标题不会被单行省略的内容`,
    cwd: mainCwd,
    updatedAt: 10_000 - index,
    status: "idle",
    source: "state-db",
  }));
  await withMountedSettings(async ({ act, container, window }) => {
    await click(act, tabByName(container, "自动续跑"), window);
    const panel = activePanel(container);
    const projectPicker = panel.querySelector('select[aria-label="自动续跑项目文件夹"]');
    assert.ok(projectPicker);
    assert.equal(projectPicker.options.length, 2);
    assert.equal(projectPicker.value, mainCwd);
    assert.match(panel.textContent, /项目共 230 条/);

    let options = [...panel.querySelectorAll('.auto-resume-thread-list > button[role="option"]')];
    assert.equal(options.length, 100);
    assert.ok(options[0].textContent.includes("完整会话标题 0"));
    assert.ok(options.at(-1).textContent.includes("完整会话标题 99"));
    assert.match(panel.textContent, /继续下滑自动加载/);

    const list = panel.querySelector(".auto-resume-thread-list");
    assert.ok(list);
    Object.defineProperties(list, {
      clientHeight: { configurable: true, value: 228 },
      scrollHeight: { configurable: true, value: 1_000 },
      scrollTop: { configurable: true, writable: true, value: 772 },
    });
    await act(async () => {
      list.dispatchEvent(new window.Event("scroll", { bubbles: true }));
    });
    options = [...panel.querySelectorAll('.auto-resume-thread-list > button[role="option"]')];
    assert.equal(options.length, 200);

    await act(async () => {
      list.dispatchEvent(new window.Event("scroll", { bubbles: true }));
    });
    options = [...panel.querySelectorAll('.auto-resume-thread-list > button[role="option"]')];
    assert.equal(options.length, 230);
    assert.ok(options.at(-1).textContent.includes("完整会话标题 229"));

    await setSelectValue(act, projectPicker, otherCwd, window);
    options = [...panel.querySelectorAll('.auto-resume-thread-list > button[role="option"]')];
    assert.equal(options.length, 1);
    assert.match(options[0].textContent, /另一个项目的会话/);
  }, {
    autoResumeSettings: {
      ...defaultAutoResumeSettings(),
      threadCwd: mainCwd,
    },
    autoResumeThreads: [
      ...mainThreads,
      {
        id: "other-1",
        title: "另一个项目的会话",
        cwd: otherCwd,
        updatedAt: 20_000,
        status: "active",
        source: "state-db",
      },
    ],
  });
});

test("auto resume exposes selectable interruption reasons, select-all, schedules, quota and run-now controls", async () => {
  await withMountedSettings(async ({ act, calls, container, window }) => {
    await click(act, tabByName(container, "自动续跑"), window);
    const panel = activePanel(container);

    await click(act, buttonWithText(panel, "按间隔"), window);
    assert.ok(panel.querySelector('select[aria-label="自动续跑间隔"]'));
    await click(act, buttonWithText(panel, "每天"), window);
    assert.ok(panel.querySelector('input[aria-label="自动续跑每日时间"]'));
    assert.match(panel.textContent, /HTTP 连接失败/);
    assert.match(panel.textContent, /响应流中途断开/);
    assert.match(panel.textContent, /任务被中断/);
    await click(act, buttonWithText(panel, "全选"), window);
    assert.equal(
      panel.querySelectorAll(".auto-resume-failure-grid label.is-active").length,
      14,
      "select-all is scoped to the 14 exact failed/interrupted reasons",
    );
    const quotaToggle = panel.querySelector('input[aria-label="开启额度恢复续跑"]');
    assert.ok(quotaToggle?.checked);
    const quotaWindowChoices = panel.querySelector('[aria-label="额度恢复监测窗口"]');
    assert.deepEqual(
      [...quotaWindowChoices.querySelectorAll('[role="radio"]')].map((button) => button.textContent),
      [
        "取较低值5 小时与 7 天中，按剩余更低者判断",
        "5 小时只按 5 小时额度判断（若可用）",
        "7 天只按 7 天额度判断（若可用）",
      ],
    );
    const quotaWindowChoice = (label) => [...quotaWindowChoices.querySelectorAll('[role="radio"]')]
      .find((button) => button.querySelector("strong")?.textContent === label);
    assert.equal(quotaWindowChoice("取较低值")?.getAttribute("aria-checked"), "true");
    await click(act, quotaWindowChoice("7 天"), window);
    assert.equal(quotaWindowChoice("7 天")?.getAttribute("aria-checked"), "true");
    assert.match(panel.querySelector("button.auto-resume-task-disclosure").textContent, /额度·7d/);
    assert.ok(panel.querySelector('input[aria-label="额度开始等待刷新值"]'));
    assert.ok(panel.querySelector('input[aria-label="额度刷新后续跑值"]'));
    await click(act, quotaToggle, window);
    assert.equal(panel.querySelector('input[aria-label="额度开始等待刷新值"]'), null);
    await click(act, panel.querySelector('input[aria-label="开启额度恢复续跑"]'), window);

    const invisibleToggle = panel.querySelector('input[aria-label="无痕续跑"]');
    const prompt = panel.querySelector('textarea[aria-label="自动续跑提示词"]');
    assert.ok(invisibleToggle?.checked);
    assert.equal(prompt?.disabled, true);
    assert.match(panel.textContent, /turn\/start \+ input: \[\]/);
    await click(act, invisibleToggle, window);
    assert.equal(panel.querySelector('textarea[aria-label="自动续跑提示词"]')?.disabled, false);

    await click(act, buttonWithText(panel, "立即测试 / 续跑"), window);
    await flushPromises(act);
    assert.equal(calls.autoResumeSaves.length, 1, "run now should save dirty settings first");
    assert.equal(calls.autoResumeRuns, 1);
    assert.deepEqual(calls.autoResumeRunTaskIds, ["task-alpha"]);
    assert.deepEqual(calls.autoResumeOrder, ["save", "run"]);
  }, {
    autoResumeSettings: settingsWithTask(),
  });
});

test("clicking the task summary row and its chevron toggles disclosure", async () => {
  await withMountedSettings(async ({ act, container, window }) => {
    await click(act, tabByName(container, "自动续跑"), window);
    const panel = activePanel(container);
    const disclosure = panel.querySelector("button.auto-resume-task-disclosure");
    assert.ok(disclosure);
    assert.equal(disclosure.getAttribute("aria-expanded"), "true");
    assert.match(disclosure.textContent, /▴/);

    await click(act, disclosure, window);
    assert.equal(disclosure.getAttribute("aria-expanded"), "false");
    assert.match(disclosure.textContent, /▾/);
    assert.equal(panel.querySelector(".auto-resume-task-editor"), null);

    await click(act, disclosure, window);
    assert.ok(panel.querySelector(".auto-resume-task-editor"));
  }, {
    autoResumeSettings: settingsWithTask(),
  });
});

test("running auto resume replaces run-now with a real cancel action", async () => {
  await withMountedSettings(async ({ act, calls, container, window }) => {
    await click(act, tabByName(container, "自动续跑"), window);
    const panel = activePanel(container);
    assert.equal(buttonWithTextOrNull(panel, "立即测试 / 续跑"), null);
    assert.equal(panel.querySelector(".auto-resume-failure-grid input")?.disabled, true);
    await click(act, buttonWithText(panel, "停止本次续跑"), window);
    await flushPromises(act);
    assert.equal(calls.autoResumeCancels, 1);
  }, {
    autoResumeSettings: settingsWithTask(),
    autoResumeStatus: statusWithTask({ state: "running", message: "正在发送续跑提示", isRunning: true, revision: 7 }),
  });
});

test("auto resume translates the native armed state", async () => {
  await withMountedSettings(async ({ act, container, window }) => {
    await click(act, tabByName(container, "自动续跑"), window);
    const panel = activePanel(container);
    assert.match(panel.textContent, /已就绪/);
    assert.doesNotMatch(panel.textContent, /\barmed\b/);
  }, {
    autoResumeSettings: settingsWithTask({ enabled: true }),
    autoResumeStatus: statusWithTask({ state: "armed", message: "自动续跑已就绪", revision: 8 }),
  });
});

test("auto resume surfaces backend loading and error states", async () => {
  await withMountedSettings(async ({ act, container, window }) => {
    await click(act, tabByName(container, "自动续跑"), window);
    const panel = activePanel(container);
    assert.match(panel.textContent, /刷新中/);
    const alert = panel.querySelector('[role="alert"]');
    assert.ok(alert);
    assert.match(alert.textContent, /无法连接自动续跑服务/);
    assert.equal(buttonWithText(panel, "刷新状态").disabled, true);
  }, {
    autoResumeError: "无法连接自动续跑服务",
    autoResumeLoading: true,
  });
});

test("maintenance settings expose safe data and repair actions without local-data deletion", async () => {
  await withMountedSettings(async ({ act, calls, container, window }) => {
    for (const category of SETTINGS_CATEGORIES) {
      await click(act, tabByName(container, category), window);
      assert.doesNotMatch(activePanel(container).textContent, /删除本地数据/);
    }

    await click(act, tabByName(container, "数据与维护"), window);
    const panel = activePanel(container);
    assert.match(panel.textContent, /Codex 数据目录/);
    const codexHomeInput = panel.querySelector('input[aria-label="Codex 目录"]');
    assert.ok(codexHomeInput, "maintenance page should expose the Codex directory editor");
    assert.equal(codexHomeInput.value, "/Users/test/.codex");
    assert.match(panel.textContent, /会话消失修复/);
    assert.match(panel.textContent, /会话增强/);
    assert.equal(buttonWithTextOrNull(panel, "重新连接"), null);

    await click(act, buttonWithText(panel, "打开修复工具"), window);
    await flushAnimationFrame(act, window);
    assert.equal(calls.providerRepair, 1);
    assert.doesNotMatch(container.textContent, /删除本地数据/);
  });
});

test("session settings confirm first-time Codex relaunch without closing the settings dialog", async () => {
  await withMountedSettings(async ({ act, calls, container, document, window }) => {
    await click(act, tabByName(container, "会话增强"), window);
    const panel = activePanel(container);
    await click(act, buttonWithText(panel, "重启 Codex 并启用"), window);
    assert.ok(container.querySelector('[role="alertdialog"]'));
    assert.equal(document.activeElement.textContent.trim(), "取消");
    await pressKey(act, document.activeElement, "Escape", window);
    assert.equal(container.querySelector('[role="alertdialog"]'), null);
    assert.ok(container.querySelector('[role="dialog"]'));
    assert.equal(calls.threadDeleteReconnect, 0);

    await click(act, buttonWithText(panel, "重启 Codex 并启用"), window);
    await click(act, buttonWithText(container, "重启并启用"), window);
    assert.equal(calls.threadDeleteReconnect, 1);
  }, {
    threadDeleteBridgeStatus: {
      connected: false,
      debugPort: null,
      message: "等待 Codex 调试连接（需以调试模式启动 Codex）",
    },
  });
});

test("settings closes by Escape, close button, and backdrop while restoring focus", async () => {
  await withMountedSettings(async ({ act, before, calls, container, document, render, window }) => {
    const closeButton = container.querySelector('button[aria-label="关闭总体设置"]');
    assert.ok(closeButton);
    assert.equal(document.activeElement, closeButton);

    await pressKey(act, closeButton, "Escape", window);
    assert.equal(calls.close, 1);

    await click(act, closeButton, window);
    assert.equal(calls.close, 2);

    const backdrop = container.querySelector(".app-settings-overlay");
    assert.ok(backdrop);
    await mouseDown(act, backdrop, window);
    assert.equal(calls.close, 3);

    await render({ open: false });
    assert.equal(container.querySelector('[role="dialog"]'), null);
    assert.equal(document.activeElement, before);
  });
});

async function withMountedSettings(run, initialOverrides = {}) {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { AppSettingsDialog } = await load("/src/components/settings/AppSettingsDialog.tsx");
      const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
      const container = window.document.createElement("div");
      const before = window.document.createElement("button");
      before.textContent = "before settings";
      window.document.body.append(before, container);
      before.focus();
      const root = createRoot(container);
      const calls = {
        autoResumeCancels: 0,
        autoResumeOrder: [],
        autoResumeRefreshes: 0,
        autoResumeRunTaskIds: [],
        autoResumeRuns: 0,
        autoResumeSaves: [],
        close: 0,
        providerRepair: 0,
        threadDeleteReconnect: 0,
        sessionEnhancementSaves: [],
        tokenRateFullScale: [],
        update: 0,
      };
      let overrides = initialOverrides;
      const render = async (nextOverrides = {}) => {
        overrides = { ...overrides, ...nextOverrides };
        await React.act(async () => root.render(React.createElement(
          AppSettingsDialog,
          settingsProps(DEFAULT_FLOATING_SETTINGS, calls, overrides),
        )));
      };
      try {
        await render();
        await run({ act: React.act, before, calls, container, document: window.document, render, window });
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

function settingsProps(floatingSettings, calls = null, overrides = {}) {
  const noop = () => {};
  const callLog = calls ?? {
    autoResumeCancels: 0,
    autoResumeOrder: [],
    autoResumeRefreshes: 0,
    autoResumeRunTaskIds: [],
    autoResumeRuns: 0,
    autoResumeSaves: [],
    close: 0,
    providerRepair: 0,
    threadDeleteReconnect: 0,
    sessionEnhancementSaves: [],
    tokenRateFullScale: [],
    update: 0,
  };
  return {
    appUpdateState: { kind: "idle", message: "已是最新版本" },
    autostartStatus: { available: true, enabled: true, status: "enabled", message: "已开启" },
    autoResumeCancelling: false,
    autoResumeError: null,
    autoResumeLoading: false,
    autoResumeRunning: false,
    autoResumeSaving: false,
    autoResumeSettings: defaultAutoResumeSettings(),
    autoResumeStatus: defaultAutoResumeStatus(),
    autoResumeThreads: [],
    codexHome: { exists: true, path: "/Users/test/.codex", source: "auto" },
    displaySurfaces: {
      floatingWindowEnabled: true,
      liveRateEnabled: true,
      statusTrayLiveTextEnabled: true,
    },
    floatingSettings,
    liveRateEnabled: true,
    open: true,
    platform: platformCapabilities(),
    quotaRefreshIntervalMs: 60_000,
    sessionEnhancements: defaultSessionEnhancements(),
    threadDeleteBridgeStatus: {
      connected: true,
      debugPort: 9222,
      message: "已连接 Codex 调试端口 9222",
    },
    onCheckForUpdate: async () => { callLog.update += 1; },
    onCancelAutoResume: async () => {
      callLog.autoResumeCancels += 1;
      callLog.autoResumeOrder.push("cancel");
    },
    onClose: () => { callLog.close += 1; },
    onCodexHomeChange: async () => {},
    onCodexHomeReset: async () => {},
    onFloatingContentVisibilityChange: noop,
    onFloatingGradientChange: noop,
    onFloatingOpacityChange: noop,
    onFloatingScaleChange: noop,
    onFloatingTextToneChange: noop,
    onFloatingUnreadEffectChange: noop,
    onOpenProviderRepair: () => { callLog.providerRepair += 1; },
    onQuotaRefreshIntervalChange: async () => {},
    onRefreshAutoResume: async () => { callLog.autoResumeRefreshes += 1; },
    onReconnectThreadDelete: async () => { callLog.threadDeleteReconnect += 1; },
    onRunAutoResume: async (taskId) => {
      callLog.autoResumeRuns += 1;
      callLog.autoResumeRunTaskIds.push(taskId);
      callLog.autoResumeOrder.push("run");
    },
    onSaveAutoResume: async (settings) => {
      callLog.autoResumeSaves.push(settings);
      callLog.autoResumeOrder.push("save");
    },
    onSaveSessionEnhancements: async (settings) => {
      callLog.sessionEnhancementSaves.push(settings);
    },
    onTokenRateFullScaleChange: (value) => { callLog.tokenRateFullScale.push(value); },
    onToggleAutostart: noop,
    onToggleFloating: noop,
    onToggleLiveRate: noop,
    onToggleStatusTray: noop,
    ...overrides,
  };
}

function defaultSessionEnhancements() {
  return {
    sessionDelete: true,
    markdownExport: true,
    pasteFix: false,
    projectMove: true,
    threadIDBadge: false,
    conversationView: false,
    conversationViewMaxWidth: 900,
    threadScrollRestore: true,
  };
}

function platformCapabilities() {
  const available = (label) => ({ available: true, status: "ready", label, note: `${label}可用` });
  return {
    platform: "macos",
    shell: "zsh",
    floatingWindow: available("悬浮窗"),
    floatingTransparency: available("悬浮窗透明度"),
    floatingDrag: available("悬浮窗拖动"),
    floatingLock: available("悬浮窗锁定"),
    statusTray: available("状态栏"),
    statusTrayLiveText: available("状态栏数字"),
    autostart: available("开机自启"),
    notifications: available("通知"),
  };
}

function defaultAutoResumeSettings() {
  return {
    taskCollectionVersion: 2,
    selectedTaskId: "",
    tasks: [],
    enabled: false,
    threadId: "",
    threadTitle: "",
    threadCwd: "",
    prompt: "继续",
    invisibleResumeEnabled: true,
    scheduleMode: "off",
    intervalMinutes: 60,
    dailyHour: 9,
    dailyMinute: 0,
    failureRecoveryPolicyVersion: 2,
    failureRecoveryReasons: [],
    capacityRecoveryEnabled: false,
    quotaResumeEnabled: true,
    quotaWindow: "either",
    quotaLowThresholdPercent: 5,
    quotaRecoveryThresholdPercent: 20,
    cooldownMinutes: 30,
    maxRunsPerDay: 6,
    notifyOnResult: true,
  };
}

function defaultAutoResumeStatus() {
  return {
    state: "disabled",
    message: "自动续跑未开启",
    isRunning: false,
    waitingForQuota: false,
    lastTrigger: null,
    lastRunAt: null,
    nextScheduledAt: null,
    runsToday: 0,
    revision: 0,
    taskId: null,
    runningTaskId: null,
    protectedTasks: 0,
    totalTasks: 0,
    tasks: [],
  };
}

function defaultAutoResumeTask(overrides = {}) {
  return {
    ...defaultAutoResumeSettings(),
    id: "task-alpha",
    createdAt: 1_784_000_000_000,
    updatedAt: 1_784_000_000_000,
    threadId: "thread-alpha",
    threadTitle: "Alpha thread",
    threadCwd: "/Users/test/project",
    ...overrides,
    selectedTaskId: undefined,
    tasks: undefined,
  };
}

function settingsWithTask(overrides = {}) {
  const task = defaultAutoResumeTask(overrides);
  return {
    ...task,
    selectedTaskId: task.id,
    tasks: [task],
  };
}

function statusWithTask(overrides = {}) {
  const taskStatus = {
    taskId: "task-alpha",
    state: "waiting",
    message: "正在等待触发条件",
    isRunning: false,
    waitingForQuota: false,
    lastTrigger: null,
    lastRunAt: null,
    nextScheduledAt: null,
    runsToday: 0,
    revision: 1,
    ...overrides,
  };
  return {
    ...defaultAutoResumeStatus(),
    ...overrides,
    taskId: taskStatus.taskId,
    runningTaskId: taskStatus.isRunning ? taskStatus.taskId : null,
    protectedTasks: 1,
    totalTasks: 1,
    tasks: [taskStatus],
  };
}

function settingTabs(container) {
  return [...container.querySelectorAll('[role="tab"]')];
}

function tabByName(container, name) {
  const tab = settingTabs(container).find((candidate) => tabName(candidate) === name);
  assert.ok(tab, `settings tab ${name} should exist`);
  return tab;
}

function tabName(tab) {
  return tab.querySelector("strong")?.textContent?.trim() ?? tab.textContent.trim();
}

function selectedTab(container) {
  const selected = container.querySelector('[role="tab"][aria-selected="true"]');
  assert.ok(selected, "one settings tab should be selected");
  return selected;
}

function activePanel(container) {
  const panel = container.querySelector('[role="tabpanel"]');
  assert.ok(panel, "active settings tab should own a tabpanel");
  return panel;
}

function buttonWithText(container, text) {
  const matches = [...container.querySelectorAll("button")]
    .filter((button) => button.textContent?.includes(text));
  assert.equal(matches.length, 1, `expected one button containing ${text}`);
  return matches[0];
}

function buttonWithTextOrNull(container, text) {
  return [...container.querySelectorAll("button")]
    .find((button) => button.textContent?.includes(text)) ?? null;
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

async function click(act, target, window) {
  await act(async () => target.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true })));
}

async function mouseDown(act, target, window) {
  await act(async () => target.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true })));
}

async function submitForm(act, form, window) {
  assert.ok(form);
  await act(async () => form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true })));
}

async function pressKey(act, target, key, window, options = {}) {
  assert.ok(target);
  await act(async () => target.dispatchEvent(new window.KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    key,
    ...options,
  })));
}

async function flushAnimationFrame(act, window) {
  await act(async () => new Promise((resolve) => window.requestAnimationFrame(resolve)));
}

async function setRangeValue(act, input, value, window) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")?.set;
  assert.ok(setter, "range value setter should exist");
  setter.call(input, String(value));
  await act(async () => input.dispatchEvent(new window.Event("input", { bubbles: true, cancelable: true })));
}

async function setInputValue(act, input, value, window) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")?.set;
  assert.ok(setter, "input value setter should exist");
  setter.call(input, value);
  await act(async () => input.dispatchEvent(new window.Event("input", { bubbles: true, cancelable: true })));
}

async function setSelectValue(act, select, value, window) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")?.set;
  assert.ok(setter, "select value setter should exist");
  setter.call(select, value);
  await act(async () => select.dispatchEvent(new window.Event("change", { bubbles: true, cancelable: true })));
}

async function flushPromises(act) {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

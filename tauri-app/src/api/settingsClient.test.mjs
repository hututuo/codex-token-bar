import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("readAppSettings distinguishes browser absence from a native read failure", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const calls = [];

  try {
    Object.defineProperty(globalThis, "window", {
      configurable: true,
      value: {
        clearTimeout: globalThis.clearTimeout.bind(globalThis),
        setTimeout: globalThis.setTimeout.bind(globalThis),
      },
      writable: true,
    });

    await withSsrModules(async (load) => {
      const { completeFloatingPagingGuide, readAppSettings } = await load("/src/api/settingsClient.ts");
      assert.equal(
        await readAppSettings(),
        null,
        "only a non-Tauri browser runtime should resolve to null",
      );

      globalThis.window.__TAURI_INTERNALS__ = {
        invoke(command, args) {
          calls.push({ command, args });
          return Promise.resolve({ setupGuideCompleted: true });
        },
      };
      assert.deepEqual(await readAppSettings(), { setupGuideCompleted: true });
      assert.deepEqual(calls, [{ command: "read_app_settings", args: {} }]);

      assert.deepEqual(
        await completeFloatingPagingGuide(true, 3),
        { setupGuideCompleted: true },
      );
      assert.deepEqual(calls[1], {
        command: "complete_floating_paging_guide",
        args: { showPageNavigationArrows: true, pagingGuideRevision: 3 },
      });

      globalThis.window.__TAURI_INTERNALS__.invoke = () => Promise.reject("settings unreadable");
      await assert.rejects(
        readAppSettings(),
        /settings unreadable/,
        "a native read failure must remain visible to the settings error banner",
      );
    });
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow);
    else delete globalThis.window;
  }
});

test("saveUsageRefreshSettings sends all three cadences through one native command", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const calls = [];
  const settings = {
    usageLightRefreshIntervalSeconds: 150,
    usageVisibleAggregateIntervalMinutes: 5,
    usageBackgroundAggregateIntervalMinutes: 30,
  };

  try {
    Object.defineProperty(globalThis, "window", {
      configurable: true,
      value: {
        clearTimeout: globalThis.clearTimeout.bind(globalThis),
        setTimeout: globalThis.setTimeout.bind(globalThis),
        __TAURI_INTERNALS__: {
          invoke(command, args) {
            calls.push({ command, args });
            return Promise.resolve({
              quotaRefreshIntervalMs: 60_000,
              ...settings,
            });
          },
        },
      },
      writable: true,
    });

    await withSsrModules(async (load) => {
      const { saveUsageRefreshSettings } = await load("/src/api/settingsClient.ts");
      assert.deepEqual(await saveUsageRefreshSettings(settings), {
        quotaRefreshIntervalMs: 60_000,
        ...settings,
      });
    });

    assert.deepEqual(calls, [{
      command: "save_usage_refresh_settings",
      args: { settings },
    }]);
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow);
    else delete globalThis.window;
  }
});

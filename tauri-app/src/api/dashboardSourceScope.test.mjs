import assert from "node:assert/strict";
import test from "node:test";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("usage summary and quota IPC calls forward the exact source token", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const calls = [];
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __TAURI_INTERNALS__: {
        invoke(command, args) {
          calls.push({ args, command });
          return Promise.resolve(command === "read_account_quota" ? { quota: {} } : { totalTokens: 1 });
        },
      },
      clearTimeout: globalThis.clearTimeout.bind(globalThis),
      setTimeout: globalThis.setTimeout.bind(globalThis),
    },
    writable: true,
  });

  try {
    await withSsrModules(async (load) => {
      const {
        readAccountQuota,
        readUsageSummarySnapshot,
      } = await load("/src/api/dashboardClient.ts");
      const sourceToken = {
        canonicalHomeKey: "/same/.codex",
        physicalHomeKey: "unix:1:2",
        transitionGeneration: 7,
      };

      await readUsageSummarySnapshot(sourceToken);
      await readAccountQuota(sourceToken, true);

      assert.deepEqual(calls, [
        {
          command: "read_usage_summary_snapshot",
          args: { sourceToken },
        },
        {
          command: "read_account_quota",
          args: { forceRefresh: true, sourceToken },
        },
      ]);
    });
  } finally {
    if (previousWindow) {
      Object.defineProperty(globalThis, "window", previousWindow);
    } else {
      delete globalThis.window;
    }
  }
});

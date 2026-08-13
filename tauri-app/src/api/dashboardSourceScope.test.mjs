import assert from "node:assert/strict";
import test from "node:test";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("usage, quota, reset credits, and attribution safety IPC calls forward the exact source token", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const calls = [];
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __TAURI_INTERNALS__: {
        invoke(command, args) {
          calls.push({ args, command });
          if (command === "read_usage_summary_snapshot") return Promise.resolve(null);
          if (command === "read_account_quota") return Promise.resolve({ quota: {} });
          if (command === "read_account_reset_credits") return Promise.resolve({ successful: true });
          if (command === "acknowledge_attribution_safety") return Promise.resolve(true);
          return Promise.resolve({ totalTokens: 1 });
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
        acknowledgeAttributionSafety,
        readAccountQuota,
        readAccountResetCredits,
        readUsageSummarySnapshot,
      } = await load("/src/api/dashboardClient.ts");
      const sourceToken = {
        canonicalHomeKey: "/same/.codex",
        physicalHomeKey: "unix:1:2",
        transitionGeneration: 7,
      };

      assert.equal(await readUsageSummarySnapshot(sourceToken), null);
      await readAccountQuota(sourceToken, true);
      await readAccountResetCredits(sourceToken, true);
      assert.equal(await acknowledgeAttributionSafety(
        sourceToken,
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        9,
      ), true);

      assert.deepEqual(calls, [
        {
          command: "read_usage_summary_snapshot",
          args: { sourceToken },
        },
        {
          command: "read_account_quota",
          args: { forceRefresh: true, sourceToken },
        },
        {
          command: "read_account_reset_credits",
          args: { forceRefresh: true, sourceToken },
        },
        {
          command: "acknowledge_attribution_safety",
          args: {
            provenanceEpoch: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            sourceToken,
            throughGeneration: 9,
            unsafeId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          },
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

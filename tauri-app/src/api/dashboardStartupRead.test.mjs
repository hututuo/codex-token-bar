import assert from "node:assert/strict";
import test from "node:test";

import { withSsrModules } from "../test/ssrHarness.mjs";

const sourceToken = {
  canonicalHomeKey: "/fixture/.codex",
  physicalHomeKey: "unix:1:2",
  transitionGeneration: 1,
};

test("startup dashboard reads stay pending past the legacy 4000ms budget", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  let resolveInvoke;
  const nativeSnapshot = {
    generatedAt: "2026-08-03T08:00:00.000Z",
    stats: { totalTokens: 42 },
  };

  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __TAURI_INTERNALS__: {
        invoke(command, args) {
          assert.equal(command, "read_dashboard_snapshot");
          assert.deepEqual(args, { sourceToken });
          return new Promise((resolve) => {
            resolveInvoke = resolve;
          });
        },
      },
      clearTimeout: globalThis.clearTimeout.bind(globalThis),
      setTimeout: globalThis.setTimeout.bind(globalThis),
    },
    writable: true,
  });

  try {
    await withSsrModules(async (load) => {
      const { readDashboardSnapshot } = await load("/src/api/dashboardClient.ts");
      const pending = readDashboardSnapshot(sourceToken);
      let settled = false;
      void pending.then(() => {
        settled = true;
      });

      await new Promise((resolve) => setTimeout(resolve, 4_050));
      assert.equal(
        settled,
        false,
        "the startup IPC must not resolve with an empty fallback at 4000ms",
      );

      resolveInvoke(nativeSnapshot);
      assert.deepEqual(await pending, nativeSnapshot);
    });
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow);
    else delete globalThis.window;
  }
});

test("a real startup dashboard rejection remains visible as a local failure", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __TAURI_INTERNALS__: {
        invoke(command, args) {
          assert.equal(command, "read_dashboard_snapshot");
          assert.deepEqual(args, { sourceToken });
          return Promise.reject(new Error("state database unavailable"));
        },
      },
      clearTimeout: globalThis.clearTimeout.bind(globalThis),
      setTimeout: globalThis.setTimeout.bind(globalThis),
    },
    writable: true,
  });

  try {
    await withSsrModules(async (load) => {
      const { callCommand, getCommandDiagnosticsSnapshot } = await load(
        "/src/api/command.ts",
      );
      const fallback = await callCommand(
        "read_dashboard_snapshot",
        { stats: { totalTokens: 0 } },
        { sourceToken },
        null,
      );

      assert.equal(fallback.stats.totalTokens, 0);
      const diagnostic = getCommandDiagnosticsSnapshot().find(
        (item) => item.command === "read_dashboard_snapshot",
      );
      assert.equal(diagnostic?.message, "state database unavailable");
    });
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow);
    else delete globalThis.window;
  }
});

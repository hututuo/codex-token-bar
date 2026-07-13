import assert from "node:assert/strict";
import test from "node:test";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("thread delete activation calls the dedicated native restart command", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const calls = [];
  const status = {
    connected: false,
    debugPort: null,
    message: "正在等待 Codex 调试连接",
  };
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __TAURI_INTERNALS__: {
        invoke(command, args) {
          calls.push({ args, command });
          return Promise.resolve(status);
        },
      },
      clearTimeout: globalThis.clearTimeout.bind(globalThis),
      setTimeout: globalThis.setTimeout.bind(globalThis),
    },
    writable: true,
  });

  try {
    await withSsrModules(async (load) => {
      const { enableThreadDeleteBridge } = await load("/src/api/threadDeleteClient.ts");
      assert.deepEqual(await enableThreadDeleteBridge(), status);
      assert.deepEqual(calls, [{ command: "enable_thread_delete_bridge", args: {} }]);
    });
  } finally {
    if (previousWindow) {
      Object.defineProperty(globalThis, "window", previousWindow);
    } else {
      delete globalThis.window;
    }
  }
});

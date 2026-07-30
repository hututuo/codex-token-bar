import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("session management client uses the exact plural native command contract", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const calls = [];
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __TAURI_INTERNALS__: {
        invoke(command, args) {
          calls.push({ command, args });
          if (command === "list_session_management_catalog") return Promise.resolve({ threads: [] });
          if (command === "read_session_context_page") return Promise.resolve({ messages: [] });
          return Promise.resolve({ results: [], warnings: [] });
        },
      },
      clearTimeout: globalThis.clearTimeout.bind(globalThis),
      setTimeout: globalThis.setTimeout.bind(globalThis),
    },
    writable: true,
  });

  try {
    await withSsrModules(async (load) => {
      const client = await load("/src/api/sessionManagementClient.ts");
      const sourceToken = {
        canonicalHomeKey: "/fixture/codex",
        physicalHomeKey: "unix:1:2",
        transitionGeneration: 7,
      };
      await client.listSessionManagementCatalog(sourceToken);
      await client.readSessionContextPage(sourceToken, "thread-a", 900, 25);
      await client.archiveSessionThreads(sourceToken, ["thread-a"]);
      await client.unarchiveSessionThreads(sourceToken, ["thread-b"]);
      const confirmation = {
        schemaVersion: 1,
        preparedAt: 2_000_000_000,
        physicalHomeKey: sourceToken.physicalHomeKey,
        requestedIds: ["thread-c"],
        effectiveRootIds: ["thread-c"],
        affectedIds: ["thread-c", "thread-child"],
        rollouts: [],
      };
      await client.prepareSessionDeleteConfirmation(sourceToken, ["thread-c"]);
      await client.deleteSessionThreads(sourceToken, ["thread-c"], confirmation);
      await client.createSessionRecoveryArchives(sourceToken, ["thread-d"]);

      assert.deepEqual(calls, [
        { command: "list_session_management_catalog", args: { sourceToken } },
        {
          command: "read_session_context_page",
          args: { sourceToken, threadId: "thread-a", beforeOffset: 900, pageSize: 25 },
        },
        { command: "archive_session_threads", args: { sourceToken, threadIds: ["thread-a"] } },
        { command: "unarchive_session_threads", args: { sourceToken, threadIds: ["thread-b"] } },
        {
          command: "prepare_session_delete_confirmation",
          args: { sourceToken, threadIds: ["thread-c"] },
        },
        {
          command: "delete_session_threads",
          args: {
            sourceToken,
            threadIds: ["thread-c"],
            createRecoveryArchive: true,
            confirmation,
          },
        },
        {
          command: "create_session_recovery_archives",
          args: { sourceToken, threadIds: ["thread-d"] },
        },
      ]);
    });
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow);
    else delete globalThis.window;
  }
});

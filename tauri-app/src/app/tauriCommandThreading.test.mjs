import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("live commands that read local files run off the command thread", async () => {
  const liveCommands = await readFile(
    new URL("../../src-tauri/src/commands/live.rs", import.meta.url),
    "utf8",
  );

  for (const command of [
    "read_live_rate_snapshot",
    "read_live_thread_options",
    "start_live_rate_stream",
    "read_floating_snapshot",
    "read_unread_summary",
  ]) {
    assert.match(liveCommands, new RegExp(`pub async fn ${command}\\b`));
  }

  assert.match(liveCommands, /async_runtime::spawn_blocking/);
  assert.match(liveCommands, /run_blocking_command/);
});

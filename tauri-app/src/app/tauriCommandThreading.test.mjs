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
    "claim_live_rate_owner_session",
    "start_live_rate_stream",
    "read_floating_snapshot",
    "read_unread_summary",
    "acknowledge_current_unread",
  ]) {
    assert.match(liveCommands, new RegExp(`pub async fn ${command}\\b`));
  }

  assert.match(liveCommands, /async_runtime::spawn_blocking/);
  assert.match(liveCommands, /run_blocking_command/);
  assert.match(liveCommands, /const ACTIVE_STREAM_HOLD: Duration = Duration::from_secs\(10\);/);
  assert.match(liveCommands, /last_active_at/);
  assert.match(liveCommands, /last_active\.elapsed\(\) <= ACTIVE_STREAM_HOLD/);
});

test("running thread summary starts its scanner on the blocking pool", async () => {
  const source = await readFile(
    new URL("../../src-tauri/src/commands/thread_activity.rs", import.meta.url),
    "utf8",
  );

  assert.match(source, /pub async fn read_running_thread_summary\b/);
  assert.match(source, /tauri::async_runtime::spawn_blocking/);
  assert.match(source, /snapshot_or_start/);
  assert.match(source, /validate_codex_home_source\(&completed_source_token\)/);
});

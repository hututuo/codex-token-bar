import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("unread summary reads stay strict while backend soft-handles only a missing live sidebar", async () => {
  const source = await readFile(new URL("./liveClient.ts", import.meta.url), "utf8");
  const commands = await readFile(
    new URL("../../src-tauri/src/commands/live.rs", import.meta.url),
    "utf8",
  );

  assert.match(source, /callCommandStrict<UnreadSummary>\("read_unread_summary"/);
  assert.doesNotMatch(source, /callCommand\("read_unread_summary", emptyUnreadSummary/);
  assert.match(commands, /is_sidebar_snapshot_unavailable_error\(&error\)/);
  assert.match(commands, /source: "codex_sidebar_unavailable"/);
  assert.match(commands, /return Err\(error\)/);
  assert.match(commands, /pin_captured_codex_home_source\(&captured\)/);
  assert.match(commands, /unread::try_read_unread_summary_for_source\(/);
  assert.match(commands, /&pinned\.source_scope_key/);
  assert.match(commands, /validate_codex_home_source\(&completed_source_token\)/);
  assert.match(commands, /snapshot_at_with_unread\(/);
  assert.match(commands, /immediate_unread_summary_for_source\(/);
  assert.match(commands, /immediate_snapshot_at_with_unread\(/);
  assert.match(commands, /UNREAD_SUMMARY_CHANGED_EVENT: &str = "unread-summary-changed"/);
  assert.match(commands, /schedule_unread_refresh\(/);
  assert.match(commands, /source_token\.transition_generation/);
  assert.match(commands, /floating_snapshot_with_unread\(/);
  assert.doesNotMatch(
    commands,
    /snapshot_at\([\s\S]{0,300}try_read_unread_summary_for_source/,
  );
});

test("initial live-rate IPC timeout becomes typed pending without hiding native failures", async () => {
  const source = await readFile(new URL("./liveClient.ts", import.meta.url), "utf8");
  const initialRead = source.slice(
    source.indexOf("export async function readInitialLiveRateSnapshot"),
    source.indexOf("export function readLiveThreadOptions"),
  );

  assert.match(initialRead, /callCommandStrict<LiveRateSnapshot>/);
  assert.match(initialRead, /sourceToken \},\s*null,/);
  assert.match(initialRead, /withInitialLiveRateIpcBudget\(invocation\)/);
  assert.match(initialRead, /error instanceof InitialLiveRateIpcTimeoutError/);
  assert.match(initialRead, /emptyLiveRateSnapshot\(selectedThreadId\)/);
  assert.match(initialRead, /threadTitle: "实时速率正在连接"/);
  assert.match(source, /INITIAL_LIVE_RATE_IPC_TIMEOUT_MS = 1_500/);
});

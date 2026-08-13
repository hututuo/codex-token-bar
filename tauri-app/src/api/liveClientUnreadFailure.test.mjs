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
  assert.match(commands, /floating_snapshot_with_unread\(/);
  assert.doesNotMatch(
    commands,
    /snapshot_at\([\s\S]{0,300}try_read_unread_summary_for_source/,
  );
});

test("compact initial live-rate reads propagate timeout instead of returning empty fallback", async () => {
  const source = await readFile(new URL("./liveClient.ts", import.meta.url), "utf8");
  const strictRead = source.slice(
    source.indexOf("export function readLiveRateSnapshotStrict"),
    source.indexOf("export function readLiveThreadOptions"),
  );

  assert.match(strictRead, /callCommandStrict<LiveRateSnapshot>/);
  assert.doesNotMatch(strictRead, /emptyLiveRateSnapshot/);
});

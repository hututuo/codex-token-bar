import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("unread summary reads propagate persistence failures instead of returning an empty fallback", async () => {
  const source = await readFile(new URL("./liveClient.ts", import.meta.url), "utf8");
  const commands = await readFile(
    new URL("../../src-tauri/src/commands/live.rs", import.meta.url),
    "utf8",
  );

  assert.match(source, /callCommandStrict<UnreadSummary>\("read_unread_summary"/);
  assert.doesNotMatch(source, /callCommand\("read_unread_summary", emptyUnreadSummary/);
  assert.match(commands, /unread::try_read_unread_summary\(source\.codex_home\(\)\)/);
});

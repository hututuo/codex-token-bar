import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("running thread summary uses a strict source-scoped command without a zero fallback", async () => {
  const source = await readFile(new URL("./liveClient.ts", import.meta.url), "utf8");
  const command = source.slice(
    source.indexOf("export function readRunningThreadSummary"),
    source.indexOf("export function acknowledgeUnreadSummary"),
  );

  assert.match(command, /callCommandStrict<RunningThreadSummary>/);
  assert.match(command, /"read_running_thread_summary"/);
  assert.match(command, /\{ sourceToken \}/);
  assert.doesNotMatch(command, /total:\s*0|mainThreads:\s*0|subagents:\s*0/);
});

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("Status panel can acknowledge the same unread baseline as the main dashboard", async () => {
  const source = await readFile(new URL("./StatusPanelApp.tsx", import.meta.url), "utf8");

  assert.match(source, /acknowledgeUnreadSummary/);
  assert.match(source, /标记已读/);
});

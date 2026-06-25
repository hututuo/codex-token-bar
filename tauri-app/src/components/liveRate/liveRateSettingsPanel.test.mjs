import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("content settings rows show Swift-style subtitles and movement feedback", async () => {
  const panel = await readFile(new URL("./LiveRateSettingsPanel.tsx", import.meta.url), "utf8");

  assert.equal(panel.includes("label.subtitle"), true);
  assert.equal(panel.includes("靠近速率会吸附"), false);
  assert.equal(panel.includes("moveFloatingContent"), true);
  assert.equal(panel.includes("aria-live"), true);
});

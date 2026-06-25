import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("content settings rows show Swift-style subtitles and movement feedback", async () => {
  const panel = await readFile(new URL("./LiveRateSettingsPanel.tsx", import.meta.url), "utf8");
  const labels = await readFile(new URL("../../floating/floatingContent.ts", import.meta.url), "utf8");

  assert.equal(panel.includes("label.subtitle"), true);
  assert.equal(labels.includes("靠近速率会吸附"), true);
  assert.equal(panel.includes("moveFloatingContent"), true);
  assert.equal(panel.includes("aria-live"), true);
  assert.equal(panel.includes("movedInfo"), true);
  assert.equal(panel.includes("已${movedInfo.direction === \"up\" ? \"上移\" : \"下移\"}"), true);
  assert.equal(panel.includes("data-move-direction"), true);
  assert.equal(panel.includes("向上移动"), true);
  assert.equal(panel.includes("向下移动"), true);
});

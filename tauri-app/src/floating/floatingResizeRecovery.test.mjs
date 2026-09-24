import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { restoreFloatingWindowFrame } from "./floatingResizeRecovery.ts";

test("drawer close retries a failed native restore and confirms only a successful frame", async () => {
  let calls = 0;
  const waits = [];
  assert.equal(await restoreFloatingWindowFrame(async () => ++calls === 2, () => true,
    async ms => { waits.push(ms); }), true);
  assert.equal(calls, 2);
  assert.deepEqual(waits, [75]);
});

test("persistent failure is bounded and does not report a restored frame", async () => {
  let calls = 0;
  assert.equal(await restoreFloatingWindowFrame(async () => { calls++; return false; }, () => true,
    async () => {}), false);
  assert.equal(calls, 3);
});

test("new layout or unmount stops queued restores and ignores a stale successful completion", async () => {
  let current = true, calls = 0;
  assert.equal(await restoreFloatingWindowFrame(async () => { calls++; return false; }, () => current,
    async () => { current = false; }), false);
  assert.equal(calls, 1);
  current = true;
  assert.equal(await restoreFloatingWindowFrame(async () => { current = false; return true; }, () => current), false);
});

test("all drawer close paths keep the base position until native restoration succeeds", () => {
  const source = readFileSync(new URL("./FloatingWindowApp.tsx", import.meta.url), "utf8");
  assert.match(source, /restoreFloatingWindowFrame\(resize, \(\) => !cancelled\)/);
  assert.match(source, /if \(resized && !effectiveRunningModelDetailsExpanded && !cancelled\)\s*\{\s*runningModelDetailsBasePositionRef\.current = null/);
});

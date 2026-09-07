import test from "node:test";
import assert from "node:assert/strict";
import { waitForDockViewport, waitForDockPaint } from "./floatingDockPaintHandoff.ts";

function browser(t) {
  const prior = { window: globalThis.window, requestAnimationFrame: globalThis.requestAnimationFrame, cancelAnimationFrame: globalThis.cancelAnimationFrame };
  const window = new EventTarget();
  Object.assign(window, { innerWidth: 12, innerHeight: 100, setTimeout, clearTimeout });
  const frames = new Map(); let id = 0;
  Object.assign(globalThis, { window,
    requestAnimationFrame: (callback) => { frames.set(++id, callback); return id; },
    cancelAnimationFrame: (key) => frames.delete(key),
  });
  t.after(() => Object.assign(globalThis, prior));
  return { window, paint() { const frame = [...frames.entries()][0]; assert.ok(frame); frames.delete(frame[0]); frame[1](0); } };
}
async function drain() { for (let i = 0; i < 8; i++) await Promise.resolve(); }

test("viewport gate waits for WebKit resize instead of trusting native completion", async (t) => {
  const b = browser(t); let ready = false;
  const gate = waitForDockViewport(300, 100).then(() => { ready = true; });
  await drain(); assert.equal(ready, false);
  b.window.dispatchEvent(new Event("resize")); await drain(); assert.equal(ready, false);
  b.window.innerWidth = 300; b.window.dispatchEvent(new Event("resize"));
  await gate; assert.equal(ready, true);
});

test("paint gate keeps the mask through the first resized layout frame", async (t) => {
  const b = browser(t); let ready = false;
  const gate = waitForDockPaint().then(() => { ready = true; });
  b.paint(); await drain(); assert.equal(ready, false);
  b.paint(); await gate; assert.equal(ready, true);
});

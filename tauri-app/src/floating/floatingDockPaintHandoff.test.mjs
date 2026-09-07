import test from "node:test";
import assert from "node:assert/strict";
import { fadeBeforeNativeDockReveal, waitForDockViewport, waitForDockPaint } from "./floatingDockPaintHandoff.ts";

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

test("old narrow surface stays transparent until the native handoff is released", async (t) => {
  const b = browser(t); const animations = [];
  const host = { isConnected: true, animate(keyframes, options) {
    const animation = { keyframes, options, finished: Promise.resolve(), cancelled: 0, cancel() { this.cancelled++; } };
    animations.push(animation); return animation;
  } };
  const gate = fadeBeforeNativeDockReveal(host, false); await drain();
  assert.equal(animations.length, 1);
  assert.equal(animations[0].keyframes.at(-1).opacity, 0);
  assert.equal(animations[0].options.fill, "forwards");
  b.paint(); const release = await gate;
  assert.equal(animations[0].cancelled, 0);
  release(); release();
  assert.equal(animations[0].cancelled, 1);
  assert.equal(animations.length, 2);
  assert.equal(animations[1].keyframes[0].opacity, 0);
  assert.equal(animations[1].keyframes.at(-1).opacity, 1);
});

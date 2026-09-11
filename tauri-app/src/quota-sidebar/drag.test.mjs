import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import { readFile } from "node:fs/promises";
import { createSidebarDragSession, isSidebarDragTarget } from "./drag.ts";
import { sidebarReducer } from "./model.ts";
const flush = () => new Promise(resolve => setImmediate(resolve));
test("only blank rail and resting bars initiate dragging; complete quota/task button content remains clickable", () => {
  const window = new Window();
  try {
    window.document.body.innerHTML = '<main><span class="qs-bar"><i></i></span><button><svg><circle/></svg><strong>70%</strong></button></main>';
    for (const tag of ["main", "i"]) assert.equal(isSidebarDragTarget(window.document.querySelector(tag)), true);
    for (const tag of ["button", "circle", "strong"]) assert.equal(isSidebarDragTarget(window.document.querySelector(tag)), false);
  } finally { window.close(); }
});
test("disable/unmount invalidates a pending native release and reenable cannot admit duplicate drag", async () => {
  let resolve; let calls = 0; const completions = []; const errors = [];
  const session = createSidebarDragSession(() => { calls++; return new Promise(done => { resolve = done; }); }, value => completions.push(value), e => errors.push(e));
  assert.equal(session.start(), false);
  session.setEnabled(true); assert.equal(session.start(), true); assert.equal(session.start(), false);
  const oldEpoch = session.epoch;
  session.setEnabled(false); session.setEnabled(true); assert.equal(session.isCurrent(oldEpoch), false);
  assert.equal(session.start(), false); resolve(true); await flush();
  assert.deepEqual(completions, []); assert.deepEqual(errors, []); assert.equal(calls, 1);
  assert.equal(session.start(), true); resolve(true); await flush(); assert.deepEqual(completions, [true]);
});
test("disabled late errors are ignored, while current errors release the session", async () => {
  let reject; const completions = []; const errors = [];
  const session = createSidebarDragSession(() => new Promise((_, fail) => { reject = fail; }), v => completions.push(v), e => errors.push(e));
  session.setEnabled(true); session.start(); session.setEnabled(false); reject("old"); await flush();
  assert.deepEqual(errors, []); assert.deepEqual(completions, []);
  session.setEnabled(true); session.start(); reject("current"); await flush();
  assert.deepEqual(errors, ["current"]); assert.deepEqual(completions, [false]); assert.equal(session.active, false);
});
test("native drag-start closes detail/unpins without expanding resting rail, and real surface uses the session", async () => {
  assert.deepEqual(sidebarReducer({ mode: "detail", tab: "radar", pinned: true }, { type: "drag" }), { mode: "hover", tab: "radar", pinned: false });
  assert.equal(sidebarReducer({ mode: "rest", tab: "quota", pinned: false }, { type: "drag" }).mode, "rest");
  const source = await readFile(new URL("./QuotaSidebarApp.tsx", import.meta.url), "utf8");
  assert.ok(source.includes('dragSession.current = createSidebarDragSession('));
  assert.ok(source.includes('onPointerDown={startDrag}'));
});

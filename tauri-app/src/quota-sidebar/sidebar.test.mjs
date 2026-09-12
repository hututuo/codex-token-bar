import assert from "node:assert/strict";
import test from "node:test";
import { initialSidebarState, isSidebarAction, quotaPercent, sidebarReducer } from "./model.ts";
import { createSidebarNativeCoordinator } from "./nativeCoordinator.ts";
import { sanitizeDisplaySurfaces } from "../settings/displaySettings.ts";

const tick = () => new Promise(resolve => setImmediate(resolve));
test("old settings migrate to a disabled independent sidebar, preserving floating", () => {
  const old = sanitizeDisplaySurfaces({ floatingWindowEnabled: true, liveRateEnabled: false });
  assert.equal(old.quotaSidebarEnabled, false); assert.equal(old.quotaSidebarSide, "right");
  const sidebarOnly = sanitizeDisplaySurfaces({ floatingWindowEnabled: false, statusTrayLiveTextEnabled: false, quotaSidebarEnabled: true, quotaSidebarSide: "left" });
  assert.equal(sidebarOnly.quotaSidebarEnabled, true); assert.equal(sidebarOnly.floatingWindowEnabled, false);
  assert.equal(sidebarOnly.quotaSidebarSide, "left");
});
test("hover can only reveal the summary; details require an item click", () => {
  let state = sidebarReducer(initialSidebarState, { type: "enter" });
  assert.equal(state.mode, "hover");
  state = sidebarReducer(state, { type: "enter" }); assert.equal(state.mode, "hover");
  state = sidebarReducer(state, { type: "open", tab: "running" }); assert.equal(state.mode, "detail"); assert.equal(state.tab, "running");
  state = sidebarReducer(state, { type: "enter" }); assert.equal(state.mode, "detail");
});
test("leaving the window union closes unless pinned, while close and disable clear pin", () => {
  let state = sidebarReducer(initialSidebarState, { type: "open", tab: "quota" });
  assert.equal(sidebarReducer(state, { type: "leave" }).mode, "rest");
  state = sidebarReducer(state, { type: "pin" });
  assert.equal(sidebarReducer(state, { type: "leave" }).mode, "detail");
  assert.deepEqual(sidebarReducer(state, { type: "disable" }), initialSidebarState);
  assert.equal(sidebarReducer(state, { type: "close" }).pinned, false);
});
test("invalid wire actions cannot open a detail or corrupt reducer state", () => {
  for (const action of [null, 1, {}, { type: "open", tab: "injected" }, { type: "delete" }]) assert.equal(isSidebarAction(action), false);
  assert.equal(isSidebarAction({ type: "open", tab: "quota" }), true);
  assert.equal(sidebarReducer(initialSidebarState, { type: "invalid" }), initialSidebarState);
});
test("unknown quota remains unknown, including NaN and a stale nonmeasured value", () => {
  assert.equal(quotaPercent("unavailable", 89), null); assert.equal(quotaPercent("absent", 100), null);
  assert.equal(quotaPercent("measured", NaN), null); assert.equal(quotaPercent("measured", null), null);
  assert.equal(quotaPercent("measured", 0), 0); assert.equal(quotaPercent("measured", 103), 100);
});
test("frame updates share one queue across rapid renders and coalesce to the latest intent", async () => {
  const calls = []; const releases = [];
  const queue = createSidebarNativeCoordinator(mode => { calls.push(mode); return new Promise(resolve => releases.push(resolve)); }, () => {});
  queue.setEnabled(true); queue.update("hover"); queue.update("detail");
  assert.deepEqual(calls, ["rest"]);
  releases.shift()(); await tick(); assert.deepEqual(calls, ["rest", "detail"]);
  queue.update("rest"); releases.shift()(); await tick(); assert.deepEqual(calls, ["rest", "detail", "rest"]);
  releases.shift()(); await tick(); queue.setEnabled(false);
});
test("disable invalidates in-flight reports and cancels queued reopen", async () => {
  let reject; const calls = []; const reports = [];
  const queue = createSidebarNativeCoordinator(mode => { calls.push(mode); return new Promise((_, fail) => { reject = fail; }); }, error => reports.push(error));
  queue.setEnabled(true); queue.update("detail"); queue.setEnabled(false);
  reject(new Error("late")); await tick();
  assert.deepEqual(calls, ["rest"]); assert.deepEqual(reports, []);
});
test("reenable drains behind an older command, preserving the new epoch", async () => {
  const calls = []; const releases = []; const reports = [];
  const queue = createSidebarNativeCoordinator(mode => { calls.push(mode); return new Promise(resolve => releases.push(resolve)); }, error => reports.push(error));
  queue.setEnabled(true); queue.setEnabled(false); queue.update("hover"); queue.setEnabled(true);
  assert.deepEqual(calls, ["rest"]); releases.shift()(); await tick();
  assert.deepEqual(calls, ["rest", "hover"]); assert.deepEqual(reports, []);
  releases.shift()(); await tick(); assert.deepEqual(reports, [null]); queue.setEnabled(false);
});

test("5h presence changes share the pending mode queue without resetting detail or pin", async () => {
  const calls = []; const releases = [];
  const queue = createSidebarNativeCoordinator((mode, showsFiveHour) => {
    calls.push({ mode, showsFiveHour }); return new Promise(resolve => releases.push(resolve));
  }, () => {});
  let state = sidebarReducer(initialSidebarState, { type: "open", tab: "running" });
  state = sidebarReducer(state, { type: "pin" });
  queue.update(state.mode, true); queue.setEnabled(true);
  queue.update(state.mode, false); queue.update(state.mode, true); queue.update(state.mode, false);
  assert.deepEqual(calls, [{ mode: "detail", showsFiveHour: true }]);
  releases.shift()(); await tick();
  assert.deepEqual(calls, [{ mode: "detail", showsFiveHour: true }, { mode: "detail", showsFiveHour: false }]);
  assert.deepEqual(state, { mode: "detail", tab: "running", pinned: true });
  releases.shift()(); await tick(); queue.setEnabled(false);
});

test("summary pin keeps the second level open without opening details", () => {
  let state = sidebarReducer(initialSidebarState, { type: "enter" });
  state = sidebarReducer(state, { type: "pin" });
  assert.equal(state.pinned, true);
  assert.equal(sidebarReducer(state, { type: "leave" }).mode, "hover");
  state = sidebarReducer(state, { type: "pin" });
  assert.equal(sidebarReducer(state, { type: "leave" }).mode, "rest");
});

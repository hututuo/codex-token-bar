import assert from "node:assert/strict";
import test from "node:test";
import { createFloatingEdgeDockController, resolveDockAnchor } from "./floatingEdgeDock.ts";

const area = { x: 0, y: 24, width: 1200, height: 800 };
const geometry = (frame, scaleFactor = 1, workArea = area) => ({ frame, scaleFactor, workArea });
for (const [edge, frame] of [
  ["left", { x: 10, y: 150, width: 300, height: 120 }],
  ["right", { x: 890, y: 150, width: 300, height: 120 }],
  ["top", { x: 400, y: 30, width: 300, height: 120 }],
  ["bottom", { x: 400, y: 695, width: 300, height: 120 }],
]) {
  test(`${edge} snaps to the work area and retains only a twelve-point quota handle`, () => {
    const anchor = resolveDockAnchor(geometry(frame));
    assert.equal(anchor.edge, edge);
    assert.equal(edge === "left" || edge === "right" ? anchor.lip.width : anchor.lip.height, 12);
    assert.ok(anchor.lip.x >= anchor.frame.x && anchor.lip.y >= anchor.frame.y);
    assert.ok(anchor.lip.x + anchor.lip.width <= anchor.frame.x + anchor.frame.width);
    assert.ok(anchor.lip.y + anchor.lip.height <= anchor.frame.y + anchor.frame.height);
  });
}

test("negative monitors, Retina scaling, corners and invalid geometry", () => {
  const anchor = resolveDockAnchor(geometry({ x: -1980, y: 200, width: 600, height: 240 }, 2,
    { x: -2000, y: 0, width: 2000, height: 1600 }));
  assert.equal(anchor.edge, "left");
  assert.equal(anchor.frame.x, -2000);
  assert.equal(anchor.lip.width, 24);
  assert.equal(resolveDockAnchor(geometry({ x: 70, y: 150, width: 300, height: 120 })), null);
  assert.equal(resolveDockAnchor(geometry({ x: NaN, y: 24, width: 300, height: 120 })), null);
  assert.equal(resolveDockAnchor(geometry({ x: 0, y: 24, width: 1300, height: 120 })), null);
  assert.equal(resolveDockAnchor(geometry({ x: 0, y: 24, width: 300, height: 120 })).edge, "left");
});

async function drain() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
function fixture(options = {}) {
  let now = 0, next = 0;
  const timers = new Map();
  let current = geometry({ x: 8, y: 150, width: 300, height: 120 });
  let pointer = { x: 500, y: 500, leftButtonDown: false };
  const frames = [], saved = [], states = [], errors = [];
  let reads = 0;
  let reducedMotion = false;
  let onFrame = null;
  const prepared = [];
  const dock = createFloatingEdgeDockController({
    geometry: async () => current,
    pointer: async () => { reads++; return pointer; },
    frame: async (frame) => { frames.push(frame); current = { ...current, frame }; onFrame?.(); },
    persist: (position) => saved.push(position),
    present: (state) => states.push(state), reducedMotion: () => reducedMotion,
    startDrag: options.startDrag ?? (async () => true),
    prepareReveal: async () => { prepared.push({ ...dock.state() }); await options.prepareReveal?.(); },
    prepareCompact: options.prepareCompact,
    report: (error) => errors.push(error),
    timer: (callback, delay) => { const id = ++next; timers.set(id, { at: now + delay, callback }); return id; },
    cancelTimer: (id) => timers.delete(id),
  });
  async function advance(ms) {
    const end = now + ms;
    for (;;) {
      await drain();
      const first = [...timers].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!first) break;
      now = first[1].at; timers.delete(first[0]); first[1].callback();
    }
    now = end; await drain();
  }
  return { dock, advance, frames, saved, states, errors, timers, prepared,
    pointer: (value) => { pointer = value; }, reads: () => reads,
    reduceMotion: (value) => { reducedMotion = value; },
    geometry: (value) => { current = value; }, onFrame: (callback) => { onFrame = callback; } };
}

test("idle dock collapses native bounds; hover restores full size; no idle polling or animation-position saves", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(350);
  assert.equal(f.dock.state().anchor.edge, "left");
  assert.equal(f.saved.length, 1);
  await f.advance(450);
  assert.equal(f.dock.state().collapsed, true);
  assert.equal(f.frames.at(-1).width, 300);
  await f.advance(340);
  assert.equal(f.dock.state().compact, true);
  assert.equal(f.frames.at(-1).width, 12);
  const reads = f.reads(); await f.advance(60_000);
  assert.equal(f.reads(), reads); assert.equal(f.timers.size, 0);
  f.pointer({ x: 2, y: 210, leftButtonDown: false }); f.dock.hover(true);
  await f.advance(120);
  assert.equal(f.dock.state().collapsed, false);
  assert.equal(f.dock.state().compact, false);
  assert.equal(f.frames.at(-1).width, 300);
  assert.equal(f.saved.length, 1);
  assert.deepEqual(f.errors, []);
});

test("re-enter during collapse cancels the stale native shrink", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(800);
  assert.equal(f.dock.state().collapsed, true);
  f.pointer({ x: 2, y: 210, leftButtonDown: false }); f.dock.hover(true);
  await f.advance(1000);
  assert.equal(f.dock.state().collapsed, false);
  assert.equal(f.frames.some((frame) => frame.width === 12), false);
});

test("native resize hover events cannot cancel the compact-window settlement", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(350);
  f.onFrame(() => f.dock.hover(false));
  await f.advance(1000);
  assert.equal(f.dock.state().compact, true);
  assert.equal(f.frames.at(-1).width, 12);
});

test("details suspend restores the normal frame and does not hide until released", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(1200);
  await f.dock.suspend(true);
  assert.equal(f.frames.at(-1).width, 300);
  assert.equal(f.dock.state().anchor, null);
  await f.advance(10_000); assert.equal(f.timers.size, 0);
  await f.dock.suspend(false); await f.advance(100);
  assert.equal(f.dock.state().anchor.edge, "left");
});

test("native drag waits for mouse release even after startDragging resolves", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(350);
  f.pointer({ x: 40, y: 200, leftButtonDown: true });
  await f.dock.startDrag(); await f.advance(600);
  assert.equal(f.dock.state().anchor, null);
  f.pointer({ x: 40, y: 200, leftButtonDown: false }); await f.advance(60);
  assert.equal(f.dock.state().anchor.edge, "left");
});

test("failed drag preparation restores docking without waiting for a nonexistent mouse-up", async () => {
  let nativeDrags = 0;
  const f = fixture({ startDrag: async () => { nativeDrags++; return true; } });
  f.dock.initialize(); await f.advance(350);
  let failed = false;
  f.onFrame(() => { if (!failed) { failed = true; throw new Error("detach failed"); } });
  await assert.rejects(f.dock.startDrag(), /detach failed/);
  assert.equal(nativeDrags, 0);
  await f.advance(100);
  assert.equal(f.dock.state().anchor?.edge, "left");
  await f.advance(1000);
  assert.equal(f.dock.state().compact, true);
  assert.equal(f.timers.size, 0);
  f.dock.dispose();
});

test("a declined native drag and a disposed preparation release drag ownership", async () => {
  const f = fixture({ startDrag: async () => false });
  f.dock.initialize(); await f.advance(350);
  await f.dock.startDrag(); await f.advance(100);
  assert.equal(f.dock.state().anchor?.edge, "left");
  f.onFrame(() => { f.dock.dispose(); throw new Error("window closed"); });
  await assert.rejects(f.dock.startDrag(), /window closed/);
  assert.equal(f.timers.size, 0);
});

test("native drag failure releases ownership and re-enabling after an in-flight drag still docks", async () => {
  const failed = fixture({ startDrag: async () => { throw new Error("native drag failed"); } });
  failed.dock.initialize(); await failed.advance(350);
  await assert.rejects(failed.dock.startDrag(), /native drag failed/);
  await failed.advance(1100);
  assert.equal(failed.dock.state().compact, true);
  failed.dock.dispose();

  let finish;
  const f = fixture({ startDrag: () => new Promise(resolve => { finish = resolve; }) });
  f.dock.initialize(); await f.advance(350);
  const drag = f.dock.startDrag(); await drain();
  await f.dock.suspend(true);
  finish(false); await drag;
  assert.equal(f.timers.size, 0);
  await f.dock.suspend(false); await f.advance(1100);
  assert.equal(f.dock.state().compact, true);
  f.dock.dispose();
});

test("monitor changes restore and clamp the full frame in the new work area", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(1200);
  f.geometry(geometry({ x: -1000, y: 350, width: 6, height: 72 }, 2,
    { x: -1200, y: 0, width: 1200, height: 1000 }));
  f.dock.moved(); await f.advance(120);
  const anchor = f.dock.state().anchor;
  assert.equal(anchor.frame.width, 600);
  assert.equal(anchor.frame.x, -1200);
  assert.equal(anchor.lip.width, 24);
});

test("dispose cancels timers and late geometry completion", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(350);
  f.dock.dispose(); const count = f.states.length; await f.advance(5000);
  assert.equal(f.states.length, count); assert.equal(f.timers.size, 0);
  assert.equal(f.frames.length, 1);
});

test("failed native collapse restores full bounds instead of leaving an invisible hit region", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(350);
  let fail = true;
  f.onFrame(() => { if (fail) { fail = false; throw new Error("position write failed"); } });
  await f.advance(1000);
  assert.equal(f.frames.at(-1).width, 300);
  assert.equal(f.dock.state().anchor, null);
  assert.equal(f.errors.length, 1);
});

test("late geometry reads cannot attach after suspension", async () => {
  const f = fixture();
  let finish;
  f.geometry(new Promise((resolve) => { finish = resolve; }));
  f.dock.initialize(); await f.advance(350);
  await f.dock.suspend(true);
  finish(geometry({ x: 8, y: 150, width: 300, height: 120 }));
  await f.advance(1000);
  assert.equal(f.dock.state().anchor, null);
  assert.equal(f.frames.length, 0);
});

test("reduced motion skips animation settlement delay", async () => {
  const f = fixture(); f.reduceMotion(true); f.dock.initialize(); await f.advance(800);
  assert.equal(f.dock.state().compact, true);
  assert.equal(f.dock.state().motion, "none");
  assert.equal(f.frames.at(-1).width, 12);
});

test("reveal rechecks display bounds even if a monitor-change event was missed", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(1200);
  f.geometry(geometry({ x: -1200, y: 100, width: 12, height: 144 }, 2,
    { x: -1200, y: 0, width: 1200, height: 1000 }));
  f.pointer({ x: -1198, y: 150, leftButtonDown: false }); f.dock.hover(true);
  await f.advance(400);
  assert.equal(f.frames.at(-1).x, -1200);
  assert.equal(f.frames.at(-1).width, 600);
  assert.equal(f.dock.state().compact, false);
});


test("near edges and partial overshoot attach; vertical quota rail retains full height", () => {
  for (const x of [36, -90, 864, 990]) {
    const anchor = resolveDockAnchor(geometry({ x, y: 150, width: 300, height: 120 }));
    assert.ok(anchor);
    assert.equal(anchor.lip.height, 120);
    assert.equal(anchor.lip.width, 12);
    assert.ok(anchor.frame.x >= 0 && anchor.frame.x + anchor.frame.width <= 1200);
  }
  assert.equal(resolveDockAnchor(geometry({ x: 1201, y: 150, width: 300, height: 120 })), null);
});

test("native hover reveals an inactive window immediately with no debounce timer", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(1200);
  f.pointer({ x: 2, y: 210, leftButtonDown: false });
  f.dock.hover(true); await drain();
  assert.equal(f.dock.state().compact, false);
  assert.equal(f.dock.state().collapsed, false);
  assert.equal(f.timers.size, 0);
  f.pointer({ x: 500, y: 500, leftButtonDown: false }); f.dock.hover(false);
  await f.advance(1000);
  assert.equal(f.dock.state().compact, true);
  f.pointer({ x: 2, y: 210, leftButtonDown: false }); f.dock.hover(true); await drain();
  assert.equal(f.dock.state().collapsed, false);
});


test("expanded native viewport resolves the collapsed visual before beginning reveal", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(1200);
  f.pointer({ x: 2, y: 210, leftButtonDown: false }); f.dock.hover(true); await drain();
  assert.equal(f.prepared.length, 1);
  assert.equal(f.prepared[0].compact, false);
  assert.equal(f.prepared[0].collapsed, true);
  assert.equal(f.dock.state().collapsed, false);
});

test("duplicate pointer exits cannot restart an in-flight collapse", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(820);
  assert.equal(f.dock.state().collapsed, true);
  for (let i = 0; i < 5; i++) { f.dock.hover(false); await f.advance(70); }
  assert.equal(f.dock.state().compact, true);
});


test("native expansion keeps quota visible until the shell is ready to grow", async () => {
  let viewport;
  const f = fixture({ prepareReveal: () => new Promise(resolve => { viewport = resolve; }) });
  f.dock.initialize(); await f.advance(1200);
  f.pointer({ x: 2, y: 210, leftButtonDown: false }); f.dock.hover(true); await drain();
  f.dock.hover(true); await drain();
  assert.equal(f.frames.at(-1).width, 300);
  assert.equal(f.dock.state().collapsed, true);
  assert.equal(f.dock.state().railReady, true);
  viewport(); await drain();
  assert.equal(f.dock.state().collapsed, false);
  assert.equal(f.dock.state().railReady, false);
  assert.equal(f.dock.state().motion, "expand");
});

test("native reveal rechecks the real pointer after transient DOM leave noise", async () => {
  const f = fixture();
  f.dock.initialize();
  await f.advance(1200);
  assert.equal(f.dock.state().compact, true);
  f.pointer({ x: 2, y: 210, leftButtonDown: false });
  f.onFrame(() => f.dock.hover(false));
  f.dock.hover(true);
  await drain();
  assert.equal(f.dock.state().collapsed, false);
  assert.equal(f.dock.state().compact, false);
  await f.advance(700);
  assert.equal(f.dock.state().collapsed, false);
});

test("cancelled viewport preparation cannot revive a suspended dock", async () => {
  let viewport;
  const f = fixture({ prepareReveal: () => new Promise(resolve => { viewport = resolve; }) });
  f.dock.initialize(); await f.advance(1200);
  f.dock.hover(true); await drain();
  await f.dock.suspend(true);
  const count = f.frames.length;
  viewport(); await drain();
  assert.equal(f.dock.state().anchor, null);
  assert.equal(f.frames.length, count);
});

test("failed viewport preparation restores a usable full window", async () => {
  const f = fixture({ prepareReveal: async () => { throw new Error("viewport timeout"); } });
  f.dock.initialize(); await f.advance(1200);
  f.dock.hover(true); await drain(); await drain();
  assert.equal(f.frames.at(-1).width, 300);
  assert.equal(f.dock.state().anchor, null);
  assert.equal(f.errors.length, 1);
});


test("quota fades in only after the compact viewport is ready", async () => {
  let ready;
  const f = fixture({ prepareCompact: () => new Promise(resolve => { ready = resolve; }) });
  f.dock.initialize(); await f.advance(800);
  assert.equal(f.dock.state().collapsed, true);
  assert.equal(f.dock.state().railReady, false);
  await f.advance(170);
  assert.equal(f.frames.at(-1).width, 12);
  assert.equal(f.dock.state().compact, true);
  assert.equal(f.dock.state().railReady, false);
  ready(); await drain();
  assert.equal(f.dock.state().railReady, true);
  assert.deepEqual(f.errors, []);
});

test("hover during compact paint cancels stale quota visibility", async () => {
  let ready;
  const f = fixture({ prepareCompact: () => new Promise(resolve => { ready = resolve; }) });
  f.dock.initialize(); await f.advance(970);
  f.pointer({ x: 2, y: 210, leftButtonDown: false }); f.dock.hover(true);
  await drain(); ready(); await drain();
  assert.equal(f.dock.state().collapsed, false);
  assert.equal(f.dock.state().railReady, false);
  assert.equal(f.frames.at(-1).width, 300);
});

test("compact viewport failure restores the full usable window", async () => {
  const f = fixture({ prepareCompact: async () => { throw new Error("viewport timeout"); } });
  f.dock.initialize(); await f.advance(970);
  assert.equal(f.dock.state().anchor, null);
  assert.equal(f.frames.at(-1).width, 300);
  assert.equal(f.errors.length, 1);
});

test("enter delivered during native shrink resumes reveal after frame completion", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(800);
  f.pointer({ x: 2, y: 210, leftButtonDown: false });
  f.onFrame(() => f.dock.hover(true));
  await f.advance(170);
  assert.equal(f.dock.state().compact, false);
  assert.equal(f.dock.state().collapsed, false);
  assert.equal(f.dock.state().railReady, false);
  assert.equal(f.frames.at(-1).width, 300);
});

test("details resize preserves the dock shell and cannot auto-collapse while held open", async () => {
  const f = fixture(); f.dock.initialize(); await f.advance(350);
  const original = f.dock.state().anchor.frame;
  await f.dock.holdOpen(true);
  await f.dock.beforeResize();
  assert.equal(f.dock.state().anchor.edge, "left");
  f.geometry(geometry({ ...original, height: 320 }));
  f.dock.afterResize(); await drain();
  assert.equal(f.dock.state().anchor.frame.height, 320);
  f.dock.hover(false); await f.advance(5000);
  assert.equal(f.dock.state().collapsed, false);
  assert.equal(f.states.some(state => !state.anchor), false);
  assert.equal(f.saved.length, 1);
  await f.dock.beforeResize(); f.geometry(geometry(original)); f.dock.afterResize(); await drain();
  await f.dock.holdOpen(false); await f.advance(700);
  assert.equal(f.dock.state().compact, true);
  assert.deepEqual(f.dock.state().anchor.frame, original);
  assert.equal(f.saved.length, 1);
});

test("a free-window drawer reaching the edge does not acquire a new dock", async () => {
  const f = fixture(); await f.dock.holdOpen(true);
  f.dock.initialize(); await f.advance(5000);
  assert.equal(f.dock.state().anchor, null);
  assert.equal(f.frames.length, 0);
});

test("real-window rehearsal reuses docking, isolates the real pointer, and never saves demo positions", async () => {
  const f = fixture();
  f.pointer({ x: 900, y: 600, leftButtonDown: true });
  await f.dock.beginGuide({ x: 100, y: 180 });
  await f.dock.guideBeginDrag();
  await f.dock.guideEndDrag();
  assert.equal(f.dock.state().anchor.edge, "left");
  assert.equal(f.reads(), 0);
  assert.equal(f.saved.length, 0);
  f.dock.guideHover({ x: 500, y: 500 });
  await f.advance(900);
  assert.equal(f.dock.state().compact, true);
  f.dock.hover(true);
  await f.advance(100);
  assert.equal(f.dock.state().compact, true, "real mouse events must not advance the rehearsal");
  f.dock.guideHover({ x: 6, y: 200 });
  await f.advance(200);
  assert.equal(f.dock.state().collapsed, false);
  await f.dock.guideBeginDrag();
  f.geometry(geometry({ x: 250, y: 180, width: 300, height: 120 }));
  await f.dock.guideEndDrag();
  assert.equal(f.dock.state().anchor, null);
  assert.equal(f.saved.length, 0);
  f.dock.endGuide();
  assert.equal(f.dock.isGuiding(), false);
  assert.deepEqual(f.errors, []);
});
